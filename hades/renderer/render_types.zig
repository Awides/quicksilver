const std = @import("std");
const wgpu = @import("wgpu");

pub const Vec2 = extern struct {
    x: f32,
    y: f32,
};

pub const Blob = extern struct {
    pos_x: f32,
    pos_y: f32,
    radius: f32,
    pad: f32,
};

pub const Droplet = extern struct {
    x: f32,
    y: f32,
    radius: f32,
    life: f32,
};

pub const AppUniforms = extern struct {
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
    // padding to align blobs to 16 bytes (offset must be multiple of 16)
    pad1: f32,
    pad2: f32,
    pad3: f32,
    blobs: [4]Blob,
    sweat_droplets: [128]Droplet,
};

pub const Vertex = struct {
    pos: [2]f32,
    uv: [2]f32,
};

pub const FontInfo = struct {
    glyph_map: std.AutoHashMap(u21, @import("msdf").AtlasGlyphData),
    vertex_buffer: ?*wgpu.Buffer,
    vertex_count: u32,
    text_width: f32,
    text_height: f32,
    center_x: f32,
    center_y: f32,
    glyph_size_px: u16,
};
