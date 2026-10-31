//! Entry point. Hands the game to the engine. Gameplay changes belong in src/game/.

const std = @import("std");

const engine = @import("bairava");
const config = @import("game/config.zig");
const Game = @import("game/game.zig").Game;

/// Panics are recorded in the log file before Zig prints them, so a crash leaves its reason behind.
/// Zig's default handler then prints the message and a stack trace to the terminal and aborts.
pub const panic = std.debug.FullPanic(panicWithLog);

fn panicWithLog(msg: []const u8, first_trace_addr: ?usize) noreturn {
    engine.log.recordPanic(msg);
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main() !void {
    try engine.run(engine.SceneHost(Game), .{
        .title = config.title,
        .window_w = config.window_w,
        .window_h = config.window_h,
        .native_w = config.native_w,
        .native_h = config.native_h,
        .clear_rgb = config.clear_rgb,
        .update_hz = config.update_hz,
        .scale_mode = config.scale_mode,
        .zoom_min = config.zoom_min,
        .zoom_max = config.zoom_max,
        .zoom_rate = config.zoom_rate,
        .debug_font_path = config.ui_font_path,
        .debug_font_px = config.ui_font_px,
        .log_file = config.log_file_name,
        .settings_file = config.settings_file_name,
        .fullscreen = config.fullscreen,
        .vsync = config.vsync,
    });
}
