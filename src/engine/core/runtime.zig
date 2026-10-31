//! The frame loop. `run` opens the engine, creates the game, and runs frames until the game sets
//! `running` to false or the window closes. Each frame measures its time, drains events, runs the
//! fixed-step updates, lays out the native view, draws the world into it, and presents it.
//!
//! Timing: `update` runs at a fixed rate, so game logic doesn't depend on the display. `draw` runs
//! once per frame and gets `alpha` to blend between the last two updates.

const std = @import("std");
const platform = @import("../platform/platform.zig");
const application = @import("application.zig");
const allocator_types = @import("allocators.zig");
const context = @import("context.zig");
const event = @import("event.zig");
const lifecycle = @import("lifecycle.zig");
const logging = @import("../logging/log.zig");
const profile = @import("../profiling/profile.zig");
const debug_overlay = @import("../profiling/debug_overlay.zig");
const renderer = @import("../renderer/renderer.zig");
const view = @import("../renderer/view.zig");
const sprite = @import("../renderer/sprite.zig");
const Rect = sprite.Rect;
const texture = @import("../renderer/texture.zig");
const Texture = @import("../renderer/texture.zig").Texture;

const Config = application.Config;
const DrawContext = context.DrawContext;
const elog = logging.scoped("engine");

/// Longest frame time the loop will use. A longer stall is cut short, so the game slows down
/// rather than racing to catch up.
const max_dt: f32 = 0.1;
/// How long to sleep when there is nothing to draw, in milliseconds. A minimized window has no
/// pixels to draw into, so the loop idles instead of spinning. The sleep is short enough that a
/// restored window shows up within a frame.
const idle_sleep_ms: u32 = 16;

const black = renderer.Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

/// Opens the window and runs `Game` until it sets `running` to false or the window closes.
///
/// Returns an error when the config is invalid, when the engine can't start, or when the game's
/// `init` fails. Each failure is logged, and everything opened before it is released first. A
/// clean run returns normally.
pub fn run(comptime Game: type, config: Config) !void {
    config.validate() catch |err| {
        elog.err("{s}", .{Config.validationMessage(err)});
        return err;
    };

    // The logger reads the platform clock, so it is set before the first log line. Its timestamps
    // then share a clock with the frame timing below.
    logging.setClock(platform.clock.nowNs);

    // The log file sits beside the executable, which the platform resolves.
    lifecycle.openLog(config);
    defer logging.closeFile();
    elog.info("profiling zones {s}", .{if (profile.enabled) "on (Tracy)" else "off"});

    const fixed_dt: f32 = 1.0 / @as(f32, @floatFromInt(config.update_hz));

    var allocators = allocator_types.RuntimeAllocators.init(config.allocator);
    defer allocators.deinit();

    var session = lifecycle.Session{};
    session.start(config, &allocators) catch |err| {
        elog.err("engine startup failed: {s}", .{@errorName(err)});
        return err;
    };
    defer session.stop();
    const ctx = &session.ctx;

    var game = Game.init(ctx) catch |err| {
        elog.err("game initialization failed: {s}", .{@errorName(err)});
        return err;
    };
    defer game.deinit();
    // The overlay bakes its own copy of the debug font, loaded from the same files as the game's fonts.
    const debug_font = ctx.loadFont(config.debug_font_path, config.debug_font_px) catch |err| blk: {
        elog.warn("debug overlay font '{s}' unavailable: {s}; overlay disabled", .{ config.debug_font_path, @errorName(err) });
        break :blk null;
    };
    var overlay = debug_overlay.Overlay.init(allocators.engineAllocator(), debug_font);
    defer overlay.deinit();

    const native_wf: f32 = @floatFromInt(config.native_w);
    const native_hf: f32 = @floatFromInt(config.native_h);
    const clear = renderer.Color{
        .r = config.clear_rgb[0],
        .g = config.clear_rgb[1],
        .b = config.clear_rgb[2],
        .a = 1.0,
    };

    var last_mode = ctx.scale_mode;
    var last_ns = platform.clock.nowNs();
    var accumulator: f32 = 0;
    var total_frames: u64 = 0;
    var last_draw_calls: u32 = 0;

    while (ctx.running) {
        allocators.resetFrame();
        // Each Tracy frame runs from one mark to the next, so idle frames show in the profile too.
        profile.frameMark();
        const frame_zone = profile.zoneNamed(@src(), "frame");
        defer frame_zone.End();

        // Frame timing: seconds since the last frame, capped at max_dt.
        const now_ns = platform.clock.nowNs();
        // The overlay graphs the raw time, so a long stall shows in full. The update loop uses the capped time.
        const frame_seconds = @as(f32, @floatFromInt(now_ns - last_ns)) / 1_000_000_000.0;
        const frame_dt = @min(frame_seconds, max_dt);
        last_ns = now_ns;
        overlay.record(frame_seconds);

        // Events, then the held keys as of this pump. Presses and clicks wait in Input for an update.
        {
            const zone = profile.zoneNamed(@src(), "events");
            defer zone.End();
            const pumped = event.pump(session.window, &session.input);
            if (pumped.quit) ctx.running = false;
            if (pumped.toggle_overlay) overlay.toggle();
            session.input.sampleHeld(platform.events.isHeld);
        }

        // Fixed-timestep updates. Run whole steps while the accumulated time covers one, so game
        // logic advances at the same rate on any display. Stop early if the game quits.
        accumulator += frame_dt;
        var steps: u32 = 0;
        while (accumulator >= fixed_dt and ctx.running) {
            session.input.latch();
            ctx.dt = fixed_dt;
            {
                const zone = profile.zoneNamed(@src(), "update");
                defer zone.End();
                game.update(ctx);
            }
            accumulator -= fixed_dt;
            steps += 1;
        }
        if (steps > 4) {
            elog.debug("{d} update steps in one frame, so the frame took {d:.1} ms", .{ steps, frame_dt * 1000.0 });
        }
        // Free finished voices and keep looping voices fed. Once per frame is enough, because a
        // looping voice queues a full copy of its sound ahead of time.
        {
            const zone = profile.zoneNamed(@src(), "audio");
            defer zone.End();
            session.audio.update();
        }
        if (ctx.scale_mode != last_mode) {
            elog.info("scale mode: {s}", .{@tagName(ctx.scale_mode)});
            last_mode = ctx.scale_mode;
        }

        // The leftover time as a fraction of a step. Drawing blends between the last two updates by this amount.
        const alpha = @min(accumulator / fixed_dt, 1.0);
        logging.assert(alpha >= 0.0 and alpha <= 1.0, @src(), "blend factor {d} is outside 0 to 1", .{alpha});

        // Window size in pixels, which is also the swapchain size on high-DPI displays.
        const px = platform.window.pixelSize(session.window);
        if (px.w <= 0 or px.h <= 0) {
            // Minimized: there is nothing to draw into, so sleep rather than spin. Events stay
            // queued in SDL until the next pump.
            platform.clock.sleepMs(idle_sleep_ms);
            continue;
        }
        const win_wf: f32 = @floatFromInt(px.w);
        const win_hf: f32 = @floatFromInt(px.h);

        // Ease the camera's zoom toward the zoom the game asked for. This runs before the view is
        // sized, so this frame is drawn at the zoom it has reached.
        session.cam.approachZoom(ctx.zoom_target, frame_dt, config.zoom_rate);

        // Choose the scale and the view size for this zoom. The fallback rules for integer mode live
        // in view.chooseFit.
        const fit = view.chooseFit(win_wf, win_hf, native_wf, native_hf, ctx.scale_mode, session.cam.zoom);
        const mode_label: []const u8 = if (fit.pixel_perfect) "integer" else "fit";
        const view_w = fit.view_w;
        const view_h = fit.view_h;
        const view_wf: f32 = @floatFromInt(view_w);
        const view_hf: f32 = @floatFromInt(view_h);
        logging.assert(view_w >= 1 and view_h >= 1, @src(), "view {d}x{d} is empty", .{ view_w, view_h });

        if (session.target.width != view_w or session.target.height != view_h) {
            const zone = profile.zoneNamed(@src(), "rebuild target");
            defer zone.End();
            // Wait first, because the old target may still be in use by the GPU.
            platform.gpu.waitIdle(session.gpu.device);
            session.target.deinit();
            session.target = texture.createTarget(allocators.engineAllocator(), session.gpu.device, view_w, view_h, session.format);
            elog.debug("native target is now {d}x{d} at {d:.2} scale ({s})", .{ view_w, view_h, fit.scale, mode_label });
        }

        session.cam.view_w = view_wf;
        session.cam.view_h = view_hf;

        // Acquire the frame after the layout is known. A minimized window can report a nonzero size
        // yet get no swapchain, so this path idles too.
        const frame = session.gpu.beginFrame() orelse {
            platform.clock.sleepMs(idle_sleep_ms);
            continue;
        };

        // Pass 1: the game queues its sprites, and they're drawn into the view-sized target.
        session.world_batch.begin(view_wf, view_hf);
        const draw_ctx = DrawContext{
            .batch = &session.world_batch,
            .cam = &session.cam,
            .view_w = view_wf,
            .view_h = view_hf,
            .alpha = alpha,
            .dt = frame_dt,
        };
        {
            const zone = profile.zoneNamed(@src(), "game draw");
            defer zone.End();
            game.draw(&draw_ctx);
        }
        // The overlay goes above the game in the same native view. Its draw-call count is from the
        // last frame, since this frame's batches are not drawn until below.
        overlay.draw(&session.world_batch, view_wf, .{
            .sprites = session.world_batch.sprite_count,
            .draw_calls = last_draw_calls,
            .mode = mode_label,
            .scale = fit.scale,
            .zoom = session.cam.zoom,
            .view_w = view_w,
            .view_h = view_h,
        });
        sprite.upload(&session.world_batch, frame.cmd);
        const world_pass = renderer.beginPass(frame.cmd, texture.backendTexture(&session.target), clear);
        sprite.draw(&session.world_batch, world_pass);
        renderer.endPass(world_pass);

        // Pass 2: stretch the target onto the window. Fit mode covers the whole window. Integer
        // mode covers a centered whole-number multiple of the view, and the edges stay black.
        {
            const zone = profile.zoneNamed(@src(), "present");
            defer zone.End();
            var dst_rect = Rect{ .x = 0, .y = 0, .w = win_wf, .h = win_hf };
            if (fit.pixel_perfect) {
                const content_w = view_wf * fit.scale;
                const content_h = view_hf * fit.scale;
                dst_rect = Rect{
                    .x = @floor((win_wf - content_w) / 2.0),
                    .y = @floor((win_hf - content_h) / 2.0),
                    .w = content_w,
                    .h = content_h,
                };
            }
            // Record where the view landed, so the next update maps mouse positions with the same rectangle.
            ctx.layout = .{
                .pixel_density = platform.window.pixelDensity(session.window),
                .dst_x = dst_rect.x,
                .dst_y = dst_rect.y,
                .dst_w = dst_rect.w,
                .dst_h = dst_rect.h,
                .view_w = view_wf,
                .view_h = view_hf,
            };
            const view_rect = Rect{ .x = 0, .y = 0, .w = view_wf, .h = view_hf };
            session.screen_batch.begin(win_wf, win_hf);
            session.screen_batch.drawSprite(&session.target, view_rect, dst_rect, .{});
            sprite.upload(&session.screen_batch, frame.cmd);
            const screen_pass = renderer.beginPass(frame.cmd, frame.swapchain, black);
            sprite.draw(&session.screen_batch, screen_pass);
            renderer.endPass(screen_pass);
        }

        platform.gpu.Gpu.endFrame(frame);

        // The window title stays as configured. The frame stats are in the debug overlay (F3).
        last_draw_calls = session.world_batch.draw_calls + session.screen_batch.draw_calls;
        total_frames += 1;
    }
    elog.info("main loop ended after {d} frames", .{total_frames});
}
