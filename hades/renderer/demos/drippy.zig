const std = @import("std");
const glfw = @import("zglfw");
const renderer_mod = @import("renderer.zig");
const demos = @import("demos.zig");
const render_types = @import("render_types.zig");

pub fn runDrippy() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try glfw.init();
    defer glfw.terminate();

    const start_fullscreen = true;
    var fullscreen = start_fullscreen;
    var windowed_state = struct { x: i32, y: i32, w: i32, h: i32 }{ .x = 100, .y = 100, .w = 800, .h = 600 };

    var window: *glfw.Window = undefined;
    if (start_fullscreen) {
        const monitor = glfw.Monitor.getPrimary() orelse return error.NoMonitor;
        const mode = monitor.getVideoMode() catch null;
        if (mode) |vm| {
            window = try glfw.Window.create(vm.width, vm.height, "Drippy", monitor, null);
        } else {
            window = try glfw.Window.create(800, 600, "Drippy", null, null);
        }
    } else {
        window = try glfw.Window.create(800, 600, "Drippy", null, null);
    }
    defer window.destroy();
    glfw.makeContextCurrent(window);

    const font_configs = &[_]renderer_mod.FontConfig{
        .{ .label = "Iosevka-Thin", .layer = 0 },
        .{ .label = "Iosevka-Heavy", .layer = 1 },
        .{ .label = "IosevkaAile-Regular", .layer = 2 },
        .{ .label = "IosevkaAile-SemiBold", .layer = 3 },
    };

    var rend = try renderer_mod.Renderer.init(allocator, window, font_configs);
    defer rend.deinit(allocator);

    var available_layers: [4]i32 = undefined;
    var available_count: usize = 0;
    for (rend.font_infos, 0..) |opt, i| {
        if (opt != null) {
            available_layers[available_count] = @as(i32, @intCast(i));
            available_count += 1;
        }
    }
    if (available_count == 0) {
        std.debug.print("No fonts loaded.\n", .{});
        return;
    }

    // Message buffer
    var message_buf: [256]u21 = undefined;
    var message_len: usize = 0;
    const init_text = "HADES";
    var iter = std.unicode.Utf8Iterator{ .bytes = init_text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        if (message_len < message_buf.len) {
            message_buf[message_len] = cp;
            message_len += 1;
        }
    }

    // Use the first available layer
    const layer_i32 = available_layers[0];
    const layer_usize = @as(usize, @intCast(layer_i32));

    // Build geometry for all fonts
    try rend.buildTextGeometry(allocator, message_buf[0..message_len], 300, 300);

    const active_font = rend.font_infos[layer_usize] orelse {
        std.debug.print("Selected font layer not available.\n", .{});
        return;
    };





     const start_time = glfw.getTime();
     var last_time = start_time;

    // Droplet state (128 droplets)
    var droplets: [128]render_types.Droplet = undefined;
    {
        const init_w = @as(f32, @floatFromInt(rend.current_width));
        const init_h = @as(f32, @floatFromInt(rend.current_height));
        for (&droplets, 0..) |*d, i| {
            const seed = @as(f32, @floatFromInt(i));
            const rx = @mod(seed * 12.9898, 1.0);
            const ry = @mod(seed * 78.233, 1.0);
            d.* = .{
                .x = rx * init_w,
                .y = ry * init_h,
                .radius = 5.0,
                .life = 1.0,
            };
        }
    }

    while (!window.shouldClose()) {
        glfw.pollEvents();
        rend.resizeIfNeeded(window);

        const now = glfw.getTime();
        const time = @as(f32, @floatCast(now - start_time));
        const dt_val = @as(f32, @floatCast(now - last_time));
        last_time = now;
        const resolution = [2]f32{ @floatFromInt(rend.current_width), @floatFromInt(rend.current_height) };

        // Compute scale and screen bounds (match vertex shader)
        const base_scale = @min(
            if (active_font.text_width > 0) (resolution[0] * 0.9) / active_font.text_width else 1.0,
            if (active_font.text_height > 0) (resolution[1] * 0.5) / active_font.text_height else 1.0,
        );

        const window_center = @Vector(2, f32){ resolution[0] * 0.5, resolution[1] * 0.5 };
        const float_offset = @Vector(2, f32){ 0.0, 0.0 };
        const scale = base_scale;
        const screen_center = window_center + float_offset;

        const half_w = active_font.text_width * 0.5;
        const half_h = active_font.text_height * 0.5;
        const half_w_screen = half_w * scale;
        const half_h_screen = half_h * scale;
        const screen_left = screen_center[0] - half_w_screen;
        const screen_right = screen_center[0] + half_w_screen;
        const screen_top = screen_center[1] - half_h_screen;   // top = smaller y
        const screen_bottom = screen_center[1] + half_h_screen; // bottom = larger y
        const spawn_y = screen_bottom - 10.0;

        // Update droplets: pull away from center
        const center_y = (screen_top + screen_bottom) * 0.5;
        for (&droplets, 0..) |*d, i| {
            const idx_f = @as(f32, @floatFromInt(i));
            const dir: f32 = if (d.y < center_y) -1.0 else 1.0;
            d.y += 20.0 * dt_val * dir;
            if (d.radius < 120.0) {
                d.radius += 1.0 * dt_val;
            }
            if (d.y < screen_top - 20.0 or d.y > screen_bottom + 20.0) {
                const r = @sin(time * 0.5 + idx_f * 1.7) * 0.5 + 0.5;
                if (r < 0.3) {
                    const rx = @mod(idx_f * 12.9898, 1.0);
                    const ry = @mod(idx_f * 78.233, 1.0);
                    d.x = screen_left + rx * (screen_right - screen_left);
                    d.y = screen_top + ry * (screen_bottom - screen_top);
                    d.radius = 5.0;
                }
            }
        }

        const demo_params = demos.getDemoParams(.drippy, time, resolution);
        const blobs = demos.getBlobs(time, resolution);


        const uniforms = render_types.AppUniforms{
            .resolution_x = resolution[0],
            .resolution_y = resolution[1],
            .center_x = active_font.center_x,
            .center_y = active_font.center_y,
            .time = time,
            .viscosity = demo_params.viscosity,
            .glow = demo_params.glow,
            .phase = demo_params.phase,
            .base_scale = base_scale,
            .font_layer = layer_i32,
            .demo_mode = 1,
            .metaball_alpha = 150.0,
            .metaball_hardness = 0.3,
            .pad1 = 0.0,
            .pad2 = 0.0,
            .pad3 = 0.0,
            .blobs = blobs,
            .sweat_droplets = droplets,
        };

        rend.render(active_font, &uniforms);
    }
}
