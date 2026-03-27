const std = @import("std");
const glfw = @import("zglfw");
const wgpu = @import("wgpu");
const msdf = @import("msdf");
const render_types = @import("render_types.zig");
const font_atlas = @import("font_atlas.zig");
const shaders = @import("shaders.zig");
const demos = @import("demos.zig");

pub const FontConfig = struct {
    label: []const u8,
    layer: u32,
};

pub const Geometry = struct {
    vertex_buffer: ?*wgpu.Buffer,
    vertex_count: u32,
    center_x: f32,
    center_y: f32,
    text_width: f32,
    text_height: f32,
};

const native_os = @import("builtin").target.os.tag;
const win = if (native_os == .windows) @cImport({
    @cInclude("windows.h");
}) else void;

pub const Renderer = struct {
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    surface: *wgpu.Surface,
    surface_format: wgpu.TextureFormat,
    current_width: u32,
    current_height: u32,
    text_pipeline: *wgpu.RenderPipeline,
    bg_pipeline: *wgpu.RenderPipeline,
    uniform_buffer: *wgpu.Buffer,
    bind_group: *wgpu.BindGroup,
    bg_bind_group: *wgpu.BindGroup,
    font_texture: *wgpu.Texture,
    texture_view: *wgpu.TextureView,
    sampler: *wgpu.Sampler,
    font_infos: [4]?render_types.FontInfo,

    pub fn init(allocator: std.mem.Allocator, window: *glfw.Window, font_configs: []const FontConfig) !Renderer {
        const instance = wgpu.Instance.create(null) orelse return error.CreateInstanceFailed;
        defer instance.release();

        const surface_desc = if (native_os == .windows) blk: {
            const hwnd = glfw.getWin32Window(window).?;
            const hinstance = win.GetModuleHandleW(null);
            break :blk wgpu.surfaceDescriptorFromWindowsHWND(.{
                .label = "Hades Surface",
                .hinstance = hinstance,
                .hwnd = hwnd,
            });
        } else if (native_os == .linux) blk: {
            const display = glfw.getX11Display() orelse return error.NoDisplay;
            const x11_window = glfw.getX11Window(window);
            break :blk wgpu.surfaceDescriptorFromXlibWindow(.{
                .label = "Hades Surface",
                .display = display,
                .window = x11_window,
            });
        } else {
            return error.UnsupportedOS;
        };
        const surface = instance.createSurface(&surface_desc) orelse return error.CreateSurfaceFailed;

        const adapter_response = instance.requestAdapterSync(null, 10_000_000);
        if (adapter_response.status != .success) return error.RequestAdapterFailed;
        const adapter = adapter_response.adapter orelse return error.NoAdapter;
        const device_response = adapter.requestDeviceSync(instance, null, 10_000_000);
        if (device_response.status != .success) return error.RequestDeviceFailed;
        const device = device_response.device orelse return error.NoDevice;
        const queue = device.getQueue() orelse return error.NoQueue;

        var capabilities: wgpu.SurfaceCapabilities = undefined;
        _ = surface.getCapabilities(adapter, &capabilities);
        const surface_format = capabilities.formats[0];

        const size = window.getSize();
        var current_width: u32 = @as(u32, @intCast(size[0]));
        var current_height: u32 = @as(u32, @intCast(size[1]));
        if (current_width == 0 or current_height == 0) {
            current_width = 800;
            current_height = 600;
        }

        surface.configure(&wgpu.SurfaceConfiguration{
            .device = device,
            .format = surface_format,
            .usage = wgpu.TextureUsages.render_attachment,
            .width = current_width,
            .height = current_height,
            .present_mode = wgpu.PresentMode.fifo,
            .alpha_mode = wgpu.CompositeAlphaMode.auto,
        });

        const uniform_struct_size = @sizeOf(render_types.AppUniforms);
        var uniform_buffer_size: usize = uniform_struct_size;
        // Align to 256 bytes for GPU uniform buffer requirements
        uniform_buffer_size = std.mem.alignForward(usize, uniform_buffer_size, 256);
        const uniform_buffer = device.createBuffer(&wgpu.BufferDescriptor{
            .size = uniform_buffer_size,
            .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @intFromBool(false),
            .label = wgpu.StringView.fromSlice("Uniform Buffer"),
        }) orelse return error.CreateUniformBufferFailed;

        const texture_desc = wgpu.TextureDescriptor{
            .size = .{ .width = 2048, .height = 2048, .depth_or_array_layers = 5 },
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = wgpu.TextureDimension.@"2d",
            .format = wgpu.TextureFormat.rgba8_unorm,
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .label = wgpu.StringView.fromSlice("Font Atlas Array"),
        };
        const font_texture = device.createTexture(&texture_desc) orelse return error.CreateTextureFailed;

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
        const sampler = device.createSampler(&sampler_desc) orelse return error.CreateSamplerFailed;

        var font_infos: [4]?render_types.FontInfo = .{null} ** 4;
        for (font_configs) |config| {
            const loaded = font_atlas.getAtlas(allocator, config.label) catch continue;
            const atlas = loaded.atlas;
            const gsize = loaded.glyph_size_px;
            const w = loaded.atlas_width;
            const h = loaded.atlas_height;

            const pixel_data = atlas.pixels.normal;
            const rgba_pixel_count = @as(usize, w) * @as(usize, h) * 4;
            const rgba_data = try allocator.alloc(u8, rgba_pixel_count);
            errdefer allocator.free(rgba_data);
            var i: usize = 0;
            var j: usize = 0;
            while (i < pixel_data.len) : (i += 3) {
                rgba_data[j] = pixel_data[i];
                rgba_data[j+1] = pixel_data[i+1];
                rgba_data[j+2] = pixel_data[i+2];
                rgba_data[j+3] = 255;
                j += 4;
            }

            const dest_info = wgpu.TexelCopyTextureInfo{
                .texture = font_texture,
                .mip_level = 0,
                .origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = config.layer },
                .aspect = wgpu.TextureAspect.all,
            };
            var buffer_layout = wgpu.TexelCopyBufferLayout{
                .offset = 0,
                .bytes_per_row = w * 4,
                .rows_per_image = h,
            };
            const write_size = wgpu.Extent3D{
                .width = w,
                .height = h,
                .depth_or_array_layers = 1,
            };
            queue.writeTexture(&dest_info, rgba_data.ptr, rgba_data.len, &buffer_layout, &write_size);
            allocator.free(rgba_data);

            var glyph_map = std.AutoHashMap(u21, msdf.AtlasGlyphData).init(allocator);
            for (atlas.glyphs) |g| {
                try glyph_map.put(g.codepoint, g);
            }

            font_infos[config.layer] = render_types.FontInfo{
                .glyph_map = glyph_map,
                .vertex_buffer = null,
                .vertex_count = 0,
                .text_width = 0,
                .text_height = 0,
                .center_x = 0,
                .center_y = 0,
                .glyph_size_px = gsize,
            };
        }

        const texture_view = font_texture.createView(null) orelse return error.CreateViewFailed;

        const uniform_buffer_size_usize = uniform_buffer_size;
        const bind_layout_entries = [3]wgpu.BindGroupLayoutEntry{
            wgpu.BindGroupLayoutEntry{
                .binding = 0,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = wgpu.TextureBindingLayout{
                    .sample_type = wgpu.SampleType.float,
                    .view_dimension = wgpu.ViewDimension.@"2d_array",
                    .multisampled = @intFromBool(false),
                },
            },
            wgpu.BindGroupLayoutEntry{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = wgpu.SamplerBindingLayout{
                    .type = wgpu.SamplerBindingType.filtering,
                },
            },
            wgpu.BindGroupLayoutEntry{
                .binding = 2,
                .visibility = wgpu.ShaderStages.vertex | wgpu.ShaderStages.fragment,
                .buffer = wgpu.BufferBindingLayout{
                    .type = wgpu.BufferBindingType.uniform,
                    .has_dynamic_offset = @intFromBool(false),
                    .min_binding_size = @intCast(uniform_buffer_size_usize),
                },
            },
        };
        const bind_group_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Text Bind Group Layout"),
            .entry_count = 3,
            .entries = &bind_layout_entries,
        }) orelse return error.CreateBindGroupLayoutFailed;

        const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Text Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bind_group_layout),
        }) orelse return error.CreatePipelineLayoutFailed;

        const bind_group_entries = [3]wgpu.BindGroupEntry{
            wgpu.BindGroupEntry{
                .binding = 0,
                .texture_view = texture_view,
            },
            wgpu.BindGroupEntry{
                .binding = 1,
                .sampler = sampler,
            },
            wgpu.BindGroupEntry{
                .binding = 2,
                .buffer = uniform_buffer,
                .offset = 0,
                .size = uniform_buffer_size,
            },
        };
        const bind_group = device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Text Bind Group"),
            .layout = bind_group_layout,
            .entry_count = 3,
            .entries = &bind_group_entries,
        }) orelse return error.CreateBindGroupFailed;

        const vs_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Text Vertex Shader",
            .code = shaders.textVertexSource,
        })) orelse return error.CreateShaderModuleFailed;
        defer vs_module.release();

        const fs_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Text Fragment Shader",
            .code = shaders.textFragmentSource,
        })) orelse return error.CreateShaderModuleFailed;
        defer fs_module.release();

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
        const vertex_buffer_layout = wgpu.VertexBufferLayout{
            .array_stride = @sizeOf(render_types.Vertex),
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
        const text_pipeline = device.createRenderPipeline(&pipeline_desc) orelse return error.CreateRenderPipelineFailed;

        const bg_bind_layout_entries = [1]wgpu.BindGroupLayoutEntry{
            wgpu.BindGroupLayoutEntry{
                .binding = 0,
                .visibility = wgpu.ShaderStages.fragment,
                .buffer = wgpu.BufferBindingLayout{
                    .type = wgpu.BufferBindingType.uniform,
                    .has_dynamic_offset = @intFromBool(false),
                    .min_binding_size = @intCast(@sizeOf(render_types.AppUniforms)),
                },
            },
        };
        const bg_bind_group_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Background Bind Group Layout"),
            .entry_count = 1,
            .entries = &bg_bind_layout_entries,
        }) orelse return error.CreateBindGroupLayoutFailed;
        defer bg_bind_group_layout.release();

        const bg_bind_group_entries = [1]wgpu.BindGroupEntry{
            wgpu.BindGroupEntry{
                .binding = 0,
                .buffer = uniform_buffer,
                .offset = 0,
                .size = uniform_buffer_size,
            },
        };
        const bg_bind_group = device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("Background Bind Group"),
            .layout = bg_bind_group_layout,
            .entry_count = 1,
            .entries = &bg_bind_group_entries,
        }) orelse return error.CreateBindGroupFailed;

        const bg_pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("Background Pipeline Layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = @ptrCast(&bg_bind_group_layout),
        }) orelse return error.CreatePipelineLayoutFailed;
        defer bg_pipeline_layout.release();

        const bg_vs_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Background Vertex Shader",
            .code = shaders.bgVertexSource,
        })) orelse return error.CreateShaderModuleFailed;
        defer bg_vs_module.release();

        const bg_fs_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "Background Fragment Shader",
            .code = shaders.bgFragmentSource,
        })) orelse return error.CreateShaderModuleFailed;
        defer bg_fs_module.release();

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
        const bg_pipeline = device.createRenderPipeline(&bg_pipeline_desc) orelse return error.CreateRenderPipelineFailed;

        return Renderer{
            .device = device,
            .queue = queue,
            .surface = surface,
            .surface_format = surface_format,
            .current_width = current_width,
            .current_height = current_height,
            .text_pipeline = text_pipeline,
            .bg_pipeline = bg_pipeline,
            .uniform_buffer = uniform_buffer,
            .bind_group = bind_group,
            .bg_bind_group = bg_bind_group,
            .font_texture = font_texture,
            .texture_view = texture_view,
            .sampler = sampler,
            .font_infos = font_infos,
        };
    }

    pub fn deinit(self: *Renderer, _: std.mem.Allocator) void {
        for (&self.font_infos) |*opt| {
            if (opt.*) |_| {
                opt.*.?.glyph_map.deinit();
                if (opt.*.?.vertex_buffer) |vb| vb.release();
            }
        }
        self.font_texture.release();
        self.sampler.release();
        self.texture_view.release();
        self.bind_group.release();
        self.bg_bind_group.release();
        self.uniform_buffer.release();
        self.text_pipeline.release();
        self.bg_pipeline.release();
        self.surface.release();
        self.device.release();
        self.queue.release();
    }

    pub fn buildTextGeometry(self: *Renderer, allocator: std.mem.Allocator, message: []const u21, start_x: f32, baseline_y: f32) !void {
        for (&self.font_infos) |*opt| {
            if (opt.*) |_| {
                if (opt.*.?.vertex_buffer) |vb| vb.release();
                const geom = try buildGeometryForFont(allocator, self.device, self.queue, message, &opt.*.?, start_x, baseline_y);
                opt.*.?.vertex_buffer = geom.vertex_buffer;
                opt.*.?.vertex_count = geom.vertex_count;
                opt.*.?.center_x = geom.center_x;
                opt.*.?.center_y = geom.center_y;
                opt.*.?.text_width = geom.text_width;
                opt.*.?.text_height = geom.text_height;
            }
        }
    }

    fn buildGeometryForFont(
        allocator: std.mem.Allocator,
        device: *wgpu.Device,
        queue: *wgpu.Queue,
        message: []const u21,
        fi: *render_types.FontInfo,
        start_x: f32,
        baseline_y: f32,
    ) !Geometry {
        if (message.len == 0) {
            return Geometry{
                .vertex_buffer = null,
                .vertex_count = 0,
                .center_x = 0,
                .center_y = 0,
                .text_width = 0,
                .text_height = 0,
            };
        }

        const px_scale = @as(f64, @floatFromInt(fi.glyph_size_px));
        var vertices = std.ArrayList(render_types.Vertex).empty;
        var pen_x = start_x;
        var min_x: f32 = 1e9;
        var min_y: f32 = 1e9;
        var max_x: f32 = -1e9;
        var max_y: f32 = -1e9;

        for (message) |cp| {
            const gdata = fi.glyph_map.get(cp) orelse continue;
            const m = gdata.glyph_data;
            const width = std.math.lossyCast(f32, m.width);
            const height = std.math.lossyCast(f32, m.height);
            const advance = std.math.lossyCast(f32, m.advance * px_scale);
            const bearing_x = std.math.lossyCast(f32, m.bearing_x * px_scale);
            const bearing_y = std.math.lossyCast(f32, m.bearing_y * px_scale);
            const x0 = pen_x + bearing_x;
            const y0 = baseline_y - bearing_y;
            const x1 = x0 + width;
            const y1 = y0 + height;
            const u_min = std.math.lossyCast(f32, gdata.tex_u);
            const v_min = std.math.lossyCast(f32, gdata.tex_v);
            const u_max = std.math.lossyCast(f32, gdata.tex_u + gdata.tex_w);
            const v_max = std.math.lossyCast(f32, gdata.tex_v + gdata.tex_h);
            try vertices.append(allocator, .{ .pos = .{ x0, y0 }, .uv = .{ u_min, v_min } });
            try vertices.append(allocator, .{ .pos = .{ x1, y0 }, .uv = .{ u_max, v_min } });
            try vertices.append(allocator, .{ .pos = .{ x0, y1 }, .uv = .{ u_min, v_max } });
            try vertices.append(allocator, .{ .pos = .{ x1, y0 }, .uv = .{ u_max, v_min } });
            try vertices.append(allocator, .{ .pos = .{ x1, y1 }, .uv = .{ u_max, v_max } });
            try vertices.append(allocator, .{ .pos = .{ x0, y1 }, .uv = .{ u_min, v_max } });
            pen_x += advance;

            if (x0 < min_x) min_x = x0;
            if (y0 < min_y) min_y = y0;
            if (x1 > max_x) max_x = x1;
            if (y1 > max_y) max_y = y1;
        }

        const vertex_slice = try vertices.toOwnedSlice(allocator);
        defer allocator.free(vertex_slice);

        if (vertex_slice.len == 0) {
            return Geometry{
                .vertex_buffer = null,
                .vertex_count = 0,
                .center_x = 0,
                .center_y = 0,
                .text_width = 0,
                .text_height = 0,
            };
        }

        const vcount = @as(u32, @intCast(vertex_slice.len));
        const buffer_size = @sizeOf(render_types.Vertex) * vertex_slice.len;
        const vertex_buffer = device.createBuffer(&wgpu.BufferDescriptor{
            .size = buffer_size,
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = @intFromBool(false),
        }) orelse return error.CreateBufferFailed;
        const vertex_bytes = std.mem.sliceAsBytes(vertex_slice);
        queue.writeBuffer(vertex_buffer, 0, vertex_bytes.ptr, vertex_bytes.len);

        const center_x = (min_x + max_x) / 2.0;
        const center_y = (min_y + max_y) / 2.0;
        const text_width = max_x - min_x;
        const text_height = max_y - min_y;

        return Geometry{
            .vertex_buffer = vertex_buffer,
            .vertex_count = vcount,
            .center_x = center_x,
            .center_y = center_y,
            .text_width = text_width,
            .text_height = text_height,
        };
    }

    pub fn resizeIfNeeded(self: *Renderer, window: *glfw.Window) void {
        const size = window.getSize();
        const new_width = @as(u32, @intCast(size[0]));
        const new_height = @as(u32, @intCast(size[1]));
        if (new_width > 0 and new_height > 0 and (new_width != self.current_width or new_height != self.current_height)) {
            self.current_width = new_width;
            self.current_height = new_height;
            self.surface.configure(&wgpu.SurfaceConfiguration{
                .device = self.device,
                .format = self.surface_format,
                .usage = wgpu.TextureUsages.render_attachment,
                .width = new_width,
                .height = new_height,
                .present_mode = wgpu.PresentMode.fifo,
                .alpha_mode = wgpu.CompositeAlphaMode.auto,
            });
        }
    }

    pub fn render(self: *Renderer, active_font: ?render_types.FontInfo, uniforms: *const render_types.AppUniforms) void {
        self.queue.writeBuffer(self.uniform_buffer, 0, std.mem.asBytes(uniforms), @sizeOf(render_types.AppUniforms));

        var surface_tex: wgpu.SurfaceTexture = undefined;
        self.surface.getCurrentTexture(&surface_tex);
        const view = surface_tex.texture.? .createView(null) orelse {
            std.debug.print("Failed to create texture view\n", .{});
            return;
        };
        defer view.release();

        const encoder = self.device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{}) orelse {
            std.debug.print("Failed to create command encoder\n", .{});
            return;
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
            return;
        };
        defer pass.release();

        pass.setPipeline(self.bg_pipeline);
        pass.setBindGroup(0, self.bg_bind_group, 0, null);
        pass.draw(3, 1, 0, 0);

        if (active_font) |font| {
            if (font.vertex_buffer) |vb| {
                if (font.vertex_count > 0) {
                    pass.setPipeline(self.text_pipeline);
                    pass.setBindGroup(0, self.bind_group, 0, null);
                    pass.setVertexBuffer(0, vb, 0, @sizeOf(render_types.Vertex) * font.vertex_count);
                    pass.draw(font.vertex_count, 1, 0, 0);
        }
            }
        }

        pass.end();

        const cmd_buffer = encoder.finish(&wgpu.CommandBufferDescriptor{}) orelse {
            std.debug.print("Failed to finish encoder\n", .{});
            return;
        };
        defer cmd_buffer.release();
        self.queue.submit(&[_]*const wgpu.CommandBuffer{cmd_buffer});
        const present_status = self.surface.present();
        if (present_status != .success) {
            std.debug.print("Surface present failed: {}\n", .{present_status});
        }
    }
};
