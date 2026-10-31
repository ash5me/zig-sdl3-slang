//! Runs scenes as a game. `engine.SceneHost(Root)` has the four methods `engine.run` expects, so a
//! game is `engine.run(engine.SceneHost(FirstScene), config)`.
//!
//! `init` opens `Root` as the first scene, and fails if its `init` fails. Each update step runs the
//! active scene's update, then applies the switch it requested, if any. A switch therefore takes
//! effect after the scene that asked for it has returned, and before the next scene is updated or
//! drawn. A switch whose `init` fails is logged, and the current scene keeps running.

const std = @import("std");
const logging = @import("../logging/log.zig");
const manager = @import("scene_manager.zig");

const elog = logging.scoped("scene");

pub fn Host(comptime Ctx: type, comptime DrawCtx: type, comptime Root: type) type {
    return struct {
        const Self = @This();
        const Mgr = manager.Manager(Ctx, DrawCtx);

        scenes: Mgr,

        pub fn init(ctx: *Ctx) !Self {
            var self = Self{ .scenes = Mgr.init(ctx.allocators.game) };
            errdefer self.scenes.deinit();
            self.scenes.switchTo(Root);
            try self.scenes.applyPending(ctx);
            return self;
        }

        pub fn update(self: *Self, ctx: *Ctx) void {
            self.scenes.update(ctx);
            self.scenes.applyPending(ctx) catch |err| {
                elog.err("scene switch failed: {s}; the current scene keeps running", .{@errorName(err)});
            };
        }

        pub fn draw(self: *Self, dc: *const DrawCtx) void {
            self.scenes.draw(dc);
        }

        pub fn deinit(self: *Self) void {
            self.scenes.deinit();
        }
    };
}

const TestDraw = struct {};

/// Records the scenes' calls as two-character events, and carries the request the root reads.
const TestCtx = struct {
    allocators: struct { game: std.mem.Allocator },
    log: [64]u8 = undefined,
    len: usize = 0,
    want_next: bool = false,

    fn note(self: *TestCtx, tag: u8, event: u8) void {
        if (self.len + 2 > self.log.len) @panic("test trace is full");
        self.log[self.len] = tag;
        self.log[self.len + 1] = event;
        self.len += 2;
    }

    fn text(self: *const TestCtx) []const u8 {
        return self.log[0..self.len];
    }
};

const Nav = manager.Manager(TestCtx, TestDraw).Navigator;

/// The root scene. Its update asks for `NextScene` when `want_next` is set.
const RootScene = struct {
    ctx: *TestCtx,

    pub fn init(ctx: *TestCtx) !RootScene {
        ctx.note('R', '+');
        return .{ .ctx = ctx };
    }

    pub fn update(self: *RootScene, ctx: *TestCtx, nav: *Nav) void {
        _ = self;
        ctx.note('R', 'u');
        if (ctx.want_next) nav.switchTo(NextScene);
    }

    pub fn draw(self: *RootScene, dc: *const TestDraw) void {
        _ = dc;
        self.ctx.note('R', 'd');
    }

    pub fn deinit(self: *RootScene) void {
        self.ctx.note('R', '-');
    }
};

const NextScene = struct {
    ctx: *TestCtx,

    pub fn init(ctx: *TestCtx) !NextScene {
        ctx.note('N', '+');
        return .{ .ctx = ctx };
    }

    pub fn update(self: *NextScene, ctx: *TestCtx, nav: *Nav) void {
        _ = self;
        _ = nav;
        ctx.note('N', 'u');
    }

    pub fn draw(self: *NextScene, dc: *const TestDraw) void {
        _ = dc;
        self.ctx.note('N', 'd');
    }

    pub fn deinit(self: *NextScene) void {
        self.ctx.note('N', '-');
    }
};

/// A root whose `init` fails. Its other methods exist only to satisfy the scene contract.
const BrokenScene = struct {
    field: u8 = 0,

    pub fn init(ctx: *TestCtx) !BrokenScene {
        _ = ctx;
        return error.RootBoom;
    }

    pub fn update(self: *BrokenScene, ctx: *TestCtx, nav: *Nav) void {
        _ = self;
        _ = ctx;
        _ = nav;
    }

    pub fn draw(self: *BrokenScene, dc: *const TestDraw) void {
        _ = self;
        _ = dc;
    }

    pub fn deinit(self: *BrokenScene) void {
        _ = self;
    }
};

test "the host opens the root, applies a switch right after the update that asked for it, and releases the last scene at deinit" {
    var ctx = TestCtx{ .allocators = .{ .game = std.testing.allocator } };
    var host = try Host(TestCtx, TestDraw, RootScene).init(&ctx);
    try std.testing.expectEqualStrings("R+", ctx.text());

    ctx.want_next = true;
    host.update(&ctx);
    try std.testing.expectEqualStrings("R+RuN+R-", ctx.text());

    host.draw(&TestDraw{});
    host.deinit();
    try std.testing.expectEqualStrings("R+RuN+R-NdN-", ctx.text());
}

test "a root whose init fails makes the host init fail, with nothing left open" {
    var ctx = TestCtx{ .allocators = .{ .game = std.testing.allocator } };
    try std.testing.expectError(error.RootBoom, Host(TestCtx, TestDraw, BrokenScene).init(&ctx));
    try std.testing.expectEqualStrings("", ctx.text());
}
