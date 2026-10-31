//! The scene contract. A scene is a struct with four methods:
//!
//!     pub fn init(ctx: *Ctx) !Self
//!     pub fn update(self: *Self, ctx: *Ctx, nav: *Navigator) void
//!     pub fn draw(self: *Self, dc: *const DrawCtx) void
//!     pub fn deinit(self: *Self) void
//!
//! `Ctx` and `DrawCtx` are the engine's context types, and `nav` is the handle a scene uses to ask
//! for a change of scene (see scene_manager.zig). `init` runs once, before the first update, and
//! `deinit` runs once after a successful `init`, when the scene is replaced or the manager shuts
//! down. A scene must not keep `ctx`, `dc`, or `nav` after the call that received them.

/// Fails the build, naming the scene and the method, when `T` lacks one of the four methods or one
/// of them takes the wrong number of parameters. The parameter types are checked where the scene
/// is used, so a mismatched type fails there with the compiler's own message.
pub fn assertScene(comptime T: type) void {
    expectMethod(T, "init", 1);
    expectMethod(T, "update", 3);
    expectMethod(T, "draw", 2);
    expectMethod(T, "deinit", 1);
}

fn expectMethod(comptime T: type, comptime name: []const u8, comptime param_count: usize) void {
    if (!@hasDecl(T, name)) {
        @compileError("scene " ++ @typeName(T) ++ " has no `" ++ name ++ "` method");
    }
    const info = @typeInfo(@TypeOf(@field(T, name))).@"fn";
    if (info.params.len != param_count) {
        @compileError("scene " ++ @typeName(T) ++ "." ++ name ++ " has the wrong number of parameters");
    }
}
