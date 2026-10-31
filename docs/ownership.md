# Ownership and error rules

These rules cover `engine.run`, the memory it creates, the resources a game receives, and how
failures are reported. The code they describe is in `src/engine/core/runtime.zig`,
`allocators.zig`, `lifecycle.zig`, and `context.zig`.

## Memory

The caller owns the parent allocator, `Config.allocator`, which defaults to the page allocator.
`run` creates four arenas from it and returns their memory to it when the run ends:

| Arena | Exposed as | Lifetime |
|---|---|---|
| engine | (internal) | The whole run. Settings text, the target, sprite batches, and the debug overlay use it. |
| game | `ctx.allocators.game` | The game instance. Use it for state that lives across updates. |
| asset | `ctx.allocators.asset` | The whole run. Loaded textures, atlases, levels, fonts, and sounds use it. |
| frame | `ctx.allocators.frame` | One loop iteration. It is reset before each frame, so don't keep pointers into it. |

Asset memory is not returned to the system until the run ends. There is no unload yet, so a
game should load an asset once and keep it.

## Resources handed to the game

The session owns the window, the GPU device, the native target, the sprite batches, and the audio
device. The game receives the resources below. It owns each one from the moment it is returned and
must release it.

| Resource | Created by | Released by |
|---|---|---|
| Texture | `ctx.loadTexture` | `Texture.deinit`, or the atlas that holds it |
| Atlas | `ctx.loadAtlas` | `LoadedAtlas.deinit` |
| UI font | `ctx.loadFont`, then passed to `ui.Ui.init` | `Ui.deinit` |
| Sound | `ctx.loadSound` | `Sound.deinit` |
| File bytes | `ctx.readFile(allocator, ...)` | the caller, with the same allocator |

The debug overlay takes ownership of its font when it is created, and `Overlay.deinit` frees it.

## Teardown order

`run` registers its cleanup in the order it opens things, and Zig runs deferred cleanup in reverse.
The shutdown order is therefore:

1. The debug overlay is released.
2. `Game.deinit` runs, so the game releases its textures while the device still exists.
3. `Session.stop` runs: audio, sprite batches, target, GPU device, window, then SDL.
4. The arenas are released.
5. The log file is closed.

A game's `deinit` must release everything it loaded. The engine tears down the device right after
it, so any resource the game keeps past that point will reference a destroyed device.

A panic does not run deferred cleanup. The process aborts, and the operating system reclaims the
memory. The panic message is written to the log file first.

## Startup

`Session.start` opens resources in dependency order. Each fallible step records that it succeeded,
and an `errdefer` releases everything recorded so far. A failed start therefore leaves the session
stopped. The config is validated before any platform resource is created.

If `Game.init` fails, `run` does not call `Game.deinit`. `init` must release what it opened before
the failing step, using `errdefer` as `game/game.zig` does.

## Errors

| Situation | Handling |
|---|---|
| Invalid config, window or GPU device creation failure, or `Game.init` failure | Logged, cleaned up, and returned from `run`. The caller decides the exit status. |
| Missing or malformed asset | Returned as an `AssetError` from the `Context` loaders. The game decides whether it is fatal. |
| No audio device | Not an error. The game runs silent, and sound loads return `error.NoDevice`. |
| GPU resource creation after the device is up (textures, shaders, pipelines, buffers) | Panics with the SDL message. The engine cannot continue without these. |
| Broken invariant or programmer error | `engine.log.assert` (Debug and ReleaseSafe) or `engine.log.fail` (every build mode). Don't use `std.debug.assert`. |

## Open items

- Asset memory is never freed early (see Memory). Unload comes with P1.5.
- Device-lost recovery is not implemented.
- No test starts a real window or GPU device. Startup ordering is covered by review, not by an
  automated test.
