//! The SDL GPU backend for the renderer. Every SDL_GPU type and call the renderer makes is in this
//! folder, plus platform/sdl, which owns the device and the swapchain. Engine renderer files reach
//! SDL only through the names below, so no SDL_GPU identifier appears in them.

const c = @import("../../../platform/sdl/sdl.zig").c;

pub const shader = @import("shader.zig");
pub const pass = @import("pass.zig");
pub const texture = @import("texture.zig");
pub const sprite = @import("sprite.zig");

/// The GPU device, and the handles the renderer passes between its operations.
pub const Device = c.SDL_GPUDevice;
pub const CommandBuffer = c.SDL_GPUCommandBuffer;
pub const RenderPass = c.SDL_GPURenderPass;
/// A texture on the GPU: a sampled image, a render target, or the window's swapchain.
pub const GpuTexture = c.SDL_GPUTexture;
pub const TextureFormat = c.SDL_GPUTextureFormat;
