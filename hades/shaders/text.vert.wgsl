struct Blob {
  pos_x: f32,
  pos_y: f32,
  radius: f32,
  pad: f32,
};

struct Droplet {
  x: f32,
  y: f32,
  radius: f32,
  life: f32,
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
  demo_mode: i32,
  metaball_alpha: f32,
  metaball_hardness: f32,
  pad1: f32,
  pad2: f32,
  pad3: f32,
  blobs: array<Blob, 4>,
  sweat_droplets: array<Droplet, 128>,
};

@group(0) @binding(2) var<uniform> uniforms: Uniforms;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) screen_pos: vec2f,
};

@vertex
fn vs_main(
  @location(0) pos: vec2f,
  @location(1) uv: vec2f,
) -> VertexOutput {
  var out: VertexOutput;

  // Original text center (from vertex buffer)
  let orig_center = vec2f(uniforms.center_x, uniforms.center_y);
  // Target window center
  let window_center = vec2f(uniforms.resolution_x, uniforms.resolution_y) * 0.5;

  var scale = uniforms.base_scale;
  var float_offset = vec2f(0.0, 0.0);

  // Splash demo: animate; Drippy demo: stay centered and still
  if (uniforms.demo_mode == 0) {
    float_offset = vec2f(
      sin(uniforms.time * 0.7) * 50.0,
      cos(uniforms.time * 0.5) * 30.0
    );
    let entrance = smoothstep(0.0, 0.5, uniforms.time);
    let anim_scale = 1.0 + 0.1 * sin(uniforms.time * 2.0);
    scale = scale * entrance * anim_scale;
  }

   // Center the text at window_center, then apply offset
   var final_pos = (pos - orig_center) * scale + window_center + float_offset;

   // Glyphs remain in fixed position; no vertex displacement.

   let ndc = (final_pos / vec2f(uniforms.resolution_x, uniforms.resolution_y)) * 2.0 - 1.0;
  out.position = vec4f(ndc.x, -ndc.y, 0.0, 1.0);
  out.uv = uv;
  out.screen_pos = final_pos;
  return out;
}
