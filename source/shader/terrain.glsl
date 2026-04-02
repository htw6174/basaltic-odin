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
  
  float h = float(h0);
  
  imageStore(erosion_map, out_texel, vec4(h, 0., 0., 0.));
}
@end

@vs vs
@include ./common.glsl
layout(binding=0) uniform texture2D heightmap;
layout(binding=0) uniform sampler smp;

in vec2 position;
in vec2 cell_uv;

out vec4 color;

void main() {
    vec4 height = texture(sampler2D(heightmap, smp), cell_uv);
    gl_Position = mvp * vec4(position, height.x * 10., 1);
    color = vec4(height.x, 0, 1. - height.x, 1.);
}
@end

@fs fs
in vec4 color;
out vec4 frag_color;

void main() {
    frag_color = color;
}
@end

@program erosion cs_erosion
@program dynamic vs fs
