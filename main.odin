package main

import "core:c"
import "core:math"
import "core:math/cmplx"
import sdl "vendor:sdl3"

/* Globals */

APP_NAME :: "viz"

WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 800
WINDOW_CENTER_X :: f32(WINDOW_WIDTH) / 2
WINDOW_CENTER_Y :: f32(WINDOW_HEIGHT) / 2

SAMPLE_RATE :: 44100
NUM_SAMPLES :: 1024 // must be power of 2 for FFT
NUM_SAMPLE_BYTES :: NUM_SAMPLES * size_of(f32)
NUM_BINS :: (NUM_SAMPLES / 2) + 1 // Based on Nyquist frequency

LOW_CUTOFF :: 16
HIGH_CUTOFF :: NUM_BINS - 256
NUM_BANDS :: HIGH_CUTOFF - LOW_CUTOFF

AUDIO_SMOOTHING :: 0.8
SILENCE_THRESHOLD: f32 = 1e-4
MIN_DB :: -80.0
MAX_DB :: 0.0
INVERSE_RANGE :: 1.0 / (MAX_DB - MIN_DB)

MIN_RADIUS :: 16.0
MAX_RADIUS :: 256.0
VISUAL_SMOOTHING :: 0.7
COLOR_CHANGE_RATE :: 0.2

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
		bands:      [NUM_BANDS]f32,
	},
	visualizer: struct {
		magnitudes: [NUM_BANDS]f32,
		points:     [NUM_BANDS * 2]sdl.FPoint,
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

			for value, i in fft_buffer[LOW_CUTOFF:HIGH_CUTOFF] {
				real := cmplx.real(value)
				imag := cmplx.imag(value)
				magnitude := math.sqrt(real * real + imag * imag)
				power := 20 * math.log10(magnitude + 1e-6)

				// Normalize to 0–1 range based on expected dB limits
				power = (power - MIN_DB) * INVERSE_RANGE
				power = math.clamp(power, 0, 1)

				// Map spectrum bins to visual bands with smoothing
				bands[i] = AUDIO_SMOOTHING * bands[i] + (1 - AUDIO_SMOOTHING) * power
			}
		}
	}

	/* Visualizer */
	{
		using state.visualizer

		sdl.SetRenderDrawColor(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
		sdl.RenderClear(renderer)

		for band, i in state.audio.bands {
			point := &points[i]
			mirror := &points[len(points) - i - 1]

			magnitudes[i] =
				VISUAL_SMOOTHING * magnitudes[i] + (1 - VISUAL_SMOOTHING) * band * MAX_RADIUS
			angle := f32(i) * math.PI / len(state.audio.bands)

			point.x = WINDOW_CENTER_X + math.sin(angle) * (MIN_RADIUS + magnitudes[i])
			point.y = WINDOW_CENTER_Y + math.cos(angle) * (MIN_RADIUS + magnitudes[i])

			mirror.x = 2 * WINDOW_CENTER_X - point.x
			mirror.y = point.y
		}

		now := f64(sdl.GetTicks()) / 1000 * COLOR_CHANGE_RATE
		r := f32(0.5 + 0.5 * math.sin(now))
		g := f32(0.5 + 0.5 * math.sin(now + math.PI * 2 / 3))
		b := f32(0.5 + 0.5 * math.sin(now + math.PI * 4 / 3))
		sdl.SetRenderDrawColorFloat(renderer, r, g, b, sdl.ALPHA_OPAQUE_FLOAT)

		sdl.RenderLines(renderer, raw_data(points[:]), len(points))
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

rms :: proc "contextless" (values: []f32) -> f32 {
	sum: f32 = 0
	for value in values {
		sum += value * value
	}

	return math.sqrt(sum / f32(len(values)))
}
