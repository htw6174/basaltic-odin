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
	erosion_pipeline: sg.Pipeline,
	erosion_bindings: sg.Bindings,
	terrain_pipeline: sg.Pipeline,
	terrain_bindings: sg.Bindings,
	cube_pipeline:    sg.Pipeline,
	cube_bindings:    sg.Bindings,
	heightmap_image:  sg.Image,
	textures:         [dynamic]sg.Image,
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
		world_camera = {orbit = {math.PI / 8, math.PI / 8, 0}, distance = 10, fovy = 60},
		tick_to_real = time.Second / 60,
		time_last_frame = time.now(),
		sim_run = true,
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
	
	// make storage texture for height map input and erosion map intermediate
	g.heightmap_image = sg.make_image({
		width = sim.CHUNK_SIZE,
		height = sim.CHUNK_SIZE,
		pixel_format = .RGBA8SI,
		usage = {
			dynamic_update = true,
		},
	})
	
	erosion_image := sg.make_image({
		width = 1024,
		height = 1024,
		pixel_format = .R32F,
		usage = {
			storage_image = true,
			immutable = true,
		},
	})
	
	g.erosion_bindings.views[shader.VIEW_terrain_base_map] = sg.make_view({
		texture = {image = g.heightmap_image}
	})
	g.erosion_bindings.views[shader.VIEW_terrain_erosion_map] = sg.make_view({
		storage_image = {image = erosion_image}
	})
	g.erosion_bindings.samplers[shader.SMP_terrain_ismp] = sg.make_sampler({mag_filter = .NEAREST, min_filter = .NEAREST, mipmap_filter = .NEAREST})
	
	g.erosion_pipeline = sg.make_pipeline({
		shader = sg.make_shader(shader.erosion_shader_desc(sg.query_backend())),
		compute = true,
	})

	g.terrain_bindings = make_terrain_mesh(sim.CHUNK_SIZE)
	g.terrain_bindings.views[shader.VIEW_terrain_heightmap] = sg.make_view({
		texture = {
			image = erosion_image
		}
	})
	g.terrain_bindings.samplers[shader.SMP_terrain_smp] = sg.make_sampler({})

	g.terrain_pipeline = sg.make_pipeline(
		{
			shader = sg.make_shader(shader.dynamic_shader_desc(sg.query_backend())),
			layout = {
				buffers = {0 = {stride = 16}},
				attrs = {
					shader.ATTR_terrain_dynamic_position = {format = .FLOAT2},
					shader.ATTR_terrain_dynamic_cell_uv = {format = .FLOAT2},
				},
			},
			index_type = .UINT16,
			cull_mode = .BACK,
			depth = {write_enabled = true, compare = .LESS_EQUAL},
		},
	)

	sim.init(&g.sim_state)
	g.plane_q = ecs.query_init(
		g.sim_state.world,
		&{terms = {0 = {id = ecs.id(g.sim_state.world, sim.Plane)}}},
	)
	
	plane_it := ecs.query_iter(g.sim_state.world, g.plane_q)
	plane_entity := ecs.iter_first(&plane_it)
	plane := ecs.get(g.sim_state.world, plane_entity, sim.Plane)
	buffer_size := int(sg.query_surface_pitch(.RGBA8SI, sim.CHUNK_SIZE, sim.CHUNK_SIZE, 1))
	format_info := sg.query_pixelformat(.RGBA8SI)
	image_buffer := make([]i8, buffer_size, context.temp_allocator)
	pixel := 0
	for cell in plane.chunks[0].data {
		image_buffer[pixel] = cell.height
		// TODO: other attributes in this data texture
		pixel += int(format_info.bytes_per_pixel)
	}
	sg.update_image(
		g.heightmap_image, 
		{
			mip_levels = {
				0 = {ptr = raw_data(image_buffer), size = uint(buffer_size)}
			}
		}
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
		zoom -= 1 * 0.4
	}
	if keys[.X].down {
		zoom += 1 * 0.4
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
	}

	if g.mouse.wheel != 0 {
		zoom = g.mouse.wheel * 0.5
	}
	
	if zoom != 0 {
		g.world_camera.distance = clamp(g.world_camera.distance + zoom, 0.01, 50)
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
	g.world_camera.orbit.x = math.clamp(g.world_camera.orbit.x, 0, (math.PI / 2) - 0.001)
	camera_update(&g.world_camera)
}

draw :: proc(sim_state_interp: f32) {
	s := g.sim_state
	defer sg.commit()
	
	// compute prepass
	sg.begin_pass({compute = true})
	sg.apply_pipeline(g.erosion_pipeline)
	sg.apply_bindings(g.erosion_bindings)
	sg.dispatch(sim.CHUNK_SIZE, sim.CHUNK_SIZE, 1)
	sg.end_pass()

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
		sg.draw(0, sim.CHUNK_SIZE * sim.CHUNK_SIZE * 6 * 4 * 3, 1)
		
		// test cube
		// sg.apply_pipeline(g.cube_pipeline)
		// sg.apply_bindings(g.cube_bindings)
		// sg.apply_uniforms(shader.UB_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
		// sg.draw(0, 36, 1)

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

cam_mvp :: proc(cam: Camera) -> matrix[4, 4]f32 {
	model := linalg.MATRIX4F32_IDENTITY

	return cam._vp * model
}

camera_update :: proc(cam: ^Camera) {
	aspect := sapp.widthf() / sapp.heightf()
	projection := linalg.matrix4_perspective(math.to_radians(cam.fovy), aspect, 0.01, 100)
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

make_terrain_mesh :: proc(width: int) -> (bindings: sg.Bindings) {
	// TODO: remove vertex color when proper shader is implemented
	hex_count := width * width
	mesh_width := width + 2
	mesh_height := width + 1
	mesh_hex_count := mesh_width * mesh_height
	verts_per_hex := 3 * 4
	vertex_count := mesh_hex_count * verts_per_hex
	tris_per_hex := 6 * 4
	triangle_count := tris_per_hex * hex_count
	elements_per_hex := tris_per_hex * 3
	element_count := elements_per_hex * hex_count
	outer_radius: f32 = 0.57735026919 // = sqrt(0.75) * (2.0 / 3.0)
	inner_radius: f32 = 0.5
	half_edge := outer_radius / 2
	vert_positions := [7][2]f32 {
		{0, 0},
		// from top middle proceed clockwise
		{0, outer_radius},
		{inner_radius, half_edge},
		{inner_radius, -half_edge},
		{0, -outer_radius},
		{-inner_radius, -half_edge},
		{-inner_radius, half_edge},
	}

	vertex_floats :: 2 + 2 // 2 for xy position, 2 for cell coordinates
	verts := make([]f32, vertex_count * vertex_floats, context.temp_allocator)
	elements := make([]u16, element_count, context.temp_allocator)

	v_index := 0
	add_vert :: #force_inline proc(position: [2]f32, cell: [2]int, verts: []f32, index: ^int) {
		vd := verts[(index^ * vertex_floats):(index^ * vertex_floats) + vertex_floats]
		vd[0] = position.x
		vd[1] = position.y
		vd[2] = f32(cell.x) / 64
		vd[3] = f32(cell.y) / 64
		index^ += 1
	}

	// vertices
	for y in -1 ..< mesh_height - 1 {
		for x in -1 ..< mesh_width - 1 {
			hex_position := sim.grid_to_vec({i32(x), i32(y)})
			// first tri in hex
			for v in 0 ..< 3 {
				add_vert(hex_position + vert_positions[v], {x, y}, verts, &v_index)
			}
			// vert in center of each hex spoke
			for v in 0 ..< 6 {
				p1 := vert_positions[0]
				p2 := vert_positions[v + 1]
				pos := (p1 + p2) / 2
				add_vert(hex_position + pos, {x, y}, verts, &v_index)
			}
			// outside corner verts owned by this cell
			edge_indicies := [4]u16{6, 1, 2, 3}
			for v in 0 ..< 3 {
				p1 := vert_positions[edge_indicies[v]]
				p2 := vert_positions[edge_indicies[v + 1]]
				pos := (p1 + p2) / 2
				add_vert(hex_position + pos, {x, y}, verts, &v_index)
			}
		}
	}

	// indicies
	e_index := 0
	for y in 0 ..< width {
		for x in 0 ..< width {
			// compensate for expanded dimensions of vertex grid
			vc := (x + 1) + ((y + 1) * mesh_width)
			cell_base_element_index := vc * verts_per_hex
			// relative vertex indicies (cell base in compass direction)
			cbW := -verts_per_hex
			cbSE := -(verts_per_hex * mesh_width)
			cbSW := cbSE - verts_per_hex
			basis_indicies := [?]int {
				0,
				1,
				2,
				3,
				10,
				4,
				0,
				2,
				cbSE + 1,
				4,
				11,
				5,
				0,
				cbSE + 1,
				cbSW + 2,
				5,
				cbSE + 9,
				6,
				0,
				cbSW + 2,
				cbSW + 1,
				6,
				cbSW + 10,
				7,
				0,
				cbSW + 1,
				cbW + 2,
				7,
				cbW + 11,
				8,
				0,
				cbW + 2,
				1,
				8,
				9,
				3,
			}
			// hextant : quadrant, but 6 of them (slice is overloaded term)
			hextant_relative_indicies := [?]int{0, 3, 5, 1, 4, 3, 4, 2, 5, 3, 4, 5}
			for h in 0 ..< 6 {
				for e in 0 ..< 12 {
					ele :=
						cell_base_element_index +
						basis_indicies[hextant_relative_indicies[e] + (6 * h)]
					elements[e_index] = u16(ele)
					e_index += 1
				}
			}
		}
	}

	v_size := slice.size(verts)
	e_size := slice.size(elements)

	bindings.vertex_buffers[0] = sg.make_buffer(
		{data = {ptr = raw_data(verts), size = uint(v_size)}},
	)
	bindings.index_buffer = sg.make_buffer(
		{usage = {index_buffer = true}, data = {ptr = raw_data(elements), size = uint(e_size)}},
	)
	return bindings
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
