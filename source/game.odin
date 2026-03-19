package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import ecs "flecs"
import "sim"
import rl "vendor:raylib"

TARGET_FPS :: 60
PIXEL_WINDOW_WIDTH :: 640
PIXEL_WINDOW_HEIGHT :: 480

Game_Memory :: struct {
	run:              bool, // Only mandatory field, needed by harness
	sim_run:          bool,
	tick_to_real:     f32,
	time_accumulator: f32,
	sim_state:        sim.State,
	camera_pos:       [3]f32,
	camera_orbit:     [3]f32, // pitch, yaw, roll
	camera_zoom:      f32,
	world_camera:     rl.Camera3D,
	world_ui_camera:  rl.Camera2D,
	ui_camera:        rl.Camera2D,
	textures:         [dynamic]rl.Texture,
	// queries for access to sim data
	plane_q:          ^ecs.Query,
}

g: ^Game_Memory

init :: proc() {
	g = new(Game_Memory)
	g^ = Game_Memory {
		run = true,
		textures = make([dynamic]rl.Texture, 0),
		camera_zoom = 10,
		tick_to_real = 1.0 / 60,
		sim_run = true,
		sim_state = {seed = 6174},
	}
	append(&g.textures, rl.LoadTexture("assets/round_cat.png"))

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

	dT := rl.GetFrameTime()
	if g.sim_run {
		g.time_accumulator += dT
		for g.time_accumulator >= g.tick_to_real {
			sim.step(s)
			g.time_accumulator -= g.tick_to_real
		}
	} else {
		// manually run system for flecs REST module to update web UI
		rest_system := ecs.lookup(s.world, "flecs.rest.DequeueRest")
		ecs.run(s.world, rest_system, dT, nil)
	}
	interp := g.time_accumulator / g.tick_to_real

	input()
	draw(interp)
}

input :: proc() {
	dt := min(rl.GetFrameTime(), 1. / TARGET_FPS)

	if rl.IsKeyPressed(.ESCAPE) {
		g.run = false
	}

	move: rl.Vector2
	rotate: rl.Vector2

	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {
		move.y += 1
	}
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {
		move.y -= 1
	}
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {
		move.x -= 1
	}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {
		move.x += 1
	}

	if rl.IsKeyDown(.Q) {
		rotate.y -= 1
	}
	if rl.IsKeyDown(.E) {
		rotate.y += 1
	}

	if rl.IsKeyPressed(.SPACE) {
		g.sim_run = !g.sim_run
	}

	if rl.IsKeyPressed(.R) {
		sim.fini(&g.sim_state)
		g.sim_state.seed = rand.uint32()
		sim.init(&g.sim_state)
		g.plane_q = ecs.query_init(
			g.sim_state.world,
			&{terms = {0 = {id = ecs.id(g.sim_state.world, sim.Plane)}}},
		)
	}

	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		g.camera_zoom += wheel * 0.5
	}

	move = linalg.normalize0(move)
	g.camera_pos.xy += move * dt * 5 * g.camera_zoom
	g.camera_pos.z = 0
	g.camera_orbit.xy += rotate * math.PI * dt
}

draw :: proc(sim_state_interp: f32) {
	rl.BeginDrawing()
	defer rl.EndDrawing()
	rl.ClearBackground(rl.BLACK)

	s := g.sim_state

	world: {
		g.world_camera = world_camera()
		rl.BeginMode3D(g.world_camera)
		defer rl.EndMode3D()

		// draw axis lines for
		rl.DrawGrid(10, 1)

		// Draw map with prims
		it := ecs.query_iter(s.world, g.plane_q)
		for ecs.query_next(&it) {
			planes := ecs.field(&it, sim.Plane, 0)
			for i in 0 ..< it.count {
				plane := planes[i]
				for chunk in plane.chunks {
					for cell, c in chunk.data {
						pos := sim.grid_to_vec(sim.chunk_cell_to_grid(chunk.origin, c))
						rl.DrawCubeV(
							{pos.x, pos.y, f32(cell.height) / 10},
							{1, 1, 1},
							rl.ColorLerp(rl.BLUE, rl.RED, f32(cell.height) / 128),
						)
					}
				}
			}
		}
	}

	world_ui: {
		g.world_ui_camera = world_ui_camera()
		rl.BeginMode2D(g.world_ui_camera)
		defer rl.EndMode2D()

		mouse_world_pos := rl.GetScreenToWorld2D(rl.GetMousePosition(), g.world_ui_camera)
	}

	screen_ui: {
		ui_cam := ui_camera()
		rl.BeginMode2D(ui_cam)
		defer rl.EndMode2D()

		rl.DrawFPS(5, 5)
	}
}

world_camera :: proc() -> rl.Camera3D {
	//w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())

	return {
		position   = {
			g.camera_pos.x + math.sin(g.camera_orbit.y) * g.camera_zoom,
			g.camera_pos.y - math.cos(g.camera_orbit.y) * g.camera_zoom,
			g.camera_pos.z + g.camera_zoom,
		},
		target     = g.camera_pos,
		up         = {0, 0, 1},
		fovy       = 90, //math.exp(-g.camera_zoom) * h / (h / PIXEL_WINDOW_HEIGHT),
		projection = .PERSPECTIVE,
	}
}

world_ui_camera :: proc() -> rl.Camera2D {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())

	return {
		zoom = math.exp(g.camera_zoom) * h / PIXEL_WINDOW_HEIGHT,
		target = g.camera_pos.xy,
		offset = {w / 2, h / 2},
	}
}

ui_camera :: proc() -> rl.Camera2D {
	return {zoom = f32(rl.GetScreenHeight()) / PIXEL_WINDOW_HEIGHT}
}
