//! Named-module root for Bairava. The public API remains defined in core/engine.zig; this
//! package-root shim keeps sibling engine modules inside Zig's module import boundary.

const engine = @import("core/engine.zig");

pub const Config = engine.Config;
pub const Context = engine.Context;
pub const AssetError = engine.AssetError;
pub const DrawContext = engine.DrawContext;
pub const Allocators = engine.Allocators;
pub const run = engine.run;
pub const ScaleMode = engine.ScaleMode;
pub const Input = engine.Input;
pub const Key = engine.Key;
pub const Camera = engine.Camera;
pub const Rect = engine.Rect;
pub const SpriteBatch = engine.SpriteBatch;
pub const Texture = engine.Texture;
pub const LoadedAtlas = engine.LoadedAtlas;
pub const view = engine.view;
pub const math = engine.math;
pub const strings = engine.strings;
pub const hash_map = engine.hash_map;
pub const assets = engine.assets;
pub const atlas = engine.atlas;
pub const vector = engine.vector;
pub const entity = engine.entity;
pub const tilemap = engine.tilemap;
pub const tilemap_draw = engine.tilemap_draw;
pub const animation = engine.animation;
pub const audio = engine.audio;
pub const settings = engine.settings;
pub const ui = engine.ui;
pub const log = engine.log;
pub const profile = engine.profile;
pub const scene = engine.scene;
pub const SceneHost = engine.SceneHost;
pub const SceneNavigator = engine.SceneNavigator;