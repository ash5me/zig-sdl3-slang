//! The entity world. Each entity is one row of components, stored in a `Vector` with the layout you
//! choose (AoS or SoA). Callers refer to entities through handles, not row numbers, because a despawn
//! moves the last row into the gap, which changes that row's index.
//!
//! Storage: the rows are dense. The first `count()` rows are all alive, with nothing between them. A
//! system reads whole fields with `world.rows.column(name)`, which works under either layout. Once an
//! entity despawns, rows are no longer in spawn order.
//!
//! Handles: a handle is a slot index plus a generation. Each slot records which row it owns, and
//! `handleAt(row)` goes the other way, from a row to its handle. Despawning bumps the slot's generation,
//! so a stale handle is rejected instead of reaching whatever entity reuses the slot.
//!
//! Structural changes. A system must follow these rules:
//! - `spawn` may grow the storage, which moves it. A column view or pointer taken before a spawn is
//!   invalid after it, so take views again after spawning.
//! - A loop over `0..count()` evaluates the count once, so entities spawned inside it are not visited
//!   by that loop.
//! - `despawn` moves the last row into the freed row. To despawn while walking the rows, walk from the
//!   last row to the first. Each despawn then moves only a row the walk has already visited, so no
//!   entity is skipped or visited twice.
//!
//! Systems are plain functions, and the caller runs them in the order it chooses. There is no scheduler
//! and no deferred command buffer. The world is optional: simple game objects can stay ordinary structs.
//! The component types belong to the game, and this module knows nothing about them.
//!
//! This module imports no SDL or logger, so `zig build test` runs its tests.

const std = @import("std");
const vector = @import("../memory/vector.zig");

pub const Layout = vector.Layout;

/// Refers to one entity. Keep the handle, not a row index, because rows move when entities despawn.
pub const Handle = struct {
    /// Index of the entity's slot in the handle table.
    index: u32,
    /// The slot's generation when the entity was spawned. A mismatch means the entity is gone.
    generation: u32,
};

/// Marks "no row" and "no slot" in the bookkeeping below.
const none: u32 = std.math.maxInt(u32);

/// One entry of the handle table. A slot either owns a row, or is free and links to the next free slot.
const Slot = struct {
    generation: u32,
    /// The row this slot owns, or `none` when the slot is free.
    row: u32,
    /// The next free slot. Only meaningful while this slot is free.
    next_free: u32,
};

/// The slot that owns a row. Entry `i` describes row `i`.
const Owner = struct {
    slot: u32,
};

const OwnerList = vector.Vector(Owner, .aos);
const SlotList = vector.Vector(Slot, .aos);

/// A world whose entities each hold one `Row` of components, stored in `layout`.
pub fn World(comptime Row: type, comptime layout: Layout) type {
    return struct {
        const Self = @This();
        pub const Rows = vector.Vector(Row, layout);

        /// The component rows. Systems read and write them through `rows.column(name)`.
        rows: Rows,
        /// The slot that owns each row. It is kept in step with `rows`, so a row that moves can be repaired.
        owners: OwnerList,
        /// The handle table, indexed by slot.
        slots: SlotList,
        /// The first free slot, or `none`. Free slots form a list through `next_free`.
        free_head: u32 = none,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .rows = Rows.init(allocator),
                .owners = OwnerList.init(allocator),
                .slots = SlotList.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.rows.deinit();
            self.owners.deinit();
            self.slots.deinit();
        }

        /// The number of live entities. They occupy rows `0..count()`.
        pub fn count(self: *const Self) usize {
            return self.rows.len();
        }

        /// True while `handle` names a live entity.
        pub fn isAlive(self: *const Self, handle: Handle) bool {
            return self.liveSlot(handle) != null;
        }

        /// Adds an entity with the given components and returns its handle.
        pub fn spawn(self: *Self, row: Row) std.mem.Allocator.Error!Handle {
            // Reserve room in all three vectors first. After this nothing can fail, so the free list and
            // the rows are only changed once the spawn is certain to finish.
            try self.rows.reserve(1);
            try self.owners.reserve(1);
            try self.slots.reserve(1);

            const slot_index = self.claimSlot();
            const row_index = self.rows.len();
            self.rows.appendAssumeCapacity(row);
            self.owners.appendAssumeCapacity(.{ .slot = slot_index });

            var slot = self.slots.get(slot_index);
            slot.row = @intCast(row_index);
            self.slots.set(slot_index, slot);
            return .{ .index = slot_index, .generation = slot.generation };
        }

        /// Removes the entity. Returns false when the handle is already stale, so despawning twice is safe.
        /// The last row moves into the freed row, and its owner is updated to match.
        pub fn despawn(self: *Self, handle: Handle) bool {
            const slot_index = self.liveSlot(handle) orelse return false;
            var slot = self.slots.get(slot_index);
            const row_index: usize = slot.row;
            const last = self.rows.len() - 1;

            self.rows.swapRemove(row_index);
            self.owners.swapRemove(row_index);
            if (row_index != last) {
                // The row that used to be last now sits at row_index, so its owner must point there.
                const moved = self.owners.get(row_index).slot;
                var moved_slot = self.slots.get(moved);
                moved_slot.row = @intCast(row_index);
                self.slots.set(moved, moved_slot);
            }

            // Retire the slot. A new generation makes every handle to it stale, and the slot joins the free list.
            slot.row = none;
            slot.generation +%= 1;
            slot.next_free = self.free_head;
            self.slots.set(slot_index, slot);
            self.free_head = slot_index;
            return true;
        }

        /// The entity's components, or null if the handle is stale.
        pub fn get(self: *const Self, handle: Handle) ?Row {
            const slot_index = self.liveSlot(handle) orelse return null;
            const row_index: usize = self.slots.get(slot_index).row;
            return self.rows.get(row_index);
        }

        /// Overwrites the entity's components. Returns false, and changes nothing, when the handle is stale.
        pub fn set(self: *Self, handle: Handle, row: Row) bool {
            const slot_index = self.liveSlot(handle) orelse return false;
            const row_index: usize = self.slots.get(slot_index).row;
            self.rows.set(row_index, row);
            return true;
        }

        /// The handle of the entity that owns row `row_index`. A system that finds an entity by its row
        /// uses this to get a handle it can despawn or set. `row_index` must be below `count()`.
        pub fn handleAt(self: *const Self, row_index: usize) Handle {
            const slot_index = self.owners.get(row_index).slot;
            return .{ .index = slot_index, .generation = self.slots.get(slot_index).generation };
        }

        /// Takes a free slot from the free list, or appends a new one. Callers must reserve room first.
        fn claimSlot(self: *Self) u32 {
            if (self.free_head != none) {
                const index = self.free_head;
                self.free_head = self.slots.get(index).next_free;
                return index;
            }
            self.slots.appendAssumeCapacity(.{ .generation = 0, .row = none, .next_free = none });
            return @intCast(self.slots.len() - 1);
        }

        /// The slot index of a live entity, or null when the handle is stale or was never issued.
        fn liveSlot(self: *const Self, handle: Handle) ?u32 {
            if (handle.index >= self.slots.len()) return null;
            const slot = self.slots.get(handle.index);
            if (slot.generation != handle.generation or slot.row == none) return null;
            return handle.index;
        }
    };
}

/// Components for the tests. The fields differ in size and alignment, so padding is exercised too.
const Body = struct {
    alive: u8,
    x: f32,
    vx: f32,
    id: u64,
};

fn body(id: u64, x: f32, vx: f32) Body {
    return .{ .alive = 1, .x = x, .vx = vx, .id = id };
}

fn expectBody(expected: Body, actual: Body) !void {
    const testing = std.testing;
    try testing.expectEqual(expected.alive, actual.alive);
    try testing.expectEqual(expected.x, actual.x);
    try testing.expectEqual(expected.vx, actual.vx);
    try testing.expectEqual(expected.id, actual.id);
}

fn checkWorld(comptime layout: Layout) !void {
    const testing = std.testing;
    var world = World(Body, layout).init(testing.allocator);
    defer world.deinit();

    const a = try world.spawn(body(1, 0, 2));
    const b = try world.spawn(body(2, 10, 0));
    const c = try world.spawn(body(3, 20, -1));
    try testing.expectEqual(@as(usize, 3), world.count());
    try expectBody(body(2, 10, 0), world.get(b).?);

    // Despawning the first entity moves the last row (c) into its place. Every handle keeps its own data.
    try testing.expect(world.despawn(a));
    try testing.expectEqual(@as(usize, 2), world.count());
    try testing.expect(world.get(a) == null);
    try expectBody(body(2, 10, 0), world.get(b).?);
    try expectBody(body(3, 20, -1), world.get(c).?);

    // A second despawn of the same handle does nothing.
    try testing.expect(!world.despawn(a));

    // The freed slot is reused with a new generation. The old handle stays dead.
    const d = try world.spawn(body(4, 30, 0));
    try testing.expectEqual(a.index, d.index);
    try testing.expect(d.generation != a.generation);
    try testing.expect(world.get(a) == null);
    try testing.expect(!world.set(a, body(99, 99, 99)));
    try expectBody(body(4, 30, 0), world.get(d).?);

    // Writing through a handle changes the row it owns. c is the first row now, so despawning it moves
    // the last row (d) into its place. b and d keep their data.
    try testing.expect(world.set(c, body(33, 21, -1)));
    try expectBody(body(33, 21, -1), world.get(c).?);
    try testing.expect(world.despawn(c));
    try expectBody(body(2, 10, 0), world.get(b).?);
    try expectBody(body(4, 30, 0), world.get(d).?);

    // Despawning the row at the end needs no move.
    try testing.expect(world.despawn(b));
    try testing.expectEqual(@as(usize, 1), world.count());
    try expectBody(body(4, 30, 0), world.get(d).?);
    try testing.expect(world.isAlive(d));
    try testing.expect(!world.isAlive(b));
}

test "a world keeps every handle on its own row under both layouts" {
    inline for (.{ Layout.aos, Layout.soa }) |layout| {
        try checkWorld(layout);
    }
}

/// A system that advances every body by its velocity. It reads whole columns, so it runs the same way
/// under either layout.
fn advance(world: anytype, dt: f32) void {
    const xs = world.rows.column("x");
    const vs = world.rows.column("vx");
    for (0..world.count()) |i| {
        xs.at(i).* += vs.at(i).* * dt;
    }
}

test "a system that reads columns updates each entity under both layouts" {
    inline for (.{ Layout.aos, Layout.soa }) |layout| {
        var world = World(Body, layout).init(std.testing.allocator);
        defer world.deinit();

        const first = try world.spawn(body(1, 0, 2));
        const second = try world.spawn(body(2, 5, -1));
        advance(&world, 0.5);
        try expectBody(body(1, 1, 2), world.get(first).?);
        try expectBody(body(2, 4.5, -1), world.get(second).?);
    }
}

test "handleAt names the entity that owns each row, and the handle still works after rows move" {
    inline for (.{ Layout.aos, Layout.soa }) |layout| {
        var world = World(Body, layout).init(std.testing.allocator);
        defer world.deinit();

        const first = try world.spawn(body(1, 0, 0));
        _ = try world.spawn(body(2, 0, 0));
        _ = try world.spawn(body(3, 0, 0));
        // Despawning the first row moves the last row (id 3) into its place.
        try std.testing.expect(world.despawn(first));

        var row: usize = 0;
        while (row < world.count()) : (row += 1) {
            const handle = world.handleAt(row);
            try std.testing.expect(world.isAlive(handle));
            try std.testing.expectEqual(world.rows.get(row).id, world.get(handle).?.id);
        }
    }
}

test "walking rows from last to first despawns every match without skipping any" {
    inline for (.{ Layout.aos, Layout.soa }) |layout| {
        var world = World(Body, layout).init(std.testing.allocator);
        defer world.deinit();

        var id: u64 = 0;
        while (id < 10) : (id += 1) {
            _ = try world.spawn(body(id, 0, 0));
        }

        var row = world.count();
        while (row > 0) {
            row -= 1;
            const handle = world.handleAt(row);
            if (world.get(handle).?.id % 2 == 1) _ = world.despawn(handle);
        }

        try std.testing.expectEqual(@as(usize, 5), world.count());
        var sum: u64 = 0;
        var k: usize = 0;
        while (k < world.count()) : (k += 1) {
            const survivor = world.rows.get(k);
            try std.testing.expect(survivor.id % 2 == 0);
            sum += survivor.id;
        }
        // Every even id survives exactly once: 0 + 2 + 4 + 6 + 8.
        try std.testing.expectEqual(@as(u64, 20), sum);
    }
}

test "a spawn that runs out of memory leaves the world and its handles intact" {
    inline for (.{ Layout.aos, Layout.soa }) |layout| {
        var buffer: [2048]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        var world = World(Body, layout).init(fixed.allocator());
        defer world.deinit();

        var handles: [256]Handle = undefined;
        var spawned: usize = 0;
        while (true) {
            const handle = world.spawn(body(@intCast(spawned), @floatFromInt(spawned), 0)) catch |err| {
                try std.testing.expect(err == error.OutOfMemory);
                break;
            };
            handles[spawned] = handle;
            spawned += 1;
        }

        // The failed spawn added no row, and every handle that did succeed still names its own data.
        try std.testing.expect(spawned > 0);
        try std.testing.expectEqual(spawned, world.count());
        for (handles[0..spawned], 0..) |handle, n| {
            try expectBody(body(@intCast(n), @floatFromInt(n), 0), world.get(handle).?);
        }
        for (handles[0..spawned]) |handle| {
            try std.testing.expect(world.despawn(handle));
        }
        try std.testing.expectEqual(@as(usize, 0), world.count());
    }
}
