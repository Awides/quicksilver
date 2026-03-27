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

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@fragment
fn fs_main(@builtin(position) frag_pos: vec4f) -> @location(0) vec4f {
  return vec4f(0.0, 0.0, 0.0, 1.0);
}
