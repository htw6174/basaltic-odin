package game

import "core:image"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:time"
import ecs "flecs"
import "shader"
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
	world_camera:     Camera,
	// world_ui_camera:  rl.Camera2D,
	// ui_camera:        rl.Camera2D,
	erosion_shader:   sg.Shader,
	erosion_pipeline: sg.Pipeline,
	erosion_bindings: sg.Bindings,
	terrain_shader:   sg.Shader,
	terrain_pipeline: sg.Pipeline,
	terrain_bindings: sg.Bindings,
	cube_pipeline:    sg.Pipeline,
	cube_bindings:    sg.Bindings,
	heightmap_image:  sg.Image,
	erosion_image:    sg.Image,
	terrain_dirty:    bool,
	textures:         [dynamic]sg.Image,
	cell_cursor:      sim.Grid_Coord,
	// queries for access to sim data
	plane_q:          ^ecs.Query,
}

g: ^Game_Memory

Camera :: struct {
	position: [3]f32, // target point
	orbit:    [3]f32, // pitch, yaw, roll
	distance: f32, // from target
	fovy:     f32,
	_vp:      matrix[4, 4]f32,
}

Key :: struct {
	down, pressed, released: bool,
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
		world_camera = {
			// geez I wish Odin supported creating small arrays with a mix of others e.g. c: [3]f32 = {a.xy, b.x}
			position = {sim.grid_to_cartesian({sim.CHUNK_SIZE, sim.CHUNK_SIZE}).x, sim.grid_to_cartesian({sim.CHUNK_SIZE, sim.CHUNK_SIZE}).y, 0}, 
			orbit = {math.PI / 4, -math.PI / 6, 0}, 
			distance = 50, 
			fovy = 60,
		},
		tick_to_real = time.Second / 60,
		time_last_frame = time.now(),
		sim_run = false,
		sim_state = {seed = 6174},
	}
	//append(&g.textures, rl.LoadTexture("assets/round_cat.png")) TODO different image loader

	// TEST: cube
	//odinfmt: disable
	vertices := [?]f32 {
        -1.0, -1.0, -1.0,   1.0, 0.0, 0.0, 1.0,
         1.0, -1.0, -1.0,   1.0, 0.0, 0.0, 1.0,
         1.0,  1.0, -1.0,   1.0, 0.0, 0.0, 1.0,
        -1.0,  1.0, -1.0,   1.0, 0.0, 0.0, 1.0,

        -1.0, -1.0,  1.0,   0.0, 1.0, 0.0, 1.0,
         1.0, -1.0,  1.0,   0.0, 1.0, 0.0, 1.0,
         1.0,  1.0,  1.0,   0.0, 1.0, 0.0, 1.0,
        -1.0,  1.0,  1.0,   0.0, 1.0, 0.0, 1.0,

        -1.0, -1.0, -1.0,   0.0, 0.0, 1.0, 1.0,
        -1.0,  1.0, -1.0,   0.0, 0.0, 1.0, 1.0,
        -1.0,  1.0,  1.0,   0.0, 0.0, 1.0, 1.0,
        -1.0, -1.0,  1.0,   0.0, 0.0, 1.0, 1.0,

        1.0, -1.0, -1.0,    1.0, 0.5, 0.0, 1.0,
        1.0,  1.0, -1.0,    1.0, 0.5, 0.0, 1.0,
        1.0,  1.0,  1.0,    1.0, 0.5, 0.0, 1.0,
        1.0, -1.0,  1.0,    1.0, 0.5, 0.0, 1.0,

        -1.0, -1.0, -1.0,   0.0, 0.5, 1.0, 1.0,
        -1.0, -1.0,  1.0,   0.0, 0.5, 1.0, 1.0,
         1.0, -1.0,  1.0,   0.0, 0.5, 1.0, 1.0,
         1.0, -1.0, -1.0,   0.0, 0.5, 1.0, 1.0,

        -1.0,  1.0, -1.0,   1.0, 0.0, 0.5, 1.0,
        -1.0,  1.0,  1.0,   1.0, 0.0, 0.5, 1.0,
         1.0,  1.0,  1.0,   1.0, 0.0, 0.5, 1.0,
         1.0,  1.0, -1.0,   1.0, 0.0, 0.5, 1.0,
  }
  indices := [?]u16 {
        0, 1, 2,  0, 2, 3,
        6, 5, 4,  7, 6, 4,
        8, 9, 10,  8, 10, 11,
        14, 13, 12,  15, 14, 12,
        16, 17, 18,  16, 18, 19,
        22, 21, 20,  23, 22, 20,
  }
  //odinfmt: enable
	g.cube_bindings.vertex_buffers[0] = sg.make_buffer(
		{data = {ptr = &vertices, size = size_of(vertices)}},
	)
	g.cube_bindings.index_buffer = sg.make_buffer(
		{usage = {index_buffer = true}, data = {ptr = &indices, size = size_of(indices)}},
	)
	g.cube_pipeline = sg.make_pipeline(
		{
			shader = sg.make_shader(shader.cube_shader_desc(sg.query_backend())),
			layout = {
				buffers = {0 = {stride = 28}},
				attrs = {
					shader.ATTR_cube_position = {format = .FLOAT3},
					shader.ATTR_cube_color0 = {format = .FLOAT4},
				},
			},
			index_type = .UINT16,
			cull_mode = .BACK,
			depth = {write_enabled = true, compare = .LESS_EQUAL},
		},
	)
	
	// make dynamic texture for height map input and storage texture for erosion map intermediate
	g.heightmap_image = sg.make_image({
		width = sim.WORLD_SIZE,
		height = sim.WORLD_SIZE,
		pixel_format = .RGBA8SI,
		usage = {
			dynamic_update = true,
		},
	})
	
	g.erosion_image = sg.make_image({
		// (total map size) * (compute work group size)
		width = sim.WORLD_SIZE * 16,
		height = sim.WORLD_SIZE * 16,
		pixel_format = .RGBA32F,
		usage = {
			storage_image = true,
			immutable = true,
		},
	})
	
	g.erosion_bindings.views[shader.VIEW_terrain_base_map] = sg.make_view({
		texture = {image = g.heightmap_image}
	})
	g.erosion_bindings.views[shader.VIEW_terrain_erosion_map] = sg.make_view({
		storage_image = {image = g.erosion_image}
	})
	g.erosion_bindings.samplers[shader.SMP_terrain_ismp] = sg.make_sampler({})
	
	COMPRESS :: 1
	//terrain_vertex_buffer, terrain_index_buffer := make_hex_grid_mesh(sim.CHUNK_SIZE)
	terrain_vertex_buffer, terrain_index_buffer := make_hex_tri_mesh(60, f32(sim.CHUNK_SIZE) / (2 * COMPRESS))
	Instance_Data :: struct {
		cartesian: [2]f32,
		axial: [2]f32,
	}
	instance_buffer: [16]Instance_Data
	for &inst, i in instance_buffer {
		cell := sim.Grid_Coord{i32(i % 4) * sim.CHUNK_SIZE / COMPRESS, i32(i / 4) * sim.CHUNK_SIZE / COMPRESS}
		inst.cartesian = sim.grid_to_cartesian(cell)
		inst.axial = {f32(cell.x), f32(cell.y)}
	}
	g.terrain_bindings = {
		vertex_buffers = {
			0 = sg.make_buffer({
				data = {ptr = raw_data(&instance_buffer), size = size_of(instance_buffer)}
			}),
			1 = terrain_vertex_buffer,
		},
		index_buffer = terrain_index_buffer,
		views = {
			shader.VIEW_terrain_heightmap = sg.make_view({
				texture = {
					image = g.erosion_image
				}
			})
		},
		samplers = {
			shader.SMP_terrain_smp = sg.make_sampler({min_filter = .LINEAR, mag_filter = .LINEAR})
		},
	}
	
	make_pipelines()

	sim.init(&g.sim_state)
	g.plane_q = ecs.query_init(
		g.sim_state.world,
		&{terms = {0 = {id = ecs.id(g.sim_state.world, sim.Plane)}}},
	)
	
	update_heightmap()
}

fini :: proc() {
	delete(g.textures)
	// TODO: need to either free all sokol_gfx resources, or call sg.setup() and sg.shutdown() on every hot reset
	// This is enough to take care of all the low-limit and bulky resources for now
	destroy_pipelines()
	sg.destroy_image(g.erosion_image)
	sg.destroy_image(g.heightmap_image)
	sim.fini(&g.sim_state)
	free(g)
}

reload_shaders :: proc() {
	// dispose of existing shaders and pipelines
	destroy_pipelines()
	
	// re-create shaders and pipelines
	make_pipelines()
	//g.terrain_dirty = true
}

destroy_pipelines :: proc() {
	sg.destroy_shader(g.erosion_shader)
	sg.destroy_shader(g.terrain_shader)
	sg.destroy_pipeline(g.erosion_pipeline)
	sg.destroy_pipeline(g.terrain_pipeline)
}

make_pipelines :: proc() {
	g.erosion_shader = sg.make_shader(shader.erosion_shader_desc(sg.query_backend()))
	g.erosion_pipeline = sg.make_pipeline({
		shader = g.erosion_shader,
		compute = true,
	})

	g.terrain_shader = sg.make_shader(shader.dynamic_shader_desc(sg.query_backend()))
	g.terrain_pipeline = sg.make_pipeline(
		{
			shader = g.terrain_shader,
			layout = {
				buffers = {
					0 = {step_func = .PER_INSTANCE},
					1 = {step_func = .PER_VERTEX}
				},
				attrs = {
					shader.ATTR_terrain_dynamic_instance_position = {format = .FLOAT2},
					shader.ATTR_terrain_dynamic_instance_axial = {format = .FLOAT2},
					shader.ATTR_terrain_dynamic_position = {format = .FLOAT2, buffer_index = 1},
					shader.ATTR_terrain_dynamic_vertex_axial = {format = .FLOAT2, buffer_index = 1},
				},
			},
			index_type = .UINT16,
			cull_mode = .BACK,
			depth = {write_enabled = true, compare = .LESS_EQUAL},
		},
	)
}

update :: proc() {
	s := &g.sim_state

	now := time.now()
	dT := time.diff(g.time_last_frame, now)
	defer g.time_last_frame = now
	// TODO: consider using smoothed value sapp.frame_duration(). Can't feel an immediate different. Maybe useful for printing framerates?
	//g.dt_real_seconds = f32(sapp.frame_duration())
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
		k.pressed = false
		k.released = false
	}
	g.mouse.wheel = 0
}

event :: proc(e: ^sapp.Event) {
	#partial switch e.type {
	case .KEY_DOWN:
		keys[e.key_code].pressed = true
		keys[e.key_code].down = true
	case .KEY_UP:
		keys[e.key_code].released = true
		keys[e.key_code].down = false
	case .MOUSE_SCROLL:
		g.mouse.wheel = e.scroll_y
	}
}

input :: proc() {
	dT := time.duration_seconds(time.diff(g.time_last_frame, time.now()))
	dt := min(f32(dT), 1. / TARGET_FPS)

	if keys[.ESCAPE].pressed {
		// TODO: could make this call sapp.request_quit() instead, add procs to handle prompt and deny
		g.run = false
	}

	move: [2]f32
	rotate: [2]f32
	zoom: f32

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
	if keys[.R].down {
		rotate.x += 1
	}
	if keys[.F].down {
		rotate.x -= 1
	}
	
	if keys[.Z].down {
		zoom += 1 * 0.6
	}
	if keys[.X].down {
		zoom -= 1 * 0.6
	}
	
	// move cell cursor
	if keys[.J].pressed {
		g.cell_cursor.x -= 1
	}
	if keys[.L].pressed {
		g.cell_cursor.x += 1
	}
	if keys[.K].pressed {
		g.cell_cursor.y -= 1
	}
	if keys[.I].pressed {
		g.cell_cursor.y += 1
	}
	
	if keys[.U].pressed {
		plane_it := ecs.query_iter(g.sim_state.world, g.plane_q)
		plane_entity := ecs.iter_first(&plane_it)
		plane := ecs.get(g.sim_state.world, plane_entity, sim.Plane)
		cell_data := sim.plane_get(plane, g.cell_cursor)
		cell_data.height += 1
		g.terrain_dirty = true
	}
	
	if keys[.O].pressed {
		plane_it := ecs.query_iter(g.sim_state.world, g.plane_q)
		plane_entity := ecs.iter_first(&plane_it)
		plane := ecs.get(g.sim_state.world, plane_entity, sim.Plane)
		cell_data := sim.plane_get(plane, g.cell_cursor)
		cell_data.height -= 1
		g.terrain_dirty = true
	}

	if keys[.SPACE].pressed {
		g.sim_run = !g.sim_run
	}

	if keys[.G].pressed {
		sim.fini(&g.sim_state)
		g.sim_state.seed = rand.uint32()
		sim.init(&g.sim_state)
		g.plane_q = ecs.query_init(
			g.sim_state.world,
			&{terms = {0 = {id = ecs.id(g.sim_state.world, sim.Plane)}}},
		)
		g.terrain_dirty = true
	}
	
	// TODO: should only mark terrain dirty, for now has to restart sim to work around component ID retrieval issue
	if keys[.H].pressed {
		sim.fini(&g.sim_state)
		// Don't reset seed to keep same map
		sim.init(&g.sim_state)
		g.plane_q = ecs.query_init(
			g.sim_state.world,
			&{terms = {0 = {id = ecs.id(g.sim_state.world, sim.Plane)}}},
		)
		g.terrain_dirty = true
	}

	if g.mouse.wheel != 0 {
		zoom = g.mouse.wheel * 0.5
	}
	
	if zoom != 0 {
		g.world_camera.distance = clamp(g.world_camera.distance + zoom, 0.01, 100)
	}

	// scale by distance
	move = linalg.normalize0(move) * g.world_camera.distance
	// rotate so movement axies are aligned to camera direction
	sin_yaw := math.sin(g.world_camera.orbit.y)
	cos_yaw := math.cos(g.world_camera.orbit.y)
	move = {(move.x * cos_yaw) + (move.y * -sin_yaw), (move.y * cos_yaw) + (move.x * sin_yaw)}
	g.world_camera.position.xy += move * dt * 3
	g.world_camera.position.z = 0
	g.world_camera.orbit.xy += rotate * math.PI * dt
	g.world_camera.orbit.x = math.clamp(g.world_camera.orbit.x, -(math.PI / 2) + 0.001, (math.PI / 2) - 0.001)
	camera_update(&g.world_camera)
}

draw :: proc(sim_state_interp: f32) {
	s := g.sim_state
	defer sg.commit()
	
	if g.terrain_dirty {
		update_heightmap()
		g.terrain_dirty = false
	}

	world: {
		sg.begin_pass(
			{
				action = {colors = {0 = {load_action = .CLEAR, clear_value = {0.5, 0.5, 0.5, 1}}}},
				swapchain = sglue.swapchain(),
			},
		)
		defer sg.end_pass()

		vs_params := shader.Vs_Params {
			mvp = cam_mvp(g.world_camera),
		}
		
		// test generated terrain
		sg.apply_pipeline(g.terrain_pipeline)
		sg.apply_bindings(g.terrain_bindings)
		sg.apply_uniforms(shader.UB_terrain_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
		sg.draw(0, sim.CHUNK_SIZE * sim.CHUNK_SIZE * 6 * 4 * 3, 16)
		
		// test cube
		sg.apply_pipeline(g.cube_pipeline)
		sg.apply_bindings(g.cube_bindings)
		sg.apply_uniforms(shader.UB_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
		sg.draw(0, 36, 1)
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

update_heightmap :: proc() {
	plane_it := ecs.query_iter(g.sim_state.world, g.plane_q)
	plane_entity := ecs.iter_first(&plane_it)
	plane := ecs.get(g.sim_state.world, plane_entity, sim.Plane)
	buffer_size := int(sg.query_surface_pitch(.RGBA8SI, sim.WORLD_SIZE, sim.WORLD_SIZE, 1))
	format_info := sg.query_pixelformat(.RGBA8SI)
	// TODO: persist this buffer
	image_buffer := make([]i8, buffer_size, context.temp_allocator)
	for chunk, chunk_idx in plane.chunks {
		for cell, cell_idx in chunk.data {
			cell_coord := sim.chunk_cell_to_grid(chunk.origin, cell_idx)
			texel := sim.grid_to_index(cell_coord, {sim.WORLD_SIZE, sim.WORLD_SIZE})
			buffer_idx := texel * int(format_info.bytes_per_pixel)
			image_buffer[buffer_idx] = cell.height
			// TODO: other attributes in this data texture
		}
	}
	sg.update_image(
		g.heightmap_image, 
		{
			mip_levels = {
				0 = {ptr = raw_data(image_buffer), size = uint(buffer_size)}
			}
		}
	)
	
	sg.begin_pass({compute = true})
	sg.apply_pipeline(g.erosion_pipeline)
	sg.apply_bindings(g.erosion_bindings)
	sg.dispatch(sim.WORLD_SIZE, sim.WORLD_SIZE, 1)
	sg.end_pass()
}

cam_mvp :: proc(cam: Camera) -> matrix[4, 4]f32 {
	model := linalg.MATRIX4F32_IDENTITY

	return cam._vp * model
}

camera_update :: proc(cam: ^Camera) {
	aspect := sapp.widthf() / sapp.heightf()
	projection := linalg.matrix4_perspective(math.to_radians(cam.fovy), aspect, 0.01, 1000)
	sphere_pos := [3]f32 {
		math.sin(cam.orbit.y) * math.cos(cam.orbit.x),
		-math.cos(cam.orbit.y) * math.cos(cam.orbit.x),
		math.sin(cam.orbit.x),
	}
	view := linalg.matrix4_look_at(
		cam.position + (sphere_pos * cam.distance),
		cam.position,
		[3]f32{0, 0, 1},
	)
	cam._vp = projection * view
}

// probably don't need this as it was used in the original c source, might be useful later
barycentric :: proc(a, b, c: [2]f32) -> [3]f32 {
	d00 := linalg.dot(b, b)
	d01 := linalg.dot(b, c)
	d11 := linalg.dot(c, c)
	d20 := linalg.dot(a, b)
	d21 := linalg.dot(a, c)
	denom := d00 * d11 - d01 * d01
	v := (d11 * d20 - d01 * d21) / denom
	w := (d00 * d21 - d01 * d20) / denom
	u := 1 - v - w
	return {u, v, w}
}

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
