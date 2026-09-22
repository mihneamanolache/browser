// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");

const String = lp.String;
const ExtendableEvent = @This();

pub const Proto = Event;

_proto: *Event,
_promises: std.ArrayList(js.Promise.Global) = .empty,

pub const Options = Event.inheritOptions(ExtendableEvent, struct {});

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*ExtendableEvent {
    const arena = try page.getArena(.tiny, "ExtendableEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, page);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*ExtendableEvent {
    const arena = try page.getArena(.tiny, "ExtendableEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, opts_, true, page);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts_: ?Options, trusted: bool, page: *Page) !*ExtendableEvent {
    const opts = opts_ orelse Options{};
    const event = try page.factory.event(arena, typ, ExtendableEvent{ ._proto = undefined });
    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *ExtendableEvent) *Event {
    return self._proto;
}

pub fn acquireRef(self: *ExtendableEvent) void {
    self._proto.acquireRef();
}

pub fn releaseRef(self: *ExtendableEvent, page: *Page) void {
    self._proto._rc.release(self, page);
}

pub fn deinit(self: *ExtendableEvent, page: *Page) void {
    for (self._promises.items) |promise| promise.deinit();
    self._proto.deinit(page);
}

fn waitUntil(self: *ExtendableEvent, promise: js.Promise.Global, exec: *js.Execution) !void {
    // waitUntil is only legal while the install/activate event is actively
    // being dispatched. EventManagerBase stamps the direct-dispatch phase.
    if (self._proto._event_phase == .none) return error.InvalidStateError;
    promise.local(exec.js.local.?).markAsHandled();
    errdefer promise.deinit();
    try self._promises.append(self._proto._arena.allocator(), promise);
}

pub const PromiseStatus = enum { fulfilled, pending, rejected };

pub fn promiseStatus(self: *const ExtendableEvent, local: *const js.Local) PromiseStatus {
    var pending = false;
    for (self._promises.items) |global| {
        switch (global.local(local).state()) {
            .fulfilled => {},
            .pending => pending = true,
            .rejected => return .rejected,
        }
    }
    return if (pending) .pending else .fulfilled;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ExtendableEvent);

    pub const Meta = struct {
        pub const name = "ExtendableEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ExtendableEvent.init, .{});
    pub const waitUntil = bridge.function(ExtendableEvent.waitUntil, .{});
};
