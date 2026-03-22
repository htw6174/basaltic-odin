package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:time"
import ecs "flecs"
import "sim"
import sapp "sokol/app"
import sg "sokol/gfx"
import sglue "sokol/glue"

TARGET_FPS :: 60
PIXEL_WINDOW_WIDTH :: 640
PIXEL_WINDOW_HEIGHT :: 480

Game_Memory :: struct {
	run:              bool, // Only mandatory field, needed by harness
	sim_run:          bool,
	tick_to_real:     time.Duration,
	time_accumulator: time.Duration,
	time_last_frame:  time.Time,
	dt_real_seconds:  f32,
	sim_state:        sim.State,
	// input
	mouse:            Mouse,
	camera_pos:       [3]f32,
	camera_orbit:     [3]f32, // pitch, yaw, roll
	camera_zoom:      f32,
	// world_camera:     rl.Camera3D,
	// world_ui_camera:  rl.Camera2D,
	// ui_camera:        rl.Camera2D,
	textures:         [dynamic]sg.Image,
	// queries for access to sim data
	plane_q:          ^ecs.Query,
}

g: ^Game_Memory

Key :: struct {
	pressed, up, down: bool,
}

Mouse :: struct {
	wheel: f32,
}

// TODO: move outside reload boundary or embed in g
keys: #sparse[sapp.Keycode]Key = {}

init :: proc() {
	g = new(Game_Memory)
	g^ = Game_Memory {
		run = true,
		textures = make([dynamic]sg.Image, 0),
		camera_zoom = 10,
		tick_to_real = time.Second / 60,
		time_last_frame = time.now(),
		sim_run = true,
		sim_state = {seed = 6174},
	}
	//append(&g.textures, rl.LoadTexture("assets/round_cat.png")) TODO different image loader

	sim.init(&g.sim_state)
	g.plane_q = ecs.query_init(
		g.sim_state.world,
		&{terms = {0 = {id = ecs.id(g.sim_state.world, sim.Plane)}}},
	)
}

fini :: proc() {
	delete(g.textures)
	sim.fini(&g.sim_state)
	free(g)
}

update :: proc() {
	s := &g.sim_state

	now := time.now()
	dT := time.diff(g.time_last_frame, now)
	defer g.time_last_frame = now
	g.dt_real_seconds = f32(time.duration_seconds(dT))
	if g.sim_run {
		g.time_accumulator += dT
		for g.time_accumulator >= g.tick_to_real {
			sim.step(s)
			g.time_accumulator -= g.tick_to_real
		}
	} else {
		// manually run system for flecs REST module to update web UI
		rest_system := ecs.lookup(s.world, "flecs.rest.DequeueRest")
		ecs.run(s.world, rest_system, g.dt_real_seconds, nil)
	}
	interp := f32(
		time.duration_seconds(g.time_accumulator) / time.duration_seconds(g.tick_to_real),
	)

	input()
	draw(interp)

	// reset key events
	// TODO: should make sure the window losing or regaining focus also resets these
	for &k in keys {
		k.down = false
		k.up = false
	}
}

event :: proc(e: ^sapp.Event) {
	#partial switch e.type {
	case .KEY_DOWN:
		keys[e.key_code].down = true
		keys[e.key_code].pressed = true
	case .KEY_UP:
		keys[e.key_code].up = true
		keys[e.key_code].pressed = false
	}
}

input :: proc() {
	dT := time.duration_seconds(time.diff(g.time_last_frame, time.now()))
	dt := min(f32(dT), 1. / TARGET_FPS)

	if keys[.ESCAPE].down {
		// TODO: could make this call sapp.request_quit() instead, add procs to handle prompt and deny
		g.run = false
	}

	move: [2]f32
	rotate: [2]f32

	if keys[.DOWN].down || keys[.W].down {
		move.y += 1
	}
	if keys[.DOWN].down || keys[.S].down {
		move.y -= 1
	}
	if keys[.LEFT].down || keys[.A].down {
		move.x -= 1
	}
	if keys[.RIGHT].down || keys[.D].down {
		move.x += 1
	}

	if keys[.Q].down {
		rotate.y -= 1
	}
	if keys[.E].down {
		rotate.y += 1
	}

	if keys[.SPACE].down {
		g.sim_run = !g.sim_run
	}

	if keys[.R].down {
		sim.fini(&g.sim_state)
		g.sim_state.seed = rand.uint32()
		sim.init(&g.sim_state)
		g.plane_q = ecs.query_init(
			g.sim_state.world,
			&{terms = {0 = {id = ecs.id(g.sim_state.world, sim.Plane)}}},
		)
	}

	if g.mouse.wheel != 0 {
		g.camera_zoom += g.mouse.wheel * 0.5
	}

	move = linalg.normalize0(move)
	g.camera_pos.xy += move * dt * 5 * g.camera_zoom
	g.camera_pos.z = 0
	g.camera_orbit.xy += rotate * math.PI * dt
}

draw :: proc(sim_state_interp: f32) {
	s := g.sim_state

	sg.begin_pass(
		{
			action = {colors = {0 = {load_action = .CLEAR, clear_value = {0.5, 0.5, 0.5, 1}}}},
			swapchain = sglue.swapchain(),
		},
	)
	defer sg.end_pass()

	world: {
		// g.world_camera = world_camera()
		// sg.begin_pass()
		// defer sg.end_pass()

		// Draw map with prims
		it := ecs.query_iter(s.world, g.plane_q)
		for ecs.query_next(&it) {
			planes := ecs.field(&it, sim.Plane, 0)
			for i in 0 ..< it.count {
				plane := planes[i]
				for chunk in plane.chunks {
					for cell, c in chunk.data {
						pos := sim.grid_to_vec(sim.chunk_cell_to_grid(chunk.origin, c))
						_ = pos
						// rl.DrawCubeV(
						// 	{pos.x, pos.y, f32(cell.height) / 10},
						// 	{1, 1, 1},
						// 	rl.ColorLerp(rl.BLUE, rl.RED, f32(cell.height) / 128),
						// )
					}
				}
			}
		}
	}

	world_ui: {
		//g.world_ui_camera = world_ui_camera()
		// sg.begin_pass()
		// defer sg.end_pass()

		//mouse_world_pos := rl.GetScreenToWorld2D(rl.GetMousePosition(), g.world_ui_camera)
	}

	screen_ui: {
		//ui_cam := ui_camera()
		// sg.begin_pass()
		// defer sg.end_pass()

		//rl.DrawFPS(5, 5)
	}
}

// world_camera :: proc() -> rl.Camera3D {
// 	//w := f32(rl.GetScreenWidth())
// 	h := f32(rl.GetScreenHeight())

// 	return {
// 		position   = {
// 			g.camera_pos.x + math.sin(g.camera_orbit.y) * g.camera_zoom,
// 			g.camera_pos.y - math.cos(g.camera_orbit.y) * g.camera_zoom,
// 			g.camera_pos.z + g.camera_zoom,
// 		},
// 		target     = g.camera_pos,
// 		up         = {0, 0, 1},
// 		fovy       = 90, //math.exp(-g.camera_zoom) * h / (h / PIXEL_WINDOW_HEIGHT),
// 		projection = .PERSPECTIVE,
// 	}
// }

// world_ui_camera :: proc() -> rl.Camera2D {
// 	w := f32(rl.GetScreenWidth())
// 	h := f32(rl.GetScreenHeight())

// 	return {
// 		zoom = math.exp(g.camera_zoom) * h / PIXEL_WINDOW_HEIGHT,
// 		target = g.camera_pos.xy,
// 		offset = {w / 2, h / 2},
// 	}
// }

// ui_camera :: proc() -> rl.Camera2D {
// 	return {zoom = f32(rl.GetScreenHeight()) / PIXEL_WINDOW_HEIGHT}
// }
