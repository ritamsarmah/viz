package main

import "base:runtime"
import "core:c"
import "core:math"
import "core:math/cmplx"
import sdl "vendor:sdl3"

/* Globals */

APP_NAME :: "viz"

WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 800

// Audio stream API returns bytes and must be converted to f32 (4 bytes)
AUDIO_BUFFER_LEN :: 1024
AUDIO_BUFFER_LEN_BYTES: i32 = AUDIO_BUFFER_LEN * size_of(f32)
SAMPLE_RATE :: 44100
NOISE_FLOOR_DB :: -80

SMOOTHING_FACTOR :: 0.2 // between 0.1 and 0.3; lower value means higher smoothing

low_bin := max(frequency_bin(20), 1) // Exclude DC (bin 0)
mid_bin := frequency_bin(250)
high_bin := frequency_bin(4000)

window: ^sdl.Window
renderer: ^sdl.Renderer
audio_spec := sdl.AudioSpec {
	format   = .F32,
	channels = 1,
	freq     = SAMPLE_RATE,
}

AppState :: struct {
	audio:      struct {
		stream:      ^sdl.AudioStream,
		real_buffer: [AUDIO_BUFFER_LEN]f32,
		fft_buffer:  [AUDIO_BUFFER_LEN]complex64,
		bands:       [3]f32,
	},
	visualizer: struct{},
}

/* Functions */

main :: proc() {
	sdl.EnterAppMainCallbacks(0, nil, app_init, app_iterate, app_event, app_quit)
}

app_init :: proc "c" (appstate: ^rawptr, argc: c.int, argv: [^]cstring) -> sdl.AppResult {
	context = runtime.default_context()

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
	context = runtime.default_context()
	state := cast(^AppState)appstate

	/* Audio Processing */
	{
		using state.audio

		if sdl.GetAudioStreamAvailable(stream) >= AUDIO_BUFFER_LEN * size_of(f32) {
			byte_count := sdl.GetAudioStreamData(
				stream,
				&real_buffer,
				AUDIO_BUFFER_LEN * size_of(f32),
			)

			N := byte_count / size_of(f32) // sample count
			mean := math.sum(real_buffer[:N]) / f32(N)

			for i in 0 ..< N {
				// Subtract mean to remove DC bias
				real_buffer[i] -= mean

				// Apply Hann window to reduce spectral leakage
				real_buffer[i] *= 0.5 * (1 - math.cos(2 * math.PI * f32(i) / f32(N - 1)))

				// Implicit conversion from f32 to complex64
				fft_buffer[i] = real_buffer[i]
			}

			fft(fft_buffer[:N])

			// Nyquist frequency means valid bins are only 0 to n/2
			bins := fft_buffer[:(N / 2) + 1]

			// Calculate magnitudes, reusing real data buffer
			magnitudes := real_buffer[:]
			for bin, i in bins {
				real := cmplx.real(bin)
				imag := cmplx.imag(bin)
				magnitudes[i] = math.sqrt(real * real + imag * imag)
			}

			// Aggregate energy per band
			low := rms(magnitudes[low_bin:mid_bin])
			mid := rms(magnitudes[mid_bin:high_bin])
			high := rms(magnitudes[high_bin:])

			// Log scaling with small epsilon to avoid log(0)
			low = 20 * math.log10(low + 1e-12)
			mid = 20 * math.log10(mid + 1e-12)
			high = 20 * math.log10(high + 1e-12)

			// Noise floor suppression
			if low < NOISE_FLOOR_DB do low = NOISE_FLOOR_DB
			if mid < NOISE_FLOOR_DB do mid = NOISE_FLOOR_DB
			if high < NOISE_FLOOR_DB do high = NOISE_FLOOR_DB

			// Temporal smoothing
			bands[0] = bands[0] * (1 - SMOOTHING_FACTOR) + low * SMOOTHING_FACTOR
			bands[1] = bands[1] * (1 - SMOOTHING_FACTOR) + mid * SMOOTHING_FACTOR
			bands[2] = bands[2] * (1 - SMOOTHING_FACTOR) + high * SMOOTHING_FACTOR
		}
	}

	/* Visualizer */
	{
		using state.visualizer

		sdl.RenderClear(renderer)
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

bit_reverse :: proc(x: int, bits: int) -> int {
	x := x
	y := 0

	for i in 0 ..< bits {
		y = (y << 1) | (x & 1)
		x >>= 1
	}

	return y
}

bit_reversal_permutation :: proc(data: []$T) {
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
fft :: proc(data: []complex64) {
	n := len(data)
	if n <= 1 do return

	assert(n & (n - 1) == 0, "Length must be a power of 2")

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

frequency_bin :: proc "contextless" (hz: int) -> int {
	return int(math.floor(f32(hz * AUDIO_BUFFER_LEN) / f32(SAMPLE_RATE)))
}

rms :: proc "contextless" (values: []f32) -> f32 {
	sum: f32 = 0
	for value in values {
		sum += value * value
	}

	return math.sqrt(sum / f32(len(values)))
}
