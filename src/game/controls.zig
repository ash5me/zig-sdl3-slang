//! Named actions and the keys bound to them. Gameplay asks for actions and never for keys.
//! The keys in `defaultKeys` are the defaults. The settings file rebinds an action with a `bind`
//! line, such as `bind move_left = left, a`, and that replaces the action's keys. Key names are
//! the enum names of `Key` in src/engine/input/input.zig.

const std = @import("std");

const engine = @import("bairava");

const log = engine.log.scoped("controls");

/// Everything the player can ask for through input. Add a name here, then give it default keys in
/// `defaultKeys`. The settings file can bind it with a `bind` line.
pub const Action = enum {
    move_left,
    move_right,
    move_up,
    move_down,
    quit,
    toggle_scale,
    zoom_in,
    zoom_out,
    zoom_reset,
    save_game,
    load_game,
};

const action_count = std.enums.values(Action).len;

// The default keys. An action is active when any of its keys is.
const move_left_keys = [_]engine.Key{ .left, .a };
const move_right_keys = [_]engine.Key{ .right, .d };
const move_up_keys = [_]engine.Key{ .up, .w };
const move_down_keys = [_]engine.Key{ .down, .s };
const quit_keys = [_]engine.Key{.escape};
const toggle_scale_keys = [_]engine.Key{.i};
const zoom_in_keys = [_]engine.Key{ .equal, .keypad_plus };
const zoom_out_keys = [_]engine.Key{ .minus, .keypad_minus };
const zoom_reset_keys = [_]engine.Key{.zero};
const save_game_keys = [_]engine.Key{.f5};
const load_game_keys = [_]engine.Key{.f9};

/// The default keys for an action. The switch has no default, so an action without keys is a compile error.
fn defaultKeys(action: Action) []const engine.Key {
    return switch (action) {
        .move_left => &move_left_keys,
        .move_right => &move_right_keys,
        .move_up => &move_up_keys,
        .move_down => &move_down_keys,
        .quit => &quit_keys,
        .toggle_scale => &toggle_scale_keys,
        .zoom_in => &zoom_in_keys,
        .zoom_out => &zoom_out_keys,
        .zoom_reset => &zoom_reset_keys,
        .save_game => &save_game_keys,
        .load_game => &load_game_keys,
    };
}

/// The keys each action responds to, after the settings file has been read.
pub const Bindings = struct {
    keys: [action_count][engine.settings.max_keys_per_action]engine.Key,
    counts: [action_count]usize,

    /// Starts from the default keys, then applies the `bind` lines in the settings text. An action
    /// keeps its defaults unless a valid `bind` line names it. Problems are logged.
    pub fn load(text: []const u8) Bindings {
        var bindings = defaults();
        var lines = engine.settings.Lines.init(text);
        while (lines.next()) |line| {
            const value = line.value orelse {
                log.warn("settings line {d}: '{s}' has no '=', so it is ignored", .{ line.number, line.key });
                continue;
            };
            if (std.mem.startsWith(u8, line.key, "bind ")) {
                bindings.bind(line.number, line.key["bind ".len..], value);
            } else if (!engine.settings.isWindowKey(line.key)) {
                log.warn("settings line {d}: unknown setting '{s}'", .{ line.number, line.key });
            }
        }
        return bindings;
    }

    /// The default keys for every action.
    pub fn defaults() Bindings {
        var bindings: Bindings = undefined;
        for (std.enums.values(Action)) |action| {
            const index = @intFromEnum(action);
            const keys = defaultKeys(action);
            // A capacity limit, so it must hold in every build mode: the copy below would overflow.
            if (keys.len > engine.settings.max_keys_per_action) {
                engine.log.fail(@src(), "action {s} has {d} default keys, above the limit of {d}", .{ @tagName(action), keys.len, engine.settings.max_keys_per_action });
            }
            @memcpy(bindings.keys[index][0..keys.len], keys);
            bindings.counts[index] = keys.len;
        }
        return bindings;
    }

    /// Replaces the keys of the action named `name_text`. A bad name or an empty key list is
    /// logged, and the action keeps its keys.
    fn bind(self: *Bindings, number: usize, name_text: []const u8, value: []const u8) void {
        const name = std.mem.trim(u8, name_text, " \t");
        const action = std.meta.stringToEnum(Action, name) orelse {
            log.warn("settings line {d}: '{s}' is not an action", .{ number, name });
            return;
        };
        const list = engine.settings.parseKeyList(value);
        if (list.skipped > 0) {
            log.warn("settings line {d}: {d} key name(s) not recognized or past the limit of {d} keys, so they are dropped", .{ number, list.skipped, engine.settings.max_keys_per_action });
        }
        if (list.len == 0) {
            log.warn("settings line {d}: '{s}' has no valid keys, so its defaults stay", .{ number, name });
            return;
        }
        const index = @intFromEnum(action);
        @memcpy(self.keys[index][0..list.len], list.keys[0..list.len]);
        self.counts[index] = list.len;
    }

    /// The keys bound to `action`.
    fn keysFor(self: *const Bindings, action: Action) []const engine.Key {
        const index = @intFromEnum(action);
        return self.keys[index][0..self.counts[index]];
    }

    /// True while any key bound to `action` is held.
    pub fn held(self: *const Bindings, input: *const engine.Input, action: Action) bool {
        return input.anyHeld(self.keysFor(action));
    }

    /// True during the update step that first sees any key bound to `action` go down.
    pub fn pressed(self: *const Bindings, input: *const engine.Input, action: Action) bool {
        return input.anyPressed(self.keysFor(action));
    }

    /// True during the update step that first sees any key bound to `action` go up.
    pub fn released(self: *const Bindings, input: *const engine.Input, action: Action) bool {
        return input.anyReleased(self.keysFor(action));
    }
};
