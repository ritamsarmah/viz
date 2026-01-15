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

AUDIO_BUFFER_LEN :: 1024

window: ^sdl.Window
renderer: ^sdl.Renderer
audio_spec := sdl.AudioSpec {
	format   = .S16,
	channels = 1,
	freq     = 44100,
}


AppState :: struct {
	background:   sdl.FColor,
	audio_stream: ^sdl.AudioStream,
	audio_buffer: [AUDIO_BUFFER_LEN]i16,
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
	state.background = {0, 0, 0, sdl.ALPHA_OPAQUE_FLOAT}

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

	state.audio_stream = sdl.OpenAudioDeviceStream(
		sdl.AUDIO_DEVICE_DEFAULT_RECORDING,
		&audio_spec,
		nil,
		nil,
	)

	// Device starts paused, so must be manually started
	sdl.ResumeAudioStreamDevice(state.audio_stream)

	return .CONTINUE
}

app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = runtime.default_context()
	state := cast(^AppState)appstate

	// bytes_read := sdl.GetAudioStreamData(
	// 	state.audio_stream,
	// 	&state.audio_buffer,
	// 	len(state.audio_buffer),
	// )

	// if bytes_read < 0 {
	// 	sdl.Log("Failed to read bytes from capture device: %s", sdl.GetError())
	// 	return .FAILURE
	// }

	// sdl.Log("%d", bytes_read)

	{
		using state

		now := f64(sdl.GetTicks()) / 1000

		background.r = f32(0.5 + 0.5 * sdl.sin(now))
		background.g = f32(0.5 + 0.5 * sdl.sin(now + math.PI * 2 / 3))
		background.b = f32(0.5 + 0.5 * sdl.sin(now + math.PI * 4 / 3))
		background.a = sdl.ALPHA_OPAQUE_FLOAT

		sdl.SetRenderDrawColorFloat(
			renderer,
			background.r,
			background.b,
			background.g,
			background.a,
		)
	}

	sdl.RenderClear(renderer)
	sdl.RenderPresent(renderer)

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

	sdl.DestroyAudioStream(state.audio_stream)
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

bit_reversal_permutation :: proc(data: []f32) {
	n := len(data)

	// Compute bit length of data length
	bits := 0; for tmp := n; tmp > 1; tmp >>= 1 do bits += 1

	for i in 0 ..< n {
		j := bit_reverse(i, bits)
		if j > i do data[i], data[j] = data[j], data[i]
	}
}

/// In-place radix-2 Cooley-Tukey FFT (NOTE: Data length must be a power of 2)
/// https://en.wikipedia.org/wiki/Cooley%E2%80%93Tukey_FFT_algorithm
fft :: proc(data: []complex64) {
}
// 	n := len(data)

// 	if n <= 1 do return

// 	// Compute bit length of n
// 	bits := 0; for tmp := n; tmp > 1; tmp >>= 1 do bits += 1

// 	// Bit-reversal permutation
// 	for i in 0 ..< n {
// 		j := bit_reverse(i, bits)
// 		if j > i do data[i], data[j] = data[j], data[i]
// 	}

// 	// Iterative FFT
// 	for s in 1 ..< math.log2(f32(n)) {
// 		m := math.pow(2, s)
// 		omega_m := math.exp(f32(-2) * math.PI * i / m)
// 		for k: f32 = 0; k < f32(n); k += m {
// 			omega: f32 = 1
// 			for j in 0 ..< (m / 2 - 1) {
// 				index_t := int(k + j + m / 2)
// 				index_u := int(k + j)

// 				t := omega * data[index_t]
// 				u := data[index_u]
// 				data[index_u] = u + t
// 				data[index_t] = u - t
// 				omega *= omega_m
// 			}
// 		}
// 	}
// }
