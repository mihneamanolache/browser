// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! `navigator.keyboard` — the Keyboard Map API.
//!
//! Desktop Chrome only, which is part of why fingerprinters read it: a
//! browser claiming desktop Chrome without it is caught for free, and one
//! that has it reports a map that says which physical layout is attached.
//! The layout comes from the profile's region (see
//! `fingerprint/keyboard.zig`), so an fr-FR identity gets an AZERTY map
//! rather than the American one every spoofing library hardcodes.
//!
//! `lock()`/`unlock()` are the Keyboard Lock half of the same interface.
//! They only matter in fullscreen, which does not exist here, so lock
//! resolves and unlock does nothing — the point is that the methods are
//! present with the right names and arities.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Execution = js.Execution;
const Frame = @import("../Frame.zig");

const fingerprint = lp.fingerprint;
const keyboard_layouts = fingerprint.keyboard_layouts;

const log = lp.log;

pub fn registerTypes() []const type {
    return &.{
        Keyboard,
        KeyboardLayoutMap,
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

const Keyboard = @This();

comptime {
    // A JS-visible member at offset 0 would alias its container in the
    // identity map, so the two would be the same object to JS.
    if (@offsetOf(Keyboard, "_layout_map") == 0) {
        @compileError("_layout_map aliases the Keyboard");
    }
}

/// Sorts before `_layout_map` because it is the higher-aligned field, which
/// is what keeps the map off offset 0.
_pad: u64 = 0,
_layout_map: KeyboardLayoutMap = .{},

/// Resolves with the map for the attached layout. Chrome returns a promise
/// because a real implementation asks the OS; ours is already known.
fn getLayoutMap(self: *Keyboard, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(&self._layout_map);
}

/// Keyboard Lock. Outside fullscreen Chrome rejects, but nothing here is ever
/// in fullscreen and a rejected promise no page handles is noisier than a
/// resolved one that changed nothing.
fn lock(_: *Keyboard, _: ?[]const []const u8, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

fn unlock(_: *Keyboard) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Keyboard);

    pub const Meta = struct {
        pub const name = "Keyboard";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getLayoutMap = bridge.function(Keyboard.getLayoutMap, .{});
    pub const lock = bridge.function(Keyboard.lock, .{});
    pub const unlock = bridge.function(Keyboard.unlock, .{});
};

/// A readonly maplike of `KeyboardEvent.code` to the character that key
/// produces. Holds no state: the entries are the active region's layout, and
/// the region does not change after startup.
pub const KeyboardLayoutMap = struct {
    _pad: bool = false,

    fn entriesFor() []const keyboard_layouts.Entry {
        return keyboard_layouts.layout(fingerprint.keyboard());
    }

    pub fn get(_: *const KeyboardLayoutMap, code: []const u8) ?[]const u8 {
        for (entriesFor()) |e| {
            if (std.mem.eql(u8, e.code, code)) return e.key;
        }
        return null;
    }

    pub fn has(self: *const KeyboardLayoutMap, code: []const u8) bool {
        return self.get(code) != null;
    }

    pub fn getSize(_: *const KeyboardLayoutMap) u32 {
        return @intCast(entriesFor().len);
    }

    pub fn keys(self: *KeyboardLayoutMap, frame: *Frame) !*KeyIterator {
        return .init(.{ .map = self }, frame);
    }

    pub fn values(self: *KeyboardLayoutMap, frame: *Frame) !*ValueIterator {
        return .init(.{ .map = self }, frame);
    }

    pub fn entries(self: *KeyboardLayoutMap, frame: *Frame) !*EntryIterator {
        return .init(.{ .map = self }, frame);
    }

    pub fn forEach(self: *KeyboardLayoutMap, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

        for (entriesFor()) |e| {
            var caught: js.TryCatch.Caught = .{};
            // Maplike order is (value, key, map), same as Map#forEach.
            cb.tryCall(void, .{ e.key, e.code, self }, &caught) catch {
                log.debug(.js, "forEach callback", .{ .caught = caught, .source = "KeyboardLayoutMap" });
            };
        }
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(KeyboardLayoutMap);

        pub const Meta = struct {
            pub const name = "KeyboardLayoutMap";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const get = bridge.function(KeyboardLayoutMap.get, .{});
        pub const has = bridge.function(KeyboardLayoutMap.has, .{});
        pub const size = bridge.accessor(KeyboardLayoutMap.getSize, null, .{});
        pub const keys = bridge.function(KeyboardLayoutMap.keys, .{});
        pub const values = bridge.function(KeyboardLayoutMap.values, .{});
        pub const entries = bridge.function(KeyboardLayoutMap.entries, .{});
        pub const forEach = bridge.function(KeyboardLayoutMap.forEach, .{});
        pub const symbol_iterator = bridge.iterator(KeyboardLayoutMap.entries, .{});
    };
};

pub const Iterator = struct {
    index: u32 = 0,
    map: *KeyboardLayoutMap,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *const Frame) ?Iterator.Entry {
        const entries = KeyboardLayoutMap.entriesFor();
        const index = self.index;
        if (index >= entries.len) {
            return null;
        }
        self.index = index + 1;
        return .{ entries[index].code, entries[index].key };
    }
};

const GenericIterator = @import("collections/iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);
