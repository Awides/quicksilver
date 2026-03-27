const std = @import("std");
const msdf = @import("msdf");

pub const LoadedAtlas = struct {
    atlas: msdf.AtlasData,
    glyph_size_px: u16,
    atlas_width: u16,
    atlas_height: u16,
};

const CacheHeader = extern struct {
    magic: u32,
    version: u32,
    width: u16,
    height: u16,
    glyph_count: u16,
    glyph_size_px: u16,
    range: u16,
    pixel_data_len: usize,
};

const thin_data = @embedFile("embedded/Iosevka-Thin_2048x2048_128px_32rg.atlas");
const heavy_data = @embedFile("embedded/Iosevka-Heavy_2048x2048_128px_32rg.atlas");
const aile_regular_data = @embedFile("embedded/IosevkaAile-Regular_2048x2048_128px_32rg.atlas");
const aile_semibold_data = @embedFile("embedded/IosevkaAile-SemiBold_2048x2048_128px_32rg.atlas");

fn loadAtlas(allocator: std.mem.Allocator, data: []const u8) !LoadedAtlas {
    // Copy to heap buffer to ensure proper alignment
    const buf = try allocator.alloc(u8, data.len);
    defer allocator.free(buf);
    @memcpy(buf, data);

    if (buf.len < @sizeOf(CacheHeader)) return error.InvalidAtlas;
    const header = @as(*const CacheHeader, @ptrCast(@alignCast(buf.ptr))).*;
    if (header.magic != 0x41544C43) return error.InvalidAtlas; // "CLTA"

    var offset: usize = @sizeOf(CacheHeader);
    const glyphs_len = header.glyph_count;
    const glyph_size = @sizeOf(msdf.AtlasGlyphData);
    if (buf.len < offset + glyphs_len * glyph_size) return error.InvalidAtlas;
    const glyphs_ptr = @as([*]const msdf.AtlasGlyphData, @ptrCast(@alignCast(buf.ptr + offset)));
    const glyphs = glyphs_ptr[0..glyphs_len];
    offset += glyphs_len * glyph_size;

    const pixel_data_len = header.pixel_data_len;
    if (buf.len < offset + pixel_data_len) return error.InvalidAtlas;
    const pixel_data = buf[offset..offset + pixel_data_len];

    // Allocate owned copies
    const owned_glyphs = try allocator.alloc(msdf.AtlasGlyphData, glyphs_len);
    @memcpy(owned_glyphs, glyphs);
    const owned_pixels = try allocator.alloc(u8, pixel_data_len);
    @memcpy(owned_pixels, pixel_data);
    const owned_kernings = try allocator.alloc(msdf.KerningPair, 0);

    return LoadedAtlas{
        .atlas = msdf.AtlasData{
            .glyphs = owned_glyphs,
            .kernings = owned_kernings,
            .pixels = .{ .normal = owned_pixels },
        },
        .glyph_size_px = header.glyph_size_px,
        .atlas_width = header.width,
        .atlas_height = header.height,
    };
}

pub fn getAtlas(allocator: std.mem.Allocator, font_label: []const u8) !LoadedAtlas {
    if (std.mem.eql(u8, font_label, "Iosevka-Thin")) {
        return loadAtlas(allocator, thin_data);
    } else if (std.mem.eql(u8, font_label, "Iosevka-Heavy")) {
        return loadAtlas(allocator, heavy_data);
    } else if (std.mem.eql(u8, font_label, "IosevkaAile-Regular")) {
        return loadAtlas(allocator, aile_regular_data);
    } else if (std.mem.eql(u8, font_label, "IosevkaAile-SemiBold")) {
        return loadAtlas(allocator, aile_semibold_data);
    } else {
        return error.UnknownFont;
    }
}
