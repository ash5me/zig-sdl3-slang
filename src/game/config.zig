//! Game settings: title, window and native view sizes, level path, background color, update
//! rate, and scale mode. Read once at startup. The engine knows nothing else about the game.

const engine = @import("bairava");

/// Window title. The window keeps it as written; frame stats are in the debug overlay (F3).
pub const title: [:0]const u8 = "Semkootru";
/// Window size in pixels at startup. The settings file can change it with `resolution`.
pub const window_w: c_int = 960;
pub const window_h: c_int = 540;
/// Fullscreen and vsync at startup. The settings file can change both.
pub const fullscreen = false;
pub const vsync = true;
/// The settings file, beside the executable. It sets the resolution, fullscreen, vsync, and key
/// bindings. A missing file means these defaults. Copy `settings.txt` there to edit it.
pub const settings_file_name = "settings.txt";
/// The reference view size, in native pixels. At zoom 1 it fits the window on its limiting axis,
/// so the view is exactly this size on that axis. The pixel art is designed at this size.
pub const native_w: u32 = 320;
pub const native_h: u32 = 180;
/// Background color behind the world, as RGB from 0 to 1.
pub const clear_rgb = [3]f32{ 0.2, 0.3, 0.5 };
/// Game logic steps per second. Movement is in pixels per second, so this changes smoothness, not speed.
pub const update_hz: u32 = 60;
/// Starting scale mode. Press I in game to toggle between fit and integer.
pub const scale_mode: engine.ScaleMode = .fit;
/// How fast the camera catches up with the player, as a rate per second. Higher is snappier. Zero
/// turns smoothing off, so the camera snaps to the player.
pub const camera_rate: f32 = 10.0;
/// Zoom limits and step. 1 is the normal view. The bounds must include 1, so the reset key lands
/// inside them, and the minimum must be positive, because zoom eases in logarithmic steps.
pub const zoom_min: f32 = 0.5;
pub const zoom_max: f32 = 4.0;
/// Each zoom-in press multiplies the zoom by this. Each zoom-out press divides by it.
pub const zoom_step: f32 = 1.25;
/// How fast the camera eases to a new zoom, per second. Zero snaps.
pub const zoom_rate: f32 = 8.0;

comptime {
    if (!(zoom_min > 0.0 and zoom_min <= 1.0 and zoom_max >= 1.0)) @compileError("zoom bounds must be positive and include 1");
    if (!(zoom_step > 1.0)) @compileError("zoom_step must be greater than 1");
}
/// The texture atlas: one image that holds every sprite, and an index of where each sprite sits in
/// it. `zig build` makes both from the sprite list in build.zig, and installs them beside the
/// executable. Paths are relative to the executable's folder. A sprite the game asks for by name
/// must be in atlas_sprites in build.zig, or the game panics at startup.
pub const atlas_image_path = "assets/atlas.png";
pub const atlas_index_path = "assets/atlas.txt";

/// The tile map the game loads at startup, relative to the executable's folder.
pub const level_path = "assets/maps/level1.txt";

/// Looping ambience, relative to the executable's folder.
pub const ambient_sound_path = "assets/wind1.wav";

/// The gameplay save beside the executable. It is human-editable JSON with a schema version.
pub const save_file_name = "save.json";

/// The font for the demo panel, relative to the executable's folder, and its height in native
/// pixels. The UI is drawn at native resolution, so 10 keeps it legible at the 320x180 view. The
/// build's preprocessed `<path>.bfnt` beside it is used when it matches this size.
pub const ui_font_path = "assets/font.ttf";
pub const ui_font_px: f32 = 10;

/// The log file, written beside the executable and replaced on each run. Null logs to the terminal only.
pub const log_file_name: ?[:0]const u8 = "Semkootru.log";
