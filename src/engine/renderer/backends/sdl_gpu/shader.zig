const std = @import("std");

const c = @import("../../../platform/sdl/sdl.zig").c;

/// Shader formats the engine can load. Declaration order is the preference order: when the device
/// accepts more than one, the first one listed here is used. Adding a format doesn't compile until
/// every switch below handles it.
pub const Format = enum {
    spirv,
    dxil,
    msl,

    /// The SDL flag the device must accept for this format to be usable.
    fn sdlFlag(self: Format) c.SDL_GPUShaderFormat {
        return switch (self) {
            .spirv => c.SDL_GPU_SHADERFORMAT_SPIRV,
            .dxil => c.SDL_GPU_SHADERFORMAT_DXIL,
            .msl => c.SDL_GPU_SHADERFORMAT_MSL,
        };
    }

    /// The entry point name inside the compiled code. Slang names SPIR-V entry points "main" whatever
    /// the function is called in the source. DXIL and MSL keep the source name, so it is passed in.
    fn entryName(self: Format, source_entry: [:0]const u8) [:0]const u8 {
        return switch (self) {
            .spirv => "main",
            .dxil => source_entry,
            .msl => source_entry,
        };
    }

    /// The compiled code of `source` in this format.
    fn codeOf(self: Format, source: Source) []const u8 {
        return switch (self) {
            .spirv => source.code.spirv,
            .dxil => source.code.dxil,
            .msl => source.code.msl,
        };
    }
};

/// Resource counts a shader declares. SDL_GPU needs these when the shader is created.
pub const Resources = struct {
    samplers: u32 = 0,
    uniform_buffers: u32 = 0,
};

/// Compiled code for one shader, with one field per format. The bytes come from the build's
/// generated `embedded_shaders` module, so no file is read at runtime. SPIR-V and DXIL are read as
/// 32-bit words, so their slices carry 4-byte alignment. DXIL and MSL are empty unless enabled at
/// build time, and the renderer only asks SDL to accept formats that are embedded.
pub const Code = struct {
    spirv: []align(4) const u8,
    dxil: []align(4) const u8,
    msl: []const u8,
};

/// One shader program: its name for error messages, its compiled code, the stage it runs in, and
/// the resources it reads. Declare these as constants beside the code that binds them.
pub const Source = struct {
    /// Name for error messages, such as "default.vert".
    name: []const u8,
    /// The entry function's name in the Slang source, such as "vertexMain".
    entry: [:0]const u8,
    stage: c.SDL_GPUShaderStage,
    code: Code,
    resources: Resources = .{},
};

/// The first format in `Format` order that the device accepts. Panics when there is none, because
/// nothing can be drawn without a shader format.
pub fn pickFormat(device: *c.SDL_GPUDevice) Format {
    const supported = c.SDL_GetGPUShaderFormats(device);
    return pickFormatFromFlags(supported) orelse std.debug.panic(
        "device accepts no shader format the engine supports (flags {d})",
        .{supported},
    );
}

/// Selects the first supported format in the engine's preference order. Kept separate from the SDL
/// query so the selection logic can be covered without creating a GPU device.
fn pickFormatFromFlags(supported: c.SDL_GPUShaderFormat) ?Format {
    for (std.enums.values(Format)) |format| {
        if ((supported & format.sdlFlag()) != 0) return format;
    }
    return null;
}

/// Creates a GPU shader from `source` compiled in `format`. The code is already in the executable,
/// so nothing is read from disk here.
pub fn load(device: *c.SDL_GPUDevice, format: Format, source: Source) *c.SDL_GPUShader {
    const code = format.codeOf(source);

    var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    info.code_size = code.len;
    info.code = code.ptr;
    info.entrypoint = format.entryName(source.entry).ptr;
    info.format = format.sdlFlag();
    info.stage = source.stage;
    info.num_samplers = source.resources.samplers;
    info.num_uniform_buffers = source.resources.uniform_buffers;

    return c.SDL_CreateGPUShader(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUShader('{s}') failed: {s}", .{ source.name, c.SDL_GetError() });
    };
}

test "shader format selection prefers SPIR-V, then DXIL, then MSL" {
    const all_formats = c.SDL_GPU_SHADERFORMAT_SPIRV |
        c.SDL_GPU_SHADERFORMAT_DXIL |
        c.SDL_GPU_SHADERFORMAT_MSL;
    try std.testing.expectEqual(Format.spirv, pickFormatFromFlags(all_formats).?);
    try std.testing.expectEqual(Format.dxil, pickFormatFromFlags(
        c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL,
    ).?);
    try std.testing.expectEqual(Format.msl, pickFormatFromFlags(c.SDL_GPU_SHADERFORMAT_MSL).?);
    try std.testing.expectEqual(@as(?Format, null), pickFormatFromFlags(0));
}

test "MSL shaders use their source entry point and embedded source" {
    const source_text = "vertex float4 vertexMain() { return 0; }";
    const source = Source{
        .name = "test.msl",
        .entry = "vertexMain",
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .code = .{ .spirv = &.{}, .dxil = &.{}, .msl = source_text },
    };

    try std.testing.expectEqualStrings("vertexMain", Format.msl.entryName(source.entry));
    try std.testing.expectEqualStrings(source_text, Format.msl.codeOf(source));
    try std.testing.expectEqual(c.SDL_GPU_SHADERFORMAT_MSL, Format.msl.sdlFlag());
}
