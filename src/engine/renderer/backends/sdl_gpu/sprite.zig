//! The SDL_GPU half of sprite batching: the pipeline, the vertex, upload, and index buffers, and the draw
//! calls. The engine's SpriteBatch (renderer/sprite.zig) builds the vertices and the texture runs on the
//! CPU, then hands them here.

const std = @import("std");
const c = @import("../../../platform/sdl/sdl.zig").c;
const embedded = @import("embedded_shaders");
const render_types = @import("../../render_types.zig");
const shader = @import("shader.zig");
const texture = @import("texture.zig");

const Vertex = render_types.Vertex;
const vertices_per_quad = render_types.vertices_per_quad;
const indices_per_quad = render_types.indices_per_quad;
const index_size = render_types.index_size;

/// The sprite shaders. build.zig compiles them and embeds the code under the `decl` names in its
/// `shader_entries` table. The resource counts sit here, beside the pipeline that binds them.
const vertex_source = shader.Source{
    .name = "default.vert",
    .entry = "vertexMain",
    .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
    .code = .{ .spirv = embedded.default_vert, .dxil = embedded.default_vert_dxil, .msl = embedded.default_vert_msl },
};
const fragment_source = shader.Source{
    .name = "default.frag",
    .entry = "fragmentMain",
    .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    .code = .{ .spirv = embedded.default_frag, .dxil = embedded.default_frag_dxil, .msl = embedded.default_frag_msl },
    // The fragment shader samples one texture, which takes one sampler slot.
    .resources = .{ .samplers = 1 },
};

/// The GPU objects of one sprite batch. The engine keeps a pointer to the state, and `destroy` frees it.
pub const State = struct {
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    vertex_buffer: *c.SDL_GPUBuffer,
    vb_binding: c.SDL_GPUBufferBinding,
    upload_buffer: *c.SDL_GPUTransferBuffer,
    index_buffer: *c.SDL_GPUBuffer,
    ib_binding: c.SDL_GPUBufferBinding,
    index_filled: bool = false,
    index_staging: ?*c.SDL_GPUTransferBuffer = null,
    gpu_vertex_capacity: usize,
};

/// Builds the pipeline and the GPU buffers. `initial_vertices` is the starting capacity; the vertex buffer
/// is replaced when a frame needs more. `color_format` is the swapchain format the sprites render into.
pub fn create(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, color_format: c.SDL_GPUTextureFormat, initial_vertices: usize) *State {
    const format = shader.pickFormat(device);
    const vert = shader.load(device, format, vertex_source);
    defer c.SDL_ReleaseGPUShader(device, vert);
    const frag = shader.load(device, format, fragment_source);
    defer c.SDL_ReleaseGPUShader(device, frag);

    // Alpha blending, so transparent pixels show what's behind them.
    var color_desc = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
    color_desc.format = color_format;
    color_desc.blend_state = .{
        .enable_blend = true,
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
    };

    var vb_desc = std.mem.zeroes(c.SDL_GPUVertexBufferDescription);
    vb_desc.slot = 0;
    vb_desc.pitch = @sizeOf(Vertex);
    vb_desc.input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX;

    // Locations must match the [vk::location] values in shaders/default.slang.
    var vb_attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "pos") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "uv") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex, "color") },
        .{ .location = 3, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = @offsetOf(Vertex, "sdf") },
    };

    var pipeline_info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
    pipeline_info.vertex_shader = vert;
    pipeline_info.fragment_shader = frag;
    pipeline_info.vertex_input_state.vertex_buffer_descriptions = &vb_desc;
    pipeline_info.vertex_input_state.num_vertex_buffers = 1;
    pipeline_info.vertex_input_state.vertex_attributes = &vb_attrs;
    pipeline_info.vertex_input_state.num_vertex_attributes = @intCast(vb_attrs.len);
    pipeline_info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    pipeline_info.depth_stencil_state.compare_op = c.SDL_GPU_COMPAREOP_ALWAYS;
    pipeline_info.target_info.num_color_targets = 1;
    pipeline_info.target_info.color_target_descriptions = &color_desc;

    const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_info) orelse {
        std.debug.panic("SDL_CreateGPUGraphicsPipeline failed: {s}", .{c.SDL_GetError()});
    };

    // The GPU buffers start at the initial size and are replaced when a frame needs more. The index buffer
    // has one set of six indices for each quad the vertex buffer holds.
    const gpu_vertex_capacity = initial_vertices;
    const vertex_buffer = createVertexBuffer(device, gpu_vertex_capacity);
    const upload_buffer = createUploadBuffer(device, gpu_vertex_capacity);
    const index_buffer = createIndexBuffer(device, gpu_vertex_capacity / vertices_per_quad);
    const state = allocator.create(State) catch @panic("out of memory");
    state.* = .{
        .device = device,
        .pipeline = pipeline,
        .vertex_buffer = vertex_buffer,
        .vb_binding = .{ .buffer = vertex_buffer, .offset = 0 },
        .upload_buffer = upload_buffer,
        .index_buffer = index_buffer,
        .ib_binding = .{ .buffer = index_buffer, .offset = 0 },
        .gpu_vertex_capacity = gpu_vertex_capacity,
    };
    return state;
}

/// Copies this frame's vertices to the GPU, growing the buffers first if the frame has more than they hold.
/// Call before the render pass, since the copy has to happen outside a render pass.
pub fn upload(state: *State, cmd: *c.SDL_GPUCommandBuffer, vertices: []const Vertex) void {
    if (vertices.len == 0) return;
    if (vertices.len > state.gpu_vertex_capacity) growGpuBuffers(state, vertices.len);
    if (!state.index_filled) fillIndexBuffer(state, cmd);
    const bytes = vertexBytes(vertices.len);

    // cycle = true lets SDL hand us a fresh buffer if the GPU is still reading the last one.
    const mapped = c.SDL_MapGPUTransferBuffer(state.device, state.upload_buffer, true) orelse {
        std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..bytes], std.mem.sliceAsBytes(vertices));
    c.SDL_UnmapGPUTransferBuffer(state.device, state.upload_buffer);

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
    const src = c.SDL_GPUTransferBufferLocation{ .transfer_buffer = state.upload_buffer, .offset = 0 };
    const region = c.SDL_GPUBufferRegion{ .buffer = state.vertex_buffer, .offset = 0, .size = bytes };
    c.SDL_UploadToGPUBuffer(copy_pass, &src, &region, true);
    c.SDL_EndGPUCopyPass(copy_pass);
}

/// Binds the pipeline and the vertex and index buffers for this batch's draws. Call inside a render pass,
/// after `upload`.
pub fn beginDraw(state: *const State, pass: ?*c.SDL_GPURenderPass) void {
    c.SDL_BindGPUGraphicsPipeline(pass, state.pipeline);
    c.SDL_BindGPUVertexBuffers(pass, 0, &state.vb_binding, 1);
    c.SDL_BindGPUIndexBuffer(pass, &state.ib_binding, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
}

/// Draws one run of quads that share a texture: the vertices from `first_vertex` on, `vertex_count` of them.
/// The indices name absolute vertices, so the draw starts at this run's first quad in the index buffer and
/// uses no base vertex.
pub fn drawRun(pass: ?*c.SDL_GPURenderPass, tex: *const texture.State, first_vertex: u32, vertex_count: u32) void {
    const sampler = texture.binding(tex);
    c.SDL_BindGPUFragmentSamplers(pass, 0, &sampler, 1);
    const first_quad = first_vertex / vertices_per_quad;
    const quads = vertex_count / vertices_per_quad;
    c.SDL_DrawGPUIndexedPrimitives(pass, quads * indices_per_quad, 1, first_quad * indices_per_quad, 0, 0);
}

/// Releases the GPU objects, then the state. Call before the device is destroyed.
pub fn destroy(state: *State, allocator: std.mem.Allocator) void {
    c.SDL_ReleaseGPUTransferBuffer(state.device, state.upload_buffer);
    if (state.index_staging) |staging| c.SDL_ReleaseGPUTransferBuffer(state.device, staging);
    c.SDL_ReleaseGPUBuffer(state.device, state.index_buffer);
    c.SDL_ReleaseGPUBuffer(state.device, state.vertex_buffer);
    c.SDL_ReleaseGPUGraphicsPipeline(state.device, state.pipeline);
    allocator.destroy(state);
}

/// Replaces the GPU vertex, upload, and index buffers with ones that hold `needed` vertices. The old buffers
/// are released at once. SDL frees each one after the frames still using it finish, so this doesn't wait for
/// the GPU. The new index buffer is written by the next upload.
fn growGpuBuffers(state: *State, needed: usize) void {
    const capacity = render_types.grownCapacity(state.gpu_vertex_capacity, needed);
    c.SDL_ReleaseGPUBuffer(state.device, state.vertex_buffer);
    c.SDL_ReleaseGPUTransferBuffer(state.device, state.upload_buffer);
    c.SDL_ReleaseGPUBuffer(state.device, state.index_buffer);
    if (state.index_staging) |staging| c.SDL_ReleaseGPUTransferBuffer(state.device, staging);
    state.index_staging = null;
    state.vertex_buffer = createVertexBuffer(state.device, capacity);
    state.upload_buffer = createUploadBuffer(state.device, capacity);
    state.index_buffer = createIndexBuffer(state.device, capacity / vertices_per_quad);
    state.vb_binding = .{ .buffer = state.vertex_buffer, .offset = 0 };
    state.ib_binding = .{ .buffer = state.index_buffer, .offset = 0 };
    state.gpu_vertex_capacity = capacity;
    state.index_filled = false;
}

/// Writes the index of every quad corner into the whole index buffer. The indices name this frame's vertices,
/// so no draw needs a base vertex. The copy is recorded on `cmd`, so it runs before this frame's draws. The
/// contents depend only on the capacity, so this runs once per creation.
fn fillIndexBuffer(state: *State, cmd: *c.SDL_GPUCommandBuffer) void {
    const quads = state.gpu_vertex_capacity / vertices_per_quad;
    const bytes = indexBytes(quads);

    if (state.index_staging == null) {
        var info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        info.size = bytes;
        state.index_staging = c.SDL_CreateGPUTransferBuffer(state.device, &info) orelse {
            std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
        };
    }
    const staging = state.index_staging.?;

    const mapped = c.SDL_MapGPUTransferBuffer(state.device, staging, false) orelse {
        std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const dst: [*]u8 = @ptrCast(mapped);
    for (0..quads) |quad| {
        for (0..indices_per_quad) |k| {
            const at = (quad * indices_per_quad + k) * index_size;
            std.mem.writeInt(u32, dst[at .. at + index_size][0..index_size], render_types.indexValue(quad, k), .little);
        }
    }
    c.SDL_UnmapGPUTransferBuffer(state.device, staging);

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
    const src = c.SDL_GPUTransferBufferLocation{ .transfer_buffer = staging, .offset = 0 };
    const region = c.SDL_GPUBufferRegion{ .buffer = state.index_buffer, .offset = 0, .size = bytes };
    c.SDL_UploadToGPUBuffer(copy_pass, &src, &region, false);
    c.SDL_EndGPUCopyPass(copy_pass);

    state.index_filled = true;
}

/// Creates a GPU vertex buffer that holds `vertex_count` vertices.
fn createVertexBuffer(device: *c.SDL_GPUDevice, vertex_count: usize) *c.SDL_GPUBuffer {
    var info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    info.size = vertexBytes(vertex_count);
    return c.SDL_CreateGPUBuffer(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
    };
}

/// Creates a GPU index buffer that holds the indices of `quad_count` quads.
fn createIndexBuffer(device: *c.SDL_GPUDevice, quad_count: usize) *c.SDL_GPUBuffer {
    var info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    info.usage = c.SDL_GPU_BUFFERUSAGE_INDEX;
    info.size = indexBytes(quad_count);
    return c.SDL_CreateGPUBuffer(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
    };
}

/// Creates the staging buffer that the CPU writes a frame's vertices into.
fn createUploadBuffer(device: *c.SDL_GPUDevice, vertex_count: usize) *c.SDL_GPUTransferBuffer {
    var info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    info.size = vertexBytes(vertex_count);
    return c.SDL_CreateGPUTransferBuffer(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
}

/// The byte size of `vertex_count` vertices. SDL takes buffer sizes as 32-bit integers, so this is the one
/// ceiling left: about 33 million sprites in a single frame.
fn vertexBytes(vertex_count: usize) u32 {
    const bytes = vertex_count * @sizeOf(Vertex);
    if (bytes > std.math.maxInt(u32)) {
        std.debug.panic("a frame of {d} vertices needs {d} bytes, more than SDL's 32-bit buffer size allows", .{ vertex_count, bytes });
    }
    return @intCast(bytes);
}

/// The byte size of the indices for `quad_count` quads. Each quad has six indices.
fn indexBytes(quad_count: usize) u32 {
    const bytes = quad_count * indices_per_quad * index_size;
    if (bytes > std.math.maxInt(u32)) {
        std.debug.panic("{d} quads need {d} index bytes, more than SDL's 32-bit buffer size allows", .{ quad_count, bytes });
    }
    return @intCast(bytes);
}
