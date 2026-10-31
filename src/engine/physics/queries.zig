//! Queries and movement against a list of static colliders. Each query scans the slice in order, so
//! the scene's list of colliders is the broad phase. A spatial index can replace the scan later, once
//! a profile shows the scan costs too much.
//!
//! Detection and response are separate. `firstOverlap` and `anyOverlap` only report. `moveBox` reports
//! where a box ends up, and it never changes a collider.
//!
//! Layers: a query's `mask` is a set of bits. A collider is hit when its layer and the mask share a
//! bit. A collider with layer 0 is hit by no mask.
//!
//! Movement resolves one axis at a time, the way `TileMap.moveBox` does: X first, then Y from the X
//! position the box ended at. Only colliders ahead of the box on the axis of motion can stop it, and
//! the nearest one stops it flush, so the box slides along walls. A box that already overlaps a
//! collider can move out of it. A non-finite delta leaves that axis where it is, and an empty box
//! moves freely. There is no swept test, so a step longer than a collider can pass through it: keep
//! steps shorter than the thinnest collider.

const std = @import("std");
const shapes = @import("shapes.zig");
const collision = @import("collision.zig");

const Point = shapes.Point;
const Box = shapes.Box;
pub const Collider = collision.Collider;

/// A mask with every bit set, so it hits any collider with a nonzero layer.
pub const all_layers: u32 = std.math.maxInt(u32);

fn hits(c: Collider, mask: u32) bool {
    return c.layer & mask != 0;
}

/// True when the ranges [a, a + a_len) and [b, b + b_len) share some length.
fn rangesOverlap(a: f32, a_len: f32, b: f32, b_len: f32) bool {
    return a < b + b_len and b < a + a_len;
}

/// True when some collider that the mask hits overlaps `box`.
pub fn anyOverlap(colliders: []const Collider, box: Box, mask: u32) bool {
    return firstOverlap(colliders, box, mask) != null;
}

/// The index of the first collider, in slice order, that the mask hits and that overlaps `box`.
pub fn firstOverlap(colliders: []const Collider, box: Box, mask: u32) ?usize {
    for (colliders, 0..) |c, i| {
        if (hits(c, mask) and collision.boxesOverlap(c.box, box)) return i;
    }
    return null;
}

/// Moves `box` by (dx, dy) and returns its new top-left corner. Only colliders the mask hits can stop it.
pub fn moveBox(colliders: []const Collider, box: Box, dx: f32, dy: f32, mask: u32) Point {
    const x = slideX(colliders, box, dx, mask);
    const y = slideY(colliders, .{ .x = x, .y = box.y, .w = box.w, .h = box.h }, dy, mask);
    return .{ .x = x, .y = y };
}

/// The X position after moving `box` by `dx`, stopped flush against the nearest blocker ahead.
fn slideX(colliders: []const Collider, box: Box, dx: f32, mask: u32) f32 {
    if (!std.math.isFinite(dx) or dx == 0) return box.x;
    const target = box.x + dx;
    if (collision.isEmptyBox(box)) return target;
    var result = target;
    for (colliders) |c| {
        if (!hits(c, mask) or collision.isEmptyBox(c.box)) continue;
        if (!rangesOverlap(c.box.y, c.box.h, box.y, box.h)) continue;
        if (dx > 0) {
            // Ahead of the box, and starting before the box's new right edge. Touching counts as ahead.
            if (c.box.x >= box.x + box.w and c.box.x < target + box.w) {
                result = @min(result, c.box.x - box.w);
            }
        } else {
            // Behind the box, and ending after the box's new left edge.
            if (c.box.x + c.box.w <= box.x and c.box.x + c.box.w > target) {
                result = @max(result, c.box.x + c.box.w);
            }
        }
    }
    return result;
}

/// The Y position after moving `box` by `dy`, stopped flush against the nearest blocker ahead.
fn slideY(colliders: []const Collider, box: Box, dy: f32, mask: u32) f32 {
    if (!std.math.isFinite(dy) or dy == 0) return box.y;
    const target = box.y + dy;
    if (collision.isEmptyBox(box)) return target;
    var result = target;
    for (colliders) |c| {
        if (!hits(c, mask) or collision.isEmptyBox(c.box)) continue;
        if (!rangesOverlap(c.box.x, c.box.w, box.x, box.w)) continue;
        if (dy > 0) {
            if (c.box.y >= box.y + box.h and c.box.y < target + box.h) {
                result = @min(result, c.box.y - box.h);
            }
        } else {
            if (c.box.y + c.box.h <= box.y and c.box.y + c.box.h > target) {
                result = @max(result, c.box.y + c.box.h);
            }
        }
    }
    return result;
}

const expectEqual = std.testing.expectEqual;

test "a query hits only colliders whose layer shares a bit with the mask" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .layer = 0b01 },
        .{ .box = .{ .x = 20, .y = 0, .w = 10, .h = 10 }, .layer = 0b10 },
    };
    const probe = Box{ .x = 0, .y = 0, .w = 30, .h = 10 };
    try expectEqual(@as(?usize, 0), firstOverlap(&walls, probe, 0b01));
    try expectEqual(@as(?usize, 1), firstOverlap(&walls, probe, 0b10));
    try expectEqual(@as(?usize, 0), firstOverlap(&walls, probe, 0b11));
    try expectEqual(@as(?usize, null), firstOverlap(&walls, probe, 0b100));
}

test "firstOverlap reports the first hit in slice order, and nothing for an empty list" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
        .{ .box = .{ .x = 5, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
    };
    const probe = Box{ .x = 6, .y = 0, .w = 2, .h = 2 };
    try expectEqual(@as(?usize, 0), firstOverlap(&walls, probe, all_layers));
    const none = [_]Collider{};
    try expectEqual(@as(?usize, null), firstOverlap(&none, probe, all_layers));
    try expectEqual(false, anyOverlap(&none, probe, all_layers));
}

test "moveBox stops flush against the nearest wall on each side" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 100, .y = 0, .w = 10, .h = 100 }, .layer = 1 },
        .{ .box = .{ .x = -10, .y = 0, .w = 10, .h = 100 }, .layer = 1 },
        .{ .box = .{ .x = 0, .y = 100, .w = 100, .h = 10 }, .layer = 1 },
        .{ .box = .{ .x = 0, .y = -10, .w = 100, .h = 10 }, .layer = 1 },
    };
    const b = Box{ .x = 40, .y = 40, .w = 20, .h = 20 };
    const right = moveBox(&walls, b, 200, 0, all_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 80), right.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 40), right.y, 1e-4);
    const left = moveBox(&walls, b, -200, 0, all_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 0), left.x, 1e-4);
    const down = moveBox(&walls, b, 0, 200, all_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 80), down.y, 1e-4);
    const up = moveBox(&walls, b, 0, -200, all_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 0), up.y, 1e-4);
}

test "the nearest collider stops a move no matter what order the list is in" {
    const near = Collider{ .box = .{ .x = 50, .y = 0, .w = 10, .h = 10 }, .layer = 1 };
    const far = Collider{ .box = .{ .x = 80, .y = 0, .w = 10, .h = 10 }, .layer = 1 };
    const forward = [_]Collider{ far, near };
    const backward = [_]Collider{ near, far };
    const b = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expectEqual(@as(f32, 40), moveBox(&forward, b, 100, 0, all_layers).x);
    try expectEqual(@as(f32, 40), moveBox(&backward, b, 100, 0, all_layers).x);
}

test "a box already overlapping a collider can move out of it" {
    const wall = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 20, .h = 20 }, .layer = 1 },
    };
    const inside = Box{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try std.testing.expectApproxEqAbs(@as(f32, -5), moveBox(&wall, inside, -10, 0, all_layers).x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 15), moveBox(&wall, inside, 10, 0, all_layers).x, 1e-4);
}

test "a collider only stops a box when the mask hits its layer" {
    const wall = [_]Collider{
        .{ .box = .{ .x = 50, .y = 0, .w = 10, .h = 10 }, .layer = 0b10 },
    };
    const b = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expectEqual(@as(f32, 100), moveBox(&wall, b, 100, 0, 0b01).x);
    try expectEqual(@as(f32, 40), moveBox(&wall, b, 100, 0, 0b10).x);
}

test "a non-finite move leaves its axis alone, and an empty box moves freely" {
    const wall = [_]Collider{
        .{ .box = .{ .x = 50, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
    };
    const b = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const stuck = moveBox(&wall, b, std.math.nan(f32), 0, all_layers);
    try expectEqual(@as(f32, 0), stuck.x);
    try expectEqual(@as(f32, 0), stuck.y);
    const empty = Box{ .x = 0, .y = 0, .w = 0, .h = 10 };
    try expectEqual(@as(f32, 100), moveBox(&wall, empty, 100, 0, all_layers).x);
}

test "identical inputs give identical results" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 30, .y = 30, .w = 10, .h = 10 }, .layer = 1 },
    };
    const b = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const first = moveBox(&walls, b, 13.25, -4.5, all_layers);
    const second = moveBox(&walls, b, 13.25, -4.5, all_layers);
    try expectEqual(first.x, second.x);
    try expectEqual(first.y, second.y);
}
