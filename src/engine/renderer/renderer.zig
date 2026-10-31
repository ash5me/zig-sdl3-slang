//! Render passes. A pass draws into one target: the native view, or the window's swapchain.
//! The GPU device and the swapchain are in platform/sdl/gpu.zig. The SDL calls are in backends/sdl_gpu.

const render_types = @import("render_types.zig");
const backend = @import("backends/sdl_gpu/backend.zig");

pub const Color = render_types.Color;

/// Starts a render pass that clears `target` to `clear`.
/// The target can be the swapchain or any texture created with texture.createTarget.
pub fn beginPass(cmd: *backend.CommandBuffer, target: *backend.GpuTexture, clear: Color) ?*backend.RenderPass {
    return backend.pass.begin(cmd, target, clear);
}

/// Ends a render pass that `beginPass` started.
pub fn endPass(pass: ?*backend.RenderPass) void {
    backend.pass.end(pass);
}
