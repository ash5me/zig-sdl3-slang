//! Overlap tests for points, boxes, and circles. This is detection only: these functions say whether
//! shapes overlap and never move anything. Pure code with no SDL, no rendering, no tile map, and no
//! ECS, so it runs in tests without a window.
//!
//! Edges follow shapes.zig: a box's right and bottom edges are outside it, so touching edges do not
//! overlap. Empty shapes overlap nothing.

const std = @import("std");
const shapes = @import("shapes.zig");

const Point = shapes.Point;
const Box = shapes.Box;
const Circle = shapes.Circle;

/// A static collider: a box that queries and movement can hit. `layer` is a set of bits, and one
/// collider can belong to several layers. See queries.zig for how masks select layers.
pub const Collider = struct {
    box: Box,
    layer: u32,
};

/// True when the box has no area, or one of its values is not finite.
pub fn isEmptyBox(box: Box) bool {
    return !finite4(box.x, box.y, box.w, box.h) or box.w <= 0 or box.h <= 0;
}

/// True when the circle has no area, or its radius is not finite or not positive.
pub fn isEmptyCircle(c: Circle) bool {
    return !(std.math.isFinite(c.x) and std.math.isFinite(c.y) and std.math.isFinite(c.r)) or c.r <= 0;
}

/// True when the point lies inside the box. The left and top edges are inside, and the right and
/// bottom edges are not.
pub fn pointInBox(p: Point, box: Box) bool {
    if (isEmptyBox(box) or !(std.math.isFinite(p.x) and std.math.isFinite(p.y))) return false;
    return p.x >= box.x and p.x < box.x + box.w and p.y >= box.y and p.y < box.y + box.h;
}

/// True when two boxes share some area. Boxes that only touch along an edge or a corner do not.
pub fn boxesOverlap(a: Box, b: Box) bool {
    if (isEmptyBox(a) or isEmptyBox(b)) return false;
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// True when two circles overlap. Circles that only touch do not.
pub fn circlesOverlap(a: Circle, b: Circle) bool {
    if (isEmptyCircle(a) or isEmptyCircle(b)) return false;
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const reach = a.r + b.r;
    return dx * dx + dy * dy < reach * reach;
}

/// True when a circle and a box overlap. The box point nearest the circle's center decides it, so a
/// circle that only touches the box's edge or corner does not overlap.
pub fn circleOverlapsBox(c: Circle, box: Box) bool {
    if (isEmptyCircle(c) or isEmptyBox(box)) return false;
    const nearest_x = std.math.clamp(c.x, box.x, box.x + box.w);
    const nearest_y = std.math.clamp(c.y, box.y, box.y + box.h);
    const dx = c.x - nearest_x;
    const dy = c.y - nearest_y;
    return dx * dx + dy * dy < c.r * c.r;
}

fn finite4(a: f32, b: f32, c: f32, d: f32) bool {
    return std.math.isFinite(a) and std.math.isFinite(b) and std.math.isFinite(c) and std.math.isFinite(d);
}

const expect = std.testing.expect;

test "boxes that only touch along an edge or corner do not overlap" {
    const a = Box{ .x = 0, .y = 0, .w = 16, .h = 16 };
    try expect(!boxesOverlap(a, .{ .x = 16, .y = 0, .w = 16, .h = 16 }));
    try expect(!boxesOverlap(a, .{ .x = 0, .y = 16, .w = 16, .h = 16 }));
    try expect(!boxesOverlap(a, .{ .x = 16, .y = 16, .w = 16, .h = 16 }));
    try expect(boxesOverlap(a, .{ .x = 15.5, .y = 0, .w = 16, .h = 16 }));
}

test "boxes overlap when they share area, including one inside another" {
    const big = Box{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try expect(boxesOverlap(big, .{ .x = 40, .y = 40, .w = 5, .h = 5 }));
    try expect(!boxesOverlap(big, .{ .x = 100, .y = 0, .w = 5, .h = 5 }));
    try expect(!boxesOverlap(big, .{ .x = 200, .y = 200, .w = 5, .h = 5 }));
}

test "negative coordinates overlap the same way as positive ones" {
    try expect(boxesOverlap(.{ .x = -20, .y = -20, .w = 10, .h = 10 }, .{ .x = -15, .y = -15, .w = 10, .h = 10 }));
    try expect(!boxesOverlap(.{ .x = -20, .y = -20, .w = 10, .h = 10 }, .{ .x = -10, .y = -20, .w = 10, .h = 10 }));
}

test "empty and non-finite boxes overlap nothing" {
    const solid = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expect(!boxesOverlap(solid, .{ .x = 0, .y = 0, .w = 0, .h = 10 }));
    try expect(!boxesOverlap(solid, .{ .x = 0, .y = 0, .w = -5, .h = 10 }));
    try expect(!boxesOverlap(solid, .{ .x = std.math.nan(f32), .y = 0, .w = 10, .h = 10 }));
    try expect(!boxesOverlap(solid, .{ .x = 0, .y = 0, .w = std.math.inf(f32), .h = 10 }));
    try expect(!pointInBox(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0, .w = -1, .h = 1 }));
}

test "a point is inside a box on its left and top edges, not on its right and bottom edges" {
    const box = Box{ .x = 0, .y = 0, .w = 16, .h = 16 };
    try expect(pointInBox(.{ .x = 0, .y = 0 }, box));
    try expect(pointInBox(.{ .x = 15.9, .y = 15.9 }, box));
    try expect(!pointInBox(.{ .x = 16, .y = 8 }, box));
    try expect(!pointInBox(.{ .x = 8, .y = 16 }, box));
    try expect(!pointInBox(.{ .x = -0.1, .y = 8 }, box));
}

test "circles overlap only when their centers are closer than the sum of their radii" {
    const a = Circle{ .x = 0, .y = 0, .r = 5 };
    try expect(circlesOverlap(a, .{ .x = 9, .y = 0, .r = 5 }));
    try expect(!circlesOverlap(a, .{ .x = 10, .y = 0, .r = 5 }));
    try expect(!circlesOverlap(a, .{ .x = 0, .y = 0, .r = 0 }));
}

test "a circle overlaps a box when the box point nearest its center is inside the circle" {
    const box = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expect(circleOverlapsBox(.{ .x = 5, .y = 5, .r = 1 }, box));
    try expect(circleOverlapsBox(.{ .x = -4, .y = 5, .r = 5.5 }, box));
    try expect(!circleOverlapsBox(.{ .x = -5, .y = 5, .r = 5 }, box));
    // Near the top-left corner the nearest point is (0, 0), and its distance from (-3, -4) is exactly 5.
    try expect(!circleOverlapsBox(.{ .x = -3, .y = -4, .r = 5 }, box));
    try expect(circleOverlapsBox(.{ .x = -3, .y = -4, .r = 5.01 }, box));
}
