//! GPU textures on SDL_GPU: the sampled image, its sampler, and the fence that says when the upload has
//! finished. The engine's Texture (renderer/texture.zig) holds a pointer to a State from here.

const std = @import("std");
const c = @import("../../../platform/sdl/sdl.zig").c;
const image = @import("../../../assets/loaders/image.zig");

/// The GPU objects behind one texture. The state is heap-allocated, so the engine keeps a pointer to
/// it, and `destroy` frees it with the allocator it came from.
pub const State = struct {
    device: *c.SDL_GPUDevice,
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    upload_fence: ?*c.SDL_GPUFence,
    allocator: std.mem.Allocator,
};

/// Uploads tightly packed RGBA8 pixels. `linear` selects linear filtering, used for signed-distance-field
/// font atlases. Otherwise sampling is nearest-neighbor, so pixel art stays sharp when it is scaled up.
pub fn uploadRgba8(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const u8, linear: bool) *State {
    return upload(allocator, device, width, height, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, pixels, width, height, linear);
}

/// Uploads a prebuilt block-compressed image. The caller checks `supportsCompression` first.
pub fn uploadCompressed(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, compression: image.Compression, blocks: []const u8) *State {
    const format = gpuFormat(compression) orelse unreachable;
    return upload(allocator, device, width, height, format, blocks, 0, 0, false);
}

/// Creates a texture the GPU can both sample and draw into. The native view is one of these.
pub fn createTarget(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat) *State {
    const texture = createTexture(device, width, height, format, c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER);
    return wrap(allocator, device, texture, createSampler(device, false), null);
}

/// True when the device can sample the block-compressed format. RGBA8 is always supported.
pub fn supportsCompression(device: *c.SDL_GPUDevice, compression: image.Compression) bool {
    const format = gpuFormat(compression) orelse return true;
    return c.SDL_GPUTextureSupportsFormat(device, format, c.SDL_GPU_TEXTURETYPE_2D, c.SDL_GPU_TEXTUREUSAGE_SAMPLER);
}

/// True once the GPU has finished the upload, so sampling the texture is safe. Only call this when
/// `hasUploadFence` is true.
pub fn isUploadDone(state: *const State) bool {
    return c.SDL_QueryGPUFence(state.device, state.upload_fence.?);
}

/// True when the texture has an upload to wait for. Render targets have none.
pub fn hasUploadFence(state: *const State) bool {
    return state.upload_fence != null;
}

/// The texture object itself, for drawing into it as a render target.
pub fn gpuTexture(state: *const State) *c.SDL_GPUTexture {
    return state.texture;
}

/// The texture and sampler pair a fragment shader reads through.
pub fn binding(state: *const State) c.SDL_GPUTextureSamplerBinding {
    return .{ .texture = state.texture, .sampler = state.sampler };
}

/// Releases the GPU objects, then the state. The device must still exist.
pub fn destroy(state: *State) void {
    if (state.upload_fence) |fence| c.SDL_ReleaseGPUFence(state.device, fence);
    c.SDL_ReleaseGPUSampler(state.device, state.sampler);
    c.SDL_ReleaseGPUTexture(state.device, state.texture);
    state.allocator.destroy(state);
}

fn upload(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat, pixels: []const u8, pixels_per_row: u32, rows_per_layer: u32, linear: bool) *State {
    const texture = createTexture(device, width, height, format, c.SDL_GPU_TEXTUREUSAGE_SAMPLER);

    // Stage the pixels in an upload buffer, then copy them into the texture.
    var tb_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    tb_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    tb_info.size = @intCast(pixels.len);
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &tb_info) orelse {
        std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..pixels.len], pixels);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        std.debug.panic("SDL_AcquireGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
    const src = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer,
        .offset = 0,
        .pixels_per_row = pixels_per_row,
        .rows_per_layer = rows_per_layer,
    };
    const region = c.SDL_GPUTextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    };
    c.SDL_UploadToGPUTexture(copy_pass, &src, &region, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse {
        std.debug.panic("SDL_SubmitGPUCommandBufferAndAcquireFence failed: {s}", .{c.SDL_GetError()});
    };
    return wrap(allocator, device, texture, createSampler(device, linear), fence);
}

fn wrap(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, texture: *c.SDL_GPUTexture, sampler: *c.SDL_GPUSampler, fence: ?*c.SDL_GPUFence) *State {
    const state = allocator.create(State) catch @panic("out of memory");
    state.* = .{ .device = device, .texture = texture, .sampler = sampler, .upload_fence = fence, .allocator = allocator };
    return state;
}

fn gpuFormat(compression: image.Compression) ?c.SDL_GPUTextureFormat {
    return switch (compression) {
        .rgba8 => null,
        .bc1 => c.SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM,
        .bc3 => c.SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM,
        .astc_4x4 => c.SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM,
    };
}

fn createTexture(device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat, usage: u32) *c.SDL_GPUTexture {
    var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
    info.type = c.SDL_GPU_TEXTURETYPE_2D;
    info.format = format;
    info.usage = usage;
    info.width = width;
    info.height = height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    return c.SDL_CreateGPUTexture(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUTexture failed: {s}", .{c.SDL_GetError()});
    };
}

fn createSampler(device: *c.SDL_GPUDevice, linear: bool) *c.SDL_GPUSampler {
    var info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
    info.min_filter = if (linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
    info.mag_filter = if (linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
    info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    return c.SDL_CreateGPUSampler(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUSampler failed: {s}", .{c.SDL_GetError()});
    };
}
