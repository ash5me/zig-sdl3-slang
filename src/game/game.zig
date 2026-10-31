//! Gameplay: the level, the player, the demo panel, and how actions drive them. The engine calls
//! into this file through `init`, `update`, `draw`, and `deinit`, and never looks inside it. Game
//! code imports only the named `bairava` module, so everything the game needs from the platform goes through
//! the engine's `Context`.

const std = @import("std");

const engine = @import("bairava");
const config = @import("config.zig");
const controls = @import("controls.zig");
const Level = @import("level.zig").Level;
const Player = @import("player.zig").Player;
const save_store = @import("save.zig");

const log = engine.log.scoped("game");

/// Draw order of the panel. Sprites sort by z, so this places the panel above the world and the player.
const ui_z: i32 = 1000;

pub const Game = struct {
    level: Level,
    player: Player,
    /// One texture that holds every sprite. Packing them at build time means the whole world and
    /// the player sample the same texture, so they can share a draw call.
    atlas: engine.LoadedAtlas,
    /// The atlas regions of the sprites this game draws.
    tile: engine.atlas.Region,
    warrior: engine.atlas.Region,
    /// Immediate-mode UI for the demo panel. It owns its font and its widget state.
    ui: engine.ui.Ui,
    /// Demo panel state: how often the button was clicked, and the slider value.
    clicks: u32,
    volume: f32,
    audio: *engine.audio.Audio,
    ambient_sound: ?engine.audio.Sound,
    ambient_voice: ?engine.audio.Handle,
    ambient_attempted: bool,
    /// Key bindings from the settings file, with the defaults for anything it leaves out.
    bindings: controls.Bindings,

    pub fn init(ctx: *engine.Context) engine.AssetError!Game {
        const zone = engine.profile.zoneNamed(@src(), "game init");
        defer zone.End();
        var atlas = ctx.loadAtlas(config.atlas_image_path, config.atlas_index_path) catch |err| {
            log.err("required atlas '{s}'/ '{s}' failed to load: {s}", .{ config.atlas_image_path, config.atlas_index_path, @errorName(err) });
            return err;
        };
        errdefer atlas.deinit();
        log.info("atlas {d}x{d} with {d} sprites", .{ atlas.texture.width, atlas.texture.height, atlas.index.len });

        const tile = atlas.region("tile");
        const warrior = atlas.region("warrior");
        var level = Level.load(ctx, config.level_path) catch |err| {
            log.err("required level '{s}' failed to load: {s}", .{ config.level_path, @errorName(err) });
            return err;
        };
        errdefer level.deinit();
        checkTileset(&level, tile);

        const spawn = level.map.spawn;
        const player = Player.standingOn(spawn.col, spawn.row);
        log.info("map {d}x{d} tiles, player starts on tile ({d}, {d})", .{ level.map.cols, level.map.rows, spawn.col, spawn.row });

        const ui_font = ctx.loadFont(config.ui_font_path, config.ui_font_px) catch |err| {
            log.err("required UI font '{s}' failed to load: {s}", .{ config.ui_font_path, @errorName(err) });
            return err;
        };
        const ui = engine.ui.Ui.init(ctx.allocators.game, ui_font);
        const bindings = controls.Bindings.load(ctx.settings_text);
        const ambient_sound: ?engine.audio.Sound = ctx.loadSound(config.ambient_sound_path) catch |err| blk: {
            if (err != error.NoDevice) log.warn("ambient sound could not be loaded: {s}", .{@errorName(err)});
            break :blk null;
        };

        var game: Game = .{
            .level = level,
            .player = player,
            .atlas = atlas,
            .tile = tile,
            .warrior = warrior,
            .ui = ui,
            .clicks = 0,
            .volume = 0.5,
            .audio = ctx.audio,
            .ambient_sound = ambient_sound,
            .ambient_voice = null,
            .ambient_attempted = false,
            .bindings = bindings,
        };
        game.loadSave(ctx);
        return game;
    }

    pub fn deinit(self: *Game) void {
        if (self.ambient_voice) |voice| self.audio.stop(voice);
        if (self.ambient_sound) |*sound| sound.deinit();
        self.level.deinit();
        self.atlas.deinit();
        self.ui.deinit();
    }

    /// Runs at the fixed update rate. `ctx.dt` is the length of the step. `nav` asks for a change of
    /// scene. This game is one scene, so it never asks.
    pub fn update(self: *Game, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = nav;
        self.startAmbient();
        const input = ctx.input;
        if (self.bindings.pressed(input, .quit)) {
            log.info("quit action pressed", .{});
            ctx.running = false;
        }
        if (self.bindings.pressed(input, .save_game)) self.saveGame(ctx);
        if (self.bindings.pressed(input, .load_game)) self.loadSave(ctx);
        if (self.bindings.pressed(input, .toggle_scale)) {
            ctx.scale_mode = switch (ctx.scale_mode) {
                .fit => .integer,
                .integer => .fit,
            };
        }
        if (self.bindings.pressed(input, .zoom_in)) ctx.zoomBy(config.zoom_step);
        if (self.bindings.pressed(input, .zoom_out)) ctx.zoomBy(1.0 / config.zoom_step);
        if (self.bindings.pressed(input, .zoom_reset)) ctx.resetZoom();

        // Each movement action contributes one unit on its axis.
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (self.bindings.held(input, .move_left)) dx -= 1;
        if (self.bindings.held(input, .move_right)) dx += 1;
        if (self.bindings.held(input, .move_up)) dy -= 1;
        if (self.bindings.held(input, .move_down)) dy += 1;

        self.player.update(dx, dy, ctx.dt, &self.level.map);
        self.updateUi(ctx);
    }

    fn startAmbient(self: *Game) void {
        if (self.ambient_attempted) return;
        self.ambient_attempted = true;
        if (self.ambient_sound) |*sound| {
            self.ambient_voice = self.audio.play(sound, .{ .loop = true }) catch |err| {
                log.warn("ambient sound could not start: {s}", .{@errorName(err)});
                return;
            };
        }
    }

    fn saveGame(self: *const Game, ctx: *const engine.Context) void {
        const state = save_store.State{
            .player_x = self.player.x,
            .player_y = self.player.y,
            .facing = self.player.facing,
            .moving = self.player.anim.clip.frame_count > 1,
            .animation_time = self.player.anim.time,
            .clicks = self.clicks,
            .volume = self.volume,
            .scale_mode = if (ctx.scale_mode == .integer) .integer else .fit,
            .zoom_target = ctx.zoom_target,
        };
        const json = save_store.serialize(ctx.allocators.frame, state) catch |err| {
            log.err("save serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.allocators.frame.free(json);

        // writeFile logs the reason when the write fails, so there is nothing more to say here.
        ctx.writeFile(config.save_file_name, json) catch return;
        log.info("saved game to {s}", .{config.save_file_name});
    }

    fn loadSave(self: *Game, ctx: *engine.Context) void {
        const text = ctx.readFile(ctx.allocators.frame, config.save_file_name) catch |err| {
            if (err != error.FileNotFound) log.warn("save '{s}' could not be read: {s}", .{ config.save_file_name, @errorName(err) });
            return;
        };
        defer ctx.allocators.frame.free(text);

        const defaults = save_store.State{
            .player_x = self.player.x,
            .player_y = self.player.y,
            .facing = self.player.facing,
            .clicks = self.clicks,
            .volume = self.volume,
            .scale_mode = if (ctx.scale_mode == .integer) .integer else .fit,
            .zoom_target = ctx.zoom_target,
        };
        const state = save_store.deserialize(ctx.allocators.frame, text, defaults) catch |err| {
            log.warn("save '{s}' was ignored: {s}", .{ config.save_file_name, @errorName(err) });
            return;
        };
        if (!state.level_matches) {
            log.warn("save '{s}' belongs to a different level; it was ignored", .{config.save_file_name});
            return;
        }

        if (positionIsValid(state.player_x, state.player_y, &self.level)) {
            self.player.restore(state.player_x, state.player_y, state.facing, state.moving, state.animation_time);
        } else {
            log.warn("saved player position is outside the current level; using the level spawn", .{});
        }
        self.clicks = state.clicks;
        self.volume = state.volume;
        ctx.scale_mode = if (state.scale_mode == .integer) .integer else .fit;
        ctx.zoom_target = std.math.clamp(state.zoom_target, config.zoom_min, config.zoom_max);
        log.info("loaded game from {s}", .{config.save_file_name});
    }

    /// Runs once per frame. `dc.alpha` blends the player between the last two updates. The camera
    /// eases toward the player using the frame time, so its speed doesn't depend on the frame rate.
    pub fn draw(self: *Game, dc: *const engine.DrawContext) void {
        const center = self.player.drawCenter(dc.alpha);
        dc.cam.world_w = self.level.widthPx();
        dc.cam.world_h = self.level.heightPx();
        dc.cam.followSmooth(center.x, center.y, dc.dt, config.camera_rate);

        // Draw order: ground, decoration, the player, and then foreground, which can cover the player.
        const tiles = &self.atlas.texture;
        const map = &self.level.map;
        engine.tilemap_draw.drawLayer(map, dc.batch, tiles, self.tile, dc.cam, .ground);
        engine.tilemap_draw.drawLayer(map, dc.batch, tiles, self.tile, dc.cam, .decoration);
        self.player.draw(dc.batch, tiles, self.warrior, dc.cam, dc.alpha);
        engine.tilemap_draw.drawLayer(map, dc.batch, tiles, self.tile, dc.cam, .foreground);

        // The panel goes last. Its quads were built in the update step, so this only queues them.
        self.ui.queue(dc.batch, ui_z);
    }

    /// Builds the demo panel for this frame. It runs in the update step, so each press and release
    /// reaches the widgets exactly once.
    fn updateUi(self: *Game, ctx: *engine.Context) void {
        const ui = &self.ui;
        // The panel sits in the top-left corner of the view, 120 view pixels wide.
        ui.begin(ctx.input, ctx.layout, 4, 4, 120);
        ui.label("Semkootru");
        ui.label("F5 save  F9 load");
        if (ui.button("Click me##go")) self.clicks += 1;

        var clicks_buf: [32]u8 = undefined;
        ui.label(std.fmt.bufPrint(&clicks_buf, "Clicks: {d}", .{self.clicks}) catch
            std.debug.panic("click label does not fit its buffer", .{}));
        _ = ui.slider("Volume", &self.volume, 0, 1);
        var level_buf: [32]u8 = undefined;
        ui.label(std.fmt.bufPrint(&level_buf, "Level: {d:.2}", .{self.volume}) catch
            std.debug.panic("level label does not fit its buffer", .{}));
        self.audio.setMasterGain(self.volume);
        ui.end();
    }
};

/// True when a player whose top-left corner is at (x, y) fits in the level without touching a solid
/// tile. The bounds check uses the whole sprite, and the collision check uses the feet.
fn positionIsValid(x: f32, y: f32, level: *const Level) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or y < 0 or
        x + Player.sprite_w > level.widthPx() or y + Player.sprite_h > level.heightPx()) return false;
    return !level.map.boxOverlapsSolid(Player.feetAt(x, y));
}

/// Every tile ID in the map must name a tile in the tile sprite. Otherwise the map would draw blank
/// or wrong tiles. Panics with the offending ID so the map or the sprite can be fixed.
fn checkTileset(level: *const Level, tileset: engine.atlas.Region) void {
    const count = tileset.cellCount(engine.tilemap.tile_size);
    const largest = level.map.largestId();
    if (largest >= count) {
        std.debug.panic("the map uses tile ID {d}, but the tile sprite holds only {d} tiles", .{ largest, count });
    }
}
