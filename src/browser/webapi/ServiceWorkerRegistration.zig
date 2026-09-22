// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const EventTarget = @import("EventTarget.zig");
const ServiceWorker = @import("ServiceWorker.zig");
const ServiceWorkerGlobalScope = @import("ServiceWorkerGlobalScope.zig");

const ServiceWorkerRegistration = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_scope: *ServiceWorkerGlobalScope,
_worker: *ServiceWorker,
_on_update_found: ?js.Function.Global = null,

pub fn init(scope: *ServiceWorkerGlobalScope, page: *Page) !*ServiceWorkerRegistration {
    const worker = try ServiceWorker.init(scope, page);
    return page.factory.eventTarget(ServiceWorkerRegistration{
        ._proto = undefined,
        ._scope = scope,
        ._worker = worker,
    });
}

fn getInstalling(self: *const ServiceWorkerRegistration) ?*ServiceWorker {
    return switch (self._scope._state) {
        .parsed, .installing => self._worker,
        else => null,
    };
}

fn getWaiting(self: *const ServiceWorkerRegistration) ?*ServiceWorker {
    return if (self._scope._state == .installed) self._worker else null;
}

fn getActive(self: *const ServiceWorkerRegistration) ?*ServiceWorker {
    return switch (self._scope._state) {
        .activating, .activated => self._worker,
        else => null,
    };
}

fn getScope(self: *const ServiceWorkerRegistration) []const u8 {
    return self._scope._scope;
}

fn getUpdateViaCache(self: *const ServiceWorkerRegistration) ServiceWorkerGlobalScope.UpdateViaCache {
    return self._scope._update_via_cache;
}

fn update(self: *ServiceWorkerRegistration, exec: *const js.Execution) !js.Promise {
    // The installed script is already the newest known version. Chrome still
    // resolves update() to this registration when the byte-for-byte update is
    // unchanged.
    return exec.js.local.?.resolvePromise(self);
}

fn unregister(self: *ServiceWorkerRegistration, exec: *const js.Execution) !js.Promise {
    const removed = self._scope.unregister();
    return exec.js.local.?.resolvePromise(removed);
}

fn getOnUpdateFound(self: *const ServiceWorkerRegistration) ?js.Function.Global {
    return self._on_update_found;
}

fn setOnUpdateFound(self: *ServiceWorkerRegistration, setter: ?FunctionSetter) void {
    self._on_update_found = getFunctionFromSetter(setter);
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
    pub const bridge = js.Bridge(ServiceWorkerRegistration);

    pub const Meta = struct {
        pub const name = "ServiceWorkerRegistration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const installing = bridge.accessor(ServiceWorkerRegistration.getInstalling, null, .{});
    pub const waiting = bridge.accessor(ServiceWorkerRegistration.getWaiting, null, .{});
    pub const active = bridge.accessor(ServiceWorkerRegistration.getActive, null, .{});
    pub const scope = bridge.accessor(ServiceWorkerRegistration.getScope, null, .{});
    pub const updateViaCache = bridge.accessor(ServiceWorkerRegistration.getUpdateViaCache, null, .{});
    pub const update = bridge.function(ServiceWorkerRegistration.update, .{});
    pub const unregister = bridge.function(ServiceWorkerRegistration.unregister, .{});
    pub const onupdatefound = bridge.accessor(ServiceWorkerRegistration.getOnUpdateFound, ServiceWorkerRegistration.setOnUpdateFound, .{});
};
