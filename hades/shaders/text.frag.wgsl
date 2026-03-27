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

@group(0) @binding(0) var font_texture: texture_2d_array<f32>;
@group(0) @binding(1) var font_sampler: sampler;
@group(0) @binding(2) var<uniform> uniforms: Uniforms;

fn median(a: f32, b: f32, c: f32) -> f32 {
  let ab_min = min(a, b);
  let ab_max = max(a, b);
  let c_min = min(ab_max, c);
  return max(ab_min, c_min);
}

@fragment
fn fs_main(@location(0) uv: vec2f, @location(1) screen_pos: vec2f) -> @location(0) vec4f {
  // Sample glyph SDF
  let c = textureSample(font_texture, font_sampler, uv, uniforms.font_layer).rgb;
  let d = median(c.r, c.g, c.b);

  // Glyph density: smooth transition from inside (1) to outside (0)
  let glyph_density = smoothstep(0.45, 0.55, d);

  // Droplet density contribution with edge-distance and vertical falloff
  var drop_field: f32 = 0.0;
  for (var i: u32 = 0; i < 128; i++) {
    let drop = uniforms.sweat_droplets[i];
    if (drop.life <= 0.0) { continue; }
    let dvec = screen_pos - vec2f(drop.x, drop.y);
    let dist = length(dvec);
    let infl = drop.radius * 1.5;
    if (dist < infl) {
      let m = 1.0 - dist / infl;
      let falloff = m * m;

      // Distance from glyph edge: 0 at edge, positive inside/outside
      let edge_dist = abs(d - 0.5);
      // Fade when far from edge: strong fade for deep inside, less for outside near edge
      let edge_fade = smoothstep(0.3, 0.0, edge_dist);

      // Vertical bias: lower y (larger screen y) gets less fade
      // Normalized y in [0,1] where 0 at top, 1 at bottom
      let y_norm = screen_pos.y / uniforms.resolution_y;
      let vertical_bias = y_norm; // more fade reduction at bottom

      // Combined factor: base edge_fade plus vertical influence
      let factor = edge_fade * (0.1 + 0.9 * vertical_bias);

      drop_field += falloff * drop.life * uniforms.metaball_alpha * 0.04 * factor;
    }
  }

  // Combined density (glyph + droplets)
  let total = glyph_density + drop_field;

  // Threshold with soft edge to create a cohesive, gloopy shape
  let width = 0.1 + 0.05 * fwidth(total);
  let alpha = smoothstep(0.6, 0.75, total);

  // Glow based on warped distance (total)
  let glow_width = 0.15 + uniforms.glow * 0.2;
  let glow_factor = smoothstep(0.5 - glow_width, 0.5 + glow_width, total) * exp(-abs(total - 0.5) / glow_width);
  let glow_color = vec3f(1.0, 0.9, 0.7);

  var color = vec3f(1.0, 1.0, 1.0);
  color += glow_color * glow_factor * uniforms.glow;

  return vec4f(color, alpha);
}
