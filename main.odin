package main

import "core:c"
import "core:math"
import "core:math/cmplx"
import sdl "vendor:sdl3"

/* Globals */

APP_NAME :: "viz"

WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 800

SAMPLE_RATE :: 44100
NUM_SAMPLES :: 1024 // must be power of 2 for FFT
NUM_SAMPLE_BYTES :: NUM_SAMPLES * size_of(f32)
NUM_BINS :: (NUM_SAMPLES / 2) + 1 // Based on Nyquist frequency

LOG_MIN :: -80.0
LOG_MAX :: 0.0
INVERSE_RANGE :: 1.0 / (LOG_MAX - LOG_MIN)

BAR_WIDTH :: 1.0
SMOOTHING_FACTOR :: 0.85

// band_indices := [NUM_BANDS + 1]int {
// 	frequency_bin(20), // sub-bass (omitting DC bin)
// 	frequency_bin(50), // mid-bass
// 	frequency_bin(100), // upper bass
// 	frequency_bin(250), // lower mids
// 	frequency_bin(500), // mids
// 	frequency_bin(2000), // upper mids
// 	frequency_bin(4000), // lower treble
// 	frequency_bin(6000), // mid treble
// 	frequency_bin(10000), // upper treble
// 	frequency_bin(20000), // treble cutoff
// }

window: ^sdl.Window
renderer: ^sdl.Renderer
audio_spec := sdl.AudioSpec {
	format   = .F32,
	channels = 1,
	freq     = SAMPLE_RATE,
}

AppState :: struct {
	audio:      struct {
		stream:     ^sdl.AudioStream,
		buffer:     [NUM_SAMPLES]f32,
		fft_buffer: [NUM_SAMPLES]complex64,
	},
	visualizer: struct {
		rects: [NUM_BINS]sdl.FRect,
	},
}

/* Functions */

main :: proc() {
	sdl.EnterAppMainCallbacks(0, nil, app_init, app_iterate, app_event, app_quit)
}

app_init :: proc "c" (appstate: ^rawptr, argc: c.int, argv: [^]cstring) -> sdl.AppResult {
	sdl.Log("Initializing %s...\n", APP_NAME)
	if ok := sdl.SetAppMetadata(APP_NAME, "1.0", "me.ritam.viz"); !ok {
		sdl.Log("Failed to set app metadata: %s", sdl.GetError())
		return .FAILURE
	}

	appstate^ = sdl.malloc(size_of(AppState))
	if appstate == nil {
		sdl.Log("Failed to initialize app state\n")
		return .FAILURE
	}

	state := cast(^AppState)appstate^

	// Initialize visualizer rects
	for &rect, i in state.visualizer.rects {
		rect.x = BAR_WIDTH * f32(i)
		rect.y = WINDOW_HEIGHT
		rect.w = BAR_WIDTH
	}

	if ok := sdl.Init({.VIDEO, .AUDIO}); !ok {
		sdl.Log("Failed to initialize SDL: %s\n", sdl.GetError())
		return .FAILURE
	}

	if ok := sdl.CreateWindowAndRenderer(
		APP_NAME,
		WINDOW_WIDTH,
		WINDOW_HEIGHT,
		{.HIGH_PIXEL_DENSITY},
		&window,
		&renderer,
	); !ok {
		sdl.Log("Failed to create window or renderer: %s", sdl.GetError())
		return .FAILURE
	}

	sdl.SetRenderVSync(renderer, 1)
	sdl.SetRenderLogicalPresentation(renderer, WINDOW_WIDTH, WINDOW_HEIGHT, .LETTERBOX)

	state.audio.stream = sdl.OpenAudioDeviceStream(
		sdl.AUDIO_DEVICE_DEFAULT_RECORDING,
		&audio_spec,
		nil,
		nil,
	)

	// Device starts paused, so must be manually started
	sdl.ResumeAudioStreamDevice(state.audio.stream)

	return .CONTINUE
}

app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	state := cast(^AppState)appstate

	/* Audio Processing */
	{
		using state.audio

		if sdl.GetAudioStreamAvailable(stream) >= NUM_SAMPLE_BYTES {
			byte_count := sdl.GetAudioStreamData(stream, &buffer, NUM_SAMPLE_BYTES)
			mean := math.sum(buffer[:]) / NUM_SAMPLES

			// Preprocess samples
			for i in 0 ..< NUM_SAMPLES {
				// Subtract mean to remove DC bias
				buffer[i] -= mean

				// Apply Hann window to reduce spectral leakage
				buffer[i] *= 0.5 * (1 - math.cos(2 * math.PI * f32(i) / f32(NUM_SAMPLES - 1)))

				// Convert to complex number
				fft_buffer[i] = complex(buffer[i], 0)
			}

			fft(fft_buffer[:])

			// Calculate magnitudes (reusing buffer used for original samples)
			magnitudes := buffer[:NUM_BINS]
			for value, i in fft_buffer[:NUM_BINS] {
				real := cmplx.real(value)
				imag := cmplx.imag(value)
				magnitudes[i] = math.sqrt(real * real + imag * imag)
			}

			// for i in 0 ..< len(band_indices) - 1 {
			// 	// Band RMS
			// 	start := band_indices[i]
			// 	end := band_indices[i + 1]
			// 	raw := rms(magnitudes[start:end])

			// 	// Temporal smoothing
			// }


			// Log compression and normalization
			for &magnitude in magnitudes {
				scaled := math.log10(magnitude + 1e-12)
				clamped := math.max(math.min(scaled, LOG_MAX), LOG_MIN)
				raw := (clamped - LOG_MIN) / (LOG_MAX - LOG_MIN)
				magnitude = SMOOTHING_FACTOR * magnitude + (1 - SMOOTHING_FACTOR) * raw
			}
		}
	}

	/* Visualizer */
	{
		using state.visualizer

		sdl.SetRenderDrawColor(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
		sdl.RenderClear(renderer)

		sdl.SetRenderDrawColor(renderer, 0, 255, 0, sdl.ALPHA_OPAQUE)

		for &rect, i in rects {
			rect.h = -state.audio.buffer[i] * f32(WINDOW_HEIGHT)
			sdl.RenderFillRect(renderer, &rect)
		}

		sdl.RenderPresent(renderer)
	}

	return .CONTINUE
}


app_event :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		return .SUCCESS
	}

	return .CONTINUE
}

app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	state := cast(^AppState)appstate

	sdl.Log("Quitting %s with result %d", APP_NAME, result)

	sdl.DestroyAudioStream(state.audio.stream)
	sdl.DestroyRenderer(renderer)
	sdl.DestroyWindow(window)
	sdl.Quit()

	sdl.free(appstate)
}

/* Fast Fourier Transform */

bit_reverse :: proc "contextless" (x: int, bits: int) -> int {
	x := x
	y := 0

	for i in 0 ..< bits {
		y = (y << 1) | (x & 1)
		x >>= 1
	}

	return y
}

bit_reversal_permutation :: proc "contextless" (data: []$T) {
	n := len(data)

	// Compute bit length of data length
	bits := 0; for tmp := n; tmp > 1; tmp >>= 1 do bits += 1

	for i in 0 ..< n {
		j := bit_reverse(i, bits)
		if j > i do data[i], data[j] = data[j], data[i]
	}
}

/// In-place radix-2 Cooley-Tukey FFT
/// https://en.wikipedia.org/wiki/Cooley%E2%80%93Tukey_FFT_algorithm
fft :: proc "contextless" (data: []complex64) {
	n := len(data)
	if n <= 1 do return

	bit_reversal_permutation(data)

	for s in 1 ..= math.log2(f32(n)) {
		m := 1 << uint(s)
		half := m >> 1

		angle := -2 * math.PI / f32(m)
		w_m := cmplx.exp(complex64(angle) * 1i) // mth root of unity

		for k := 0; k < n; k += m {
			w: complex64 = 1

			for j in 0 ..< half {
				t := w * data[k + j + half]
				u := data[k + j]

				data[k + j] = u + t
				data[k + j + half] = u - t

				w *= w_m
			}
		}
	}
}

/* Utilities */

frequency_bin :: proc "contextless" (hz: f32) -> int {
	// Clamped between 1 (omitting DC bin) and max bin
	return clamp(int(math.floor(hz * NUM_SAMPLES / SAMPLE_RATE)), 1, NUM_BINS - 1)
}

rms :: proc "contextless" (values: []f32) -> f32 {
	sum: f32 = 0
	for value in values {
		sum += value * value
	}

	return math.sqrt(sum / f32(len(values)))
}
