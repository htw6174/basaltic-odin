package sim

import "core:hash/xxhash"
import "core:math"

CHUNK_SIZE :: 32

//sqrt(3)/2
HALF_SQRT_3 :: 0.8660254040

Grid_Coord :: distinct [2]i32
Cube_Coord :: distinct [3]i32

Hex_Direction :: enum {
	NORTH_EAST,
	EAST,
	SOUTH_EAST,
	SOUTH_WEST,
	WEST,
	NORTH_WEST,
}

cube_directions :: [Hex_Direction]Cube_Coord {
	.NORTH_EAST = {0, 1, -1},
	.EAST       = {1, 0, -1},
	.SOUTH_EAST = {1, -1, 0},
	.SOUTH_WEST = {0, -1, 1},
	.WEST       = {-1, 0, 1},
	.NORTH_WEST = {-1, 1, 0},
}

axial_directions :: [Hex_Direction]Grid_Coord {
	.NORTH_EAST = {0, 1},
	.EAST       = {1, 0},
	.SOUTH_EAST = {1, -1},
	.SOUTH_WEST = {0, -1},
	.WEST       = {-1, 0},
	.NORTH_WEST = {-1, 1},
}

chunk_cell_to_grid :: proc "contextless" (origin: Grid_Coord, cell_index: int) -> Grid_Coord {
	return origin + {i32(cell_index) % CHUNK_SIZE, i32(cell_index) / CHUNK_SIZE}
}

grid_to_vec :: proc "contextless" (grid: Grid_Coord) -> [2]f32 {
	x := f32(grid.x)
	y := f32(grid.y)
	return {x - (y * 0.5), y * HALF_SQRT_3}
}

cartesian_to_axial :: proc "contextless" (pos: [2]f32) -> [2]f32 {
	return {pos.x + (pos.y * 0.5 / HALF_SQRT_3), -pos.y * (1 / HALF_SQRT_3)}
}

hex_perimeter :: proc "contextless" (#any_int radius: int) -> int {
	return max(6 * (radius - 1), 1)
}

hex_area :: proc "contextless" (#any_int radius: int) -> int {
	return (3 * (radius * radius)) - (3 * radius) + 1
}

xxh_2d :: proc "contextless" (seed: u32, x, y: i32) -> f32 {
	hash := seed + xxhash.XXH_PRIME32_5
	// add input size for matching behavior with generalized hash
	hash += 2 * 4

	// unrolled loop
	hash += u32(x) * xxhash.XXH_PRIME32_3
	hash = (hash << 17) | (hash >> (32 - 17)) * xxhash.XXH_PRIME32_4
	hash += u32(y) * xxhash.XXH_PRIME32_3
	hash = (hash << 17) | (hash >> (32 - 17)) * xxhash.XXH_PRIME32_4

	hash ~= hash >> 15
	hash *= xxhash.XXH_PRIME32_2
	hash ~= hash >> 13
	hash *= xxhash.XXH_PRIME32_3
	hash ~= hash >> 16

	return f32(hash) / (1 << 32)
}

simplex_2d :: proc "contextless" (x, y: f32, repeat_x, repeat_y: i32, seed: u32) -> f32 {
	integral_x, fraction_x := math.modf(x)
	integral_y, fraction_y := math.modf(y)
	ix := i32(integral_x)
	iy := i32(integral_y)
	// wrap sample coordinates
	x0 := ix % repeat_x
	x1 := (ix + 1) % repeat_x
	y0 := iy % repeat_y
	y1 := (iy + 1) % repeat_y

	simplex: f32 = 0 if fraction_x > fraction_y else 1
	//simplex: f32 = 0 if fraction_x + fraction_y < 1 else 1

	// kernels - deterministic random values at closest simplex corners
	k1 := xxh_2d(seed, x0, y0)
	k2 := xxh_2d(seed, x1, y1)
	k3 := xxh_2d(seed, x1, y0) if simplex == 0 else xxh_2d(seed, x0, y1)

	// distance of sample from each corner, using cube coordinate distance
	d1 := (abs(fraction_x - 0) + abs(fraction_x - fraction_y - 0 + 0) + abs(-fraction_y + 0)) / 2.0
	d2 := (abs(fraction_x - 1) + abs(fraction_x - fraction_y - 1 + 1) + abs(-fraction_y + 1)) / 2.0
	d3 :=
		(abs(fraction_x - (1 - simplex)) +
		 abs(fraction_x - fraction_y - (1 - simplex) + simplex) +
		 abs(-fraction_y + simplex)) / 2.0

	c1 := k1 * (1 - d1)
	c2 := k2 * (1 - d2)
	c3 := k3 * (1 - d3)

	return c1 + c2 + c3
}

fill_grid_simplex :: proc "contextless" (
	values: []f32,
	origin: Grid_Coord,
	area: [2]i32,
	seed: u32,
	octaves, repeat_interval, samples_per_repeat: i32,
) {
	scale := f32(samples_per_repeat) / f32(repeat_interval)
	denominator := (1 << u32(octaves)) - 1
	for &value, i in values {
		x := origin.x + (i32(i) % area.x)
		y := origin.y + (i32(i) / area.y)
		scaled_x := f32(x) * scale
		scaled_y := f32(y) * scale
		domain := samples_per_repeat
		numerator := 1 << (u32(octaves) - 1)
		value = 0

		for iter in 0 ..< octaves {
			weight := f32(numerator) / f32(denominator)
			numerator = numerator >> 1
			value += simplex_2d(scaled_x, scaled_y, domain, domain, seed) * weight
			scaled_x *= 2
			scaled_y *= 2
			domain *= 2
		}
	}
}
