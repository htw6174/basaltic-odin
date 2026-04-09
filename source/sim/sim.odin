package sim
import ecs "../flecs"
import "core:fmt"
import "core:math"

// Sim timesteps always represent a fixed time interval. Use to convert to seconds for rendering and set speeds based on seconds.
STEPS_PER_SECOND :: 60

CHUNKS_PER_SIDE :: 4
WORLD_SIZE :: CHUNK_SIZE * CHUNKS_PER_SIDE

State :: struct {
	step:  int,
	seed:  u32,
	world: ^ecs.World,
}

init :: proc(s: ^State) {
	s.step = 0
	s.world = ecs.init()
	ecs.import_module(s.world, ecs.FlecsRestImport, "FlecsRest")
	ecs.set_id(
		s.world,
		ecs.FLECS_IDEcsRestID_,
		ecs.FLECS_IDEcsRestID_,
		size_of(ecs.Ecs_Rest),
		&ecs.Ecs_Rest{},
	)
	// FIXME: undefined symbol on import function
	//ecs.import_module(s.world, ecs.FlecsStatsImport, "FlecsStats")

	w := s.world
	plane_c := ecs.component(w, Plane)
	ecs.set_hooks_id(
		w,
		plane_c,
		&{ctor = plane_ctor, dtor = plane_dtor, move = plane_move, copy = plane_copy},
	)

	plane := Plane {
		climate = {
			pole_bio_temp = 4000,
			equator_bio_temp = -1500,
			temp_change_per_elevation_step = -65,
			seasonal_temperature_range = 2000,
			cycle_length = 360,
		},
		allocator = context.allocator,
	}

	valuemap := make([]f32, CHUNK_SIZE * CHUNK_SIZE, allocator = context.temp_allocator)
	for &c, i in plane.chunks {
		c.data = make([]Cell_Data, CHUNK_SIZE * CHUNK_SIZE, allocator = plane.allocator)
		c.origin = {i32(i % CHUNKS_PER_SIDE), i32(i / CHUNKS_PER_SIDE)} * CHUNK_SIZE
		fill_grid_simplex(
			valuemap,
			c.origin,
			{CHUNK_SIZE, CHUNK_SIZE},
			s.seed,
			3,
			WORLD_SIZE,
			3,
		)
		for &cell, j in c.data {
			cell.height = i8((valuemap[j] * 0.5) * 256)
		}
	}

	e := ecs.new(w)
	ecs.set(w, e, &plane)

	_ = ecs.system(w, system_step_day, ecs.EcsOnUpdate, "Plane")
}

fini :: proc(s: ^State) {
	ecs.fini(s.world)
	s.world = nil
}

step :: proc(s: ^State) {
	s.step += 1
	ecs.progress(s.world, 1.0 / STEPS_PER_SECOND)
}
