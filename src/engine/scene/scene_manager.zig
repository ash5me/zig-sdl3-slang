//! Scene lifecycle: one active scene at a time, with changes applied at a safe point.
//!
//! The manager owns every scene it opens. It heap-allocates each scene, so a scene's address stays
//! fixed while the manager itself moves. Each scene is released exactly once: when the next scene
//! replaces it, or when the manager is deinitialized.
//!
//! A scene asks for a change through `Navigator.switchTo`, which `update` receives. The request is
//! recorded, not run. The host loop calls `applyPending` after its update steps and before drawing.
//! That is the safe point: the old scene is not being updated or drawn, so it can be released. A
//! later request replaces an earlier one that has not been applied yet.
//!
//! `applyPending` creates the new scene before it releases the old one. If the new scene's `init`
//! fails, the error is returned, the old scene keeps running, and the failed request is dropped.
//! Both scenes exist briefly during a switch, so a scene's `init` must not claim a resource that
//! the scene it replaces still holds.
//!
//! A scene owns what its `init` opens and releases it in `deinit`. Assets loaded through the
//! engine's asset loaders are kept until the run ends, because there is no unload yet (P1.5), so
//! an asset a scene loads stays in memory after the scene is gone.

const std = @import("std");
const scene = @import("scene.zig");

pub fn Manager(comptime Ctx: type, comptime DrawCtx: type) type {
    return struct {
        const Self = @This();

        /// Behavior of one scene type, built at compile time. The scene's storage is type-erased
        /// behind `ptr`, and each function casts it back to the scene type.
        const Vtable = struct {
            update: *const fn (ptr: *anyopaque, ctx: *Ctx, nav: *Navigator) void,
            draw: *const fn (ptr: *anyopaque, dc: *const DrawCtx) void,
            destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        };

        /// An open scene. Copying an `Instance` copies the handle, not the scene.
        pub const Instance = struct {
            ptr: *anyopaque,
            vtable: *const Vtable,
            allocator: std.mem.Allocator,

            fn update(self: Instance, ctx: *Ctx, nav: *Navigator) void {
                self.vtable.update(self.ptr, ctx, nav);
            }

            fn draw(self: Instance, dc: *const DrawCtx) void {
                self.vtable.draw(self.ptr, dc);
            }

            fn destroy(self: Instance) void {
                self.vtable.destroy(self.ptr, self.allocator);
            }
        };

        /// Opens one scene type. A pending request holds one of these.
        const Factory = *const fn (allocator: std.mem.Allocator, ctx: *Ctx) anyerror!Instance;

        /// The handle `update` receives. It records a request for the next safe point.
        pub const Navigator = struct {
            pending: ?Factory = null,

            /// Asks for a scene of type `T` to replace the active one at the next safe point.
            pub fn switchTo(self: *Navigator, comptime T: type) void {
                scene.assertScene(T);
                self.pending = &Maker(T).make;
            }
        };

        allocator: std.mem.Allocator,
        active: ?Instance = null,
        navigator: Navigator = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Releases the active scene and drops any pending request. The manager is empty afterward.
        pub fn deinit(self: *Self) void {
            if (self.active) |active| active.destroy();
            self.active = null;
            self.navigator.pending = null;
        }

        /// Asks for a scene of type `T` from host code, such as a menu handler. The switch happens
        /// at the next `applyPending`, the same as a request made from `update`.
        pub fn switchTo(self: *Self, comptime T: type) void {
            self.navigator.switchTo(T);
        }

        /// Runs the active scene's update. The scene may ask for a change through its navigator.
        pub fn update(self: *Self, ctx: *Ctx) void {
            if (self.active) |active| active.update(ctx, &self.navigator);
        }

        /// Draws the active scene. Drawing cannot request a change, so the scene stays the same for
        /// the whole draw.
        pub fn draw(self: *Self, dc: *const DrawCtx) void {
            if (self.active) |active| active.draw(dc);
        }

        /// Applies the pending request, if there is one. If the new scene's `init` fails, its error
        /// is returned, the current scene keeps running, and the failed request is dropped.
        pub fn applyPending(self: *Self, ctx: *Ctx) anyerror!void {
            const factory = self.navigator.pending orelse return;
            self.navigator.pending = null;
            const next = try factory(self.allocator, ctx);
            if (self.active) |old| old.destroy();
            self.active = next;
        }

        fn Maker(comptime T: type) type {
            return struct {
                fn make(allocator: std.mem.Allocator, ctx: *Ctx) anyerror!Instance {
                    const storage = try allocator.create(T);
                    errdefer allocator.destroy(storage);
                    storage.* = try T.init(ctx);
                    return .{ .ptr = storage, .vtable = &Erased(T).vtable, .allocator = allocator };
                }
            };
        }

        // The helpers have their own names. Inside this struct a bare `update` or `draw` would also
        // match the manager's methods of the same name, and Zig rejects that as ambiguous.
        fn Erased(comptime T: type) type {
            return struct {
                fn callUpdate(ptr: *anyopaque, ctx: *Ctx, nav: *Navigator) void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    self.update(ctx, nav);
                }

                fn callDraw(ptr: *anyopaque, dc: *const DrawCtx) void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    self.draw(dc);
                }

                fn callDestroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    self.deinit();
                    allocator.destroy(self);
                }

                const vtable: Vtable = .{ .update = callUpdate, .draw = callDraw, .destroy = callDestroy };
            };
        }
    };
}

// Tests. Each scene writes its calls into a trace in the test context, so a test can check the
// exact order of events. Each event is two characters: the scene's tag, then the event.
// `+` is init, `u` is update, `d` is draw, and `-` is deinit.

const Trace = struct {
    log: [1024]u8 = undefined,
    len: usize = 0,
    /// Scenes that have finished `init` and have not been deinitialized yet.
    live: usize = 0,

    fn note(self: *Trace, c: u8) void {
        if (self.len == self.log.len) @panic("test trace is full");
        self.log[self.len] = c;
        self.len += 1;
    }

    fn text(self: *const Trace) []const u8 {
        return self.log[0..self.len];
    }
};

const TestCtx = struct { trace: Trace = .{} };
const TestDraw = struct {};
const M = Manager(TestCtx, TestDraw);

fn mark(trace: *Trace, tag: u8, event: u8) void {
    trace.note(tag);
    trace.note(event);
}

/// Scene `A`. Its update asks for `Beta`, so the switch is still pending when update returns.
const Alpha = struct {
    trace: *Trace,

    pub fn init(ctx: *TestCtx) !Alpha {
        mark(&ctx.trace, 'A', '+');
        ctx.trace.live += 1;
        return .{ .trace = &ctx.trace };
    }

    pub fn update(self: *Alpha, ctx: *TestCtx, nav: *M.Navigator) void {
        _ = ctx;
        mark(self.trace, 'A', 'u');
        nav.switchTo(Beta);
    }

    pub fn draw(self: *Alpha, dc: *const TestDraw) void {
        _ = dc;
        mark(self.trace, 'A', 'd');
    }

    pub fn deinit(self: *Alpha) void {
        mark(self.trace, 'A', '-');
        self.trace.live -= 1;
    }
};

/// Scene `B`. It never asks for a change.
const Beta = struct {
    trace: *Trace,

    pub fn init(ctx: *TestCtx) !Beta {
        mark(&ctx.trace, 'B', '+');
        ctx.trace.live += 1;
        return .{ .trace = &ctx.trace };
    }

    pub fn update(self: *Beta, ctx: *TestCtx, nav: *M.Navigator) void {
        _ = ctx;
        _ = nav;
        mark(self.trace, 'B', 'u');
    }

    pub fn draw(self: *Beta, dc: *const TestDraw) void {
        _ = dc;
        mark(self.trace, 'B', 'd');
    }

    pub fn deinit(self: *Beta) void {
        mark(self.trace, 'B', '-');
        self.trace.live -= 1;
    }
};

/// A scene whose `init` fails. Its other methods only satisfy the scene contract, and they must
/// never run, so they write nothing into the trace.
const Broken = struct {
    field: u8 = 0,

    pub fn init(ctx: *TestCtx) !Broken {
        ctx.trace.note('F');
        return error.SceneBoom;
    }

    pub fn update(self: *Broken, ctx: *TestCtx, nav: *M.Navigator) void {
        _ = self;
        _ = ctx;
        _ = nav;
    }

    pub fn draw(self: *Broken, dc: *const TestDraw) void {
        _ = self;
        _ = dc;
    }

    pub fn deinit(self: *Broken) void {
        _ = self;
    }
};

test "lifecycle: init, update, and draw in order, with deinit once when replaced and at shutdown" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Alpha);
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    manager.draw(&TestDraw{});
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    manager.draw(&TestDraw{});
    manager.deinit();

    try std.testing.expectEqualStrings("A+AuAdB+A-BuBdB-", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "a switch requested during update waits for applyPending" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Alpha);
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    try std.testing.expectEqualStrings("A+Au", ctx.trace.text());

    try manager.applyPending(&ctx);
    try std.testing.expectEqualStrings("A+AuB+A-", ctx.trace.text());

    manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "a failed init keeps the current scene running and drops the request" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);

    manager.switchTo(Broken);
    try std.testing.expectError(error.SceneBoom, manager.applyPending(&ctx));
    try std.testing.expectEqual(@as(usize, 1), ctx.trace.live);

    // The failed request was dropped, so applying again changes nothing.
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    try std.testing.expectEqualStrings("B+FBu", ctx.trace.text());

    manager.deinit();
    try std.testing.expectEqualStrings("B+FBuB-", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "repeated switches leak nothing and keep exactly one scene live" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    var cycle: usize = 0;
    while (cycle < 50) : (cycle += 1) {
        if (cycle % 2 == 0) {
            manager.switchTo(Alpha);
        } else {
            manager.switchTo(Beta);
        }
        try manager.applyPending(&ctx);
        try std.testing.expectEqual(@as(usize, 1), ctx.trace.live);
    }

    manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "an empty manager ignores update, draw, and applyPending" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.update(&ctx);
    manager.draw(&TestDraw{});
    try manager.applyPending(&ctx);
    try std.testing.expectEqualStrings("", ctx.trace.text());

    manager.deinit();
}
