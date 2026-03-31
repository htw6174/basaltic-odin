layout(binding = 0) uniform globals {
  float time;
  vec4 mouse; // xy = position, zw = delta (coordinate space?)
};

layout(binding = 1) uniform vs_params {
  mat4 mvp;
};
