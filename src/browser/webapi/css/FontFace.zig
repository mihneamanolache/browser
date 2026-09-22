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
const URL = @import("../../URL.zig");
const screenshot = @import("../../screenshot.zig");
const DOMException = @import("../DOMException.zig");
const HttpClient = @import("../../../network/HttpClient.zig");

const FontFace = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_family: []const u8,
_source: []const u8,
_base_url: [:0]const u8,
_status: Status = .unloaded,
_loaded_resolver: ?js.PromiseResolver.Global = null,
_style: []const u8 = "normal",
_weight: []const u8 = "normal",
_stretch: []const u8 = "normal",
_unicode_range: []const u8 = "U+0-10FFFF",
_variant: []const u8 = "normal",
_feature_settings: []const u8 = "normal",
_display: []const u8 = "auto",

const Status = enum { unloaded, loading, loaded, err };

pub fn init(family: []const u8, source: []const u8, frame: *Frame) !*FontFace {
    return initWithBase(family, source, frame.base(), frame);
}

pub fn initWithBase(family: []const u8, source: []const u8, base_url: []const u8, frame: *Frame) !*FontFace {
    const arena = try frame.getArena(.tiny, "FontFace");
    errdefer arena.release();

    const self = try arena.create(FontFace);
    self.* = .{
        ._arena = arena,
        ._family = try arena.dupe(u8, family),
        ._source = try arena.dupe(u8, source),
        ._base_url = try arena.dupeZ(u8, base_url),
    };
    return self;
}

pub fn deinit(self: *FontFace, _: *Page) void {
    if (self._loaded_resolver) |resolver| resolver.deinit();
    self._arena.release();
}

pub fn releaseRef(self: *FontFace, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FontFace) void {
    self._rc.acquire();
}

fn getFamily(self: *const FontFace) []const u8 {
    return self._family;
}

pub fn setCssDescriptor(self: *FontFace, name: []const u8, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return;
    const field: *[]const u8 = if (std.ascii.eqlIgnoreCase(name, "font-style")) &self._style else if (std.ascii.eqlIgnoreCase(name, "font-weight")) &self._weight else if (std.ascii.eqlIgnoreCase(name, "font-stretch")) &self._stretch else if (std.ascii.eqlIgnoreCase(name, "unicode-range")) &self._unicode_range else if (std.ascii.eqlIgnoreCase(name, "font-variant")) &self._variant else if (std.ascii.eqlIgnoreCase(name, "font-feature-settings")) &self._feature_settings else if (std.ascii.eqlIgnoreCase(name, "font-display")) &self._display else return;
    field.* = if (field == &self._unicode_range) try self.canonicalUnicodeRange(trimmed) else try self._arena.dupe(u8, trimmed);
}

fn canonicalUnicodeRange(self: *FontFace, value: []const u8) ![]const u8 {
    const allocator = self._arena.allocator();
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var ranges = std.mem.splitScalar(u8, value, ',');
    while (ranges.next()) |raw| {
        const range = std.mem.trim(u8, raw, " \t\r\n");
        if (!std.ascii.startsWithIgnoreCase(range, "U+")) return try self._arena.dupe(u8, value);
        const dash = std.mem.indexOfScalar(u8, range, '-');
        const first = std.fmt.parseInt(u32, range[2 .. dash orelse range.len], 16) catch return try self._arena.dupe(u8, value);
        const last: ?u32 = if (dash) |index| std.fmt.parseInt(u32, range[index + 1 ..], 16) catch return try self._arena.dupe(u8, value) else null;
        if (result.items.len != 0) try result.appendSlice(allocator, ", ");
        try result.appendSlice(allocator, try std.fmt.allocPrint(allocator, "U+{X}", .{first}));
        if (last) |end| try result.appendSlice(allocator, try std.fmt.allocPrint(allocator, "-{X}", .{end}));
    }
    return try result.toOwnedSlice(allocator);
}

fn getStyle(self: *const FontFace) []const u8 {
    return self._style;
}
fn getWeight(self: *const FontFace) []const u8 {
    return self._weight;
}
fn getStretch(self: *const FontFace) []const u8 {
    return self._stretch;
}
fn getUnicodeRange(self: *const FontFace) []const u8 {
    return self._unicode_range;
}
fn getVariant(self: *const FontFace) []const u8 {
    return self._variant;
}
fn getFeatureSettings(self: *const FontFace) []const u8 {
    return self._feature_settings;
}
fn getDisplay(self: *const FontFace) []const u8 {
    return self._display;
}

fn getStatus(self: *const FontFace) []const u8 {
    return switch (self._status) {
        .unloaded => "unloaded",
        .loading => "loading",
        .loaded => "loaded",
        .err => "error",
    };
}

fn localName(source: []const u8) ?[]const u8 {
    const prefix = "local(";
    if (!std.ascii.startsWithIgnoreCase(source, prefix) or source.len <= prefix.len or source[source.len - 1] != ')') {
        return null;
    }

    var name = std.mem.trim(u8, source[prefix.len .. source.len - 1], " \t\r\n");
    if (name.len >= 2 and ((name[0] == '\'' and name[name.len - 1] == '\'') or
        (name[0] == '"' and name[name.len - 1] == '"')))
    {
        name = name[1 .. name.len - 1];
    }
    return name;
}

fn sourceUrl(source: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "url(")) return null;
    var pos: usize = 4;
    while (pos < trimmed.len and std.ascii.isWhitespace(trimmed[pos])) : (pos += 1) {}
    if (pos == trimmed.len) return null;
    if (trimmed[pos] == '\'' or trimmed[pos] == '"') {
        const quote = trimmed[pos];
        pos += 1;
        const end = std.mem.indexOfScalarPos(u8, trimmed, pos, quote) orelse return null;
        return trimmed[pos..end];
    }
    const end = std.mem.indexOfScalarPos(u8, trimmed, pos, ')') orelse return null;
    return std.mem.trimEnd(u8, trimmed[pos..end], " \t\r\n");
}

// A font source list is comma-separated at the top level. A data URL's comma,
// or a comma in a quoted local name, must not start another source.
fn nextSource(source: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= source.len) return null;
    const start = cursor.*;
    var depth: usize = 0;
    var quote: u8 = 0;
    while (cursor.* < source.len) : (cursor.* += 1) {
        const ch = source[cursor.*];
        if (quote != 0) {
            if (ch == quote and (cursor.* == 0 or source[cursor.* - 1] != '\\')) quote = 0;
        } else switch (ch) {
            '\'', '"' => quote = ch,
            '(' => depth += 1,
            ')' => depth -|= 1,
            ',' => if (depth == 0) {
                const item = std.mem.trim(u8, source[start..cursor.*], " \t\r\n");
                cursor.* += 1;
                return item;
            },
            else => {},
        }
    }
    return std.mem.trim(u8, source[start..], " \t\r\n");
}

pub fn load(self: *FontFace, frame: *Frame) !js.Promise {
    const promise = try self.getLoaded(frame);
    if (self._status != .unloaded) return promise;

    var cursor: usize = 0;
    var resolved_url: ?[:0]const u8 = null;
    while (nextSource(self._source, &cursor)) |candidate| {
        if (localName(candidate)) |name| {
            if (screenshot.systemFontAvailable(name)) {
                self.finishLoad(frame, true);
                return promise;
            }
            continue;
        }
        const source = sourceUrl(candidate) orelse continue;
        resolved_url = URL.resolve(frame.local_arena, self._base_url, source, .{ .encoding = frame.charset }) catch continue;
        break;
    }
    const resolved = resolved_url orelse {
        self.finishLoad(frame, false);
        return promise;
    };
    const fetch = try frame._factory.create(FontLoad{
        .frame = frame,
        .face = self,
        .allocator = frame._factory.storageAllocator(),
        .cursor = cursor,
    });
    self.acquireRef();
    self._status = .loading;
    fetch.startFetch(resolved) catch fetch.retry();
    return promise;
}

fn finishLoad(self: *FontFace, frame: *Frame, success: bool) void {
    self._status = if (success) .loaded else .err;
    if (frame.isGoingAway()) return;
    var scope: js.Local.Scope = undefined;
    frame.js.localScope(&scope);
    defer scope.deinit();
    const resolver = scope.toLocal(self._loaded_resolver.?);
    if (success) {
        resolver.resolve("FontFace.load", self);
    } else {
        resolver.reject("FontFace.load", DOMException.init("A network error occurred.", "NetworkError"));
    }
}

const FontLoad = struct {
    frame: *Frame,
    face: *FontFace,
    allocator: std.mem.Allocator,
    cursor: usize,
    status: u16 = 0,
    body: std.ArrayList(u8) = .empty,
    const max_font_body = 32 * 1024 * 1024;
    extern "c" fn lp_font_decode_valid([*]const u8, usize) c_int;

    fn startFetch(self: *FontLoad, url: [:0]const u8) !void {
        const frame = self.frame;
        const transfer = try frame._session.browser.http_client.newRequest(.{
            .ctx = self,
            .url = url,
            .method = .GET,
            .origin = frame.origin,
            .request_mode = .cors,
            .credentials_mode = .same_origin,
            .resource_type = .font,
            .streaming = true,
            .header_callback = headerCallback,
            .data_callback = dataCallback,
            .done_callback = doneCallback,
            .error_callback = errorCallback,
            .shutdown_callback = shutdownCallback,
        }, &frame._http_owner);
        {
            errdefer transfer.deinit();
            try transfer.setHeader("Accept", "*/*", .{});
            try frame.headersForRequest(transfer);
        }
        // submit consumes the transfer even on failure and calls errorCallback.
        // That callback may finish and free self, so do not touch it afterward.
        transfer.submit() catch {};
    }

    fn retry(self: *FontLoad) void {
        self.body.clearRetainingCapacity();
        self.status = 0;
        const frame = self.frame;
        while (nextSource(self.face._source, &self.cursor)) |candidate| {
            if (localName(candidate)) |name| {
                if (screenshot.systemFontAvailable(name)) return self.settle(true);
                continue;
            }
            const source = sourceUrl(candidate) orelse continue;
            const resolved = URL.resolve(frame.local_arena, self.face._base_url, source, .{ .encoding = frame.charset }) catch continue;
            self.startFetch(resolved) catch continue;
            return;
        }
        self.settle(false);
    }

    fn headerCallback(transfer: *HttpClient.Transfer) !HttpClient.Transfer.HeaderResult {
        const self: *FontLoad = @ptrCast(@alignCast(transfer.req.ctx));
        self.status = transfer.responseStatus() orelse 0;
        return .proceed;
    }

    fn dataCallback(transfer: *HttpClient.Transfer, bytes: []const u8) !void {
        const self: *FontLoad = @ptrCast(@alignCast(transfer.req.ctx));
        if (self.status < 200 or self.status >= 300) return;
        if (bytes.len > max_font_body -| self.body.items.len) return error.ResponseTooLarge;
        try self.body.appendSlice(self.allocator, bytes);
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const self: *FontLoad = @ptrCast(@alignCast(ctx));
        const success = self.status >= 200 and self.status < 300 and
            self.body.items.len > 0 and lp_font_decode_valid(self.body.items.ptr, self.body.items.len) != 0;
        if (success) self.settle(true) else self.retry();
    }

    fn errorCallback(ctx: *anyopaque, _: anyerror) void {
        const self: *FontLoad = @ptrCast(@alignCast(ctx));
        self.retry();
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *FontLoad = @ptrCast(@alignCast(ctx));
        const frame = self.frame;
        const face = self.face;
        self.body.deinit(self.allocator);
        frame._factory.destroy(self);
        face._status = .err;
        face.releaseRef(frame.page);
    }

    fn settle(self: *FontLoad, success: bool) void {
        const frame = self.frame;
        const face = self.face;
        self.body.deinit(self.allocator);
        frame._factory.destroy(self);
        face.finishLoad(frame, success);
        face.releaseRef(frame.page);
    }
};

fn getLoaded(self: *FontFace, frame: *Frame) !js.Promise {
    const local = frame.js.local.?;
    if (self._loaded_resolver) |resolver| return local.toLocal(resolver).promise();
    const resolver = local.createPromiseResolver();
    self._loaded_resolver = try resolver.persist();
    return resolver.promise();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFace);

    pub const Meta = struct {
        pub const name = "FontFace";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FontFace.init, .{});
    pub const family = bridge.accessor(FontFace.getFamily, null, .{});
    pub const status = bridge.accessor(FontFace.getStatus, null, .{});
    pub const style = bridge.accessor(FontFace.getStyle, null, .{});
    pub const weight = bridge.accessor(FontFace.getWeight, null, .{});
    pub const stretch = bridge.accessor(FontFace.getStretch, null, .{});
    pub const unicodeRange = bridge.accessor(FontFace.getUnicodeRange, null, .{});
    pub const variant = bridge.accessor(FontFace.getVariant, null, .{});
    pub const featureSettings = bridge.accessor(FontFace.getFeatureSettings, null, .{});
    pub const display = bridge.accessor(FontFace.getDisplay, null, .{});
    pub const loaded = bridge.accessor(FontFace.getLoaded, null, .{});
    pub const load = bridge.function(FontFace.load, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFace" {
    try testing.htmlRunner("css/font_face.html", .{});
}
