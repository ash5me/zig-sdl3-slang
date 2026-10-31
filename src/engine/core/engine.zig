//! The engine's public API. Game code imports only this file: everything the game may use is
//! re-exported here, so the modules under src/engine/ can move without changing game code.
//!
//! Engine code never names a game type. A game plugs in by passing a type with `init`, `update`,
//! `draw`, and `deinit` to `run`. `init` runs once; then `update` and `draw` repeat until shutdown;
//! after successful initialization, `deinit` runs once. The game owns resources it loads and must
//! release them in `deinit` before the engine tears down the GPU and platform. If `init` fails,
//! `deinit` does not run, so `init` must release what it opened before the failing step. Game `init`
//! may return a recoverable error: `run` logs it, releases what the engine opened, and returns the
//! error to its caller, so a failed start never looks like a clean exit. Truly fatal programmer
//! errors and broken invariants still panic.
//!
//! Timing: `update` runs at a fixed rate, so game logic doesn't depend on the display. `draw`
//! runs once per frame and gets `alpha` to blend between the last two updates.

pub const Config = @import("application.zig").Config;
pub const Context = @import("context.zig").Context;
pub const AssetError = @import("context.zig").AssetError;
pub const DrawContext = @import("context.zig").DrawContext;
pub const Allocators = @import("allocators.zig").ContextAllocators;
pub const run = @import("runtime.zig").run;

/// How the native view is fitted to the window. See `view.chooseFit`.
pub const ScaleMode = @import("../renderer/view.zig").ScaleMode;

/// Keys and mouse state for the game. See input/input.zig.
pub const Input = @import("../input/input.zig").Input;
pub const Key = @import("../input/input.zig").Key;
pub const Camera = @import("../renderer/camera.zig").Camera;
pub const Rect = @import("../renderer/sprite.zig").Rect;
pub const SpriteBatch = @import("../renderer/sprite.zig").SpriteBatch;
pub const Texture = @import("../renderer/texture.zig").Texture;
/// A texture atlas on the GPU, with where each sprite sits in it. See `Context.loadAtlas`.
pub const LoadedAtlas = @import("../renderer/loaded_atlas.zig").LoadedAtlas;
/// Fits the native view to the window, and maps window, view, and world coordinates.
/// `Context.mouseWorld` uses the mapping.
pub const view = @import("../renderer/view.zig");
/// Vector and matrix math, backed by cglm.
pub const math = @import("math.zig");
/// Validated fixed-capacity strings for names and paths.
pub const strings = @import("../memory/string.zig");
/// Hash map keyed by validated names.
pub const hash_map = @import("../memory/hash_map.zig");
/// Asset names, ids, and validated paths.
pub const assets = @import("../assets/registry.zig");
/// Texture atlas index: the rectangle of each sprite inside the atlas image.
pub const atlas = @import("../assets/loaders/atlas.zig");
/// Custom struct vectors in an array-of-structs or structure-of-arrays layout.
pub const vector = @import("../memory/vector.zig");
/// The entity world: component rows with generational handles, stored in a vector.
pub const entity = @import("../ecs/entity.zig");
/// Tile maps: the map file format, layers, solid tiles, and box movement against them.
pub const tilemap = @import("../scene/tilemap.zig");
/// Queues tile map layers as sprites, one per visible tile. The map itself stays SDL-free.
pub const tilemap_draw = @import("../renderer/tilemap_draw.zig");
/// Sprite-sheet animation: clips that name a row of frames, and an animator that plays them.
pub const animation = @import("../animation/animation.zig");
/// Sound output: the playback device, sounds, and voices.
pub const audio = @import("../audio/audio.zig");
/// The settings file: `name = value` lines, and the window settings the engine reads from them.
pub const settings = @import("settings.zig");
/// Text and widgets: fonts baked with stb_truetype, and the IMGUI widgets in src/engine/ui/.
pub const ui = @import("../ui/ui.zig");
/// Logging and assertions. Game code uses `engine.log.scoped("name")` and `engine.log.assert`.
pub const log = @import("../logging/log.zig");
/// Profiling zones for the Tracy profiler. They record only when the build uses -Dtracy=true.
pub const profile = @import("../profiling/profile.zig");
/// Scenes: one active scene at a time, switched at a safe point. See scene/scene_manager.zig.
pub const scene = @import("../scene/scene.zig");
/// Runs a chain of scenes as a game. Pass `SceneHost(FirstScene)` to `run`.
pub fn SceneHost(comptime Root: type) type {
    return @import("../scene/host.zig").Host(Context, DrawContext, Root);
}
/// The handle a scene gets in `update`, for asking to change scene.
pub const SceneNavigator = @import("../scene/scene_manager.zig").Manager(Context, DrawContext).Navigator;
