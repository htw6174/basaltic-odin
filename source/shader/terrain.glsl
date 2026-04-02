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
  
  int h0 = texelFetch(isampler2D(base_map, ismp), in_texel, 0).x;
  int h1 = texelFetch(isampler2D(base_map, ismp), in_texel + ivec2(1, 0), 0).x;
  int h2 = texelFetch(isampler2D(base_map, ismp), in_texel + ivec2(1, 1), 0).x;
  
  // convert out_texel to barycentric coord to interpolate input samples
  
  float h = float(h0) / 128.0;
  
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
in ivec2 instance_coord;
// per-vertex
in vec2 position;
in ivec2 vertex_coord;

out vec4 color;
flat out ivec2 cell_coord;

void main() {
    cell_coord = instance_coord + vertex_coord;
    vec2 cell_uv = vec2(cell_coord) / vec2(map_size);
    float height = texture(sampler2D(heightmap, smp), cell_uv).x;
    gl_Position = mvp * vec4(instance_position + position, height * 10., 1.);
    //gl_Position = mvp * vec4(instance_position + position, 0., 1.);
    color = vec4(height.x, 0, 1. - height, 1.);
}
@end

@fs fs
in vec4 color;
flat in ivec2 cell_coord;
out vec4 frag_color;

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
  frag_color = color;
  //frag_color = vec4(ihash3(gl_PrimitiveID), 1.0);
}
@end

@program erosion cs_erosion
@program dynamic vs fs
