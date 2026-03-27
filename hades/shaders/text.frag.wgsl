struct Blob {
  pos_x: f32,
  pos_y: f32,
  radius: f32,
  pad: f32,
};

struct Uniforms {
  resolution_x: f32,
  resolution_y: f32,
  center_x: f32,
  center_y: f32,
  time: f32,
  viscosity: f32,
  glow: f32,
  phase: f32,
  base_scale: f32,
  font_layer: i32,
  pad1: f32,
  pad2: f32,
  blobs: array<Blob, 4>,
};

@group(0) @binding(0) var font_texture: texture_2d_array<f32>;
@group(0) @binding(1) var font_sampler: sampler;
@group(0) @binding(2) var<uniform> uniforms: Uniforms;

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  // Sample from the specified array layer
  let c = textureSample(font_texture, font_sampler, uv, uniforms.font_layer).rgb;
  let d = median(c.r, c.g, c.b);

  // Edge width for anti-aliasing
  let width = fwidth(d);

  // Normal text alpha
  let alpha = smoothstep(0.5 - width, 0.5 + width, d);

  // Glow from distance field
  let glow_width = 0.15 + uniforms.glow * 0.2;
  let glow_factor = smoothstep(0.5 - glow_width, 0.5 + glow_width, d) * exp(-abs(d - 0.5) / glow_width);
  let glow_color = vec3f(1.0, 0.9, 0.7);

  // Combine text color with glow (additive before alpha)
  var color = vec3f(1.0, 1.0, 1.0);
  color += glow_color * glow_factor * uniforms.glow;

  return vec4f(color, alpha);
}

fn median(a: f32, b: f32, c: f32) -> f32 {
  let ab_min = min(a, b);
  let ab_max = max(a, b);
 let c_min = min(ab_max, c);
  return max(ab_min, c_min);
}
