@header package shader
@header import sg "../sokol/gfx"

@module terrain

@include ./ctypes.glsl

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

@program dynamic vs fs
