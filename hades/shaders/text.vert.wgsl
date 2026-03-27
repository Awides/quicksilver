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

@group(0) @binding(2) var<uniform> uniforms: Uniforms;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
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
  // Floating offset (screen space)
  let float_offset = vec2f(
    sin(uniforms.time * 0.7) * 50.0,
    cos(uniforms.time * 0.5) * 30.0
  );

  // Entrance + breathing scale factor, multiplied by base_scale
  let entrance = smoothstep(0.0, 0.5, uniforms.time);
  let anim_scale = 1.0 + 0.1 * sin(uniforms.time * 2.0);
  let scale = uniforms.base_scale * entrance * anim_scale;

  // Center the text at window_center, then apply offset
  var final_pos = (pos - orig_center) * scale + window_center + float_offset;

  // Viscosity distortion: vertices pushed away from nearby blobs
  if (uniforms.viscosity > 0.0) {
    var disp = vec2f(0.0, 0.0);
    for (var i: u32 = 0; i < 4; i++) {
      let blob = uniforms.blobs[i];
      let blob_pos = vec2f(blob.pos_x, blob.pos_y);
      let diff = final_pos - blob_pos;
      let dist = length(diff);
      let influence = blob.radius + 80.0;
      if (dist < influence) {
        let force = (1.0 - dist / influence) * uniforms.viscosity * 40.0;
        disp += normalize(diff) * force;
      }
    }
    final_pos += disp;
  }

  let ndc = (final_pos / vec2f(uniforms.resolution_x, uniforms.resolution_y)) * 2.0 - 1.0;
  out.position = vec4f(ndc.x, -ndc.y, 0.0, 1.0);
  out.uv = uv;
  return out;
}
