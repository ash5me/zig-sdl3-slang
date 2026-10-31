const std = @import("std");

const math = @import("../core/math.zig");
const profile = @import("../profiling/profile.zig");
const render_types = @import("render_types.zig");
const texture = @import("texture.zig");
const backend = @import("backends/sdl_gpu/backend.zig");

const Texture = texture.Texture;
const vertices_per_quad = render_types.vertices_per_quad;
const grownCapacity = render_types.grownCapacity;

/// Vertex layout for sprite quads. Positions are in normalized device coordinates. Color is RGBA:
/// the tint in RGB, and the sprite's alpha in A.
pub const Vertex = render_types.Vertex;

/// The index the index buffer holds at position `k` of quad number `quad`. See render_types.zig.
pub const indexValue = render_types.indexValue;

/// A rectangle in pixels (for destinations) or texels (for sources).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// Per-sprite settings beyond the source and destination rectangles. The defaults draw the sprite as
/// it is: untinted, opaque, unflipped, unrotated, and in the order it was added.
pub const Options = struct {
    /// Multiplies the texture's RGB, each channel from 0 to 1.
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Multiplies the texture's alpha. 0 is invisible and 1 is opaque.
    alpha: f32 = 1,
    /// Mirrors the texture left to right, or top to bottom. The place the sprite covers stays the same.
    flip_x: bool = false,
    flip_y: bool = false,
    /// The point inside the destination rectangle, in pixels from its top-left corner, that the
    /// sprite turns around. Rotation leaves this point where it is.
    origin: [2]f32 = .{ 0, 0 },
    /// Clockwise rotation in radians around `origin`. Screen y points down, so a positive angle turns
    /// clockwise as seen on screen.
    rotation: f32 = 0,
    /// Draw order. Lower values draw first. Sprites with equal values keep the order they were added in.
    /// Batches only merge neighbors with the same texture, so alternating textures in z order costs draw calls.
    z: i32 = 0,
    /// Treat the texture alpha channel as a signed distance field and reconstruct smooth coverage.
    sdf: bool = false,
};

/// Storage starts at these sizes and doubles when a frame needs more. A frame has no sprite or
/// texture-switch limit.
const initial_sprites = 1024;
const initial_batches = 64;

/// One queued sprite. Its corners are in the order drawSprite writes them: top-left, bottom-left,
/// bottom-right, top-right. `seq` is the order the sprite was added in. It breaks ties in the z sort.
const Quad = struct {
    texture: *const Texture,
    corners: [vertices_per_quad]Vertex,
    z: i32,
    seq: u32,
};

/// Consecutive quads that sample the same texture, drawn in one call. `first_vertex` and
/// `vertex_count` count vertices. Public so tests can build a batch without a GPU.
pub const Batch = struct {
    texture: *const Texture,
    first_vertex: u32,
    vertex_count: u32,
};

/// The backend's GPU state, hidden behind an opaque type so the public SpriteBatch names no backend type.
const SpriteBatchHandle = opaque {};

pub const SpriteBatch = struct {
    /// The GPU objects, owned by the backend. Only `init` creates them, and `deinit` releases them.
    gpu_state: *SpriteBatchHandle,
    allocator: std.mem.Allocator,

    /// Sprites queued this frame, in the order they were added. `prepare` sorts them by z in place.
    /// Heap-allocated, and doubled when a frame needs more.
    quads: []Quad = &.{},
    /// Sprites queued this frame. Each one is a quad.
    sprite_count: u32 = 0,

    /// CPU-side vertices for the current frame, in draw order. `prepare` fills them.
    vertices: []Vertex,
    vertex_count: u32 = 0,
    /// Runs of sprites that share a texture, in draw order. `prepare` fills them.
    batches: []Batch,
    batch_count: u32 = 0,
    /// Draw calls issued by draw() this frame. Shows whether batching is working.
    draw_calls: u32 = 0,
    /// Maps pixel coordinates in the viewport to normalized device coordinates. Set by `begin`.
    projection: math.Mat4 = undefined,

    /// Builds the pipeline and GPU buffers. `color_format` is the swapchain format
    /// the sprites render into.
    fn init(allocator: std.mem.Allocator, device: *backend.Device, color_format: backend.TextureFormat) SpriteBatch {
        const gpu_state = backend.sprite.create(allocator, device, color_format, initial_sprites * vertices_per_quad);
        return .{
            .gpu_state = @ptrCast(gpu_state),
            .allocator = allocator,
            .quads = allocQuads(allocator, initial_sprites),
            .vertices = allocVertices(allocator, initial_sprites * vertices_per_quad),
            .batches = allocBatches(allocator, initial_batches),
            .projection = math.ortho2d(1.0, 1.0),
        };
    }

    /// Starts a new frame of sprites. `viewport_w` and `viewport_h` are the drawing area in pixels,
    /// with (0,0) at the top-left.
    pub fn begin(self: *SpriteBatch, viewport_w: f32, viewport_h: f32) void {
        self.sprite_count = 0;
        self.vertex_count = 0;
        self.batch_count = 0;
        self.draw_calls = 0;
        self.projection = math.ortho2d(viewport_w, viewport_h);
    }

    /// Queues one sprite. `src` is the texel rectangle to sample, and `dst` is the on-screen rectangle
    /// in pixels, before `opts` applies. `opts` sets the tint, alpha, flip, origin, rotation, and z.
    /// Sprites draw in z order, and sprites with equal z draw in the order they were added.
    pub fn drawSprite(self: *SpriteBatch, texture_ref: *const Texture, src: Rect, dst: Rect, opts: Options) void {
        // Make room before writing. Storage doubles when it fills, so a frame has no sprite limit.
        if (self.sprite_count == self.quads.len) self.growQuads(self.sprite_count + 1);
        self.quads[self.sprite_count] = .{
            .texture = texture_ref,
            .corners = cornersFor(&self.projection, texture_ref, src, dst, opts),
            .z = opts.z,
            .seq = self.sprite_count,
        };
        self.sprite_count += 1;
    }

    /// Puts this frame's sprites in draw order, and writes their vertices and texture runs. `upload`
    /// calls this, and so do tests, which have no GPU. It rebuilds the same result if it runs again.
    pub fn prepare(self: *SpriteBatch) void {
        const zone = profile.zoneNamed(@src(), "sprite prepare");
        defer zone.End();
        const queued = self.quads[0..self.sprite_count];
        if (!inZOrder(queued)) heapSort(queued);

        self.vertex_count = 0;
        self.batch_count = 0;
        const needed = @as(usize, self.sprite_count) * vertices_per_quad;
        if (needed > self.vertices.len) self.growVertices(needed);

        for (queued) |quad| {
            // Start a new run whenever the texture changes. Runs double too, so there is no switch limit.
            if (self.batch_count == 0 or self.batches[self.batch_count - 1].texture != quad.texture) {
                if (self.batch_count == self.batches.len) self.growBatches(self.batch_count + 1);
                self.batches[self.batch_count] = .{
                    .texture = quad.texture,
                    .first_vertex = self.vertex_count,
                    .vertex_count = 0,
                };
                self.batch_count += 1;
            }
            self.batches[self.batch_count - 1].vertex_count += vertices_per_quad;
            for (quad.corners) |corner| {
                self.vertices[self.vertex_count] = corner;
                self.vertex_count += 1;
            }
        }
    }

    /// Copies this frame's vertices to the GPU. Call before beginPass, since the copy
    /// has to happen outside a render pass.
    fn upload(self: *SpriteBatch, cmd: *backend.CommandBuffer) void {
        const zone = profile.zoneNamed(@src(), "sprite upload");
        defer zone.End();
        self.prepare();
        if (self.vertex_count == 0) return;
        backend.sprite.upload(gpuOf(self), cmd, self.vertices[0..self.vertex_count]);
    }

    /// Records one draw call per batch. Call inside a render pass, after upload().
    fn draw(self: *SpriteBatch, pass: ?*backend.RenderPass) void {
        const zone = profile.zoneNamed(@src(), "sprite draw");
        defer zone.End();
        if (self.batch_count == 0) return;
        backend.sprite.beginDraw(gpuOf(self), pass);

        for (self.batches[0..self.batch_count]) |batch| {
            // A texture whose upload is still running has nothing to sample yet. Skip its batch this
            // frame. The game queues the sprite again next frame.
            if (!batch.texture.isReady()) continue;
            backend.sprite.drawRun(pass, texture.backendState(batch.texture), batch.first_vertex, batch.vertex_count);
            self.draw_calls += 1;
        }
    }

    /// Doubles the quad storage until it holds `needed` sprites. Sprites already queued this frame
    /// are kept.
    fn growQuads(self: *SpriteBatch, needed: usize) void {
        const bigger = allocQuads(self.allocator, grownCapacity(self.quads.len, needed));
        @memcpy(bigger[0..self.sprite_count], self.quads[0..self.sprite_count]);
        freeSlice(self.allocator, Quad, self.quads);
        self.quads = bigger;
    }

    /// Doubles the vertex storage until it holds `needed` vertices. Vertices already written this
    /// frame are kept.
    fn growVertices(self: *SpriteBatch, needed: usize) void {
        const bigger = allocVertices(self.allocator, grownCapacity(self.vertices.len, needed));
        @memcpy(bigger[0..self.vertex_count], self.vertices[0..self.vertex_count]);
        freeSlice(self.allocator, Vertex, self.vertices);
        self.vertices = bigger;
    }

    /// Doubles the batch storage until it holds `needed` batches. Batches already built this frame
    /// are kept.
    fn growBatches(self: *SpriteBatch, needed: usize) void {
        const bigger = allocBatches(self.allocator, grownCapacity(self.batches.len, needed));
        @memcpy(bigger[0..self.batch_count], self.batches[0..self.batch_count]);
        freeSlice(self.allocator, Batch, self.batches);
        self.batches = bigger;
    }

    /// Releases the GPU objects and the CPU storage. Call before the renderer is deinitialized.
    pub fn deinit(self: *SpriteBatch) void {
        backend.sprite.destroy(gpuOf(self), self.allocator);
        freeSlice(self.allocator, Quad, self.quads);
        freeSlice(self.allocator, Vertex, self.vertices);
        freeSlice(self.allocator, Batch, self.batches);
        self.* = undefined;
    }
};

pub fn create(allocator: std.mem.Allocator, device: *backend.Device, color_format: backend.TextureFormat) SpriteBatch {
    return SpriteBatch.init(allocator, device, color_format);
}

pub fn upload(batch: *SpriteBatch, cmd: *backend.CommandBuffer) void {
    batch.upload(cmd);
}

pub fn draw(batch: *SpriteBatch, pass: ?*backend.RenderPass) void {
    batch.draw(pass);
}

/// The backend state of a batch. The cast reverses how `init` stored it.
fn gpuOf(batch: *const SpriteBatch) *backend.sprite.State {
    return @ptrCast(@alignCast(batch.gpu_state));
}

/// The four corners of one sprite in pixels, through `projection`. The texture coordinates, flip,
/// origin, rotation, and color are applied. The order is top-left, bottom-left, bottom-right, top-right.
fn cornersFor(projection: *const math.Mat4, texture_ref: *const Texture, src: Rect, dst: Rect, opts: Options) [vertices_per_quad]Vertex {
    // Texel rectangle -> UV coordinates (0..1). A flip swaps the two ends of an axis.
    // Names avoid u0/u1, which are Zig's unsigned integer type names.
    const tw: f32 = @floatFromInt(texture_ref.width);
    const th: f32 = @floatFromInt(texture_ref.height);
    var u_left = src.x / tw;
    var u_right = (src.x + src.w) / tw;
    var v_top = src.y / th;
    var v_bottom = (src.y + src.h) / th;
    if (opts.flip_x) std.mem.swap(f32, &u_left, &u_right);
    if (opts.flip_y) std.mem.swap(f32, &v_top, &v_bottom);

    // The corners relative to the origin, before rotation. The origin is the pivot, and it stays at
    // dst.x + origin[0], dst.y + origin[1].
    const ox = opts.origin[0];
    const oy = opts.origin[1];
    const s = @sin(opts.rotation);
    const co = @cos(opts.rotation);
    const pivot_x = dst.x + ox;
    const pivot_y = dst.y + oy;
    const o_tl = turned(-ox, -oy, s, co);
    const o_bl = turned(-ox, dst.h - oy, s, co);
    const o_br = turned(dst.w - ox, dst.h - oy, s, co);
    const o_tr = turned(dst.w - ox, -oy, s, co);

    const p_tl = math.transformPoint(projection, pivot_x + o_tl[0], pivot_y + o_tl[1]);
    const p_bl = math.transformPoint(projection, pivot_x + o_bl[0], pivot_y + o_bl[1]);
    const p_br = math.transformPoint(projection, pivot_x + o_br[0], pivot_y + o_br[1]);
    const p_tr = math.transformPoint(projection, pivot_x + o_tr[0], pivot_y + o_tr[1]);

    const color = [4]f32{ opts.tint[0], opts.tint[1], opts.tint[2], opts.alpha };
    const sdf: f32 = if (opts.sdf) 1 else 0;
    return .{
        .{ .pos = p_tl, .uv = .{ u_left, v_top }, .color = color, .sdf = sdf },
        .{ .pos = p_bl, .uv = .{ u_left, v_bottom }, .color = color, .sdf = sdf },
        .{ .pos = p_br, .uv = .{ u_right, v_bottom }, .color = color, .sdf = sdf },
        .{ .pos = p_tr, .uv = .{ u_right, v_top }, .color = color, .sdf = sdf },
    };
}

/// An offset (x, y) turned clockwise by the angle with sine `s` and cosine `co`. Screen y points
/// down, so this turns clockwise as seen on screen.
fn turned(x: f32, y: f32, s: f32, co: f32) [2]f32 {
    return .{ x * co - y * s, x * s + y * co };
}

/// True when the quads are already in non-decreasing z order, so no sort is needed. Most frames are.
fn inZOrder(quads: []const Quad) bool {
    var i: usize = 1;
    while (i < quads.len) : (i += 1) {
        if (quads[i].z < quads[i - 1].z) return false;
    }
    return true;
}

/// Quads sort by z, and then by the order they were added. The second key makes every quad distinct,
/// so the heap sort below gives the same result a stable sort would.
fn quadBefore(a: Quad, b: Quad) bool {
    return a.z < b.z or (a.z == b.z and a.seq < b.seq);
}

/// Sifts the quad at `root` down until the heap property holds below it, within the first `end` quads.
fn siftDown(quads: []Quad, root_start: usize, end: usize) void {
    var root = root_start;
    while (true) {
        var child = 2 * root + 1;
        if (child >= end) return;
        if (child + 1 < end and quadBefore(quads[child], quads[child + 1])) child += 1;
        if (!quadBefore(quads[root], quads[child])) return;
        std.mem.swap(Quad, &quads[root], &quads[child]);
        root = child;
    }
}

/// Sorts the quads in place by z, then by insertion order. Heap sort needs no extra memory.
fn heapSort(quads: []Quad) void {
    if (quads.len < 2) return;
    var start = quads.len / 2;
    while (start > 0) {
        start -= 1;
        siftDown(quads, start, quads.len);
    }
    var end = quads.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Quad, &quads[0], &quads[end]);
        siftDown(quads, 0, end);
    }
}

fn allocQuads(allocator: std.mem.Allocator, count: usize) []Quad {
    return allocator.alloc(Quad, count) catch @panic("out of memory");
}

fn allocVertices(allocator: std.mem.Allocator, count: usize) []Vertex {
    return allocator.alloc(Vertex, count) catch @panic("out of memory");
}

fn allocBatches(allocator: std.mem.Allocator, count: usize) []Batch {
    return allocator.alloc(Batch, count) catch @panic("out of memory");
}

/// Frees storage from `allocQuads`, `allocVertices`, or `allocBatches`. A zero-length slice owns no
/// memory, so it is skipped.
fn freeSlice(allocator: std.mem.Allocator, comptime T: type, slice: []T) void {
    if (slice.len != 0) allocator.free(slice);
}
