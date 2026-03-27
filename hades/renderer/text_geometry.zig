const std = @import("std");
const wgpu = @import("wgpu");
const msdf = @import("msdf");
const render_types = @import("render_types.zig");

pub const Geometry = struct {
    vertex_buffer: *wgpu.Buffer,
    vertex_count: u32,
    center_x: f32,
    center_y: f32,
    text_width: f32,
};

pub fn buildGeometry(
    allocator: std.mem.Allocator,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    message: []const u21,
    atlas: *const LoadedAtlas,
    start_x: f32,
    baseline_y: f32,
) !Geometry {
    // Build glyph map from atlas
    var glyph_map = std.AutoHashMap(u21, msdf.AtlasGlyphData).init(allocator);
    for (atlas.atlas.glyphs) |g| {
        try glyph_map.put(g.codepoint, g);
    }
    defer glyph_map.deinit();

    // Build vertices
    const px_scale = @as(f64, @floatFromInt(atlas.glyph_size_px));
    var vertices = std.ArrayList(render_types.Vertex).empty;
    var pen_x = start_x;
    for (message) |cp| {
        const glyph_info = glyph_map.get(cp) orelse continue;
        const m = glyph_info.glyph_data;
        const width = @as(f32, @floatCast(m.width));
        const height = @as(f32, @floatCast(m.height));
        const advance = @as(f32, @floatCast(m.advance * px_scale));
        const bearing_x = @as(f32, @floatCast(m.bearing_x * px_scale));
        const bearing_y = @as(f32, @floatCast(m.bearing_y * px_scale));
        const x0 = pen_x + bearing_x;
        const y0 = baseline_y - bearing_y;
        const x1 = x0 + width;
        const y1 = y0 + height;
        const u_min = @as(f32, @floatCast(glyph_info.tex_u));
        const v_min = @as(f32, @floatCast(glyph_info.tex_v));
        const u_max = @as(f32, @floatCast(glyph_info.tex_u + glyph_info.tex_w));
        const v_max = @as(f32, @floatCast(glyph_info.tex_v + glyph_info.tex_h));
        try vertices.append(allocator, .{ .pos = .{ x0, y0 }, .uv = .{ u_min, v_min } });
        try vertices.append(allocator, .{ .pos = .{ x1, y0 }, .uv = .{ u_max, v_min } });
        try vertices.append(allocator, .{ .pos = .{ x0, y1 }, .uv = .{ u_min, v_max } });
        try vertices.append(allocator, .{ .pos = .{ x1, y0 }, .uv = .{ u_max, v_min } });
        try vertices.append(allocator, .{ .pos = .{ x1, y1 }, .uv = .{ u_max, v_max } });
        try vertices.append(allocator, .{ .pos = .{ x0, y1 }, .uv = .{ u_min, v_max } });
        pen_x += advance;
    }
    const vertex_slice = try vertices.toOwnedSlice(allocator);
    errdefer allocator.free(vertex_slice);

    // Create vertex buffer
    const buffer_size = @sizeOf(render_types.Vertex) * vertex_slice.len;
    const vertex_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .size = buffer_size,
        .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
        .mapped_at_creation = @intFromBool(false),
    }) orelse return error.CreateBufferFailed;

    const vertex_bytes = std.mem.sliceAsBytes(vertex_slice);
    queue.writeBuffer(vertex_buffer, 0, vertex_bytes.ptr, vertex_bytes.len);
    // We'll free the vertex_slice after upload; buffer holds copy
    allocator.free(vertex_slice);

    // Compute bounding box
    var min_x: f32 = 1e9;
    var min_y: f32 = 1e9;
    var max_x: f32 = -1e9;
    var max_y: f32 = -1e9;
    // We need vertices again for bbox, but we freed. Instead compute on the fly while building, or reconstruct from glyph metrics. Simpler: as we built vertices, we also tracked min/max. Let's adjust: we can compute during vertex building.
    // We'll modify builder to compute min/max while appending.
    // Actually we can compute bbox from glyph positions directly.
    // Let's recompute: We'll iterate over message again using glyph_map and same calculations, but track min/max of quad positions.
    var pen_x2 = start_x;
    for (message) |cp| {
        const glyph_info = glyph_map.get(cp) orelse {
            continue;
        };
        const m = glyph_info.glyph_data;
        const width = @as(f32, @floatCast(m.width));
        const height = @as(f32, @floatCast(m.height));
        const advance = @as(f32, @floatCast(m.advance * px_scale));
        const bearing_x = @as(f32, @floatCast(m.bearing_x * px_scale));
        const bearing_y = @as(f32, @floatCast(m.bearing_y * px_scale));
        const x0 = pen_x2 + bearing_x;
        const y0 = baseline_y - bearing_y;
        const x1 = x0 + width;
        const y1 = y0 + height;
        if (x0 < min_x) min_x = x0;
        if (y0 < min_y) min_y = y0;
        if (x1 > max_x) max_x = x1;
        if (y1 > max_y) max_y = y1;
        pen_x2 += advance;
    }
    const center_x = (min_x + max_x) / 2.0;
    const center_y = (min_y + max_y) / 2.0;
    const text_width = max_x - min_x;

    return Geometry{
        .vertex_buffer = vertex_buffer,
        .vertex_count = @intCast(vertex_slice.len),
        .center_x = center_x,
        .center_y = center_y,
        .text_width = text_width,
    };
}

const LoadedAtlas = @import("font_atlas.zig").LoadedAtlas;
