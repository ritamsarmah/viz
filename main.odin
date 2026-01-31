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
HIGH_CUTOFF :: NUM_BINS - 32
NUM_BANDS :: HIGH_CUTOFF - LOW_CUTOFF

AUDIO_SMOOTHING :: 0.85
SILENCE_THRESHOLD: f32 = 1e-4
MIN_DB :: -80.0
MAX_DB :: 0.0
INVERSE_RANGE :: 1.0 / (MAX_DB - MIN_DB)

VISUALIZER_RADIUS: f32 : 20.0
VISUALIZER_ANGLE_STEP :: 2.0 * math.PI / f32(NUM_BANDS)
BAR_WIDTH: f32 : 2
MAX_BAR_HEIGHT: f32 : 256
VIDEO_SMOOTHING :: 0.7

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
		heights: [NUM_BANDS]f32,
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

			// Compute power spectrum
			for value, i in fft_buffer[LOW_CUTOFF:HIGH_CUTOFF] {
				real := cmplx.real(value)
				imag := cmplx.imag(value)
				power := real * real + imag * imag

				// Convert power spectrum to decibels for perceptual scaling
				power = 10.0 * math.log10(power + 1e-6)

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
		bands := state.audio.bands[:]

		sdl.SetRenderDrawColor(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
		sdl.RenderClear(renderer)

		for &height, i in heights {
			height = VIDEO_SMOOTHING * height + (1 - VIDEO_SMOOTHING) * bands[i] * MAX_BAR_HEIGHT
			angle := f32(i) * VISUALIZER_ANGLE_STEP

			// Compute end point for top half
			end_x := WINDOW_CENTER_X + math.sin(angle) * (VISUALIZER_RADIUS + height)
			end_y := WINDOW_CENTER_Y + math.cos(angle) * (VISUALIZER_RADIUS + height)

			// Compute mirrored end point for bottom half
			mirror_x := WINDOW_CENTER_X - math.sin(angle) * (VISUALIZER_RADIUS + height)
			mirror_y := WINDOW_CENTER_Y + math.cos(angle) * (VISUALIZER_RADIUS + height)

			sdl.SetRenderDrawColor(renderer, 255, 0, 0, sdl.ALPHA_OPAQUE)

			sdl.RenderLine(renderer, WINDOW_CENTER_X, WINDOW_CENTER_Y, end_x, end_y)
			sdl.RenderLine(renderer, WINDOW_CENTER_X, WINDOW_CENTER_Y, mirror_x, mirror_y)
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

rms :: proc "contextless" (values: []f32) -> f32 {
	sum: f32 = 0
	for value in values {
		sum += value * value
	}

	return math.sqrt(sum / f32(len(values)))
}
