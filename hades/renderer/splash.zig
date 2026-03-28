const std = @import("std");
const glfw = @import("zglfw");
const renderer_mod = @import("renderer.zig");
const demos = @import("demos.zig");
const render_types = @import("render_types.zig");

const WindowedState = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const AppContext = struct {
    allocator: std.mem.Allocator,
    renderer: *renderer_mod.Renderer,
    message_buf: *[256]u21,
    message_len: *usize,
    current_layer_idx: *usize,
    available_layers: []const i32,
    current_demo: *demos.Demo,
    fullscreen: *bool,
    windowed_state: *WindowedState,
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

fn keyCallback(win: *glfw.Window, key: glfw.Key, _: i32, action: glfw.Action, _: glfw.Mods) callconv(.c) void {
    const ctx = glfw.getWindowUserPointer(win, AppContext) orelse return;
    switch (key) {
        .backspace => {
            if (action == .press or action == .repeat) {
                if (ctx.message_len.* > 0) {
                    ctx.message_len.* -= 1;
                    ctx.renderer.buildTextGeometry(ctx.allocator, ctx.message_buf.*[0..ctx.message_len.*], 300, 300) catch {};
                }
            }
        },
        .up => {
            if (action == .press or action == .repeat) {
                const current = ctx.current_layer_idx.*;
                const len = ctx.available_layers.len;
                const next = (current + 1) % len;
                ctx.current_layer_idx.* = @intCast(next);
            }
        },
        .down => {
            if (action == .press or action == .repeat) {
                const current = ctx.current_layer_idx.*;
                const len = ctx.available_layers.len;
                const prev = if (current == 0) len - 1 else current - 1;
                ctx.current_layer_idx.* = @intCast(prev);
            }
        },
        .right => {
            if (action == .press or action == .repeat) {
                ctx.current_demo.* = if (ctx.current_demo.* == .splash) .drippy else .splash;
            }
        },
        .left => {
            if (action == .press or action == .repeat) {
                ctx.current_demo.* = if (ctx.current_demo.* == .splash) .drippy else .splash;
            }
        },
        .F11 => {
            if (action == .press) {
                const window = win;
                const fullscreen = ctx.fullscreen.*;
                if (fullscreen) {
                    window.setMonitor(null, ctx.windowed_state.x, ctx.windowed_state.y, ctx.windowed_state.w, ctx.windowed_state.h, 0);
                    ctx.fullscreen.* = false;
                } else {
                    const size = window.getSize();
                    ctx.windowed_state.* = .{
                        .x = window.getPos()[0],
                        .y = window.getPos()[1],
                        .w = size[0],
                        .h = size[1],
                    };
                    if (glfw.Monitor.getPrimary()) |monitor| {
                        if (monitor.getVideoMode() catch null) |vm| {
                            window.setMonitor(monitor, 0, 0, vm.width, vm.height, vm.refresh_rate);
                            ctx.fullscreen.* = true;
                        }
                    }
                }
            }
        },
        else => {},
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
    var windowed_state = WindowedState{ .x = 100, .y = 100, .w = 800, .h = 600 };

    if (start_fullscreen) {
        const monitor = glfw.Monitor.getPrimary() orelse return error.NoMonitor;
        const mode = monitor.getVideoMode() catch null;
        if (mode) |vm| {
            window = try glfw.Window.create(vm.width, vm.height, "Hades", monitor, null);
        } else {
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

    // These variables need to live long enough and be shared with callbacks
    var current_layer_idx: usize = 1; // Iosevka-Heavy layer
    var current_demo: demos.Demo = .drippy;

    const app_ctx = try allocator.create(AppContext);
    app_ctx.* = .{
        .allocator = allocator,
        .renderer = &rend,
        .message_buf = &message_buf,
        .message_len = &message_len,
        .current_layer_idx = &current_layer_idx,
        .available_layers = available_layers[0..available_count],
        .current_demo = &current_demo,
        .fullscreen = &fullscreen,
        .windowed_state = &windowed_state,
    };
    window.setUserPointer(app_ctx);
    _ = window.setCharCallback(charCallback);
    _ = window.setKeyCallback(keyCallback);

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
        const dt = @as(f32, @floatCast(now - last_time));
        last_time = now;
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

            // Compute screen-space transform to match vertex shader exactly
            const window_center = @Vector(2, f32){ resolution[0] * 0.5, resolution[1] * 0.5 };
            var float_offset = @Vector(2, f32){ @sin(time * 0.7) * 50.0, @cos(time * 0.5) * 30.0 };
            const t_val = @min(time / 0.5, 1.0);
            const entrance = t_val * t_val * (3.0 - 2.0 * t_val);
            const anim_scale = 1.0 + 0.1 * @sin(time * 2.0);
            var scale = base_scale * entrance * anim_scale;

            // For drippy demo: text stays centered and still, no offset or extra scale
            if (current_demo == .drippy) {
                float_offset = @Vector(2, f32){ 0.0, 0.0 };
                scale = base_scale;
            }

            const screen_center = window_center + float_offset;

        const half_w = active_font.text_width * 0.5;
        const half_h = active_font.text_height * 0.5;
        const half_w_screen = half_w * scale;
        const half_h_screen = half_h * scale;
        const screen_left = screen_center[0] - half_w_screen;
        const screen_right = screen_center[0] + half_w_screen;
        const screen_top = screen_center[1] - half_h_screen;
        const screen_bottom = screen_center[1] + half_h_screen;

            // Update droplets for drippy demo
            if (current_demo == .drippy) {
                const center_y = (screen_top + screen_bottom) * 0.5;
                for (&droplets, 0..) |*d, i| {
                    const idx_f = @as(f32, @floatFromInt(i));
                    // Direction away from center (up if above, down if below)
                    const dir: f32 = if (d.y < center_y) -1.0 else 1.0;
                    // Constant speed
                    const speed = 20.0;
                    d.y += speed * dt * dir;

                    // Grow to target size
                    if (d.radius < 120.0) {
                        d.radius += 1.0 * dt;
                    }

                    // Reset when outside text bounds
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
            } else {
                for (&droplets) |*d| {
                    d.* = .{ .x = 0, .y = 0, .radius = 0, .life = 1.0 };
                }
            }

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
                .demo_mode = if (current_demo == .drippy) @as(i32, 1) else @as(i32, 0),
                .metaball_alpha = if (current_demo == .drippy) 150.0 else 0.0,
                .metaball_hardness = if (current_demo == .drippy) 0.3 else 1.0,
                .pad1 = 0.0,
                .pad2 = 0.0,
                .pad3 = 0.0,
                .blobs = blobs,
                .sweat_droplets = droplets,
            };

            rend.render(active_font, &uniforms);
        }
    }
}
