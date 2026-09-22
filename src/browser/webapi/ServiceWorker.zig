// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// A page/worker-side handle for one service-worker version. The executable
// realm is ServiceWorkerGlobalScope; this object exposes its script URL and
// lifecycle state as Blink does.

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const EventTarget = @import("EventTarget.zig");
const ServiceWorkerGlobalScope = @import("ServiceWorkerGlobalScope.zig");

const ServiceWorker = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_scope: *ServiceWorkerGlobalScope,
_message_target: ?MessageTarget = null,
_on_state_change: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,

pub fn init(scope: *ServiceWorkerGlobalScope, page: *Page) !*ServiceWorker {
    return page.factory.eventTarget(ServiceWorker{
        ._proto = undefined,
        ._scope = scope,
    });
}

pub fn asEventTarget(self: *ServiceWorker) *EventTarget {
    return self._proto;
}

fn getScriptURL(self: *const ServiceWorker) []const u8 {
    return self._scope._url;
}

fn getState(self: *const ServiceWorker) ServiceWorkerGlobalScope.State {
    return self._scope._state;
}

pub const MessageTarget = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, *ServiceWorker, js.Value) anyerror!void,
};

pub fn setMessageTarget(self: *ServiceWorker, target: MessageTarget) void {
    self._message_target = target;
}

fn deliverToClient(context: *anyopaque, data: js.Value) !void {
    const self: *ServiceWorker = @ptrCast(@alignCast(context));
    const target = self._message_target orelse return;
    try target.callback(target.context, self, data);
}

fn postMessage(self: *ServiceWorker, data: js.Value) !void {
    try self._scope.receiveMessage(data, .{
        .context = self,
        .callback = deliverToClient,
    });
}

fn getOnStateChange(self: *const ServiceWorker) ?js.Function.Global {
    return self._on_state_change;
}

fn setOnStateChange(self: *ServiceWorker, setter: ?FunctionSetter) void {
    self._on_state_change = getFunctionFromSetter(setter);
}

fn getOnError(self: *const ServiceWorker) ?js.Function.Global {
    return self._on_error;
}

fn setOnError(self: *ServiceWorker, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ServiceWorker);

    pub const Meta = struct {
        pub const name = "ServiceWorker";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const postMessage = bridge.function(ServiceWorker.postMessage, .{});
    pub const scriptURL = bridge.accessor(ServiceWorker.getScriptURL, null, .{});
    pub const state = bridge.accessor(ServiceWorker.getState, null, .{});
    pub const onstatechange = bridge.accessor(ServiceWorker.getOnStateChange, ServiceWorker.setOnStateChange, .{});
    // AbstractWorker mixin.
    pub const onerror = bridge.accessor(ServiceWorker.getOnError, ServiceWorker.setOnError, .{});
};
