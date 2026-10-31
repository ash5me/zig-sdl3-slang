//! Shapes in pixels, shared by movement and collision. Pure code with no SDL, so tests need no window.
//!
//! Units and edges: positions and sizes are native pixels, and y grows downward. A `Box` covers the
//! range [x, x + w) by [y, y + h), so two boxes that only share an edge do not overlap. A `Circle`
//! covers every point closer than `r` to its center.
//!
//! Empty shapes: a box with a zero or negative width or height, or with a value that is not finite,
//! is empty. A circle whose radius is not finite or not positive is empty. Empty shapes overlap
//! nothing, and movement never stops against them.
//!
//! Tolerance: none. Comparisons are exact f32 comparisons, and a move that ends flush against an edge
//! lands on that edge exactly.

/// A point in pixels.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// A rectangle in pixels, with its top-left corner at (x, y).
pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// A circle in pixels, centered on (x, y).
pub const Circle = struct {
    x: f32,
    y: f32,
    r: f32,
};
