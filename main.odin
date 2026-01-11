package main

import "core:c"
import "core:math"
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
	state := cast(^AppState)appstate

	// TODO: Read audio from recording device

	now := f64(sdl.GetTicks()) / 1000
	{
		using state

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

	sdl.Log("Quitting %s after %s...\n", APP_NAME, result == .SUCCESS ? "success" : "failure")

	sdl.DestroyAudioStream(state.audio_stream)
	sdl.DestroyRenderer(renderer)
	sdl.DestroyWindow(window)
	sdl.Quit()

	sdl.free(appstate)
}
