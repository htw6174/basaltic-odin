@header package shader
@header import sg "../sokol/gfx"

@module terrain

@include ./ctypes.glsl

@cs cs_erosion

layout(binding=0) uniform itexture2D base_map;
@sampler_type ismp nonfiltering
layout(binding=0) uniform sampler ismp;

layout(binding=1,rgba32f) uniform writeonly image2D erosion_map;

layout(local_size_x=16, local_size_y=16, local_size_z=1) in;

#define HEIGHT_AMP 1.0

// ------------------------------------------------------------------------
// Erosion parameters.
// ------------------------------------------------------------------------

// The scale of the erosion effect, affecting it both horizontally and vertically.
const float EROSION_SCALE = 0.15;

// The strength of the erosion effect, affecting the magnitude of all octaves,
// and indirectly affecting the directions of the gullies as a result.
const float EROSION_STRENGTH = 0.22;

// The magnitude of the gullies as a weight value from 0 to 1.
// A value of 0 can sharpen peaks and valleys but feature virtually no gullies.
// A value of 1 produces full gullies but may leave peaks and valleys rounded.
// Adjusting erosion gully weight while inversely adjusting erosion scale can be
// used to control the sharpness of peaks and valleys while leaving gully
// magnitudes largely untocuhed.
const float EROSION_GULLY_WEIGHT = 0.5;

// The overall detail of the erosion. Lower values restrict the effect of higher
// frequency gullies to steeper slopes.
const float EROSION_DETAIL = 1.5;

// Separate rounding control of ridges and creases.
//  x: Rounding of ridges.
//  y: Rounding of creases.
//  z: Multiplier applied to the initial height function.
//     E.g. if the height function has noise of 5 times lower frequency
//     than the largest gullies, a value of 0.2 can compensate for that.
//  w: Multiplier applied to each subsequent gully octave after the first.
//     Setting it to the same value as the erosion lacunarity will produce
//     consistent rounding of all octaves.
const vec4 EROSION_ROUNDING = vec4(0.1, 0.0, 0.1, 2.0);

// Control over how far away from ridges/creases the erosion takes effect.
//  x: Onset used on the initial height function.
//  y: Onset used on each gully octave.
//  z: RidgeMap-specific onset used on the initial height function.
//  w: RidgeMap-specific onset used on each gully octave.
const vec4 EROSION_ONSET = vec4(1.25, 1.25, 2.8, 1.5);

// Control over the assumed slope of the initial height function.
// In practise, assuming a slope can work better than using the input slope,
// since the final terrain can be shaped quite differently than the input.
//  x: An assumed slope value to override the actual slope.
//  y: The amount (from 0 to 1) to override the actual slope.
const vec2 EROSION_ASSUMED_SLOPE = vec2(0.7, 1.0);

// Gullies are based on stripes within Voronoi-like cells in the Phacelle noise
// function. The cell scale parameter controls the sizes of the cells relative
// to the overall erosion scale, while keeping the stripe widths unaffected.
// Values close to 1 usually produce good results. Smaller values produce more
// grainy gullies while larger values produce longer unbroken gullies, but too
// large values produce chaotic curved gullies that are not aligned with the
// slopes. Value changes can cause abrupt changes in output, especially far away
// from the origin, so this parameter is not well suited for animation or for
// modulation by other functions.
const float EROSION_CELL_SCALE = 0.7;
// The degree of normalization applied in the Phacelle noise, between 0 and 1.
// The erosion filter depends on a certain consistency in magnitude of the
// Phacelle output. However, high values can create loopy results where ridges
// and creases meet up at a point, which produces unnatural looking results.
const float EROSION_NORMALIZATION = 0.5;

// Control over the erosion octaves, with each successive octave layering
// smaller gullies onto the terrain.
const int EROSION_OCTAVES = 5;
// The lacunarity controls the frequency (the inverse
// horizontal scale) of each octave relative to the last.
const float EROSION_LACUNARITY = 2.0;
// The gain controls the magnitude (the vertical
// scale) of each octave relative to the last.
const float EROSION_GAIN = 0.5;


// Move this block to common?
// -----------------------------------------------------------------------------
// Misc utility functions
// -----------------------------------------------------------------------------

#define DEG_TO_RAD (PI / 180.0)
#define clamp01(x) clamp(x, 0.0, 1.0)
#define sq(x) (x*x)

vec2 hash(in vec2 x) {
    const vec2 k = vec2(0.3183099, 0.3678794);
    x = x * k + k.yx;
    return -1.0 + 2.0 * fract(16.0 * k * fract(x.x * x.y * (x.x + x.y)));
}

// -----------------------------------------------------------------------------
// PHACELLE NOISE FUNCTION
// -----------------------------------------------------------------------------

#define TAU 6.28318530717959

// The Simple Phacelle Noise function produces a stripe pattern aligned with the input vector.
// The name Phacelle is a portmanteau of phase and cell, since the function produces a phase by
// interpolating cosine and sine waves from multiple cells.
//  - p is the input point being evaluated.
//  - normDir is the direction of the stripes at this point. It must be a normalized vector.
//  - freq is the freqency of the stripes within each cell. It's best to keep it close to 1.0, as
//    high values will produce distortions and other artifacts.
//  - offset is the phase offset of the stripes, where 1.0 is a full cycle.
//  - normalization is the degree of normalization applied, between 0 and 1. With e.g. a value of
//    0.4, raw output with a magnitude below 0.6 won't get fully normalized to a magnitude of 1.0.
// Phacelle Noise function copyright (c) 2025 Rune Skovbo Johansen
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
vec4 PhacelleNoise(in vec2 p, vec2 normDir, float freq, float offset, float normalization) {
    // Get a vector orthogonal to the input direction, with a
    // magnitude proportional to the frequency of the stripes.
    vec2 sideDir = normDir.yx * vec2(-1.0, 1.0) * freq * TAU;
    offset *= TAU;

    // Iterate over 4x4 cells, calculating a stripe pattern for each and blending between them.
    // pInt is the integer part of the current coordinate p, pFrac is the remainder.
    //
    // o   o   o   o
    //
    // o   o   o   o
    //       p
    // o   i   o   o
    //
    // o   o   o   o
    //
    // p: current coordinate    i: integer part of p    o: grid points for 4x4 cells
    //
    vec2 pInt = floor(p);
    vec2 pFrac = fract(p);
    vec2 phaseDir = vec2(0.0);
    float weightSum = 0.0;
    for (int i = -1; i <= 2; i++) {
        for (int j = -1; j <= 2; j++) {
            vec2 gridOffset = vec2(i, j);

            // Calculate a cell point by starting off with a point in the integer grid.
            vec2 gridPoint = pInt + gridOffset;

            // Calculate a random offset for the cell point between -0.5 and 0.5 on each axis.
            vec2 randomOffset = hash(gridPoint) * 0.5;

            // The final cell point (we don't store it) is the gridPoint plus the randomOffset.
            // Calculate a vector representing the input point relative to this cell point:
            // p - (gridPoint + randomOffset)
            // = (pFrac + pInt) - ((pInt + gridOffset) + randomOffset)
            // = pFrac + pInt - pInt - gridOffset - randomOffset
            // = pFrac - gridOffset - randomOffset
            vec2 vectorFromCellPoint = pFrac - gridOffset - randomOffset;

            // Bell-shaped weight function which is 1 at dist 0 and nearly 0 at dist 1.5.
            // Due to the random offsets of up to 0.5, the closest a cell point not in the 4x4
            // grid can be to the current point p is 1.5 units away.
            float sqrDist = dot(vectorFromCellPoint, vectorFromCellPoint);
            float weight = exp(-sqrDist * 2.0);
            // Subtract 0.01111 to make the function actually 0 at distance 1.5, which avoids
            // some (very subtle) grid line artefacts.
            weight = max(0.0, weight - 0.01111);

            // Keep track of the total sum of weights.
            weightSum += weight;

            // The waveInput is a gradient which increases in value along sideDir. Its rate of
            // change is the freq times tau, due to the multiplier pre-applied to sideDir.
            float waveInput = dot(vectorFromCellPoint, sideDir) + offset;

            // Add this cell's cosine and sine wave contributions to the interpolated value.
            phaseDir += vec2(cos(waveInput), sin(waveInput)) * weight;
        }
    }

    // Get the raw interpolated value.
    vec2 interpolated = phaseDir / weightSum;
    // Interpret the value as a vector whose length represents the magnitude of both waves.
    float magnitude = sqrt(dot(interpolated, interpolated));
    // Apply a lower threshold to show small magnitudes we're going to fully normalize.
    magnitude = max(1.0 - normalization, magnitude);
    // Return a vector containing the normalized cosine and sine waves, as well as the direction
    // vector, which can be multiplied onto the sine to get the derivatives of the cosine.
    return vec4(interpolated / magnitude, sideDir);
}

// -----------------------------------------------------------------------------
// EROSION FUNCTION
// -----------------------------------------------------------------------------

// First a few utility functions.

float pow_inv(float t, float power) {
    // Flip, raise to the specified power, and flip back.
    return 1.0 - pow(1.0 - clamp01(t), power);
}

float ease_out(float t) {
    // Flip by subtracting from one.
    float v = 1.0 - clamp01(t);
    // Raise to a power of two and flip back.
    return 1.0 - v * v;
}

float smooth_start(float t, float smoothing) {
    if (t >= smoothing)
        return t - 0.5 * smoothing;
    return 0.5 * t * t / smoothing;
}

vec2 safe_normalize(vec2 n) {
 	// A div-by-zero-safe replacement for normalize.
    float l = length(n);
	return (abs(l) > 1e-10) ? (n / l) : n;	
}

// Advanced Terrain Erosion Filter copyright (c) 2025 Rune Skovbo Johansen
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
vec4 ErosionFilter(
    // Input parameters that vary per pixel.
    in vec2 p, vec3 heightAndSlope, float fadeTarget,
    // Stylistic parameters that may vary per pixel.
    float strength, float gullyWeight, float detail, vec4 rounding, vec4 onset, vec2 assumedSlope,
    // Scale related parameters that do not support variation per pixel.
    float scale, int octaves, float lacunarity,
    // Other parameters.
    float gain, float cellScale, float normalization,
    // Output parameters.
    out float ridgeMap, out float debug
) {
    strength *= scale;
    fadeTarget = clamp(fadeTarget, -1.0, 1.0);
    
    vec3 inputHeightAndSlope = heightAndSlope;
    float freq = 1.0 / (scale * cellScale);
    float slopeLength = max(length(heightAndSlope.yz), 1e-10);
    float magnitude = 0.0;
    float roundingMult = 1.0;
    
    float roundingForInput = mix(rounding.y, rounding.x, clamp01(fadeTarget + 0.5)) * rounding.z;
    // The combined accumulating mask, based first on initial slope, and later on slope of each octave too.
    float combiMask = ease_out(smooth_start(slopeLength * onset.x, roundingForInput * onset.x));

    // Initialize the ridgeMap fadeTarget and mask.
    float ridgeMapCombiMask = ease_out(slopeLength * onset.z);
    float ridgeMapFadeTarget = fadeTarget;
    
    // Deteriming the strength of the initial slope used for gully directions
    // based on the specified mix of the actual slope and an assumed slope.
    vec2 gullySlope = mix(heightAndSlope.yz, heightAndSlope.yz / slopeLength * assumedSlope.x, assumedSlope.y);
    
    for (int i = 0; i < octaves; i++) {
        // Calculate and add gullies to the height and slope.
        vec4 phacelle = PhacelleNoise(p * freq, safe_normalize(gullySlope), cellScale, 0.25, normalization);
        // Multiply with freq since p was multiplied with freq.
        // Negate since we use slope directions that point down.
        phacelle.zw *= -freq;
        // Amount of slope as value from 0 to 1.
        float sloping = abs(phacelle.y);
        
        // Add non-masked, normalized slope to gullySlope, for use by subsequent octaves.
        // It's normalized to use the steepest part of the sine wave everywhere.
        gullySlope += sign(phacelle.y) * phacelle.zw * strength * gullyWeight;
        
        // Handle height offset and approximate output slope.
        
        // Gullies has height offset (from -1 to 1) in x and derivative in yz.
        vec3 gullies = vec3(phacelle.x, phacelle.y * phacelle.zw);
        // Fade gullies towards fadeTarget based on combiMask.
        vec3 fadedGullies = mix(vec3(fadeTarget, 0.0, 0.0), gullies * gullyWeight, combiMask);
        // Apply height offset and derivative (slope) according to strength of current octave.
        heightAndSlope += fadedGullies * strength;
        magnitude += strength;
        
        // Update fadeTarget to include the new octave.
        fadeTarget = fadedGullies.x;
        
        // Update the mask to include the new octave.
        float roundingForOctave = mix(rounding.y, rounding.x, clamp01(phacelle.x + 0.5)) * roundingMult;
        float newMask = ease_out(smooth_start(sloping * onset.y, roundingForOctave * onset.y));
        combiMask = pow_inv(combiMask, detail) * newMask;
        
        // Update the ridgeMap fadeTarget and mask.
        ridgeMapFadeTarget = mix(ridgeMapFadeTarget, gullies.x, ridgeMapCombiMask);
        float newRidgeMapMask = ease_out(sloping * onset.w);
        ridgeMapCombiMask = ridgeMapCombiMask * newRidgeMapMask;

        // Prepare the next octave.
        strength *= gain;
        freq *= lacunarity;
        roundingMult *= rounding.w;
    }
    
    ridgeMap = ridgeMapFadeTarget * (1.0 - ridgeMapCombiMask);
    debug = fadeTarget;
    
    vec3 heightAndSlopeDelta = heightAndSlope - inputHeightAndSlope;
    return vec4(heightAndSlopeDelta, magnitude);
}

// End of copy-pasted code

ivec2 texelWrap(ivec2 coord, ivec2 range) {
  return (coord + range) % range;
}

//sqrt(3/4)
#define Y_FACTOR 0.8660254040
vec2 gridToCartesian(vec2 grid) {
  return vec2(grid.x - (grid.y * 0.5), grid.y * Y_FACTOR);
}

void main() {
  ivec2 in_texel = ivec2(gl_WorkGroupID.xy);
  ivec2 out_texel = ivec2(gl_GlobalInvocationID.xy);
  //isampler2D base_smp = isampler2D(base_map, ismp);
  vec2 sample_uv = vec2(gl_LocalInvocationID.xy) / vec2(gl_WorkGroupSize.xy);
  
  ivec2 map_size = textureSize(isampler2D(base_map, ismp), 0);
  int h0 = texelFetch(isampler2D(base_map, ismp), texelWrap(in_texel              , map_size), 0).x;
  int h1 = texelFetch(isampler2D(base_map, ismp), texelWrap(in_texel + ivec2(1, 0), map_size), 0).x;
  int h2 = texelFetch(isampler2D(base_map, ismp), texelWrap(in_texel + ivec2(1, 1), map_size), 0).x;
  int h3 = texelFetch(isampler2D(base_map, ismp), texelWrap(in_texel + ivec2(0, 1), map_size), 0).x;
  // Same ordering as textureGather, x is top-left, runs ccw to w at bottom-left
  vec4 samples = vec4(h3, h2, h1, h0) / 128.0;
  // result is constant across whole workgroup; TODO research if this is automatically optimized in any way
  // NOTE: sampling integer textures isn't supported in the HLSL version sokol uses, must change types or texelfetch 4 samples manually
  //vec4 samples = vec4(textureGather(isampler2D(base_map, ismp), in_texel / textureSize(isampler2D(base_map, ismp), 0), 0)) / 128.0;
  vec2 cell_grid = vec2(out_texel) * vec2(map_size) / imageSize(erosion_map);
  vec2 cell_axial = cell_grid * vec2(1., -1.);
  vec2 base_cell_axial = vec2(in_texel.x, -in_texel.y);
  vec2 local_axial = cell_axial - base_cell_axial;
 	// cubic interpolation to smooth out first and second derivatives
	// vec2 f = local_axial * vec2(1., -1.);
	// f = f*f*(3.0-2.0*f);
	// vec2 fa = f * vec2(1., -1.);
	vec2 fa = local_axial;
  float s = -fa.x - fa.y;
  // Determine simplex and convert axial coordinates to barycentric to interpolate samples
  // 0 on -s side, 1 on +s side
  float cell_simplex = ceil(s);
  vec3 barycentric; // blending factors for nearest 3 cells to this point
  if (cell_simplex == 0) {
    barycentric = vec3(1. - fa.x, -fa.y, -s);
  } else {
    barycentric = vec3(1. + fa.y, fa.x, s);
  }
  // vec3 f = barycentric;
  // barycentric = f*f*(3.0-2.0*f);
  // use .z or .x depending on simplex
  float height = (barycentric.x * samples.w) + 
                 (barycentric.y * samples.y) +
                 (barycentric.z * ((1. - cell_simplex) * samples.z + (cell_simplex * samples.x)));
  
  // Setup for ErosionFilter params
  // For slope of surface at a point, can use delta of 2 horizontal points in simplex and delta of their midpoint from 3rd point, sign flipped based on simplex
  // However, this slope will be the same within the entire simplex, which will produce blocky output (same as what I'm seeing with the normals)
  // Need a better way to smooth across the whole surface
  vec2 gradient;
  if (cell_simplex == 0) {
    gradient = vec2(samples.z - samples.w, samples.y - (samples.z + samples.w) / 2.);
  } else {
    gradient = vec2(samples.y - samples.x, (samples.y + samples.x) / 2. - samples.w);
  }
  //vec4 phacelle = PhacelleNoise(gridToCartesian(cell_grid) * 0.75, safe_normalize(gradient), 1.0, 0.25, 0.5);
  // height must be in 0..1 range
  vec3 height_and_slope = vec3(height * 0.5 + 0.5, gradient * 20.);
  
  // Define the erosion fade target based on the altitude of the pre-eroded terrain.
  // The fade target should strive to be -1 at valleys and 1 at peaks, but overshooting is ok.
  float fadeTarget = clamp(height_and_slope.x / (HEIGHT_AMP * 0.6), -1.0, 1.0);
  
  float ridgeMap, debug;
  vec4 erode = ErosionFilter(
    gridToCartesian(cell_grid) / map_size, height_and_slope, fadeTarget, 
    EROSION_STRENGTH, EROSION_GULLY_WEIGHT, EROSION_DETAIL,
    EROSION_ROUNDING, EROSION_ONSET, EROSION_ASSUMED_SLOPE,
    EROSION_SCALE, EROSION_OCTAVES, EROSION_LACUNARITY,
    EROSION_GAIN, EROSION_CELL_SCALE, EROSION_NORMALIZATION,
    ridgeMap, debug
  );
  
  // TODO: should use empty channels for normals calculated with all 7 closest samples
  //imageStore(erosion_map, out_texel, vec4(height + erode.x, erode.yz * 0.5 + 0.5, ridgeMap));
  imageStore(erosion_map, out_texel, vec4(height_and_slope.x, gradient * 0.5 + 0.5, 0.));
}
@end

@vs vs
@include ./common.glsl
layout(binding=0) uniform texture2D heightmap;
layout(binding=0) uniform sampler smp;

// TODO: set with uniform
const ivec2 map_size = ivec2(128);
const float vertical_scale = 20.;

// per-instance
in vec2 instance_position;
in vec2 instance_axial;
// per-vertex
in vec2 position;
in vec2 vertex_axial;

out vec3 normal;
out vec4 color;
flat out vec2 cell_axial;

void main() {
    cell_axial = instance_axial + vertex_axial; // for use with cube coordinate math, q & r components
    vec2 cell_grid = cell_axial * vec2(1, -1); // for sampling textures which don't wrap
    //vec3 cube_coord = vec3(qr, -qr.x - qr.y);
    vec2 map_uv = cell_axial / vec2(map_size); // for sampling data that span the whole map
    // use cube coords to determine which texels need to be sampled and interpolate between them
    // base cell is closest cell to the bottom-left of this vertex
    vec2 base_cell_axial = vec2(floor(cell_axial.x), ceil(cell_axial.y));
    vec2 base_cell_grid = vec2(base_cell_axial.x, -base_cell_axial.y);
    vec2 base_cell_uv = base_cell_grid / vec2(map_size);
    //vec4 samples = textureGather(sampler2D(heightmap, smp), map_uv, 0);
    vec4 erosion_samp = texture(sampler2D(heightmap, smp), map_uv);
    float height = erosion_samp.x;
    vec2 local_axial = cell_axial - base_cell_axial;
    float s = -local_axial.x - local_axial.y;
    // Determine simplex and convert axial coordinates to barycentric
    // 0 on -s side, 1 on +s side
    float cell_simplex = ceil(s);
    vec3 barycentric; // blending factors for nearest 3 cells to this point
    if (cell_simplex == 0) {
      barycentric = vec3(1. - local_axial.x, -local_axial.y, -s);
    } else {
      barycentric = vec3(1. + local_axial.y, local_axial.x, s);
    }
    // use .z or .x depending on simplex
    // float height = (barycentric.x * samples.w) + 
    //                (barycentric.y * samples.y) +
    //                (barycentric.z * ((1. - cell_simplex) * samples.z + (cell_simplex * samples.x)));
    gl_Position = mvp * vec4(instance_position + position, height * vertical_scale, 1.);
    
    // normal TODO: precalc in another compute shader pass?
    //vec2 edge_length = vec2(0.57735026919);
    vec2 samp_delta = vec2(1.) / textureSize(sampler2D(heightmap, smp), 0);
    vec2 uv_to_world = vec2(map_size);
    vec2 samp_offset_x = vec2(cos(radians(120.)), sin(radians(120.))) * samp_delta;
    vec2 samp_offset_y = vec2(cos(radians(60.)), sin(radians(60.))) * samp_delta;
    vec2 samp_offset_z = vec2(1., 0.) * samp_delta;
    vec2 uv1 = vec2(samp_delta.x, 0.);
    vec2 uv2 = vec2(0., samp_delta.y);
    float h1 = texture(sampler2D(heightmap, smp), map_uv + uv1).x;
    float h2 = texture(sampler2D(heightmap, smp), map_uv + uv2).x;
    
    // Must scale components back to world space because the scale factor for xy and z are different
    vec3 tangent = vec3(uv1 * uv_to_world, (h1 - height) * vertical_scale);
    vec3 bitangent = vec3(uv2 * uv_to_world, (h2 - height) * vertical_scale);
    normal = normalize(cross(tangent, bitangent));
    
    //color = vec4(vec3(erosion_samp.w) * 0.5 + 0.5, 1.);
    color = vec4(vec3(erosion_samp.xyz), erosion_samp.w * 0.5 + 0.5);
}
@end

@fs fs
in vec3 normal;
in vec4 color;
flat in vec2 cell_axial;
out vec4 frag_color;

// TODO: set with uniform
const ivec2 map_size = ivec2(128);

uint ihash(uint n)
{
    n = (n ^ 61u) ^ (n >> 16u);
    n *= 9u;
    n = n ^ (n >> 4u);
    n *= 0x27d4eb2du;
    return n ^ (n >> 15u);
}

vec3 ihash3(int n)
{
  return vec3(
    float(ihash(uint(n))) / 4294967295.0,
    float(ihash(uint(n + 1u))) / 4294967295.0,
    float(ihash(uint(n + 2u))) / 4294967295.0
  );
}

#define DIFFUSE 1.25
#define REFLECTION 1.0

#define LIGHT_AMBIENT 0.05
#define LIGHT1_DIFFUSE 1.0

float phong(vec3 normal, vec3 lightDir) {
    float ambient = REFLECTION * LIGHT_AMBIENT;
    //vec3 reflection = normalize(reflect(-camera_position, normal));
    float dotLN = dot(lightDir, normal);
    if (dotLN < 0.0) {
        return ambient;
    }
    float diffuse = DIFFUSE * dotLN * LIGHT1_DIFFUSE;
    //pow(max(dot(reflect(e,n),l),0.0),s) * nrm;
    return ambient + diffuse;
}

void main() {
  vec3 albedo;
  //albedo = color.www;
  //albedo = ihash3(gl_PrimitiveID);
  int cell_idx = int(round(cell_axial.x)) + (int(round(-cell_axial.y)) * map_size.x);
  //albedo = ihash3(cell_idx);
  //albedo = vec3(0.2, 0.7, 0.1);
  albedo = (normal * 0.5) + 0.5;
  float light = 1.;
  //float light = phong(normal, normalize(vec3(1., 1., 1.)));
  frag_color = vec4(albedo * light, 1.0);
}
@end

@program erosion cs_erosion
@program dynamic vs fs
