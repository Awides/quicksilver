const std = @import("std");
const glfw = @import("zglfw");
const renderer_mod = @import("renderer.zig");
const demos = @import("demos.zig");
const render_types = @import("render_types.zig");

const AppContext = struct {
    allocator: std.mem.Allocator,
    renderer: *renderer_mod.Renderer,
    message_buf: *[256]u21,
    message_len: *usize,
};

fn charCallback(win: *glfw.Window, codepoint: u32) callconv(.c) void {
    const ctx = glfw.getWindowUserPointer(win, AppContext) orelse return;
    if (codepoint >= 32) { // printable
        const cp: u21 = @intCast(codepoint);
        const len = ctx.message_len.*;
        if (len < ctx.message_buf.len) {
            ctx.message_buf.*[len] = cp;
            ctx.message_len.* = len + 1;
        }
        ctx.renderer.buildTextGeometry(ctx.allocator, ctx.message_buf.*[0 .. ctx.message_len.*], 300, 300) catch {};
    }
}

pub fn runSplash() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try glfw.init();
    defer glfw.terminate();

    const start_fullscreen = true;
    var window: *glfw.Window = undefined;
    var fullscreen = start_fullscreen;
    var windowed_state = struct { x: i32, y: i32, w: i32, h: i32 }{ .x = 100, .y = 100, .w = 800, .h = 600 };

    if (start_fullscreen) {
        const monitor = glfw.Monitor.getPrimary() orelse return error.NoMonitor;
        const mode = monitor.getVideoMode() catch null;
        if (mode) |vm| {
            window = try glfw.Window.create(vm.width, vm.height, "Hades", monitor, null);
        } else {
            // Fallback to windowed if video mode unavailable
            window = try glfw.Window.create(800, 600, "Hades", null, null);
        }
    } else {
        window = try glfw.Window.create(800, 600, "Hades", null, null);
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

    try rend.buildTextGeometry(allocator, message_buf[0..message_len], 300, 300);

    const app_ctx = try allocator.create(AppContext);
    app_ctx.* = .{
        .allocator = allocator,
        .renderer = &rend,
        .message_buf = &message_buf,
        .message_len = &message_len,
    };
    window.setUserPointer(app_ctx);
    _ = window.setCharCallback(charCallback);

    var current_layer_idx: usize = 0;
    var current_demo: demos.Demo = .splash;

    var up_was_down = false;
    var down_was_down = false;
    var left_was_down = false;
    var right_was_down = false;
    var backspace_was_down = false;
    var f11_was_down = false;

    const start_time = glfw.getTime();

    while (!window.shouldClose()) {
        const up = window.getKey(.up);
        if (up == .press and !up_was_down) {
            current_layer_idx = (current_layer_idx + 1) % available_count;
        }
        up_was_down = (up == .press);

        const down = window.getKey(.down);
        if (down == .press and !down_was_down) {
            if (current_layer_idx == 0) {
                current_layer_idx = available_count - 1;
            } else {
                current_layer_idx -= 1;
            }
        }
        down_was_down = (down == .press);

        const left = window.getKey(.left);
        if (left == .press and !left_was_down) {
            current_demo = if (@intFromEnum(current_demo) == 0) demos.Demo.drippy else demos.Demo.splash;
        }
        left_was_down = (left == .press);

        const right = window.getKey(.right);
        if (right == .press and !right_was_down) {
            current_demo = if (@intFromEnum(current_demo) == 0) demos.Demo.drippy else demos.Demo.splash;
        }
        right_was_down = (right == .press);

        const backspace = window.getKey(.backspace);
        if (backspace == .press and !backspace_was_down) {
            if (message_len > 0) {
                message_len -= 1;
                rend.buildTextGeometry(allocator, message_buf[0..message_len], 300, 300) catch {};
            }
        }
        backspace_was_down = (backspace == .press);

        const f11 = window.getKey(.F11);
        if (f11 == .press and !f11_was_down) {
            if (fullscreen) {
                // Exit fullscreen: restore saved windowed state
                window.setMonitor(null, windowed_state.x, windowed_state.y, windowed_state.w, windowed_state.h, 0);
                fullscreen = false;
            } else {
                // Enter fullscreen: save current window state before switching
                windowed_state = .{
                    .x = window.getPos()[0],
                    .y = window.getPos()[1],
                    .w = window.getSize()[0],
                    .h = window.getSize()[1],
                };
                if (glfw.Monitor.getPrimary()) |monitor| {
                    const mode = monitor.getVideoMode() catch null;
                    if (mode) |real_mode| {
                        window.setMonitor(monitor, 0, 0, real_mode.width, real_mode.height, real_mode.refresh_rate);
                        fullscreen = true;
                    }
                }
            }
        }
        f11_was_down = (f11 == .press);

        glfw.pollEvents();

        rend.resizeIfNeeded(window);

        const now = glfw.getTime();
        const time = @as(f32, @floatCast(now - start_time));
        const resolution = [2]f32{ @floatFromInt(rend.current_width), @floatFromInt(rend.current_height) };

        const layer_i32 = available_layers[current_layer_idx];
        const layer_usize = @as(usize, @intCast(layer_i32));
        const active_opt = rend.font_infos[layer_usize];
        if (active_opt) |active_font| {
            const demo_params = demos.getDemoParams(current_demo, time, resolution);
            const blobs = demos.getBlobs(time, resolution);
            const width_scale = if (active_font.text_width > 0) (resolution[0] * 0.9) / active_font.text_width else 1.0;
            const height_scale = if (active_font.text_height > 0) (resolution[1] * 0.5) / active_font.text_height else 1.0;
            const base_scale = @min(width_scale, height_scale);

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
                .pad1 = 0,
                .pad2 = 0,
                .blobs = blobs,
            };

            rend.render(active_font, &uniforms);
        }
    }
}
