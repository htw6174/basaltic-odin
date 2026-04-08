package sim

import "core:hash/xxhash"
import "core:math"
import "core:math/linalg"

CHUNK_SIZE :: 32

//sqrt(3)/2
HALF_SQRT_3 :: 0.8660254040

Grid_Coord  :: distinct [2]i32 // to identify discrete cells
Cube_Coord  :: distinct [3]i32 // not often needed but useful for some calculations
Axial_Coord :: distinct [2]f32 // first 2 components of a cube coordinate, can lie between cells

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

grid_to_index :: proc "contextless" (grid: Grid_Coord, array_size: [2]int) -> int {
	// TODO: wrap coord to within 2d array bounds
	wrapped_x := math.floor_mod(int(grid.x), array_size.x)
	wrapped_y := math.floor_mod(int(grid.y), array_size.y)
	return wrapped_x + wrapped_y * array_size.x
}

grid_to_cartesian :: proc "contextless" (grid: Grid_Coord) -> [2]f32 {
	return axial_to_cartesian({f32(grid.x), f32(grid.y)})
}

axial_to_cartesian :: proc "contextless" (axial: [2]f32) -> [2]f32 {
	return {axial.x + (axial.y * 0.5), -axial.y * HALF_SQRT_3}
}

cartesian_to_axial :: proc "contextless" (cartesian: [2]f32) -> [2]f32 {
	return {cartesian.x + (cartesian.y * 0.5 / HALF_SQRT_3), -cartesian.y * (1 / HALF_SQRT_3)}
}

// Euclidean squared distance in axial coords
axial_dist2 :: proc "contextless" (d: [2]f32) -> f32 {
    return d.x * d.x + d.y * d.y + d.x * d.y
}

// Euclidean dot product in axial coords  (u^T G v)
axial_dot :: proc "contextless" (u, v: [2]f32) -> f32 {
    return u.x*v.x + u.y*v.y + (u.x*v.y + u.y*v.x) * 0.5
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

gradient :: proc "contextless" (seed: u32, p: [2]i32) -> [2]f32 {
	theta := xxh_2d(seed, p.x, p.y) * math.TAU
	return {math.cos(theta), math.sin(theta)}
}

simplex_2d :: proc "contextless" (sample: [2]f32, repeat: [2]i32, seed: u32) -> f32 {
	// ix, fx := math.modf(sample.x)
	// iy, fy := math.modf(sample.y)
	iq := math.floor(sample.x)
	ir := math.ceil(sample.y)
	fq := sample.x - iq
	fr := sample.y - ir
	f := [2]f32{fq, fr}
	p0 := [2]i32{i32(iq), i32(ir)}
	// wrap sample coordinates for getting gradient at lattice points
	// TODO: fix repeat on negative points
	p0 = p0 % repeat
	p1 := (p0 + {1, -1}) % repeat
	if p1.y < 0 do p1.y += repeat.y
	
	lower := -f.x - f.y < 0
	
	// displacement of sample from corners
	d0 := f
	d1 := f - {1, -1}
	d2 := f - ({1, 0} if lower else {0, -1})
	
	// kernels - deterministic random gradient at closest simplex corners
	g0 := gradient(seed, p0)
	g1 := gradient(seed, p1)
	g2 := gradient(seed, {p1.x, p0.y} if lower else {p0.x, p1.y})

	contribution :: #force_inline proc "contextless" (displacement, gradient: [2]f32) -> f32 {
		R2 :: 0.5
		t := R2 - axial_dist2(displacement)
		if t <= 0 do return 0
		t = t * t * t * t
		return t * axial_dot(gradient, displacement)
	}
	c0 := contribution(d0, g0)
	c1 := contribution(d1, g1)
	c2 := contribution(d2, g2)
	n := c0 + c1 + c2
	
	return n * 70
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
		sample := origin + {i32(i) % area.x, i32(i) / area.y}
		scaled_sample := [2]f32{f32(sample.x), f32(sample.y)} * scale
		domain := samples_per_repeat
		numerator := 1 << (u32(octaves) - 1)
		value = 0

		for iter in 0 ..< octaves {
			weight := f32(numerator) / f32(denominator)
			numerator = numerator >> 1
			value += simplex_2d(scaled_sample, {domain, domain}, seed) * weight
			scaled_sample *= 2
			domain *= 2
		}
	}
}
