@header package shader
@header import sg "../sokol/gfx"

@module terrain

@include ./ctypes.glsl

@cs cs_erosion

layout(binding=0) uniform itexture2D base_map;
@sampler_type ismp nonfiltering
layout(binding=0) uniform sampler ismp;

layout(binding=1,r32f) uniform writeonly image2D erosion_map;

layout(local_size_x=8, local_size_y=8, local_size_z=1) in;

void main() {
  ivec2 in_texel = ivec2(gl_WorkGroupID.xy);
  ivec2 out_texel = ivec2(gl_GlobalInvocationID.xy);
  vec2 sample_uv = vec2(gl_LocalInvocationID.xy) / vec2(gl_WorkGroupSize.xy);
  
  int h0 = texelFetch(isampler2D(base_map, ismp), in_texel, 0).x;
  int h1 = texelFetch(isampler2D(base_map, ismp), in_texel + ivec2(1, 0), 0).x;
  int h2 = texelFetch(isampler2D(base_map, ismp), in_texel + ivec2(1, 1), 0).x;
  
  // convert out_texel to barycentric coord to interpolate input samples
  
  float h = (float(h0) / 128.0);
  
  imageStore(erosion_map, out_texel, vec4(h, 0., 0., 0.));
}
@end

@vs vs
@include ./common.glsl
layout(binding=0) uniform texture2D heightmap;
layout(binding=0) uniform sampler smp;

// TODO: set with uniform
const ivec2 map_size = ivec2(128);

// per-instance
in vec2 instance_position;
in vec2 instance_axial;
// per-vertex
in vec2 position;
in vec2 vertex_axial;

out vec4 color;
flat out vec2 cell_axial;

void main() {
    vec2 qr = (instance_axial.xy + vertex_axial.xy) * vec2(1, -1);
    cell_axial = qr;
    //vec3 cube_coord = vec3(qr, -qr.x - qr.y);
    // use cube coords to determine which texels need to be sampled and interpolate between them
    vec2 base_cell_axial = vec2(floor(qr.x), ceil(qr.y));
    vec2 base_cell_grid = vec2(base_cell_axial.x, -base_cell_axial.y);
    vec2 base_cell_uv = base_cell_grid / vec2(map_size);
    vec4 samples = textureGather(sampler2D(heightmap, smp), base_cell_uv, 0);
    //vec2 cell_uv = cell_coord / vec2(map_size);
    //float height = texture(sampler2D(heightmap, smp), cell_uv).x;
    vec2 sample_uv = qr - base_cell_axial;
    float s = -sample_uv.x - sample_uv.y;
    // Determine simplex and convert axial coordinates to barycentric
    // 0 on -s side, 1 on +s side
    float simplex = ceil(s);
    vec3 barycentric;
    if (simplex == 0) {
      barycentric = vec3(1. - sample_uv.x, -sample_uv.y, -s);
    } else {
      barycentric = vec3(1. + sample_uv.y, sample_uv.x, s);
    }
    // use .z or .x depending on simplex
    float height = (barycentric.x * samples.w) + 
                   (barycentric.y * samples.y) +
                   (barycentric.z * ((1. - simplex) * samples.z + (simplex * samples.x)));
    gl_Position = mvp * vec4(instance_position + position, height * 20., 1.);
    //gl_Position = mvp * vec4(instance_position + position, 0., 1.);
    color = vec4(height, 0, -height, 1.);
}
@end

@fs fs
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

void main() {
  //frag_color = color;
  //frag_color = vec4(ihash3(gl_PrimitiveID), 1.0);
  int cell_idx = int(round(cell_axial.x)) + (int(round(-cell_axial.y)) * map_size.x);
  frag_color = vec4(ihash3(cell_idx), 1.0);
}
@end

@program erosion cs_erosion
@program dynamic vs fs
