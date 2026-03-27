const std = @import("std");
const glfw = @import("zglfw");
const wgpu = @import("wgpu");
const msdf = @import("msdf");
const native_os = @import("builtin").target.os.tag;
const win = if (native_os == .windows) @cImport({
    @cInclude("windows.h");
}) else void;

// Uniform buffer layout matching WGSL std140
const Vec2 = extern struct {
    x: f32,
    y: f32,
} align(8);

const Blob = extern struct {
    pos_x: f32,
    pos_y: f32,
    radius: f32,
    pad: f32,
};

const AppUniforms = extern struct {
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
    blobs: [4]Blob,
};

const Vertex = struct {
    pos: [2]f32,
    uv: [2]f32,
};

const FontInfo = struct {
    glyph_map: std.AutoHashMap(u21, msdf.AtlasGlyphData),
    vertex_buffer: *wgpu.Buffer,
    vertex_count: u32,
    text_width: f32,
    center_x: f32,
    center_y: f32,
};

const text_vs_source = @embedFile("shaders/text.vert.wgsl");
const text_fs_source = @embedFile("shaders/text.frag.wgsl");
const bg_vs_source = @embedFile("shaders/bg.vert.wgsl");
const bg_fs_source = @embedFile("shaders/bg.frag.wgsl");

var g_adapter: ?*wgpu.Adapter = null;
var g_device: ?*wgpu.Device = null;

fn loadOrGenerateAtlas(
    allocator: std.mem.Allocator,
    font_label: []const u8,
    generator: anytype,
    codepoints: []const u21,
    atlas_width: u16,
    atlas_height: u16,
    glyph_size_px: u16,
    range: u16,
    padding: u8,
    use_kerning: bool,
) !msdf.AtlasData {
    const cache_dir = "cache";
    const cache_name = std.fmt.allocPrint(allocator, "{s}_{d}x{d}_{d}px_{d}rg.atlas", .{
        font_label, atlas_width, atlas_height, glyph_size_px, range,
    }) catch unreachable;
    defer allocator.free(cache_name);
    const cache_path = try std.fs.path.join(allocator, &.{ cache_dir, cache_name });

    const CacheHeader = extern struct {
        magic: u32 = 0x41544C43,
        version: u32 = 1,
        width: u16,
        height: u16,
        glyph_count: u16,
        glyph_size_px: u16,
        range: u16,
        pixel_data_len: usize,
    };

    if (std.fs.cwd().openFile(cache_path, .{ .mode = .read_only })) |file| {
        defer file.close();
        var header: CacheHeader = undefined;
        if (file.read(std.mem.asBytes(&header))) |bytes_read| {
            if (bytes_read == @sizeOf(CacheHeader) and
                header.magic == 0x41544C43 and
                header.width == atlas_width and
                header.height == atlas_height and
                header.glyph_count == @as(u16, @intCast(codepoints.len)) and
                header.glyph_size_px == glyph_size_px and
                header.range == range)
            {
                std.debug.print("Loading atlas from cache: {s}\n", .{cache_path});
                const glyphs = try allocator.alloc(msdf.AtlasGlyphData, header.glyph_count);
                errdefer allocator.free(glyphs);
                _ = try file.readAll(std.mem.sliceAsBytes(glyphs));
                const kernings = try allocator.alloc(msdf.KerningPair, 0);
                errdefer allocator.free(kernings);
                const pixel_data = try allocator.alloc(u8, header.pixel_data_len);
                errdefer allocator.free(pixel_data);
                _ = try file.readAll(pixel_data);
                return msdf.AtlasData{
                    .glyphs = glyphs,
                    .kernings = kernings,
                    .pixels = .{ .normal = pixel_data },
                };
            } else {
                std.debug.print("Cache invalid or mismatch, will regenerate\n", .{});
            }
        } else |err| {
            std.debug.print("Failed to read cache header: {s}\n", .{@errorName(err)});
        }
    } else |_| {
        std.debug.print("Cache not found: {s} (will generate)\n", .{cache_path});
    }

    std.debug.print("Generating atlas...\n", .{});
    const new_atlas = try generator.generateAtlas(allocator, codepoints, atlas_width, atlas_height, padding, use_kerning, .{
        .sdf_type = .msdf,
        .px_size = glyph_size_px,
        .px_range = range,
        .coloring_rng_seed = 0,
        .corner_angle_threshold = 3.0,
        .orientation = .guess,
        .geometry_preprocess = false,
        .scanline_fill_rule = null,
        .error_correction_opts = null,
        .var_font_args = &.{},
    });

    // Save to cache
    {
        if (std.fs.cwd().makeDir(cache_dir)) {} else |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("Warning: failed to create cache dir: {s}\n", .{@errorName(err)});
            }
        }
        const cache_file_out = std.fs.cwd().createFile(cache_path, .{}) catch |err| {
            std.debug.print("Warning: failed to create cache file: {s}\n", .{@errorName(err)});
            return new_atlas;
        };
        defer cache_file_out.close();
        var header = CacheHeader{
            .width = atlas_width,
            .height = atlas_height,
            .glyph_count = @as(u16, @intCast(new_atlas.glyphs.len)),
            .glyph_size_px = glyph_size_px,
            .range = range,
            .pixel_data_len = new_atlas.pixels.normal.len,
        };
        cache_file_out.writeAll(std.mem.asBytes(&header)) catch |err| {
            std.debug.print("Warning: failed to write cache header: {s}\n", .{@errorName(err)});
            return new_atlas;
        };
        cache_file_out.writeAll(std.mem.sliceAsBytes(new_atlas.glyphs)) catch |err| {
            std.debug.print("Warning: failed to write glyphs: {s}\n", .{@errorName(err)});
            return new_atlas;
        };
        cache_file_out.writeAll(new_atlas.pixels.normal) catch |err| {
            std.debug.print("Warning: failed to write pixel data: {s}\n", .{@errorName(err)});
            return new_atlas;
        };
        std.debug.print("Atlas cached to: {s}\n", .{cache_path});
    }
    return new_atlas;
}

pub fn main() !void {
    std.debug.print("=== Hades (Text Demo) ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    glfw.init() catch |err| {
        std.debug.print("GLFW init failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer glfw.terminate();

    const window = glfw.Window.create(800, 600, "Hades", null, null) catch |err| {
        std.debug.print("Failed to create window: {s}\n", .{@errorName(err)});
        return;
    };
    defer window.destroy();
    glfw.makeContextCurrent(window);

    const instance = wgpu.Instance.create(null) orelse {
        std.debug.print("Failed to create WGPU instance\n", .{});
        return;
    };
    defer instance.release();

    const surface_desc = if (native_os == .windows) blk: {
        const hwnd_opt = glfw.getWin32Window(window);
        const hwnd = hwnd_opt.?;
        const hinstance = win.GetModuleHandleW(null);
        break :blk wgpu.surfaceDescriptorFromWindowsHWND(.{
            .label = "Hades Surface",
            .hinstance = hinstance,
            .hwnd = hwnd,
        });
    } else if (native_os == .linux) blk: {
        const display = glfw.getX11Display().?;
        const x11_window = glfw.getX11Window(window);
        break :blk wgpu.surfaceDescriptorFromXlibWindow(.{
            .label = "Hades Surface",
            .display = display,
            .window = x11_window,
        });
    } else {
        std.debug.print("Unsupported OS\n", .{});
        return;
    };

    const surface = instance.createSurface(&surface_desc) orelse {
        std.debug.print("Failed to create surface\n", .{});
        return;
    };
    defer surface.release();

    const adapter_response = instance.requestAdapterSync(null, 10_000_000);
    if (adapter_response.status != .success) {
        std.debug.print("Failed to get adapter: {}\n", .{adapter_response.status});
        return;
    }
    g_adapter = adapter_response.adapter;
    const adapter = g_adapter orelse {
        std.debug.print("Failed to get adapter\n", .{});
        return;
    };

    const device_response = adapter.requestDeviceSync(instance, null, 10_000_000);
    if (device_response.status != .success) {
        std.debug.print("Failed to get device: {}\n", .{device_response.status});
        return;
    }
    g_device = device_response.device;
    const device = g_device orelse {
        std.debug.print("Failed to get device\n", .{});
        return;
    };

    const queue = device.getQueue() orelse {
        std.debug.print("Failed to get queue\n", .{});
        return;
    };
    std.debug.print("Queue OK\n", .{});

    // Atlas dimensions
    const atlas_width: u16 = 2048;
    const atlas_height: u16 = 2048;
    const glyph_size_px: u16 = 36;
    const padding: u8 = 4;
    const range: u16 = 8;
    const use_kerning = false;

    // Character set
    const chars = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
    var codepoints = std.ArrayList(u21).empty;
    {
        var iter = std.unicode.Utf8Iterator{ .bytes = chars, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            try codepoints.append(allocator, cp);
        }
    }
    defer codepoints.deinit(allocator);

    // Text geometry constants
    const text_to_render = "HADES";
    const start_x: f32 = 300;
    const baseline_y: f32 = 300;

    // Font configuration
    var font_texture: ?*wgpu.Texture = null;
    var font_infos: [4]?FontInfo = .{null} ** 4;

    const font_configs = [_]struct {
        path: []const u8,
        label: []const u8,
        layer: u32,
    }{
        .{ .path = "fonts/Iosevka-Thin.ttc", .label = "Iosevka-Thin", .layer = 0 },
        .{ .path = "fonts/Iosevka-Heavy.ttc", .label = "Iosevka-Heavy", .layer = 1 },
        .{ .path = "fonts/IosevkaAile-Regular.ttc", .label = "IosevkaAile-Regular", .layer = 2 },
        .{ .path = "fonts/IosevkaAile-SemiBold.ttc", .label = "IosevkaAile-SemiBold", .layer = 3 },
    };

    // Load each font, generate atlas and geometry
    for (font_configs) |config| {
        if (std.fs.cwd().openFile(config.path, .{ .mode = .read_only })) |file| {
            file.close();
        } else |_| {
            continue;
        }

        const font_data = std.fs.cwd().readFileAlloc(allocator, config.path, 100 * 1024 * 1024) catch |err| {
            std.debug.print("Failed to load font {s}: {s}\n", .{config.path, @errorName(err)});
            continue;
        };
        errdefer allocator.free(font_data);
        std.debug.print("Font loaded OK: {s}, {} bytes\n", .{config.label, font_data.len});

        var generator = msdf.create(font_data) catch |err| {
            std.debug.print("Failed to create MSDF generator for {s}: {s}\n", .{config.label, @errorName(err)});
            continue;
        };
        defer generator.destroy();

        const atlas = loadOrGenerateAtlas(allocator, config.label, &generator, codepoints.items, atlas_width, atlas_height, glyph_size_px, range, padding, use_kerning) catch |err| {
            std.debug.print("Failed to generate atlas for {s}: {s}\n", .{config.label, @errorName(err)});
            continue;
        };
        defer atlas.deinit(allocator);

        const pixel_data = switch (atlas.pixels) {
            .normal => |p| p,
            else => {
                std.debug.print("Unexpected pixel format for {s}\n", .{config.label});
                continue;
            },
        };
        const rgba_pixel_count = @as(usize, atlas_width) * @as(usize, atlas_height) * 4;
        const rgba_data = try allocator.alloc(u8, rgba_pixel_count);
        {
            var i: usize = 0;
            var j: usize = 0;
            while (i < pixel_data.len) : (i += 3) {
                rgba_data[j] = pixel_data[i];
                rgba_data[j+1] = pixel_data[i+1];
                rgba_data[j+2] = pixel_data[i+2];
                rgba_data[j+3] = 255;
                j += 4;
            }
        }
        defer allocator.free(rgba_data);

        if (font_texture == null) {
            const texture_desc = wgpu.TextureDescriptor{
                .size = .{ .width = atlas_width, .height = atlas_height, .depth_or_array_layers = 5 },
                .mip_level_count = 1,
                .sample_count = 1,
                .dimension = wgpu.TextureDimension.@"2d",
                .format = wgpu.TextureFormat.rgba8_unorm,
                .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
                .label = wgpu.StringView.fromSlice("Font Atlas Array"),
                .view_format_count = 0,
                .view_formats = undefined,
            };
            font_texture = device.createTexture(&texture_desc) orelse {
                std.debug.print("Failed to create font texture array\n", .{});
                return;
            };
        }
        const tex = font_texture.?;

        const dest_info = wgpu.TexelCopyTextureInfo{
            .texture = tex,
            .mip_level = 0,
            .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = config.layer },
            .aspect = wgpu.TextureAspect.all,
        };
        var buffer_layout = wgpu.TexelCopyBufferLayout{
            .offset = 0,
            .bytes_per_row = atlas_width * 4,
            .rows_per_image = atlas_height,
        };
        const write_size = wgpu.Extent3D{
            .width = atlas_width,
            .height = atlas_height,
            .depth_or_array_layers = 1,
        };
        queue.writeTexture(&dest_info, rgba_data.ptr, rgba_data.len, &buffer_layout, &write_size);

        var glyph_map_tmp = std.AutoHashMap(u21, msdf.AtlasGlyphData).init(allocator);
        for (atlas.glyphs) |g| {
            try glyph_map_tmp.put(g.codepoint, g);
        }

        var vertices = std.ArrayList(Vertex).empty;
        {
            var iter = std.unicode.Utf8Iterator{ .bytes = text_to_render, .i = 0 };
            var pen_x = start_x;
            while (iter.nextCodepoint()) |cp| {
                const glyph_info = glyph_map_tmp.get(cp) orelse continue;
                const m = glyph_info.glyph_data;
                const px_scale = @as(f64, @floatFromInt(glyph_size_px));
                const width = @as(f32, @floatFromInt(m.width));
                const height = @as(f32, @floatFromInt(m.height));
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
        }
        const text_vertices = try vertices.toOwnedSlice(allocator);
        defer allocator.free(text_vertices);
        std.debug.print("{s} vertices: {}\n", .{config.label, text_vertices.len});

        var min_x: f32 = 1e9;
        var min_y: f32 = 1e9;
        var max_x: f32 = -1e9;
        var max_y: f32 = -1e9;
        for (text_vertices) |v| {
            const x = v.pos[0];
            const y = v.pos[1];
            if (x < min_x) min_x = x;
            if (y < min_y) min_y = y;
            if (x > max_x) max_x = x;
            if (y > max_y) max_y = y;
        }
        const center_x = (min_x + max_x) / 2.0;
        const center_y = (min_y + max_y) / 2.0;
        const text_width = max_x - min_x;

        const vertex_buffer_size = @sizeOf(Vertex) * text_vertices.len;
        const vertex_buffer = device.createBuffer(&wgpu.BufferDescriptor{
            .size = vertex_buffer_size,
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @intFromBool(false),
        }) orelse {
            std.debug.print("Failed to create vertex buffer for {s}\n", .{config.label});
            return;
        };
        const vertex_bytes = std.mem.sliceAsBytes(text_vertices);
        queue.writeBuffer(vertex_buffer, 0, vertex_bytes.ptr, vertex_bytes.len);

        font_infos[config.layer] = FontInfo{
            .glyph_map = glyph_map_tmp,
            .vertex_buffer = vertex_buffer,
            .vertex_count = @intCast(text_vertices.len),
            .text_width = text_width,
            .center_x = center_x,
            .center_y = center_y,
        };
    }

    // Determine available layers
    var available_layers: [4]i32 = undefined;
    var available_count: usize = 0;
    for (0..4) |i| {
        if (font_infos[i] != null) {
            available_layers[available_count] = @as(i32, @intCast(i));
            available_count += 1;
        }
    }
    if (available_count == 0) {
        std.debug.print("No fonts were loaded successfully.\n", .{});
        return;
    }

    // Initial selection
    var current_layer_idx: usize = 0;
    var current_layer: i32 = available_layers[0];
    var current_font = font_infos[@intCast(usize, current_layer)].?;

    // Texture view & sampler
    const texture_view = font_texture.?.createView(null) orelse {
        std.debug.print("Failed to create texture view\n", .{});
        return;
    };
    defer texture_view.release();
    std.debug.print("Texture view created OK\n", .{});

    const sampler_desc = wgpu.SamplerDescriptor{
        .min_filter = wgpu.FilterMode.linear,
        .mag_filter = wgpu.FilterMode.linear,
        .mipmap_filter = wgpu.MipmapFilterMode.nearest,
        .address_mode_u = wgpu.AddressMode.clamp_to_edge,
        .address_mode_v = wgpu.AddressMode.clamp_to_edge,
        .address_mode_w = wgpu.AddressMode.clamp_to_edge,
        .lod_min_clamp = 0.0,
        .lod_max_clamp = 0.0,
        .compare = wgpu.CompareFunction.undefined,
        .max_anisotropy = 1,
    };
    const sampler = device.createSampler(&sampler_desc) orelse {
        std.debug.print("Failed to create sampler\n", .{});
        return;
    };
    defer sampler.release();

    // Cleanup on exit
    defer {
        for (font_infos) |opt| {
            if (opt) |f| {
                f.glyph_map.deinit();
                f.vertex_buffer.release();
            }
        }
        if (font_texture) |t| t.release();
    }

    // Uniform buffer
    const uniform_buffer_size = @sizeOf(AppUniforms);
    const uniform_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .size = uniform_buffer_size,
        .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
        .mapped_at_creation = @intFromBool(false),
    }) orelse {
        std.debug.print("Failed to create uniform buffer\n", .{});
        return;
    };
    defer uniform_buffer.release();

    // Bind group layout
    var bind_layout_entries: [3]wgpu.BindGroupLayoutEntry = undefined;
    bind_layout_entries[0] = wgpu.BindGroupLayoutEntry{
        .binding = 0,
        .visibility = wgpu.ShaderStages.fragment,
        .texture = wgpu.TextureBindingLayout{
            .sample_type = wgpu.SampleType.float,
            .view_dimension = wgpu.ViewDimension.@"2d_array",
            .multisampled = @intFromBool(false),
        },
    };
    bind_layout_entries[1] = wgpu.BindGroupLayoutEntry{
        .binding = 1,
        .visibility = wgpu.ShaderStages.fragment,
        .sampler = wgpu.SamplerBindingLayout{
            .type = wgpu.SamplerBindingType.filtering,
        },
    };
    bind_layout_entries[2] = wgpu.BindGroupLayoutEntry{
        .binding = 2,
        .visibility = wgpu.ShaderStages.vertex | wgpu.ShaderStages.fragment,
        .buffer = wgpu.BufferBindingLayout{
            .type = wgpu.BufferBindingType.uniform,
            .has_dynamic_offset = @intFromBool(false),
            .min_binding_size = @intCast(uniform_buffer_size),
        },
    };

    const bind_group_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
        .label = wgpu.StringView.fromSlice("Text Bind Group Layout"),
        .entry_count = 3,
        .entries = &bind_layout_entries,
    }) orelse {
        std.debug.print("Failed to create bind group layout\n", .{});
        return;
    };
    defer bind_group_layout.release();

    const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
        .label = wgpu.StringView.fromSlice("Text Pipeline Layout"),
        .bind_group_layout_count = 1,
        .bind_group_layouts = @ptrCast(&bind_group_layout),
    }) orelse {
        std.debug.print("Failed to create pipeline layout\n", .{});
        return;
    };
    defer pipeline_layout.release();

    // Bind group
    var bind_group_entries: [3]wgpu.BindGroupEntry = undefined;
    bind_group_entries[0] = wgpu.BindGroupEntry{
        .binding = 0,
        .texture_view = texture_view,
    };
    bind_group_entries[1] = wgpu.BindGroupEntry{
        .binding = 1,
        .sampler = sampler,
    };
    bind_group_entries[2] = wgpu.BindGroupEntry{
        .binding = 2,
        .buffer = uniform_buffer,
        .offset = 0,
        .size = uniform_buffer_size,
    };
    const bind_group = device.createBindGroup(&wgpu.BindGroupDescriptor{
        .label = wgpu.StringView.fromSlice("Text Bind Group"),
        .layout = bind_group_layout,
        .entry_count = 3,
        .entries = &bind_group_entries,
    }) orelse {
        std.debug.print("Failed to create bind group\n", .{});
        return;
    };
    defer bind_group.release();

    // Text shaders
    const vs_desc = wgpu.shaderModuleWGSLDescriptor(.{
        .label = "Text Vertex Shader",
        .code = text_vs_source,
    });
    const vs_module = device.createShaderModule(&vs_desc) orelse {
        std.debug.print("Failed to create vertex shader\n", .{});
        return;
    };
    defer vs_module.release();

    const fs_desc = wgpu.shaderModuleWGSLDescriptor(.{
        .label = "Text Fragment Shader",
        .code = text_fs_source,
    });
    const fs_module = device.createShaderModule(&fs_desc) orelse {
        std.debug.print("Failed to create fragment shader\n", .{});
        return;
    };
    defer fs_module.release();

    // Text pipeline
    const surface_format = wgpu.TextureFormat.bgra8_unorm;
    const color_target = wgpu.ColorTargetState{
        .format = surface_format,
        .blend = &wgpu.BlendState{
            .color = wgpu.BlendComponent{
                .src_factor = wgpu.BlendFactor.src_alpha,
                .dst_factor = wgpu.BlendFactor.one_minus_src_alpha,
                .operation = wgpu.BlendOperation.add,
            },
            .alpha = wgpu.BlendComponent{
                .src_factor = wgpu.BlendFactor.one,
                .dst_factor = wgpu.BlendFactor.one_minus_src_alpha,
                .operation = wgpu.BlendOperation.add,
            },
        },
        .write_mask = wgpu.ColorWriteMasks.all,
    };
    var vertex_buffer_layout = wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(Vertex),
        .step_mode = wgpu.VertexStepMode.vertex,
        .attribute_count = 2,
        .attributes = &[2]wgpu.VertexAttribute{
            wgpu.VertexAttribute{
                .shader_location = 0,
                .offset = 0,
                .format = wgpu.VertexFormat.float32x2,
            },
            wgpu.VertexAttribute{
                .shader_location = 1,
                .offset = @sizeOf([2]f32),
                .format = wgpu.VertexFormat.float32x2,
            },
        },
    };
    const vertex_state = wgpu.VertexState{
        .module = vs_module,
        .entry_point = wgpu.StringView.fromSlice("vs_main"),
        .constant_count = 0,
        .constants = &[0]wgpu.ConstantEntry{},
        .buffer_count = 1,
        .buffers = @ptrCast(&vertex_buffer_layout),
    };
    const fragment_state = wgpu.FragmentState{
        .module = fs_module,
        .entry_point = wgpu.StringView.fromSlice("fs_main"),
        .constant_count = 0,
        .constants = &[0]wgpu.ConstantEntry{},
        .target_count = 1,
        .targets = &[_]wgpu.ColorTargetState{color_target},
    };
    const pipeline_desc = wgpu.RenderPipelineDescriptor{
        .label = wgpu.StringView.fromSlice("Text Pipeline"),
        .layout = pipeline_layout,
        .vertex = vertex_state,
        .fragment = &fragment_state,
        .primitive = wgpu.PrimitiveState{
            .topology = wgpu.PrimitiveTopology.triangle_list,
            .strip_index_format = wgpu.IndexFormat.undefined,
            .front_face = wgpu.FrontFace.ccw,
            .cull_mode = wgpu.CullMode.none,
            .unclipped_depth = @intFromBool(false),
        },
        .multisample = wgpu.MultisampleState{
            .count = 1,
            .mask = std.math.maxInt(u32),
            .alpha_to_coverage_enabled = @intFromBool(false),
        },
        .depth_stencil = null,
    };
    const pipeline = device.createRenderPipeline(&pipeline_desc) orelse {
        std.debug.print("Failed to create render pipeline\n", .{});
        return;
    };
    defer pipeline.release();

    // Background pipeline
    const bg_vs_desc = wgpu.shaderModuleWGSLDescriptor(.{
        .label = "Background Vertex Shader",
        .code = bg_vs_source,
    });
    const bg_vs_module = device.createShaderModule(&bg_vs_desc) orelse {
        std.debug.print("Failed to create background vertex shader\n", .{});
        return;
    };
    defer bg_vs_module.release();

    const bg_fs_desc = wgpu.shaderModuleWGSLDescriptor(.{
        .label = "Background Fragment Shader",
        .code = bg_fs_source,
    });
    const bg_fs_module = device.createShaderModule(&bg_fs_desc) orelse {
        std.debug.print("Failed to create background fragment shader\n", .{});
        return;
    };
    defer bg_fs_module.release();

    var bg_bind_layout_entries: [1]wgpu.BindGroupLayoutEntry = undefined;
    bg_bind_layout_entries[0] = wgpu.BindGroupLayoutEntry{
        .binding = 0,
        .visibility = wgpu.ShaderStages.fragment,
        .buffer = wgpu.BufferBindingLayout{
            .type = wgpu.BufferBindingType.uniform,
            .has_dynamic_offset = @intFromBool(false),
            .min_binding_size = @intCast(@sizeOf(AppUniforms)),
        },
    };
    const bg_bind_group_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
        .label = wgpu.StringView.fromSlice("Background Bind Group Layout"),
        .entry_count = 1,
        .entries = &bg_bind_layout_entries,
    }) orelse {
        std.debug.print("Failed to create background bind group layout\n", .{});
        return;
    };
    defer bg_bind_group_layout.release();

    var bg_bind_group_entries: [1]wgpu.BindGroupEntry = undefined;
    bg_bind_group_entries[0] = wgpu.BindGroupEntry{
        .binding = 0,
        .buffer = uniform_buffer,
        .offset = 0,
        .size = uniform_buffer_size,
    };
    const bg_bind_group = device.createBindGroup(&wgpu.BindGroupDescriptor{
        .label = wgpu.StringView.fromSlice("Background Bind Group"),
        .layout = bg_bind_group_layout,
        .entry_count = 1,
        .entries = &bg_bind_group_entries,
    }) orelse {
        std.debug.print("Failed to create background bind group\n", .{});
        return;
    };
    defer bg_bind_group.release();

    const bg_pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
        .label = wgpu.StringView.fromSlice("Background Pipeline Layout"),
        .bind_group_layout_count = 1,
        .bind_group_layouts = @ptrCast(&bg_bind_group_layout),
    }) orelse {
        std.debug.print("Failed to create background pipeline layout\n", .{});
        return;
    };
    defer bg_pipeline_layout.release();

    const bg_color_target = wgpu.ColorTargetState{
        .format = surface_format,
        .blend = null,
        .write_mask = wgpu.ColorWriteMasks.all,
    };
    const bg_vertex_state = wgpu.VertexState{
        .module = bg_vs_module,
        .entry_point = wgpu.StringView.fromSlice("vs_main"),
        .constant_count = 0,
        .constants = &[0]wgpu.ConstantEntry{},
        .buffer_count = 0,
        .buffers = &[0]wgpu.VertexBufferLayout{},
    };
    const bg_fragment_state = wgpu.FragmentState{
        .module = bg_fs_module,
        .entry_point = wgpu.StringView.fromSlice("fs_main"),
        .constant_count = 0,
        .constants = &[0]wgpu.ConstantEntry{},
        .target_count = 1,
        .targets = &[_]wgpu.ColorTargetState{bg_color_target},
    };
    const bg_pipeline_desc = wgpu.RenderPipelineDescriptor{
        .label = wgpu.StringView.fromSlice("Background Pipeline"),
        .layout = bg_pipeline_layout,
        .vertex = bg_vertex_state,
        .fragment = &bg_fragment_state,
        .primitive = wgpu.PrimitiveState{
            .topology = wgpu.PrimitiveTopology.triangle_list,
            .strip_index_format = wgpu.IndexFormat.undefined,
            .front_face = wgpu.FrontFace.ccw,
            .cull_mode = wgpu.CullMode.none,
            .unclipped_depth = @intFromBool(false),
        },
        .multisample = wgpu.MultisampleState{
            .count = 1,
            .mask = std.math.maxInt(u32),
            .alpha_to_coverage_enabled = @intFromBool(false),
        },
        .depth_stencil = null,
    };
    const bg_pipeline = device.createRenderPipeline(&bg_pipeline_desc) orelse {
        std.debug.print("Failed to create background pipeline\n", .{});
        return;
    };
    defer bg_pipeline.release();

    // Initial surface configuration
    var current_width: u32 = 800;
    var current_height: u32 = 600;
    surface.configure(&wgpu.SurfaceConfiguration{
        .device = device,
        .format = surface_format,
        .usage = wgpu.TextureUsages.render_attachment,
        .width = current_width,
        .height = current_height,
        .present_mode = wgpu.PresentMode.fifo,
        .alpha_mode = wgpu.CompositeAlphaMode.auto,
    });

    // Render loop
    std.debug.print("Entering render loop...\n", .{});
    var start_time = glfw.getTime();
    while (!window.shouldClose()) {
        // Space: restart + cycle font
        if (window.getKey(.space) == .press) {
            start_time = glfw.getTime();
            current_layer_idx = (current_layer_idx + 1) % available_count;
            current_layer = available_layers[current_layer_idx];
            current_font = font_infos[@intCast(usize, current_layer)].?;
        }
        glfw.pollEvents();

        // Resize
        const size = window.getSize();
        const new_width = @as(u32, @intCast(size[0]));
        const new_height = @as(u32, @intCast(size[1]));
        if (new_width > 0 and new_height > 0 and (new_width != current_width or new_height != current_height)) {
            surface.configure(&wgpu.SurfaceConfiguration{
                .device = device,
                .format = surface_format,
                .usage = wgpu.TextureUsages.render_attachment,
                .width = new_width,
                .height = new_height,
                .present_mode = wgpu.PresentMode.fifo,
                .alpha_mode = wgpu.CompositeAlphaMode.auto,
            });
            current_width = new_width;
            current_height = new_height;
        }

        const width = current_width;
        const height = current_height;
        const resolution = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        const elapsed = glfw.getTime() - start_time;
        const time = @as(f32, @floatCast(elapsed));

        const viscosity = 0.5 + 0.5 * @sin(time * 0.5);
        const glow: f32 = 1.0;
        const phase = time * 0.1;

        // Blobs
        const center_screen = [2]f32{ resolution[0] * 0.5, resolution[1] * 0.5 };
        const max_amplitude = @min(resolution[0], resolution[1]) * 0.3;
        var blobs: [4]Blob = undefined;
        for (0..4) |i| {
            const fi = @as(f32, @floatFromInt(i));
            const speed_x: f32 = 0.3 + fi * 0.1;
            const speed_y: f32 = 0.4 + fi * 0.15;
            const phase_x: f32 = fi * 1.5;
            const phase_y: f32 = fi * 2.0;
            const pos_x = center_screen[0] + @cos(time * speed_x + phase_x) * max_amplitude;
            const pos_y = center_screen[1] + @sin(time * speed_y + phase_y) * max_amplitude;
            const radius: f32 = 80.0 + 40.0 * @sin(time * 0.7 + fi);
            blobs[i] = Blob{
                .pos_x = pos_x,
                .pos_y = pos_y,
                .radius = radius,
                .pad = 0,
            };
        }

        // Uniforms
        const base_scale = (resolution[0] * 0.9) / current_font.text_width;
        const uniforms = AppUniforms{
            .resolution_x = resolution[0],
            .resolution_y = resolution[1],
            .center_x = current_font.center_x,
            .center_y = current_font.center_y,
            .time = time,
            .viscosity = viscosity,
            .glow = glow,
            .phase = phase,
            .base_scale = base_scale,
            .font_layer = current_layer,
            .pad1 = 0,
            .pad2 = 0,
            .blobs = blobs,
        };
        queue.writeBuffer(uniform_buffer, 0, std.mem.asBytes(&uniforms), @sizeOf(AppUniforms));

        var surface_tex: wgpu.SurfaceTexture = undefined;
        surface.getCurrentTexture(&surface_tex);
        const view = surface_tex.texture.?.createView(null) orelse {
            std.debug.print("Failed to create texture view\n", .{});
            continue;
        };
        defer view.release();

        const encoder = device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{}) orelse {
            std.debug.print("Failed to create command encoder\n", .{});
            continue;
        };
        defer encoder.release();

        var color_attachment = wgpu.ColorAttachment{
            .view = view,
            .load_op = wgpu.LoadOp.clear,
            .store_op = wgpu.StoreOp.store,
            .clear_value = wgpu.Color{ .r = 0.005, .g = 0.005, .b = 0.01, .a = 1.0 },
        };
        var render_pass_desc = wgpu.RenderPassDescriptor{
            .color_attachment_count = 1,
            .color_attachments = @ptrCast(&color_attachment),
        };
        const pass = encoder.beginRenderPass(&render_pass_desc) orelse {
            std.debug.print("Failed to create render pass\n", .{});
            continue;
        };
        defer pass.release();

        // Background
        pass.setPipeline(bg_pipeline);
        pass.setBindGroup(0, bg_bind_group, 0, null);
        pass.draw(3, 1, 0, 0);

        // Text
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bind_group, 0, null);
        pass.setVertexBuffer(0, current_font.vertex_buffer, 0, @sizeOf(Vertex) * current_font.vertex_count);
        pass.draw(@intCast(current_font.vertex_count), 1, 0, 0);

        pass.end();

        const cmd_buffer = encoder.finish(&wgpu.CommandBufferDescriptor{}) orelse {
            std.debug.print("Failed to finish encoder\n", .{});
            continue;
        };
        defer cmd_buffer.release();
        queue.submit(&[_]*const wgpu.CommandBuffer{cmd_buffer});
        const present_status = surface.present();
        if (present_status != .success) {
            std.debug.print("Surface present failed: {}\n", .{present_status});
        }
    }
}
