//! Value types the renderer and its SDL GPU backend share. Nothing in this file names an SDL type, so
//! engine code can use these values without importing the backend.

/// An RGBA color, each channel from 0 to 1. Clear colors use it.
pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

/// Vertex layout for sprite quads. Positions are in normalized device coordinates. Color is RGBA:
/// the tint in RGB, and the sprite's alpha in A.
pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    sdf: f32,
};

/// A sprite is one quad: four vertices, drawn as two triangles through the index buffer.
pub const vertices_per_quad = 4;
pub const indices_per_quad = 6;
/// Indices are 32-bit, so one batch can hold any number of quads. 16-bit indices would cap a batch
/// at about 16 thousand.
pub const index_size = @sizeOf(u32);

/// The corners of one quad in the two triangles, as offsets into the quad's four vertices. drawSprite
/// writes the corners top-left, bottom-left, bottom-right, top-right, so these triangles are the ones
/// six separate vertices used to make.
pub const quad_corner_order = [indices_per_quad]usize{ 0, 1, 2, 0, 2, 3 };

/// The index the index buffer holds at position `k` of quad number `quad`. It is an absolute vertex
/// number in the frame's vertex storage, so a draw needs no base vertex. Each quad needs its own
/// numbers. A pattern shared by every quad would send a batch of many quads to the first quad's
/// vertices.
pub fn indexValue(quad: usize, k: usize) u32 {
    return @intCast(quad * vertices_per_quad + quad_corner_order[k]);
}

/// The capacity to grow to: `current` doubled, starting from at least 1, until it holds `needed`.
pub fn grownCapacity(current: usize, needed: usize) usize {
    var capacity = @max(current, 1);
    while (capacity < needed) capacity *= 2;
    return capacity;
}
