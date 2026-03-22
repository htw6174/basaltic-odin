/*
Development game exe. Loads build/hot_reload/game.dll and reloads it whenever it
changes.
*/

package main

import sapp "../sokol/app"
import sg "../sokol/gfx"
import sglue "../sokol/glue"
import slog "../sokol/log"
import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:time"

when ODIN_OS == .Windows {
	DLL_EXT :: ".dll"
} else when ODIN_OS == .Darwin {
	DLL_EXT :: ".dylib"
} else {
	DLL_EXT :: ".so"
}

GAME_DLL_DIR :: "build/hot_reload/"
GAME_DLL_PATH :: GAME_DLL_DIR + "game" + DLL_EXT

// We copy the DLL because using it directly would lock it, which would prevent
// the compiler from writing to it.
copy_dll :: proc(to: string) -> bool {
	copy_err := os.copy_file(to, GAME_DLL_PATH)

	if copy_err != nil {
		fmt.printfln("Failed to copy " + GAME_DLL_PATH + " to {0}: %v", to, copy_err)
		return false
	}

	return true
}

Game_API :: struct {
	lib:               dynlib.Library,
	init:              proc(),
	update:            proc(),
	event:             proc(e: ^sapp.Event),
	should_run:        proc() -> bool,
	shutdown:          proc(),
	memory:            proc() -> rawptr,
	memory_size:       proc() -> int,
	hot_reloaded:      proc(mem: rawptr),
	modification_time: time.Time,
	api_version:       int,
}

game_api: Game_API
game_api_version := 0
old_game_apis: [dynamic]Game_API
force_reload, force_restart: bool
tracking_allocator: mem.Tracking_Allocator
tracking_context: runtime.Context

load_game_api :: proc(api_version: int) -> (api: Game_API, ok: bool) {
	mod_time, mod_time_error := os.last_write_time_by_name(GAME_DLL_PATH)
	if mod_time_error != os.ERROR_NONE {
		fmt.printfln(
			"Failed getting last write time of " + GAME_DLL_PATH + ", error code: {1}",
			mod_time_error,
		)
		return
	}

	game_dll_name := fmt.tprintf(GAME_DLL_DIR + "game_{0}" + DLL_EXT, api_version)
	copy_dll(game_dll_name) or_return

	// This proc matches the names of the fields in Game_API to symbols in the
	// game DLL. It actually looks for symbols starting with `game_`, which is
	// why the argument `"game_"` is there.
	_, ok = dynlib.initialize_symbols(&api, game_dll_name, "game_", "lib")
	if !ok {
		fmt.printfln("Failed initializing symbols: {0}", dynlib.last_error())
	}

	api.api_version = api_version
	api.modification_time = mod_time
	ok = true

	return
}

unload_game_api :: proc(api: ^Game_API) {
	if api.lib != nil {
		if !dynlib.unload_library(api.lib) {
			fmt.printfln("Failed unloading lib: {0}", dynlib.last_error())
		}
	}

	if os.remove(fmt.tprintf(GAME_DLL_DIR + "game_{0}" + DLL_EXT, api.api_version)) != nil {
		fmt.printfln(
			"Failed to remove {0}game_{1}" + DLL_EXT + " copy",
			GAME_DLL_DIR,
			api.api_version,
		)
	}
}

reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
	err := false

	for _, value in a.allocation_map {
		log.errorf("%v: Leaked %v bytes\n", value.location, value.size)
		err = true
	}

	mem.tracking_allocator_clear(a)
	return err
}

init :: proc "c" () {
	context = tracking_context

	// Set working dir to dir of executable.
	exe_path := os.args[0]
	exe_dir := filepath.dir(string(exe_path), context.temp_allocator)
	os.set_working_directory(exe_dir)

	context.logger = log.create_console_logger()

	default_allocator := context.allocator
	mem.tracking_allocator_init(&tracking_allocator, default_allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)

	game_api_ok: bool
	game_api, game_api_ok = load_game_api(game_api_version)

	if !game_api_ok {
		fmt.println("Failed to load Game API")
		return
	}

	game_api_version += 1
	sg.setup({environment = sglue.environment(), logger = {func = slog.func}})
	fmt.println("Using backend: ", sg.query_backend())
	game_api.init()

	old_game_apis = make([dynamic]Game_API, default_allocator)
}

frame :: proc "c" () {
	context = tracking_context
	game_api.update()
	// NOTE: don't try to make these into calls from the event callback, need to re-init immediately and sokol_gfx calls from within the sapp event callback aren't supported
	reload := force_reload || force_restart
	defer force_reload = false
	defer force_restart = false
	game_dll_mod, game_dll_mod_err := os.last_write_time_by_name(GAME_DLL_PATH)

	if game_dll_mod_err == os.ERROR_NONE && game_api.modification_time != game_dll_mod {
		reload = true
	}

	if reload {
		new_game_api, new_game_api_ok := load_game_api(game_api_version)

		if new_game_api_ok {
			force_restart = force_restart || game_api.memory_size() != new_game_api.memory_size()

			if !force_restart {
				// This does the normal hot reload

				// Note that we don't unload the old game APIs because that
				// would unload the DLL. The DLL can contain stored info
				// such as string literals. The old DLLs are only unloaded
				// on a full reset or on shutdown.
				append(&old_game_apis, game_api)
				game_memory := game_api.memory()
				game_api = new_game_api
				game_api.hot_reloaded(game_memory)
			} else {
				// This does a full reset. That's basically like opening and
				// closing the game, without having to restart the executable.
				//
				// You end up in here if the game requests a full reset OR
				// if the size of the game memory has changed. That would
				// probably lead to a crash anyways.

				game_api.shutdown()
				reset_tracking_allocator(&tracking_allocator)

				for &g in old_game_apis {
					unload_game_api(&g)
				}

				clear(&old_game_apis)
				unload_game_api(&game_api)
				game_api = new_game_api
				game_api.init()
			}

			game_api_version += 1
		}
	}

	if len(tracking_allocator.bad_free_array) > 0 {
		for b in tracking_allocator.bad_free_array {
			log.errorf("Bad free at: %v", b.location)
		}

		// This prevents the game from closing without you seeing the bad frees.
		//libc.getchar()
		panic("Bad free detected")
	}

	free_all(context.temp_allocator)

	if game_api.should_run() == false {
		sapp.quit()
	}
}

cleanup :: proc "c" () {
	context = tracking_context
	game_api.shutdown()
	sg.shutdown()
	if reset_tracking_allocator(&tracking_allocator) {
		// This prevents the game from closing without you seeing the memory leaks.
		//libc.getchar()
	}

	for &g in old_game_apis {
		unload_game_api(&g)
	}

	delete(old_game_apis)

	unload_game_api(&game_api)
	mem.tracking_allocator_destroy(&tracking_allocator)
}

event :: proc "c" (e: ^sapp.Event) {
	context = tracking_context
	#partial switch e.type {
	case .KEY_DOWN:
		#partial switch e.key_code {
		case .F5:
			force_reload = true
		case .F6:
			force_restart = true
		}
	}
	game_api.event(e)
}

main :: proc() {
	tracking_context = runtime.default_context()
	sapp.run(
		{
			init_cb = init,
			frame_cb = frame,
			cleanup_cb = cleanup,
			event_cb = event,
			width = 1280,
			height = 720,
			window_title = "Odin + Sokol + Flecs + Hot Reload template!",
			icon = {sokol_default = true},
			logger = {func = slog.func},
		},
	)
}

// Make game use good GPU on laptops.

@(export)
NvOptimusEnablement: u32 = 1

@(export)
AmdPowerXpressRequestHighPerformance: i32 = 1
