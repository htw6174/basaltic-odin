@header package shader
@header import sg "../sokol/gfx"

@module terrain

@include ./ctypes.glsl

@cs cs_erosion

layout(binding=0) uniform itexture2D base_map;
@sampler_type ismp nonfiltering
layout(binding=0) uniform sampler ismp;

layout(binding=1,rgba32f) uniform writeonly image2D erosion_map;

layout(local_size_x=8, local_size_y=8, local_size_z=1) in;

ivec2 texelWrap(ivec2 coord, ivec2 range) {
  return (coord + range) % range;
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
  vec4 samples = vec4(h3, h2, h1, h0) / 128.0;
  // result is constant across whole workgroup; TODO research if this is automatically optimized in any way
  // NOTE: sampling integer textures isn't supported in the HLSL version sokol uses, must change types or texelfetch 4 samples manually
  //vec4 samples = vec4(textureGather(isampler2D(base_map, ismp), in_texel / textureSize(isampler2D(base_map, ismp), 0), 0)) / 128.0;
  vec2 cell_grid = vec2(out_texel) * vec2(map_size) / imageSize(erosion_map);
  vec2 cell_axial = cell_grid * vec2(1., -1.);
  vec2 base_cell_axial = vec2(in_texel.x, -in_texel.y);
  vec2 local_axial = cell_axial - base_cell_axial;
  float s = -local_axial.x - local_axial.y;
  // Determine simplex and convert axial coordinates to barycentric to interpolate samples
  // 0 on -s side, 1 on +s side
  float cell_simplex = ceil(s);
  vec3 barycentric; // blending factors for nearest 3 cells to this point
  if (cell_simplex == 0) {
    barycentric = vec3(1. - local_axial.x, -local_axial.y, -s);
  } else {
    barycentric = vec3(1. + local_axial.y, local_axial.x, s);
  }
  // use .z or .x depending on simplex
  float height = (barycentric.x * samples.w) + 
                 (barycentric.y * samples.y) +
                 (barycentric.z * ((1. - cell_simplex) * samples.z + (cell_simplex * samples.x)));
  
  // TODO: should use empty channels for normals calculated with all 7 closest samples
  imageStore(erosion_map, out_texel, vec4(height, 0., 0., 0.));
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
    vec2 cell_grid = instance_axial + vertex_axial;
    cell_axial = cell_grid * vec2(1, -1); // for use with cube coordinate math, q & r components
    //vec3 cube_coord = vec3(qr, -qr.x - qr.y);
    vec2 map_uv = cell_grid / vec2(map_size); // for sampling data that span the whole map
    // FIXME: this is a quick hack to get the map looking right. Somewhere, the simplex heightmap is getting flipped on one axis. Need to generate a heightmap with an obvious correct direction to determine correct orientation.
    map_uv  *= vec2(1, -1);
    // use cube coords to determine which texels need to be sampled and interpolate between them
    // base cell is closest cell to the bottom-left of this vertex
    vec2 base_cell_axial = vec2(floor(cell_axial.x), ceil(cell_axial.y));
    vec2 base_cell_grid = vec2(base_cell_axial.x, -base_cell_axial.y);
    vec2 base_cell_uv = base_cell_grid / vec2(map_size);
    //vec4 samples = textureGather(sampler2D(heightmap, smp), map_uv, 0);
    float height = texture(sampler2D(heightmap, smp), map_uv).x;
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
    
    // TODO: I don't understand why this doesn't need the vertical scale factored in to the height delta, but it looks wrong with it and right without it
    vec3 tangent = vec3(uv1 * uv_to_world, (h1 - height) * vertical_scale);
    vec3 bitangent = vec3(uv2 * uv_to_world, (h2 - height) * vertical_scale);
    // if (true) {
    //   tangent = vec3(samp_pos_z * edge_length, (samples.z - samples.w) * vertical_scale);
    //   bitangent = vec3(samp_pos_x * edge_length, (samples.x - samples.w) * vertical_scale);
    // } else {
    //   tangent = vec3(samp_pos_y * edge_length, (samples.y - samples.w) * vertical_scale);
    //   bitangent = vec3(samp_pos_x * edge_length, (samples.x - samples.w) * vertical_scale);
    // }
    normal = normalize(cross(tangent, bitangent));// * vec3(1., 1., -1.);
    //normal = vec3(samp_pos_x, edge_length);
    //normal = barycentric;
    
    color = vec4(height, 0, -height, 1.);
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
  //albedo = color.xyz;
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
