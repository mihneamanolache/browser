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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const Parser = @import("../../css/Parser.zig");
const CSSRule = @import("CSSRule.zig");
const GenericIterator = @import("../collections/iterator.zig").Entry;

const FontFace = @import("FontFace.zig");

const FontFaceSet = @This();

pub const Proto = EventTarget;
pub fn registerTypes() []const type {
    return &.{ FontFaceSet, ValueIterator };
}

_rc: lp.RC = .{},
_proto: *EventTarget,
_arena: *lp.Arena,
_author_faces: std.ArrayList(*FontFace) = .empty,
_css_faces: std.AutoHashMapUnmanaged(*CSSRule, *FontFace) = .empty,
_ready_resolver: ?js.PromiseResolver.Global = null,
_loading_count: usize = 0,
_load_failed: bool = false,

pub fn init(frame: *Frame) !*FontFaceSet {
    const arena = try frame.getArena(.tiny, "FontFaceSet");
    errdefer arena.release();

    return frame._factory.eventTargetWithAllocator(arena.allocator(), FontFaceSet{
        ._proto = undefined,
        ._arena = arena,
    });
}

pub fn deinit(self: *FontFaceSet, page: *Page) void {
    if (self._ready_resolver) |resolver| resolver.deinit();
    for (self._author_faces.items) |face| face.releaseRef(page);
    self._author_faces.deinit(self._arena.allocator());
    var it = self._css_faces.valueIterator();
    while (it.next()) |face| face.*.releaseRef(page);
    self._css_faces.deinit(self._arena.allocator());
    self._arena.release();
}

pub fn releaseRef(self: *FontFaceSet, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FontFaceSet) void {
    self._rc.acquire();
}

pub fn asEventTarget(self: *FontFaceSet) *EventTarget {
    return self._proto;
}

pub fn getReady(self: *FontFaceSet, frame: *Frame) !js.Promise {
    const local = frame.js.local.?;
    if (self._ready_resolver) |resolver| return local.toLocal(resolver).promise();
    const resolver = local.createPromiseResolver();
    self._ready_resolver = try resolver.persist();
    if (self._loading_count == 0) resolver.resolve("FontFaceSet.ready", self);
    return resolver.promise();
}

fn getStatus(self: *const FontFaceSet) []const u8 {
    return if (self._loading_count == 0) "loaded" else "loading";
}

fn trimFamily(value: []const u8) []const u8 {
    var family = std.mem.trim(u8, value, " \t\r\n");
    if (family.len >= 2 and ((family[0] == '\'' and family[family.len - 1] == '\'') or
        (family[0] == '"' and family[family.len - 1] == '"')))
    {
        family = family[1 .. family.len - 1];
    }
    return family;
}

fn matches(font: []const u8, family: []const u8) bool {
    const trimmed = std.mem.trim(u8, font, " \t\r\n");
    if (trimmed.len < family.len) return false;
    const suffix = trimmed[trimmed.len - family.len ..];
    if (!std.ascii.eqlIgnoreCase(suffix, family)) return false;
    if (trimmed.len == family.len) return true;
    const before = trimmed[trimmed.len - family.len - 1];
    return std.ascii.isWhitespace(before) or before == '\'' or before == '"';
}

fn faceFromRule(rule: *CSSRule, base_url: []const u8, frame: *Frame) !?*FontFace {
    const open = std.mem.indexOfScalar(u8, rule._text, '{') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, rule._text, '}') orelse return null;
    if (close <= open) return null;
    var declarations = Parser.parseDeclarationsList(rule._text[open + 1 .. close]);
    var family: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    while (declarations.next()) |declaration| {
        if (std.ascii.eqlIgnoreCase(declaration.name, "font-family")) family = trimFamily(declaration.value);
        if (std.ascii.eqlIgnoreCase(declaration.name, "src")) source = declaration.value;
    }
    if (family == null or source == null) return null;
    const face = try FontFace.initWithBase(family.?, source.?, base_url, frame);
    errdefer face.deinit(frame.page);
    declarations = Parser.parseDeclarationsList(rule._text[open + 1 .. close]);
    while (declarations.next()) |declaration| {
        try face.setCssDescriptor(declaration.name, declaration.value);
    }
    return face;
}

fn syncCssFaces(self: *FontFaceSet, frame: *Frame) !void {
    const allocator = self._arena.allocator();
    var seen: std.AutoHashMapUnmanaged(*CSSRule, void) = .empty;
    defer seen.deinit(allocator);
    const sheets = try frame.document.getStyleSheets(frame);
    for (sheets._sheets.items) |sheet| {
        if (sheet._disabled) continue;
        const rules = try sheet.getCssRules(frame);
        for (rules._rules.items) |rule| {
            if (rule._type != .font_face) continue;
            try seen.put(allocator, rule, {});
            if (self._css_faces.contains(rule)) continue;
            const face = try faceFromRule(rule, sheet._href orelse frame.base(), frame) orelse continue;
            face.acquireRef();
            try self._css_faces.put(allocator, rule, face);
        }
    }
    var removed: std.ArrayList(*CSSRule) = .empty;
    defer removed.deinit(allocator);
    var it = self._css_faces.iterator();
    while (it.next()) |entry| {
        if (!seen.contains(entry.key_ptr.*)) try removed.append(allocator, entry.key_ptr.*);
    }
    for (removed.items) |rule| {
        const face = self._css_faces.fetchRemove(rule).?.value;
        face.releaseRef(frame.page);
    }
}

pub fn getSize(self: *FontFaceSet, frame: *Frame) !u32 {
    try self.syncCssFaces(frame);
    return @intCast(self._author_faces.items.len + self._css_faces.count());
}

pub fn has(self: *FontFaceSet, face: *FontFace, frame: *Frame) !bool {
    try self.syncCssFaces(frame);
    for (self._author_faces.items) |item| if (item == face) return true;
    var it = self._css_faces.valueIterator();
    while (it.next()) |item| if (item.* == face) return true;
    return false;
}

pub fn check(self: *FontFaceSet, font: []const u8, frame: *Frame) !bool {
    try self.syncCssFaces(frame);
    for (self._author_faces.items) |face| {
        if (matches(font, face._family) and face._status != .loaded) return false;
    }
    var it = self._css_faces.valueIterator();
    while (it.next()) |face| {
        if (matches(font, face.*._family) and face.*._status != .loaded) return false;
    }
    return true;
}

pub fn load(self: *FontFaceSet, font: []const u8, frame: *Frame) !js.Promise {
    try self.syncCssFaces(frame);
    var matched: std.ArrayList(*FontFace) = .empty;
    defer matched.deinit(frame.local_arena);
    for (self._author_faces.items) |face| {
        if (matches(font, face._family)) try matched.append(frame.local_arena, face);
    }
    var it = self._css_faces.valueIterator();
    while (it.next()) |face| {
        if (matches(font, face.*._family)) try matched.append(frame.local_arena, face.*);
    }
    if (matched.items.len == 0) return frame.js.local.?.resolvePromise(matched.items);
    for (matched.items) |face| face.acquireRef();
    defer for (matched.items) |face| face.releaseRef(frame.page);

    const needs_loading = for (matched.items) |face| {
        if (face._status == .unloaded or face._status == .loading) break true;
    } else false;
    if (needs_loading) {
        if (self._loading_count == 0) {
            if (self._ready_resolver) |resolver| resolver.deinit();
            self._ready_resolver = null;
            self._load_failed = false;
        }
        self._loading_count += 1;
    }
    errdefer {
        if (needs_loading) self._loading_count -= 1;
    }
    var promises: std.ArrayList(js.Promise) = .empty;
    defer promises.deinit(frame.local_arena);
    for (matched.items) |face| try promises.append(frame.local_arena, try face.load(frame));

    const local = frame.js.local.?;
    const constructor = (try local.exec("Promise", null)).toObject();
    const all = try constructor.getFunction("all") orelse return error.MethodNotFound;
    const aggregate_value = try all.callWithThis(js.Value, constructor, .{promises.items});
    if (!aggregate_value.isPromise()) return error.InvalidArgument;
    const aggregate: js.Promise = .{ .local = local, .handle = @ptrCast(aggregate_value.handle) };
    if (!needs_loading) return aggregate;
    const notification = try frame._factory.create(LoadNotification{ .set = self, .frame = frame });
    // Document owns the set for the lifetime of this frame. A pending font
    // request can be aborted during frame teardown, in which case its JS
    // aggregate never settles and this callback never runs. Holding another
    // RC reference here would leak the set (and all of its CSS FontFaces).
    errdefer frame._factory.destroy(notification);
    _ = try aggregate.thenAndCatch(
        local.newCallback(LoadNotification.onFulfilled, notification),
        local.newCallback(LoadNotification.onRejected, notification),
    );
    return aggregate;
}

const LoadNotification = struct {
    set: *FontFaceSet,
    frame: *Frame,

    fn onFulfilled(self: *LoadNotification, _: js.Value) void {
        self.finish(false);
    }

    fn onRejected(self: *LoadNotification, _: js.Value) void {
        self.finish(true);
    }

    fn finish(self: *LoadNotification, failed: bool) void {
        const frame = self.frame;
        const set = self.set;
        set._load_failed = set._load_failed or failed;
        set._loading_count -= 1;
        if (set._loading_count == 0) {
            set.dispatch("loading", frame);
            set.dispatch("loadingdone", frame);
            if (set._load_failed) set.dispatch("loadingerror", frame);
            if (set._ready_resolver) |resolver| frame.js.local.?.toLocal(resolver).resolve("FontFaceSet.ready", set);
        }
        frame._factory.destroy(self);
    }
};

fn dispatch(self: *FontFaceSet, name: []const u8, frame: *Frame) void {
    if (!frame._event_manager.hasDirectListeners(self.asEventTarget(), name, null)) return;
    const event = Event.initTrusted(.wrap(name), .{}, frame.page) catch return;
    frame._event_manager.dispatchDirect(self.asEventTarget(), event, null, .{ .context = "load font face set" }) catch {};
}

pub fn add(self: *FontFaceSet, face: *FontFace, frame: *Frame) !*FontFaceSet {
    if (try self.has(face, frame)) return self;
    face.acquireRef();
    errdefer face.releaseRef(frame.page);
    try self._author_faces.append(self._arena.allocator(), face);
    return self;
}

pub fn delete(self: *FontFaceSet, face: *FontFace, frame: *Frame) bool {
    for (self._author_faces.items, 0..) |item, index| {
        if (item == face) {
            _ = self._author_faces.orderedRemove(index);
            face.releaseRef(frame.page);
            return true;
        }
    }
    return false;
}

pub fn clear(self: *FontFaceSet, frame: *Frame) void {
    for (self._author_faces.items) |face| face.releaseRef(frame.page);
    self._author_faces.clearRetainingCapacity();
}

fn values(self: *FontFaceSet, frame: *Frame) !*ValueIterator {
    try self.syncCssFaces(frame);
    return .init(.{ .set = self }, frame);
}

const ValueIterator = GenericIterator(Iterator, null);
const Iterator = struct {
    index: usize = 0,
    set: *FontFaceSet,

    pub fn acquireRef(self: *Iterator) void {
        self.set.acquireRef();
    }
    pub fn releaseRef(self: *Iterator, page: *Page) void {
        self.set.releaseRef(page);
    }
    pub fn next(self: *Iterator, _: *Frame) ?*FontFace {
        if (self.index < self.set._author_faces.items.len) {
            const face = self.set._author_faces.items[self.index];
            self.index += 1;
            return face;
        }
        var it = self.set._css_faces.valueIterator();
        var index = self.index - self.set._author_faces.items.len;
        while (it.next()) |face| {
            if (index == 0) {
                self.index += 1;
                return face.*;
            }
            index -= 1;
        }
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFaceSet);

    pub const Meta = struct {
        pub const name = "FontFaceSet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const size = bridge.accessor(FontFaceSet.getSize, null, .{});
    pub const status = bridge.accessor(FontFaceSet.getStatus, null, .{});
    pub const ready = bridge.accessor(FontFaceSet.getReady, null, .{});
    pub const check = bridge.function(FontFaceSet.check, .{});
    pub const load = bridge.function(FontFaceSet.load, .{});
    pub const add = bridge.function(FontFaceSet.add, .{});
    pub const has = bridge.function(FontFaceSet.has, .{});
    pub const delete = bridge.function(FontFaceSet.delete, .{});
    pub const clear = bridge.function(FontFaceSet.clear, .{});
    pub const symbol_iterator = bridge.iterator(FontFaceSet.values, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFaceSet" {
    try testing.htmlRunner("css/font_face_set.html", .{});
}

test "WebApi: FontFaceSet events" {
    try testing.htmlRunner("css/font_face_set_events.html", .{});
}
