package sim

import ecs "../flecs"
import "base:runtime"
import "core:math"

// Cell_Isolated :: struct {
// 	height:              i8,
// 	visibility:          u8,
// 	geology:             u32,
// 	tracks:              u16,
// 	temperature:         i16,
// 	humidity_preference: i16,
// 	understory:          u32,
// 	canopy:              u32,
// }

// Cell_Flowing :: struct {
// 	ground_water:  i16,
// 	surface_water: i16,
// }

// Cell_Data :: struct {
// 	isolated: Cell_Isolated,
// 	flowing:  Cell_Flowing,
// }

Cell_Data :: struct {
	height:              i8,
	visibility:          u8,
	geology:             u32,
	tracks:              u16,
	temperature:         i16,
	humidity_preference: i16,
	understory:          u32,
	canopy:              u32,
	ground_water:        i16,
	surface_water:       i16,
}

Climate :: struct {
	pole_bio_temp:                  i16,
	equator_bio_temp:               i16,
	temp_change_per_elevation_step: i16,
	seasonal_temperature_range:     i16,
	seasonal_temperature_actual:    i16,
	cycle_length:                   i32,
	cycle_actual:                   i32,
}

Chunk :: struct {
	data:   []Cell_Data,
	origin: Grid_Coord,
}

Plane :: struct {
	chunks:    [16]Chunk,
	climate:   Climate,
	allocator: runtime.Allocator,
}

plane_ctor :: proc "c" (ptr: rawptr, count: i32, type_info: ^ecs.Type_Info) {
	planes := ([^]Plane)(ptr)
	for i in 0 ..< count {
		plane := &planes[i]
		for &c in plane.chunks {
			c.data = nil
		}
	}
}

plane_dtor :: proc "c" (ptr: rawptr, count: i32, type_info: ^ecs.Type_Info) {
	context = runtime.default_context()
	planes := ([^]Plane)(ptr)
	for i in 0 ..< count {
		plane := &planes[i]
		for &c in plane.chunks {
			delete(c.data, allocator = plane.allocator)
		}
	}
}

plane_copy :: proc "c" (dst_ptr: rawptr, src_ptr: rawptr, count: i32, type_info: ^ecs.Type_Info) {
	dst_planes := ([^]Plane)(dst_ptr)
	src_planes := ([^]Plane)(src_ptr)
	for i in 0 ..< count {
		dst_planes[i] = src_planes[i]
	}
}

plane_move :: proc "c" (dst_ptr: rawptr, src_ptr: rawptr, count: i32, type_info: ^ecs.Type_Info) {
	context = runtime.default_context()
}

plane_get :: proc(plane: ^Plane, coord: Grid_Coord) -> ^Cell_Data {
	// Wrap coord to within plane bounds
	// Translate coord to chunk and cell within chunk
	// TODO can I make the return type of this cleaner while still allowing access to all components?
	cell_data := &plane.chunks[0].data[coord.x + (coord.y * CHUNK_SIZE)]
	return cell_data
}

update_plane :: proc "contextless" (plane: ^Plane) {
	climate := &plane.climate
	climate.cycle_actual = (climate.cycle_actual + 1) % climate.cycle_length
	climate.seasonal_temperature_actual = i16(
		(math.sin(f32(climate.cycle_actual) * math.TAU) / f32(climate.cycle_length)) *
		f32(climate.seasonal_temperature_range),
	)

	for chunk in plane.chunks {
		for &c, i in chunk.data {
			coord := chunk_cell_to_grid(chunk.origin, i)
			temperature_actual := c.temperature + plane.climate.seasonal_temperature_actual

			evaporation: i16 = 0

			if c.surface_water > 0 {
				infiltration: i16 = 0
				c.ground_water = math.max(1, c.ground_water) + infiltration
				c.surface_water -= evaporation + infiltration
			}
		}
	}
}

system_step_day :: proc "c" (it: ^ecs.Iter) {
	planes := ecs.field(it, Plane, 0)

	for i in 0 ..< it.count {
		update_plane(&planes[i])
	}
}
