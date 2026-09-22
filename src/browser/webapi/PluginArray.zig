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

//! `navigator.plugins` and `navigator.mimeTypes`.
//!
//! Chrome froze both lists in Chrome 94: five plugin entries, all of them
//! aliases for the same built-in PDF viewer, each advertising the same two
//! MIME types. The contents carry no information about the machine, so
//! reporting them costs nothing — but reporting *nothing* is itself
//! distinctive, which is why these are no longer empty.
//!
//! Chrome guarantees `navigator.plugins[0] === navigator.plugins[0]` and
//! `navigator.mimeTypes[0] === navigator.plugins[0][0]`, so every object
//! here is allocated once, up front, and handed out by pointer. Allocating
//! per lookup would break both identities. They are separate allocations
//! rather than fields nested in one struct because the identity map keys on
//! address: a nested object at offset 0 would share an address with its
//! container, which is two different types at one key.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const GenericIterator = @import("collections/iterator.zig").Entry;

const fingerprint = lp.fingerprint;

pub fn registerTypes() []const type {
    return &.{
        PluginArray,
        Plugin,
        MimeTypeArray,
        MimeType,
        PluginIterator,
        MimeTypeIterator,
    };
}

const PluginArray = @This();

// Only pointers: `&self._plugins` is never handed to JS, so this array
// sitting at offset 0 is harmless.
_plugins: [fingerprint.plugins.len]*Plugin,
_mime_types: *MimeTypeArray,

/// Builds the whole graph in one go: the plugins, the MIME types, and the
/// back-references that let a Plugin enumerate MIME types and a MimeType
/// name its plugin. Two-phase because the two arrays point at each other.
pub fn init(frame: *Frame) !*PluginArray {
    const self = try frame._factory.create(PluginArray{
        ._plugins = undefined,
        ._mime_types = undefined,
    });

    for (&self._plugins, 0..) |*slot, i| {
        slot.* = try frame._factory.create(Plugin{ ._index = i, ._owner = self });
    }

    const mime_types = try frame._factory.create(MimeTypeArray{
        ._mime_types = undefined,
        ._owner = self,
    });
    for (&mime_types._mime_types, 0..) |*slot, i| {
        slot.* = try frame._factory.create(MimeType{ ._index = i, ._owner = self });
    }

    self._mime_types = mime_types;
    return self;
}

pub fn getMimeTypes(self: *PluginArray) *MimeTypeArray {
    return self._mime_types;
}

/// Historically re-scanned the plugin directory. The list is fixed, so
/// there is nothing to re-scan.
pub fn refresh(_: *const PluginArray) void {}

pub fn getAtIndex(self: *PluginArray, index: usize) ?*Plugin {
    if (index >= self._plugins.len) {
        return null;
    }
    return self._plugins[index];
}

pub fn getByName(self: *PluginArray, name: []const u8) ?*Plugin {
    for (fingerprint.plugins, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) {
            return self._plugins[i];
        }
    }
    return null;
}

fn values(self: *PluginArray, frame: *Frame) !*PluginIterator {
    return .init(.{ ._array = self }, frame);
}

fn getIndexes(_: *PluginArray, frame: *Frame) !js.Array {
    var arr = frame.js.local.?.newArray(fingerprint.plugins.len);
    for (0..fingerprint.plugins.len) |i| {
        _ = try arr.set(@intCast(i), i, .{});
    }
    return arr;
}

const PluginIterator = GenericIterator(struct {
    _array: *PluginArray,
    _index: usize = 0,

    pub fn next(self: *@This(), _: *Frame) ?*Plugin {
        defer self._index += 1;
        return self._array.getAtIndex(self._index);
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(PluginArray);

    pub const Meta = struct {
        pub const name = "PluginArray";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.property(fingerprint.plugins.len, .{ .template = false });
    pub const refresh = bridge.function(PluginArray.refresh, .{});
    pub const @"[int]" = bridge.indexed(PluginArray.getAtIndex, PluginArray.getIndexes, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(PluginArray.getByName, null, null, null, struct {
        // [LegacyUnenumerableNamedProperties]: the names resolve but never
        // show up in Object.keys / for-in, matching Chrome.
        fn wrap(self: *PluginArray, name: []const u8) !u32 {
            if (self.getByName(name) != null) {
                return js.v8.DontEnum;
            }
            return error.NotHandled;
        }
    }.wrap, .{ .null_as_undefined = true });

    pub const item = bridge.function(struct {
        fn wrap(self: *PluginArray, index: i32) ?*Plugin {
            if (index < 0) {
                return null;
            }
            return self.getAtIndex(@intCast(index));
        }
    }.wrap, .{});

    pub const namedItem = bridge.function(PluginArray.getByName, .{});
    pub const symbol_iterator = bridge.iterator(PluginArray.values, .{});
};

/// One entry of `navigator.plugins`. Also a collection in its own right:
/// the MIME types it handles, which for every entry is the full list.
pub const Plugin = struct {
    _index: usize,
    _owner: *PluginArray,

    fn info(self: *const Plugin) fingerprint.Plugin {
        return fingerprint.plugins[self._index];
    }

    fn getName(self: *const Plugin) []const u8 {
        return self.info().name;
    }

    fn getFilename(self: *const Plugin) []const u8 {
        return self.info().filename;
    }

    fn getDescription(self: *const Plugin) []const u8 {
        return self.info().description;
    }

    // Every plugin advertises the same two types, and script compares them
    // by identity, so they all share one array.
    fn getAtIndex(self: *Plugin, index: usize) ?*MimeType {
        return self._owner.getMimeTypes().getAtIndex(index);
    }

    fn getByName(self: *Plugin, name: []const u8) ?*MimeType {
        return self._owner.getMimeTypes().getByName(name);
    }

    fn values(self: *Plugin, frame: *Frame) !*MimeTypeIterator {
        return self._owner.getMimeTypes().values(frame);
    }

    fn getIndexes(_: *Plugin, frame: *Frame) !js.Array {
        var arr = frame.js.local.?.newArray(fingerprint.mime_types.len);
        for (0..fingerprint.mime_types.len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Plugin);

        pub const Meta = struct {
            pub const name = "Plugin";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(Plugin.getName, null, .{});
        pub const filename = bridge.accessor(Plugin.getFilename, null, .{});
        pub const description = bridge.accessor(Plugin.getDescription, null, .{});
        pub const length = bridge.property(fingerprint.mime_types.len, .{ .template = false });

        pub const @"[int]" = bridge.indexed(Plugin.getAtIndex, Plugin.getIndexes, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(Plugin.getByName, null, null, null, struct {
            fn wrap(self: *Plugin, mime: []const u8) !u32 {
                if (self.getByName(mime) != null) {
                    return js.v8.DontEnum;
                }
                return error.NotHandled;
            }
        }.wrap, .{ .null_as_undefined = true });

        pub const item = bridge.function(struct {
            fn wrap(self: *Plugin, index: i32) ?*MimeType {
                if (index < 0) {
                    return null;
                }
                return self.getAtIndex(@intCast(index));
            }
        }.wrap, .{});

        pub const namedItem = bridge.function(Plugin.getByName, .{});
        pub const symbol_iterator = bridge.iterator(Plugin.values, .{});
    };
};

/// `navigator.mimeTypes`, and the MIME type list every `Plugin` exposes.
pub const MimeTypeArray = struct {
    _mime_types: [fingerprint.mime_types.len]*MimeType,
    _owner: *PluginArray,

    pub fn getAtIndex(self: *MimeTypeArray, index: usize) ?*MimeType {
        if (index >= self._mime_types.len) {
            return null;
        }
        return self._mime_types[index];
    }

    pub fn getByName(self: *MimeTypeArray, name: []const u8) ?*MimeType {
        for (fingerprint.mime_types, 0..) |m, i| {
            if (std.mem.eql(u8, m.type, name)) {
                return self._mime_types[i];
            }
        }
        return null;
    }

    fn values(self: *MimeTypeArray, frame: *Frame) !*MimeTypeIterator {
        return .init(.{ ._array = self }, frame);
    }

    fn getIndexes(_: *MimeTypeArray, frame: *Frame) !js.Array {
        var arr = frame.js.local.?.newArray(fingerprint.mime_types.len);
        for (0..fingerprint.mime_types.len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeTypeArray);

        pub const Meta = struct {
            pub const name = "MimeTypeArray";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const length = bridge.property(fingerprint.mime_types.len, .{ .template = false });
        pub const @"[int]" = bridge.indexed(MimeTypeArray.getAtIndex, MimeTypeArray.getIndexes, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(MimeTypeArray.getByName, null, null, null, struct {
            fn wrap(self: *MimeTypeArray, name: []const u8) !u32 {
                if (self.getByName(name) != null) {
                    return js.v8.DontEnum;
                }
                return error.NotHandled;
            }
        }.wrap, .{ .null_as_undefined = true });

        pub const item = bridge.function(struct {
            fn wrap(self: *MimeTypeArray, index: i32) ?*MimeType {
                if (index < 0) {
                    return null;
                }
                return self.getAtIndex(@intCast(index));
            }
        }.wrap, .{});

        pub const namedItem = bridge.function(MimeTypeArray.getByName, .{});
        pub const symbol_iterator = bridge.iterator(MimeTypeArray.values, .{});
    };
};

pub const MimeType = struct {
    _index: usize,
    _owner: *PluginArray,

    fn info(self: *const MimeType) fingerprint.MimeType {
        return fingerprint.mime_types[self._index];
    }

    fn getType(self: *const MimeType) []const u8 {
        return self.info().type;
    }

    fn getSuffixes(self: *const MimeType) []const u8 {
        return self.info().suffixes;
    }

    fn getDescription(self: *const MimeType) []const u8 {
        return self.info().description;
    }

    /// Chrome points every frozen MIME type at the first plugin entry,
    /// "PDF Viewer", rather than at whichever alias was used to reach it.
    fn getEnabledPlugin(self: *MimeType) ?*Plugin {
        return self._owner.getAtIndex(0);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeType);

        pub const Meta = struct {
            pub const name = "MimeType";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(MimeType.getType, null, .{});
        pub const suffixes = bridge.accessor(MimeType.getSuffixes, null, .{});
        pub const description = bridge.accessor(MimeType.getDescription, null, .{});
        pub const enabledPlugin = bridge.accessor(MimeType.getEnabledPlugin, null, .{});
    };
};

const MimeTypeIterator = GenericIterator(struct {
    _array: *MimeTypeArray,
    _index: usize = 0,

    pub fn next(self: *@This(), _: *Frame) ?*MimeType {
        defer self._index += 1;
        return self._array.getAtIndex(self._index);
    }
}, null);

const testing = @import("../../testing.zig");
test "WebApi: PluginArray" {
    try testing.htmlRunner("plugins.html", .{});
}
