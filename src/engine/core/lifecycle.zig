//! Startup and shutdown of the engine's subsystems, in the order they depend on each other:
//! settings, SDL, the window, the GPU device, the native target and sprite batches, input, and audio.
//! `Session` owns all of them. It is built in place and never moved, because `Context` holds
//! pointers into it.

const std = @import("std");
const build_options = @import("build_options");
const allocator_types = @import("allocators.zig");
const platform = @import("../platform/platform.zig");
const audio = @import("../audio/audio.zig");
const logging = @import("../logging/log.zig");
const Input = @import("../input/input.zig").Input;
const Camera = @import("../renderer/camera.zig").Camera;
const sprite = @import("../renderer/sprite.zig");
const SpriteBatch = @import("../renderer/sprite.zig").SpriteBatch;
const texture = @import("../renderer/texture.zig");
const Texture = @import("../renderer/texture.zig").Texture;
const settings = @import("settings.zig");
const application = @import("application.zig");
const context = @import("context.zig");

const Config = application.Config;
const Context = context.Context;
const max_full_path = context.max_full_path;
const elog = logging.scoped("engine");

/// Everything the running engine owns. `start` opens it and `stop` releases it.
pub const Session = struct {
    /// Text of the settings file. It is kept for the whole run, because the game reads from it.
    settings_bytes: ?[]u8 = null,
    engine_allocator: std.mem.Allocator = undefined,
    platform_started: bool = false,
    window_created: bool = false,
    gpu_created: bool = false,
    target_created: bool = false,
    world_batch_created: bool = false,
    screen_batch_created: bool = false,
    audio_created: bool = false,
    stopped: bool = true,
    window: *platform.Window = undefined,
    gpu: platform.gpu.Gpu = undefined,
    /// The swapchain format. Targets and pipelines use it so they can be drawn into the window.
    format: platform.gpu.TextureFormat = undefined,
    /// The world target, sized to the view. The runtime rebuilds it when the view changes.
    target: Texture = undefined,
    world_batch: SpriteBatch = undefined,
    screen_batch: SpriteBatch = undefined,
    input: Input = .{},
    audio: audio.Audio = undefined,
    cam: Camera = undefined,
    ctx: Context = undefined,

    /// Opens everything, in dependency order: settings are read, then the platform starts, then the
    /// window, the GPU device, and the audio device. A failed step returns its error after releasing
    /// whatever was opened before it, so a failed start leaves the session stopped. The config is
    /// checked before anything is opened. GPU resources made once the device is up panic instead,
    /// because the engine cannot continue without them. Missing audio does not fail startup; the
    /// game runs silent.
    pub fn start(self: *Session, config: Config, allocators: *allocator_types.RuntimeAllocators) !void {
        logging.assert(self.stopped, @src(), "a session is already running", .{});
        config.validate() catch |err| {
            elog.err("{s}", .{Config.validationMessage(err)});
            return err;
        };
        self.engine_allocator = allocators.engineAllocator();
        self.settings_bytes = readSettings(self.engine_allocator, config.settings_file);
        const settings_text: []const u8 = self.settings_bytes orelse "";
        const window_settings = loadWindowSettings(settings_text, .{
            .width = config.window_w,
            .height = config.window_h,
            .fullscreen = config.fullscreen,
            .vsync = config.vsync,
        });

        self.stopped = false;
        errdefer self.stop();
        try platform.init();
        self.platform_started = true;
        self.window = platform.window.create(config.title, window_settings.width, window_settings.height, window_settings.fullscreen) catch |err| {
            elog.err("window creation failed: {s}", .{@errorName(err)});
            return err;
        };
        self.window_created = true;
        elog.info("window {d}x{d}, native view {d}x{d}, {d} update steps per second", .{
            window_settings.width, window_settings.height, config.native_w, config.native_h, config.update_hz,
        });

        self.gpu = platform.gpu.Gpu.init(self.window, build_options.gpu_debug) catch |err| {
            elog.err("GPU device creation failed: {s}", .{@errorName(err)});
            return err;
        };
        self.gpu_created = true;
        if (!self.gpu.setVsync(window_settings.vsync)) elog.warn("immediate present is not available on this display, so vsync stays on", .{});
        const vsync_label: []const u8 = if (window_settings.vsync) "on" else "off";
        elog.info("vsync {s}", .{vsync_label});

        self.format = self.gpu.swapchainFormat();
        const gpu_debug_label: []const u8 = if (build_options.gpu_debug) "on" else "off";
        elog.info("GPU device ready, validation {s}, swapchain format {d}", .{ gpu_debug_label, self.format });

        const native_wf: f32 = @floatFromInt(config.native_w);
        const native_hf: f32 = @floatFromInt(config.native_h);
        self.target = texture.createTarget(self.engine_allocator, self.gpu.device, config.native_w, config.native_h, self.format);
        self.target_created = true;
        self.world_batch = sprite.create(self.engine_allocator, self.gpu.device, self.format);
        self.world_batch_created = true;
        self.screen_batch = sprite.create(self.engine_allocator, self.gpu.device, self.format);
        self.screen_batch_created = true;
        // Sound output. A missing device leaves it silent, so it never stops the game.
        self.audio = audio.Audio.init();
        self.audio_created = true;
        // The game sets the world size every frame, so the camera starts without one.
        self.cam = Camera{ .view_w = native_wf, .view_h = native_hf, .world_w = 0, .world_h = 0 };
        // Before the first frame is drawn, assume the view fills the window at its native size.
        self.ctx = Context{
            .gpu_state = @ptrCast(self.gpu.device),
            .allocators = allocators.context(),
            .input = &self.input,
            .scale_mode = config.scale_mode,
            .zoom_min = config.zoom_min,
            .zoom_max = config.zoom_max,
            .layout = .{ .dst_w = native_wf, .dst_h = native_hf, .view_w = native_wf, .view_h = native_hf },
            .camera = &self.cam,
            .audio = &self.audio,
            .settings_text = settings_text,
        };
    }

    /// Releases everything `start` opened, in reverse order: the audio device, the batches, the
    /// target, the GPU, the window, and then the platform. The game must be released first.
    pub fn stop(self: *Session) void {
        if (self.stopped) return;
        self.stopped = true;

        if (self.audio_created) {
            self.audio.deinit();
            self.audio_created = false;
        }
        if (self.screen_batch_created) {
            self.screen_batch.deinit();
            self.screen_batch_created = false;
        }
        if (self.world_batch_created) {
            self.world_batch.deinit();
            self.world_batch_created = false;
        }
        if (self.target_created) {
            self.target.deinit();
            self.target_created = false;
        }
        if (self.gpu_created) {
            // The device must go before the window, because it is still claimed for that window.
            self.gpu.deinit();
            self.gpu_created = false;
        }
        if (self.window_created) {
            platform.window.destroy(self.window);
            self.window_created = false;
        }
        if (self.platform_started) {
            platform.shutdown();
            self.platform_started = false;
        }
        if (self.settings_bytes) |bytes| {
            self.engine_allocator.free(bytes);
            self.settings_bytes = null;
        }
    }
};

/// Opens the log file beside the executable when the game asks for one. Each run replaces the
/// file from the last run. Startup messages and startup failures are kept, so this runs first.
pub fn openLog(config: Config) void {
    if (config.log_file) |name| {
        var path_buf: [max_full_path]u8 = undefined;
        const path = platform.files.absolutePath(.beside_executable, name, &path_buf) catch {
            elog.warn("log file name is longer than {d} bytes, so logs go to the terminal only", .{max_full_path});
            return;
        };
        if (logging.openFile(path)) {
            elog.info("log file {s}", .{path});
        } else {
            elog.warn("could not open log file {s}, so logs go to the terminal only", .{path});
        }
    }
}

/// Reads the settings file beside the executable. Returns null when there is no file, or it can't be
/// read. The caller frees the result with the supplied engine allocator.
fn readSettings(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    var buf: [max_full_path]u8 = undefined;
    const shown = platform.files.absolutePath(.beside_executable, name, &buf) catch {
        elog.warn("settings file name '{s}' is too long, so the defaults are used", .{name});
        return null;
    };
    const bytes = platform.files.read(allocator, .beside_executable, name) catch |err| {
        switch (err) {
            error.NotFound => elog.info("no settings file at {s}, so the defaults are used", .{shown}),
            else => elog.warn("settings file {s} could not be read, so the defaults are used", .{shown}),
        }
        return null;
    };
    elog.info("settings file {s}", .{shown});
    return bytes;
}

/// Reads the window settings over `defaults`. A value that can't be read is logged, and its default is kept.
fn loadWindowSettings(text: []const u8, defaults: settings.Window) settings.Window {
    var window = defaults;
    var lines = settings.Lines.init(text);
    while (lines.next()) |line| {
        const value = line.value orelse continue;
        if (settings.applyWindowLine(&window, line.key, value) == .bad_value) {
            elog.warn("settings line {d}: '{s}' has a value that isn't valid, so the default is used", .{ line.number, line.key });
        }
    }
    return window;
}

test "stopping an unstarted session is idempotent" {
    var session = Session{};
    session.stop();
    session.stop();
    try std.testing.expect(session.stopped);
}
