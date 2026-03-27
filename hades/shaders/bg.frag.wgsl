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

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@fragment
fn fs_main(@builtin(position) frag_pos: vec4f) -> @location(0) vec4f {
  let resolution = vec2f(uniforms.resolution_x, uniforms.resolution_y);
  let uv = frag_pos.xy / resolution;
  let t = uniforms.time * 0.2 + uniforms.phase;
  var color = 0.15 + 0.15 * cos(t + uv.xyx + vec3f(0.0, 2.0, 4.0));

   var blob_alpha: f32 = 0.0;
   for (var i: u32 = 0; i < 4; i++) {
     let blob = uniforms.blobs[i];
     let blob_pos = vec2f(blob.pos_x, blob.pos_y);
     let diff = frag_pos.xy - blob_pos;
     let dist = length(diff);
     let a = 1.0 - smoothstep(blob.radius * 0.7, blob.radius, dist);
     blob_alpha = max(blob_alpha, a);
   }

  let blob_color = vec3f(1.0, 0.9, 0.8);
  color = mix(color, blob_color, blob_alpha * 0.6);

  return vec4f(color, 1.0);
}
