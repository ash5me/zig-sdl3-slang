const std = @import("std");

const backend = @import("backends/sdl_gpu/backend.zig");
const image = @import("../assets/loaders/image.zig");

/// The backend state, hidden behind an opaque type so the public Texture names no backend type.
const TextureHandle = opaque {};

/// A 2D texture and its GPU state. Nearest filtering keeps pixel art sharp when it's scaled up.
pub const Texture = struct {
    gpu_state: *TextureHandle,
    width: u32,
    height: u32,
    has_upload_fence: bool,

    /// Releases the GPU resources. The owning engine runtime must outlive the texture.
    pub fn deinit(self: *Texture) void {
        backend.texture.destroy(backendState(self));
        self.* = undefined;
    }

    /// True once the GPU has finished uploading the texture, so sampling it is safe. Targets have no
    /// upload, so they are always ready.
    pub fn isReady(self: *const Texture) bool {
        if (!self.has_upload_fence) return true;
        return backend.texture.isUploadDone(backendState(self));
    }
};

/// Uploads tightly packed RGBA8 pixels (4 bytes per pixel, row 0 at the top).
pub fn createRgba8(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, pixels: []const u8) Texture {
    return wrap(backend.texture.uploadRgba8(allocator, device, width, height, pixels, false), width, height);
}

/// Uploads RGBA8 pixels with linear filtering, used for signed-distance-field font atlases.
pub fn createRgba8Linear(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, pixels: []const u8) Texture {
    return wrap(backend.texture.uploadRgba8(allocator, device, width, height, pixels, true), width, height);
}

pub fn supportsCompression(device: *backend.Device, compression: image.Compression) bool {
    return backend.texture.supportsCompression(device, compression);
}

pub fn createCompressed(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, compression: image.Compression, blocks: []const u8) Texture {
    return wrap(backend.texture.uploadCompressed(allocator, device, width, height, compression, blocks), width, height);
}

pub fn createTarget(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, format: backend.TextureFormat) Texture {
    return wrap(backend.texture.createTarget(allocator, device, width, height, format), width, height);
}

pub fn updateRgba8(texture_ref: *Texture, width: u32, height: u32, pixels: []const u8, linear: bool) void {
    const state = backendState(texture_ref);
    const device = state.device;
    const allocator = state.allocator;
    texture_ref.deinit();
    texture_ref.* = if (linear) createRgba8Linear(allocator, device, width, height, pixels) else createRgba8(allocator, device, width, height, pixels);
}

/// The GPU texture object, for drawing into this texture as a render target.
pub fn backendTexture(texture_ref: *const Texture) *backend.GpuTexture {
    return backend.texture.gpuTexture(backendState(texture_ref));
}

/// The backend state of a texture. The cast reverses how `wrap` stored it.
pub fn backendState(texture_ref: *const Texture) *backend.texture.State {
    return @ptrCast(@alignCast(texture_ref.gpu_state));
}

fn wrap(state: *backend.texture.State, width: u32, height: u32) Texture {
    return .{
        .gpu_state = @ptrCast(state),
        .width = width,
        .height = height,
        .has_upload_fence = backend.texture.hasUploadFence(state),
    };
}
