const std = @import("std");

/// cglm's C sources (v0.9.7), in the order its CMakeLists.txt lists them. They are vendored under
/// vendor/cglm/ with its headers and license.
const cglm_sources = [_][]const u8{
    "vendor/cglm/src/euler.c",
    "vendor/cglm/src/affine.c",
    "vendor/cglm/src/io.c",
    "vendor/cglm/src/quat.c",
    "vendor/cglm/src/cam.c",
    "vendor/cglm/src/vec2.c",
    "vendor/cglm/src/ivec2.c",
    "vendor/cglm/src/vec3.c",
    "vendor/cglm/src/ivec3.c",
    "vendor/cglm/src/vec4.c",
    "vendor/cglm/src/ivec4.c",
    "vendor/cglm/src/mat2.c",
    "vendor/cglm/src/mat2x3.c",
    "vendor/cglm/src/mat2x4.c",
    "vendor/cglm/src/mat3.c",
    "vendor/cglm/src/mat3x2.c",
    "vendor/cglm/src/mat3x4.c",
    "vendor/cglm/src/mat4.c",
    "vendor/cglm/src/mat4x2.c",
    "vendor/cglm/src/mat4x3.c",
    "vendor/cglm/src/plane.c",
    "vendor/cglm/src/noise.c",
    "vendor/cglm/src/frustum.c",
    "vendor/cglm/src/box.c",
    "vendor/cglm/src/aabb2d.c",
    "vendor/cglm/src/project.c",
    "vendor/cglm/src/sphere.c",
    "vendor/cglm/src/ease.c",
    "vendor/cglm/src/curve.c",
    "vendor/cglm/src/bezier.c",
    "vendor/cglm/src/ray.c",
    "vendor/cglm/src/affine2d.c",
    "vendor/cglm/src/clipspace/ortho_lh_no.c",
    "vendor/cglm/src/clipspace/ortho_lh_zo.c",
    "vendor/cglm/src/clipspace/ortho_rh_no.c",
    "vendor/cglm/src/clipspace/ortho_rh_zo.c",
    "vendor/cglm/src/clipspace/persp_lh_no.c",
    "vendor/cglm/src/clipspace/persp_lh_zo.c",
    "vendor/cglm/src/clipspace/persp_rh_no.c",
    "vendor/cglm/src/clipspace/persp_rh_zo.c",
    "vendor/cglm/src/clipspace/view_lh_no.c",
    "vendor/cglm/src/clipspace/view_lh_zo.c",
    "vendor/cglm/src/clipspace/view_rh_no.c",
    "vendor/cglm/src/clipspace/view_rh_zo.c",
    "vendor/cglm/src/clipspace/project_no.c",
    "vendor/cglm/src/clipspace/project_zo.c",
};

/// Minimal FreeType sources for TTF and OpenType CFF rasterization. Optional compressed-font
/// modules are disabled in the vendored ftoption.h, so this remains dependency-free.
const freetype_sources = [_][]const u8{
    "vendor/freetype-2.15.0/src/autofit/autofit.c",
    "vendor/freetype-2.15.0/src/base/ftbase.c",
    "vendor/freetype-2.15.0/src/base/ftbbox.c",
    "vendor/freetype-2.15.0/src/base/ftbitmap.c",
    "vendor/freetype-2.15.0/src/base/ftglyph.c",
    "vendor/freetype-2.15.0/src/base/ftinit.c",
    "vendor/freetype-2.15.0/src/base/ftmm.c",
    "vendor/freetype-2.15.0/src/base/ftsystem.c",
    "vendor/freetype-2.15.0/src/base/ftdebug.c",
    "vendor/freetype-2.15.0/src/cff/cff.c",
    "vendor/freetype-2.15.0/src/psaux/psaux.c",
    "vendor/freetype-2.15.0/src/pshinter/pshinter.c",
    "vendor/freetype-2.15.0/src/psnames/psnames.c",
    "vendor/freetype-2.15.0/src/raster/raster.c",
    "vendor/freetype-2.15.0/src/sdf/sdf.c",
    "vendor/freetype-2.15.0/src/sfnt/sfnt.c",
    "vendor/freetype-2.15.0/src/smooth/smooth.c",
    "vendor/freetype-2.15.0/src/truetype/truetype.c",
};

/// Gives `module` cglm's headers and compiles cglm's C sources into it. Two macros must match the
/// @cImport in src/engine/core/math.zig, so the C library and the translated headers agree.
/// CGLM_ALL_UNALIGNED stops cglm from assuming 16-byte alignment, which Zig arrays don't guarantee.
/// CGLM_FORCE_DEPTH_ZERO_TO_ONE gives depth from 0 (near) to 1 (far), as SDL_GPU expects. Without
/// it, cglm's exported glmc_* functions would use depth from -1 to 1 while math.zig uses 0 to 1.
/// cglm's SIMD paths are off here. Zig's @cImport translates cglm's SIMD wrappers into calls to
/// helpers that are never defined, so the build would fail to link. The portable scalar code is
/// used on every target, and src/engine/core/math.zig undefines the same macros before its @cImport.
const cglm_simd_flags = [_][]const u8{
    "-U__SSE__",
    "-U__SSE2__",
    "-U__SSE3__",
    "-U__SSE4_1__",
    "-U__SSE4_2__",
    "-U__AVX__",
    "-U__ARM_NEON",
    "-U__ARM_NEON__",
    "-U__wasm_simd128__",
};

fn addCglm(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/cglm/include"));
    module.addCMacro("CGLM_ALL_UNALIGNED", "1");
    module.addCMacro("CGLM_FORCE_DEPTH_ZERO_TO_ONE", "1");
    for (cglm_sources) |path| {
        module.addCSourceFile(.{ .file = b.path(path), .flags = &cglm_simd_flags });
    }
}

fn addFreeType(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/freetype-2.15.0/include"));
    module.addCMacro("FT2_BUILD_LIBRARY", "1");
    for (freetype_sources) |path| module.addCSourceFile(.{ .file = b.path(path) });
}

fn configureEngineModule(
    b: *std.Build,
    module: *std.Build.Module,
    sdl: *std.Build.Dependency,
    ztracy: *std.Build.Dependency,
    options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    tracy_enabled: bool,
) void {
    module.linkLibrary(sdl.artifact("SDL3"));
    module.addOptions("build_options", options);
    module.addImport("ztracy", ztracy.module("root"));
    if (tracy_enabled) module.linkLibrary(ztracy.artifact("tracy"));
    if (tracy_enabled and target.result.os.tag == .windows) module.linkSystemLibrary("secur32", .{});

    module.addIncludePath(b.path("vendor"));
    module.addIncludePath(b.path("src/engine/ui"));
    module.addIncludePath(b.path("src/engine/text"));
    module.addIncludePath(b.path("src/engine/logging"));
    addFreeType(b, module);
    addCglm(b, module);
    module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    module.addCSourceFile(.{ .file = b.path("vendor/stb_truetype_impl.c") });
    module.addCSourceFile(.{ .file = b.path("src/engine/text/text.c") });
    module.addCSourceFile(.{ .file = b.path("src/engine/ui/imgui.c") });
    module.addCSourceFile(.{ .file = b.path("vendor/log.c") });
    module.addCSourceFile(.{ .file = b.path("src/engine/logging/log_file.c") });
}

/// One entry point of shaders/default.slang. To add a shader, add a row here, then declare a
/// `shader.Source` in the code that uses it.
const ShaderEntry = struct {
    /// Function name in the Slang source.
    entry: []const u8,
    /// Stage name that slangc expects: "vertex" or "fragment".
    stage: []const u8,
    /// Output file name without an extension, such as "default.vert".
    file: []const u8,
    /// Declaration name in the generated `embedded_shaders` module, such as "default_vert".
    /// A target's `suffix` is added to this name, so each format gets its own declaration.
    decl: []const u8,
};

const shader_entries = [_]ShaderEntry{
    .{ .entry = "vertexMain", .stage = "vertex", .file = "default.vert", .decl = "default_vert" },
    .{ .entry = "fragmentMain", .stage = "fragment", .file = "default.frag", .decl = "default_frag" },
};

/// One output format for every shader entry point.
const ShaderTarget = struct {
    /// File extension for the output, such as "spv" or "dxil".
    ext: []const u8,
    /// slangc arguments that select the target and profile.
    args: []const []const u8,
    /// Added to each declaration name for this format, such as "_dxil".
    suffix: []const u8,
    /// An extra slangc argument, or null. DXIL compiles pass -DDXIL_TARGET so the shader can pick
    /// the D3D12 register layout.
    define: ?[]const u8,
    /// Build option that enables this format, or null when it is always built.
    option: ?[]const u8,
};

const shader_targets = [_]ShaderTarget{
    .{
        .ext = "spv",
        .args = &.{ "-target", "spirv", "-profile", "spirv_1_5" },
        .suffix = "",
        .define = null,
        .option = null,
    },
    .{
        .ext = "dxil",
        .args = &.{ "-target", "dxil", "-profile", "sm_6_0" },
        .suffix = "_dxil",
        .define = "-DDXIL_TARGET",
        .option = "dxil",
    },
    .{
        .ext = "msl",
        .args = &.{ "-target", "metal" },
        .suffix = "_msl",
        .define = null,
        .option = "metal",
    },
};

fn shaderTargetEnabled(target: ShaderTarget, dxil_enabled: bool, metal_enabled: bool) bool {
    const option = target.option orelse return true;
    if (std.mem.eql(u8, option, "dxil")) return dxil_enabled;
    if (std.mem.eql(u8, option, "metal")) return metal_enabled;
    unreachable;
}

/// Source of the generated `embedded_shaders` module. Each compiled shader's bytes are copied into a
/// 4-byte-aligned global, because SPIR-V is read as 32-bit words. An optional format that isn't
/// built gets an empty slice. It is built at comptime from the tables above, so the module and the
/// compile steps can't disagree about names.
fn embeddedSource(b: *std.Build, dxil_enabled: bool, metal_enabled: bool) []const u8 {
    var source: []const u8 = "";
    inline for (shader_targets) |t| {
        inline for (shader_entries) |s| {
            const decl = s.decl ++ t.suffix;
            const text: []const u8 = if (!shaderTargetEnabled(t, dxil_enabled, metal_enabled))
                "pub const " ++ decl ++ ": []align(4) const u8 = &.{};\n"
            else
                "const " ++ decl ++ "_storage align(4) = @embedFile(\"" ++ s.file ++ "." ++ t.ext ++ "\").*;\n" ++
                    "pub const " ++ decl ++ ": []align(4) const u8 = &" ++ decl ++ "_storage;\n";
            source = std.mem.concat(b.allocator, u8, &.{ source, text }) catch @panic("out of memory");
        }
    }
    return source;
}

/// Sprite names and source paths are maintained by `zig build asset-import`; the build embeds this
/// manifest so imported images automatically enter the next atlas build.
const atlas_manifest = @embedFile("assets/sprites.txt");
/// General runtime assets are declared separately from the atlas packing inputs.
const asset_manifest = @embedFile("assets/asset_manifest.txt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Usage: zig build run -Dgpu-debug=true
    const gpu_debug = b.option(bool, "gpu-debug", "Enable SDL GPU validation layers") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "gpu_debug", gpu_debug);

    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    // Tracy profiling zones, through ztracy. Off by default, so a normal build has no profiler code.
    // `zig build run -Dtracy=true` builds Tracy into the game, so the Tracy profiler can connect to it.
    const tracy_enabled = b.option(bool, "tracy", "Record profiling zones for the Tracy profiler") orelse false;
    const ztracy = b.dependency("ztracy", .{ .enable_ztracy = tracy_enabled });

    const engine_module = b.createModule(.{
        .root_source_file = b.path("src/engine/bairava.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureEngineModule(b, engine_module, sdl, ztracy, options, target, tracy_enabled);

    const exe = b.addExecutable(.{
        .name = "Semkootru",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("bairava", engine_module);

    // Parson belongs to the game save module, not to the Bairava engine module.
    exe.root_module.addIncludePath(b.path("vendor"));
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/parson.c") });

    b.installArtifact(exe);

    // Sample game: a second executable that uses only the public Bairava API, so the scene system is
    // shown without any Semkootru code. Its one texture is installed beside it.
    const sample = b.addExecutable(.{
        .name = "BairavaSample",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sample.root_module.addImport("bairava", engine_module);
    b.installArtifact(sample);

    const install_sample_texture = b.addInstallFile(b.path("sample/assets/white.png"), "bin/assets/sample/white.png");
    b.getInstallStep().dependOn(&install_sample_texture.step);

    const run_sample = b.addRunArtifact(sample);
    run_sample.step.dependOn(b.getInstallStep());
    b.step("run-sample", "Build and run the scene sample").dependOn(&run_sample.step);

    // Texture atlas: every sprite in one image, packed at build time by tools/atlas/pack.c with
    // stb_rect_pack. The packer runs on the build machine, so it is built for the host, not the target.
    const atlas_tool = b.addExecutable(.{
        .name = "atlas_pack",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    atlas_tool.root_module.addIncludePath(b.path("vendor"));
    atlas_tool.root_module.addCSourceFile(.{ .file = b.path("tools/atlas/pack.c") });

    const pack = b.addRunArtifact(atlas_tool);
    const atlas_png = pack.addOutputFileArg("atlas.png");
    const atlas_index = pack.addOutputFileArg("atlas.txt");
    var sprite_lines = std.mem.tokenizeScalar(u8, atlas_manifest, '\n');
    while (sprite_lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        const file = fields.next() orelse @panic("assets/sprites.txt: missing image path");
        if (fields.next() != null) @panic("assets/sprites.txt: expected '<name> <image-path>' per line");
        pack.addArg(name);
        pack.addFileArg(b.path(file));
    }
    // The game reads the packed-region index beside the runtime asset directory.
    const install_atlas_index = b.addInstallFile(atlas_index, "bin/assets/atlas.txt");
    b.getInstallStep().dependOn(&install_atlas_index.step);

    // Validate, compress, and stage manifest assets plus the generated runtime atlas on the host.
    const asset_builder = b.addExecutable(.{
        .name = "asset_build",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    asset_builder.root_module.addIncludePath(b.path("vendor"));
    asset_builder.root_module.addIncludePath(b.path("src/engine/ui"));
    addFreeType(b, asset_builder.root_module);
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("tools/assets/build.c") });
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_truetype_impl.c") });
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("src/engine/text/text.c") });
    const run_asset_builder = b.addRunArtifact(asset_builder);
    run_asset_builder.addFileArg(b.path("assets/asset_manifest.txt"));
    const runtime_assets = run_asset_builder.addOutputDirectoryArg("runtime-assets");
    run_asset_builder.addArg("--include-image");
    run_asset_builder.addArg("atlas");
    run_asset_builder.addFileArg(atlas_png);
    run_asset_builder.addArg("atlas.png");
    run_asset_builder.addArg("-");
    var asset_lines = std.mem.tokenizeScalar(u8, asset_manifest, '\n');
    while (asset_lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "#")) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = fields.next() orelse continue;
        const kind = fields.next() orelse @panic("assets/asset_manifest.txt: missing type");
        const source = fields.next() orelse @panic("assets/asset_manifest.txt: missing source path");
        _ = fields.next() orelse @panic("assets/asset_manifest.txt: missing output path");
        _ = fields.next() orelse @panic("assets/asset_manifest.txt: missing dependencies");
        if (std.mem.eql(u8, kind, "font")) {
            _ = fields.next() orelse @panic("assets/asset_manifest.txt: font entry needs pixel height");
            _ = fields.next() orelse @panic("assets/asset_manifest.txt: font entry needs first codepoint");
            _ = fields.next() orelse @panic("assets/asset_manifest.txt: font entry needs glyph count");
            if (fields.next()) |mode| {
                if (!std.mem.eql(u8, mode, "bitmap") and !std.mem.eql(u8, mode, "sdf"))
                    @panic("assets/asset_manifest.txt: font mode must be bitmap or sdf");
            }
        }
        if (fields.next() != null) @panic("assets/asset_manifest.txt: expected five fields, or font pixel height, first codepoint, glyph count, and optional mode");
        run_asset_builder.addFileInput(b.path(source));
    }
    const install_runtime_assets = b.addInstallDirectory(.{
        .source_dir = runtime_assets,
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_runtime_assets.step);
    b.step("asset-build", "Validate and build compressed runtime assets from the manifest").dependOn(&run_asset_builder.step);

    // Portable, opt-in image tool for removing a checkerboard background. Build it for the host
    // so it can be used during development even when the game is cross-compiled for another OS.
    const asset_keyer = b.addExecutable(.{
        .name = "asset_keyer",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    asset_keyer.root_module.addIncludePath(b.path("vendor"));
    asset_keyer.root_module.addCSourceFile(.{ .file = b.path("tools/assets/keyer.c") });
    asset_keyer.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    const run_asset_keyer = b.addRunArtifact(asset_keyer);
    if (b.args) |args| run_asset_keyer.addArgs(args);
    b.step("asset-keyer", "Remove a checkerboard background from an image").dependOn(&run_asset_keyer.step);

    // Import an image into assets/imported and register it in the atlas source manifest.
    const asset_importer = b.addExecutable(.{
        .name = "asset_import",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    asset_importer.root_module.addCSourceFile(.{ .file = b.path("tools/assets/import.c") });
    asset_importer.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    const run_asset_importer = b.addRunArtifact(asset_importer);
    if (b.args) |args| run_asset_importer.addArgs(args);
    b.step("asset-import", "Copy and register an image for the sprite atlas").dependOn(&run_asset_importer.step);

    // Compile each shader entry point for each target, and embed the results in the executable
    // through a generated module, so the game reads no shader files at runtime. DXIL and MSL are
    // optional build targets; Vulkan SPIR-V is always present.
    const dxil_enabled = b.option(bool, "dxil", "Compile DXIL shaders for D3D12") orelse false;
    const metal_enabled = b.option(bool, "metal", "Compile MSL shaders for Metal") orelse false;
    const shader_files = b.addWriteFiles();
    inline for (shader_targets) |t| {
        if (shaderTargetEnabled(t, dxil_enabled, metal_enabled)) {
            inline for (shader_entries) |s| {
                const compile = b.addSystemCommand(&.{"slangc"});
                compile.addArgs(t.args);
                if (t.define) |d| compile.addArg(d);
                compile.addArgs(&.{ "-entry", s.entry, "-stage", s.stage });
                compile.addFileArg(b.path("shaders/default.slang"));
                compile.addArg("-o");
                const out = compile.addOutputFileArg(s.file ++ "." ++ t.ext);
                _ = shader_files.addCopyFile(out, s.file ++ "." ++ t.ext);
            }
        }
    }
    const embedded_source = embeddedSource(b, dxil_enabled, metal_enabled);
    const embedded_module = shader_files.add("embedded_shaders.zig", embedded_source);
    engine_module.addAnonymousImport("embedded_shaders", .{ .root_source_file = embedded_module });

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the app").dependOn(&run.step);

    // Unit tests don't open a window or create a GPU device, but renderer tests use SDL GPU structs.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCglm(b, test_module);
    // Renderer modules use SDL GPU declarations, and embedded shaders are needed to compile them.
    // Tests open no window and create no GPU device.
    test_module.linkLibrary(sdl.artifact("SDL3"));
    test_module.addAnonymousImport("embedded_shaders", .{ .root_source_file = embedded_module });
    // tests.zig imports the logger, so the test binary builds the log C code too. Zones compile to
    // nothing without -Dtracy, so the tests need only ztracy's Zig module, not the Tracy library.
    test_module.addIncludePath(b.path("vendor"));
    test_module.addIncludePath(b.path("src/engine/logging"));
    test_module.addCSourceFile(.{ .file = b.path("vendor/log.c") });
    test_module.addCSourceFile(.{ .file = b.path("vendor/parson.c") });
    test_module.addCSourceFile(.{ .file = b.path("src/engine/logging/log_file.c") });
    test_module.addImport("ztracy", ztracy.module("root"));
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));

    const api_test_module = b.createModule(.{
        .root_source_file = b.path("src/engine_api_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    api_test_module.addImport("bairava", engine_module);
    const api_tests = b.addTest(.{ .root_module = api_test_module });
    const run_api_tests = b.addRunArtifact(api_tests);
    run_api_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run unit tests (no GPU device or window; links SDL and needs slangc)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_api_tests.step);
}
