package game

import "core:math"
import "core:math/linalg"
import "core:slice"
import "sim"
import sg "sokol/gfx"

Vertex_Data :: struct {
	cartesian: [2]f32,
	axial: [2]f32,
}

// Returns a "pointy top" hexagon of regular triangles with the center at [0, 0] and the right side at x=inner_radius
// For u16 indicies, the maximum segments_per_side is 60
make_hex_tri_mesh :: proc(segments_per_side: int, inner_radius: f32) -> (vertex_buffer, index_buffer: sg.Buffer) {
	assert(segments_per_side > 0)
	radius := segments_per_side + 1
	outer_radius := inner_radius * sim.HALF_SQRT_3 * 4 / 3
	edge_length := outer_radius / f32(segments_per_side)
	vertex_count := sim.hex_area(radius)
	triangle_count := segments_per_side * segments_per_side * 6
	element_count := triangle_count * 3
	assert(element_count < 1 << 16)
	
	verts := make([]Vertex_Data, vertex_count, context.temp_allocator)
	elements := make([]u16, element_count, context.temp_allocator)
	
	verts[0] = {}
	element: int = 0
	for layer in 2..=radius {
		layer_verts := sim.hex_perimeter(layer)
		layer_side_verts := layer_verts / 6
		layer_base_vert := sim.hex_area(layer - 1)
		// need information about previous layer to connect triangles with it
		prev_layer_verts := sim.hex_perimeter(layer - 1)
		prev_layer_side_verts := prev_layer_verts / 6
		prev_layer_base_vert := layer_base_vert - prev_layer_verts
		for v in 0..<layer_verts {
			side := v / layer_side_verts
			vert := layer_base_vert + v
			verts_from_corner := v - (layer_side_verts * side)
			
			// Corner angles for a pointy-top hex: 0/6*TAU, 1/6*TAU, ...
			corner_angle_a := f32(side) / 6.0 * math.TAU
			corner_angle_b := f32(side + 1) / 6.0 * math.TAU
			
			corner_a := [2]f32{math.sin(corner_angle_a), math.cos(corner_angle_a)} * f32(layer - 1) * edge_length
			corner_b := [2]f32{math.sin(corner_angle_b), math.cos(corner_angle_b)} * f32(layer - 1) * edge_length
			
			t := f32(verts_from_corner) / f32(layer_side_verts)
			pos := linalg.lerp(corner_a, corner_b, t)

			// TEST: just put the verts on a circle
			// theta := (f32(v) / f32(layer_verts)) * math.TAU
			// pos := [2]f32{math.sin(theta), math.cos(theta)} * f32(layer) * edge_length
			verts[vert] = {
				cartesian = pos,
				axial = sim.cartesian_to_axial(pos),
			}
			
			if v % layer_side_verts == 0 {
				// this is a corner
				// make one triangle with current vert, next, and same corner from previous layer
				elements[element    ] = u16(vert)
				elements[element + 1] = u16(layer_base_vert + (v + 1) % layer_verts)
				elements[element + 2] = u16(prev_layer_base_vert + (prev_layer_side_verts * side))
				element += 3
			} else {
				// this is on an edge
				// make two triangles with verts at corresponding offset from corner in previous layer
				elements[element    ] = u16(vert)
				elements[element + 1] = u16(prev_layer_base_vert + ((prev_layer_side_verts * side) + verts_from_corner) % prev_layer_verts)
				elements[element + 2] = u16(prev_layer_base_vert + (prev_layer_side_verts * side) + verts_from_corner - 1)
				elements[element + 3] = u16(vert)
				elements[element + 4] = u16(layer_base_vert + (v + 1) % layer_verts)
				elements[element + 5] = u16(prev_layer_base_vert + ((prev_layer_side_verts * side) + verts_from_corner) % prev_layer_verts)
				element += 6
			}
		}
	}
	
	vertex_buffer = sg.make_buffer(
		{data = {ptr = raw_data(verts), size = uint(slice.size(verts))}},
	)
	index_buffer = sg.make_buffer(
		{usage = {index_buffer = true}, data = {ptr = raw_data(elements), size = uint(slice.size(elements))}},
	)
	return vertex_buffer, index_buffer
}

make_hex_grid_mesh :: proc(width: int) -> (vertex_buffer, index_buffer: sg.Buffer) {
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
	verts := make([]Vertex_Data, vertex_count, context.temp_allocator)
	elements := make([]u16, element_count, context.temp_allocator)

	v_index := 0
	add_vert :: #force_inline proc(position: [2]f32, verts: []Vertex_Data, index: ^int) {
		vd := &verts[index^]
		vd.cartesian = position
		vd.axial = sim.cartesian_to_axial(position)
		index^ += 1
	}

	// vertices
	for y in -1 ..< mesh_height - 1 {
		for x in -1 ..< mesh_width - 1 {
			hex_position := sim.grid_to_vec({i32(x), i32(y)})
			// first tri in hex
			for v in 0 ..< 3 {
				add_vert(hex_position + vert_positions[v], verts, &v_index)
			}
			// vert in center of each hex spoke
			for v in 0 ..< 6 {
				p1 := vert_positions[0]
				p2 := vert_positions[v + 1]
				pos := (p1 + p2) / 2
				add_vert(hex_position + pos, verts, &v_index)
			}
			// outside corner verts owned by this cell
			edge_indicies := [4]u16{6, 1, 2, 3}
			for v in 0 ..< 3 {
				p1 := vert_positions[edge_indicies[v]]
				p2 := vert_positions[edge_indicies[v + 1]]
				pos := (p1 + p2) / 2
				add_vert(hex_position + pos, verts, &v_index)
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

	vertex_buffer = sg.make_buffer(
		{data = {ptr = raw_data(verts), size = uint(v_size)}},
	)
	index_buffer = sg.make_buffer(
		{usage = {index_buffer = true}, data = {ptr = raw_data(elements), size = uint(e_size)}},
	)
	return vertex_buffer, index_buffer
}
