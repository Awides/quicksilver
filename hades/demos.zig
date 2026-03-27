const std = @import("std");
const glfw = @import("zglfw");
const render_types = @import("render_types.zig");

pub const Demo = enum {
    splash,
    drippy,
};

pub const DemoParams = struct {
    viscosity: f32,
    glow: f32,
    phase: f32,
};

pub fn getDemoParams(demo: Demo, time: f32, _: [2]f32) DemoParams {
    return switch (demo) {
        .splash => DemoParams{
            .viscosity = 0.5 + 0.5 * @sin(time * 0.5),
            .glow = 1.0,
            .phase = time * 0.1,
        },
        .drippy => DemoParams{
            .viscosity = 0.8 + 0.2 * @sin(time * 0.3),
            .glow = 0.6,
            .phase = time * 0.15,
        },
    };
}

pub fn getBlobs(time: f32, resolution: [2]f32) [4]render_types.Blob {
    const center_screen = [2]f32{ resolution[0] * 0.5, resolution[1] * 0.5 };
    const max_amplitude = @min(resolution[0], resolution[1]) * 0.3;
    var blobs: [4]render_types.Blob = undefined;
    for (0..4) |i| {
        const fi = @as(f32, @floatFromInt(i));
        const speed_x: f32 = 0.3 + fi * 0.1;
        const speed_y: f32 = 0.4 + fi * 0.15;
        const phase_x: f32 = fi * 1.5;
        const phase_y: f32 = fi * 2.0;
        const pos_x = center_screen[0] + @cos(time * speed_x + phase_x) * max_amplitude;
        const pos_y = center_screen[1] + @sin(time * speed_y + phase_y) * max_amplitude;
        const radius: f32 = 80.0 + 40.0 * @sin(time * 0.7 + fi);
        blobs[i] = render_types.Blob{
            .pos_x = pos_x,
            .pos_y = pos_y,
            .radius = radius,
            .pad = 0,
        };
    }
    return blobs;
}
