//! Sample game for the scene system and the entity world. It uses only the public Bairava API and
//! imports nothing from Semkootru. Space switches between the red and blue squares, and Tab opens the
//! swarm from either square. Tab in the swarm returns to the red square. Escape quits.
//!
//! Each square scene loads its texture in `init` and releases it in `deinit`. Textures loaded through
//! the asset loader are kept until the run ends (P1.5 adds unload), so each switch adds a little memory
//! that is released only when the sample exits.

const engine = @import("bairava");

/// A 4x4 white PNG beside the executable. Drawing it with a tint gives a solid square.
const white_path = "assets/sample/white.png";

const config = engine.Config{
    .title = "Bairava sample",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.1, 0.1, 0.12 },
    .settings_file = "sample_settings.txt",
};

/// Draws a square of the given tint at the center of the native view.
fn drawSquare(texture: *const engine.Texture, dc: *const engine.DrawContext, tint: [3]f32) void {
    const side: f32 = 64;
    dc.batch.drawSprite(
        texture,
        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .{ .x = (dc.view_w - side) / 2, .y = (dc.view_h - side) / 2, .w = side, .h = side },
        .{ .tint = tint },
    );
}

/// A red square. Space switches to the blue scene, and Tab opens the swarm.
const Red = struct {
    texture: engine.Texture,

    pub fn init(ctx: *engine.Context) !Red {
        return .{ .texture = try ctx.loadTexture(white_path) };
    }

    pub fn update(self: *Red, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = self;
        if (ctx.input.wasPressed(.space)) nav.switchTo(Blue);
        if (ctx.input.wasPressed(.tab)) nav.switchTo(Swarm);
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
    }

    pub fn draw(self: *Red, dc: *const engine.DrawContext) void {
        drawSquare(&self.texture, dc, .{ 1.0, 0.35, 0.35 });
    }

    pub fn deinit(self: *Red) void {
        self.texture.deinit();
    }
};

/// A blue square. Space switches back to the red scene, and Tab opens the swarm.
const Blue = struct {
    texture: engine.Texture,

    pub fn init(ctx: *engine.Context) !Blue {
        return .{ .texture = try ctx.loadTexture(white_path) };
    }

    pub fn update(self: *Blue, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        _ = self;
        if (ctx.input.wasPressed(.space)) nav.switchTo(Red);
        if (ctx.input.wasPressed(.tab)) nav.switchTo(Swarm);
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
    }

    pub fn draw(self: *Blue, dc: *const engine.DrawContext) void {
        drawSquare(&self.texture, dc, .{ 0.35, 0.55, 1.0 });
    }

    pub fn deinit(self: *Blue) void {
        self.texture.deinit();
    }
};

/// The sample's components. They belong to the sample, not the engine.
const Mote = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    age: f32,
};

const Motes = engine.entity.World(Mote, .soa);

const max_motes: usize = 300;
const mote_life: f32 = 4.0;
const mote_speed: f32 = 60.0;
const mote_side: f32 = 3.0;
const spawn_rate: f32 = 60.0;

/// Deterministic pseudo-random numbers in [0, 1), so every run looks the same.
fn nextUnit(seed: *u32) f32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return @as(f32, @floatFromInt(seed.* >> 8)) / 16777216.0;
}

/// The one system. It moves every mote, bounces it off the view edges, and despawns it when its life
/// runs out. Rows are walked from the last to the first, so each despawn moves only a row the walk has
/// already visited.
fn stepMotes(world: *Motes, dt: f32, view_w: f32, view_h: f32) void {
    var row = world.count();
    while (row > 0) {
        row -= 1;
        const handle = world.handleAt(row);
        var m = world.get(handle).?;
        m.age += dt;
        if (m.age >= mote_life) {
            _ = world.despawn(handle);
            continue;
        }
        m.x += m.vx * dt;
        m.y += m.vy * dt;
        if (m.x < 0) {
            m.x = 0;
            m.vx = -m.vx;
        }
        if (m.x > view_w - mote_side) {
            m.x = view_w - mote_side;
            m.vx = -m.vx;
        }
        if (m.y < 0) {
            m.y = 0;
            m.vy = -m.vy;
        }
        if (m.y > view_h - mote_side) {
            m.y = view_h - mote_side;
            m.vy = -m.vy;
        }
        _ = world.set(handle, m);
    }
}

/// The swarm: motes that spawn at the center, fly outward, and expire. It shows the entity world in use.
const Swarm = struct {
    texture: engine.Texture,
    motes: Motes,
    seed: u32,
    spawn_accum: f32,

    pub fn init(ctx: *engine.Context) !Swarm {
        return .{
            .texture = try ctx.loadTexture(white_path),
            .motes = Motes.init(ctx.allocators.game),
            .seed = 12345,
            .spawn_accum = 0,
        };
    }

    pub fn update(self: *Swarm, ctx: *engine.Context, nav: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.tab)) nav.switchTo(Red);
        if (ctx.input.wasPressed(.escape)) ctx.running = false;

        // Spawning happens here, outside the system's loop, so it cannot disturb the walk.
        self.spawn_accum += spawn_rate * ctx.dt;
        while (self.spawn_accum >= 1.0) : (self.spawn_accum -= 1.0) {
            if (self.motes.count() >= max_motes) break;
            const vx = (nextUnit(&self.seed) * 2 - 1) * mote_speed;
            const vy = (nextUnit(&self.seed) * 2 - 1) * mote_speed;
            const center_x = ctx.layout.view_w / 2;
            const center_y = ctx.layout.view_h / 2;
            _ = self.motes.spawn(.{ .x = center_x, .y = center_y, .vx = vx, .vy = vy, .age = 0 }) catch break;
        }

        stepMotes(&self.motes, ctx.dt, ctx.layout.view_w, ctx.layout.view_h);
    }

    pub fn draw(self: *Swarm, dc: *const engine.DrawContext) void {
        var row: usize = 0;
        while (row < self.motes.count()) : (row += 1) {
            const m = self.motes.get(self.motes.handleAt(row)).?;
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{ .x = m.x, .y = m.y, .w = mote_side, .h = mote_side },
                .{ .tint = .{ 1.0, 0.9, 0.4 } },
            );
        }
    }

    pub fn deinit(self: *Swarm) void {
        self.motes.deinit();
        self.texture.deinit();
    }
};

pub fn main() !void {
    try engine.run(engine.SceneHost(Red), config);
}
