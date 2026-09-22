// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// Executable service-worker realm. This intentionally shares the existing
// WorkerGlobalScope runtime (networking, timers, fetch, imports and event
// dispatch) while preserving the distinct global/prototype chain that scripts
// observe in Chrome.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Transfer = @import("../../network/HttpClient.zig").Transfer;

const ExtendableEvent = @import("event/ExtendableEvent.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const Client = @import("Client.zig");
const WindowClient = Client.WindowClient;
const Worker = @import("Worker.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");
const ServiceWorkerRegistration = @import("ServiceWorkerRegistration.zig");

const log = lp.log;
const ServiceWorkerGlobalScope = @This();

pub const Proto = WorkerGlobalScope;

pub const State = enum {
    parsed,
    installing,
    installed,
    activating,
    activated,
    redundant,

    pub fn toString(self: State) []const u8 {
        return @tagName(self);
    }
};

pub const UpdateViaCache = enum {
    imports,
    all,
    none,

    pub fn toString(self: UpdateViaCache) []const u8 {
        return @tagName(self);
    }
};

pub const RegistrationOptions = struct {
    scope: ?[]const u8 = null,
    type: ?[]const u8 = null,
    updateViaCache: ?[]const u8 = null,
};

_proto: *WorkerGlobalScope,
_arena: *lp.Arena,
_url: [:0]const u8,
_scope: []const u8,
_type: Worker.WorkerType,
_update_via_cache: UpdateViaCache,
_registry_key: []const u8 = "",
_frame_id: u32,
_loader_id: u32,
_state: State = .parsed,
_script_loaded: bool = false,
_script_arena: ?*lp.Arena = null,
_script_buffer: std.ArrayList(u8) = .empty,
_http_transfer: ?*Transfer = null,
_waiters: std.ArrayList(Waiter) = .empty,
_registration: ?*ServiceWorkerRegistration = null,
_lifecycle_event: ?*ExtendableEvent = null,
_lifecycle_phase: LifecyclePhase = .install,

_on_activate: ?js.Function.Global = null,
_on_fetch: ?js.Function.Global = null,
_on_install: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_on_messageerror: ?js.Function.Global = null,

const Waiter = struct {
    registration: *ServiceWorkerRegistration,
    register_resolver: js.PromiseResolver.Global,
    ready_resolver: ?js.PromiseResolver.Global,
};

const LifecyclePhase = enum { install, activate };

pub fn init(
    frame: *Frame,
    url: [:0]const u8,
    scope: []const u8,
    worker_type: Worker.WorkerType,
    update_via_cache: UpdateViaCache,
) !*ServiceWorkerGlobalScope {
    const session = frame._session;
    const arena = try session.getArena(.small, "ServiceWorker");
    errdefer arena.release();

    const owned_url = try arena.dupeZ(u8, url);
    const owned_scope = try arena.dupe(u8, scope);
    const frame_id = session.nextFrameId();
    const loader_id = session.nextLoaderId();
    const self = try WorkerGlobalScope.init(
        arena.allocator(),
        owned_url,
        .service,
        ServiceWorkerGlobalScope{
            ._proto = undefined,
            ._arena = arena,
            ._url = owned_url,
            ._scope = owned_scope,
            ._type = worker_type,
            ._update_via_cache = update_via_cache,
            ._frame_id = frame_id,
            ._loader_id = loader_id,
        },
        worker_type == .module,
        frame_id,
        loader_id,
        frame,
    );
    const proto = self._proto;
    errdefer proto.deinit();

    if (session.load_resources.worker == false) {
        log.warnDisabledWorker();
        return self;
    }

    self._script_arena = try session.getArena(.large, "ServiceWorker.script");
    errdefer self.releaseScriptArena();

    const transfer = try proto.newRequest(.{
        .ctx = self,
        .method = .GET,
        .url = owned_url,
        .resource_type = .worker,
        .origin = frame.origin,
        .credentials_mode = .same_origin,
        .request_mode = .same_origin,
        .header_callback = httpHeaderCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    });
    self._http_transfer = transfer;
    try transfer.submit();
    return self;
}

pub fn deinit(self: *ServiceWorkerGlobalScope) void {
    if (self._http_transfer) |transfer| {
        transfer.cancel();
        self._http_transfer = null;
    }
    self.releaseLifecycleEvent();
    self.failWaiters("The service worker was terminated.");
    self.releaseScriptArena();
    _ = self.unregister();
    self._proto.deinit();
    self._arena.release();
}

pub fn register(self: *ServiceWorkerGlobalScope) !void {
    const key = try self._arena.dupe(u8, self._scope);
    const session = self._proto._session;
    try session.service_workers.put(session.arena.allocator(), key, self);
    self._registry_key = key;
}

pub fn unregister(self: *ServiceWorkerGlobalScope) bool {
    if (self._registry_key.len == 0) return false;
    const removed = self._proto._session.service_workers.remove(self._registry_key);
    self._registry_key = "";
    self._state = .redundant;
    return removed;
}

pub fn addWaiter(
    self: *ServiceWorkerGlobalScope,
    registration: *ServiceWorkerRegistration,
    register_resolver: js.PromiseResolver.Global,
    ready_resolver: ?js.PromiseResolver.Global,
) !void {
    try self._waiters.append(self._arena.allocator(), .{
        .registration = registration,
        .register_resolver = register_resolver,
        .ready_resolver = ready_resolver,
    });
    if (self._state == .activated) self.resolveWaiters();
}

fn httpHeaderCallback(transfer: *Transfer) !Transfer.HeaderResult {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(transfer.req.ctx));
    const status = transfer.responseStatus() orelse return .abort;
    if (status < 200 or status >= 300) return .abort;
    try self._script_buffer.ensureTotalCapacityPrecise(self._script_arena.?.allocator(), transfer.bodyLen());
    return .proceed;
}

fn httpDataCallback(transfer: *Transfer, data: []const u8) !void {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(transfer.req.ctx));
    try self._script_buffer.appendSlice(self._script_arena.?.allocator(), data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    defer self.releaseScriptArena();
    try self.loadInitialScript(self._script_buffer.items);
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    self.releaseScriptArena();
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    self.releaseScriptArena();
    if (err != error.TransferCanceled) {
        log.err(.browser, "service worker fetch error", .{ .url = self._url, .err = err });
        self.failWaiters("Failed to fetch the service worker script.");
    }
}

fn loadInitialScript(self: *ServiceWorkerGlobalScope, script: []const u8) !void {
    const js_context = self._proto.js;
    if (js_context.env.terminatePending()) return;

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    switch (self._type) {
        .classic => _ = ls.local.eval(script, self._url) catch |err| {
            if (!js_context.env.terminatePending()) {
                js_context.page.recordJsError(err);
                const caught = try_catch.caughtOrError(self._script_arena.?.allocator(), err);
                log.err(.browser, "service worker script error", .{ .url = self._url, .caught = caught });
                self.failWaiters("Service worker script evaluation failed.");
            }
            return;
        },
        .module => js_context.module(false, &ls.local, script, self._url, true) catch |err| {
            if (!js_context.env.terminatePending()) {
                js_context.page.recordJsError(err);
                self.failWaiters("Service worker module evaluation failed.");
            }
            return;
        },
    }
    ls.local.runMacrotasks();
    self._script_loaded = true;

    self.startLifecycle(.install) catch |err| {
        self._state = .redundant;
        self.releaseLifecycleEvent();
        self.failWaiters("Service worker lifecycle failed.");
        return err;
    };
}

fn startLifecycle(self: *ServiceWorkerGlobalScope, phase: LifecyclePhase) anyerror!void {
    const name: []const u8 = switch (phase) {
        .install => "install",
        .activate => "activate",
    };
    const handler = switch (phase) {
        .install => self._on_install,
        .activate => self._on_activate,
    };
    self._state = switch (phase) {
        .install => .installing,
        .activate => .activating,
    };
    const event = try self.dispatchLifecycle(name, handler);
    if (event == null) return self.finishLifecycle(phase);

    self._lifecycle_event = event;
    self._lifecycle_phase = phase;
    if (try self.pollLifecycle()) |delay| {
        try self._proto.js.scheduler.add(self, lifecyclePollCallback, delay, .{
            .name = "ServiceWorkerGlobalScope.waitUntil",
        });
    }
}

fn dispatchLifecycle(self: *ServiceWorkerGlobalScope, name: []const u8, handler: ?js.Function.Global) !?*ExtendableEvent {
    const wgs = self._proto;
    const target = wgs.asEventTarget();
    if (!wgs.hasDirectListeners(target, name, handler)) return null;

    const type_string = try lp.String.init(wgs.call_arena, name, .{});
    const event = try ExtendableEvent.initTrusted(type_string, .{}, wgs.page);
    event.acquireRef();
    errdefer event.releaseRef(wgs.page);
    try wgs.dispatch(target, event.asEvent(), handler, .{ .context = "ServiceWorkerGlobalScope.lifecycle" });
    if (event.asEvent()._listeners_did_throw) {
        event.releaseRef(wgs.page);
        return error.JsException;
    }
    return event;
}

fn lifecyclePollCallback(ctx: *anyopaque) !?u32 {
    const self: *ServiceWorkerGlobalScope = @ptrCast(@alignCast(ctx));
    return self.pollLifecycle() catch |err| {
        self._state = .redundant;
        self.releaseLifecycleEvent();
        self.failWaiters("Service worker lifecycle failed.");
        return err;
    };
}

fn pollLifecycle(self: *ServiceWorkerGlobalScope) anyerror!?u32 {
    const event = self._lifecycle_event orelse return null;
    var ls: js.Local.Scope = undefined;
    self._proto.js.localScope(&ls);
    defer ls.deinit();
    ls.local.runMicrotasks();

    return switch (event.promiseStatus(&ls.local)) {
        .pending => 1,
        .rejected => {
            self._state = .redundant;
            self.releaseLifecycleEvent();
            self.failWaiters("A service worker waitUntil promise rejected.");
            return null;
        },
        .fulfilled => {
            const phase = self._lifecycle_phase;
            self.releaseLifecycleEvent();
            try self.finishLifecycle(phase);
            return null;
        },
    };
}

fn finishLifecycle(self: *ServiceWorkerGlobalScope, phase: LifecyclePhase) anyerror!void {
    switch (phase) {
        .install => {
            self._state = .installed;
            try self.startLifecycle(.activate);
        },
        .activate => {
            self._state = .activated;
            self.resolveWaiters();
        },
    }
}

fn releaseLifecycleEvent(self: *ServiceWorkerGlobalScope) void {
    const event = self._lifecycle_event orelse return;
    self._lifecycle_event = null;
    event.releaseRef(self._proto.page);
}

fn resolveWaiters(self: *ServiceWorkerGlobalScope) void {
    var ls: js.Local.Scope = undefined;
    self._proto._frame.js.localScope(&ls);
    defer ls.deinit();
    for (self._waiters.items) |waiter| {
        ls.local.toLocal(waiter.register_resolver).resolve("ServiceWorkerContainer.register", waiter.registration);
        waiter.register_resolver.deinit();
        if (waiter.ready_resolver) |resolver| {
            ls.local.toLocal(resolver).resolve("ServiceWorkerContainer.ready", waiter.registration);
            resolver.deinit();
        }
    }
    self._waiters.clearRetainingCapacity();
}

fn failWaiters(self: *ServiceWorkerGlobalScope, message: []const u8) void {
    if (self._waiters.items.len == 0) return;
    var ls: js.Local.Scope = undefined;
    self._proto._frame.js.localScope(&ls);
    defer ls.deinit();
    for (self._waiters.items) |waiter| {
        ls.local.toLocal(waiter.register_resolver).rejectError("ServiceWorkerContainer.register", .{ .type_error = message });
        waiter.register_resolver.deinit();
        if (waiter.ready_resolver) |resolver| resolver.deinit();
    }
    self._waiters.clearRetainingCapacity();
}

fn releaseScriptArena(self: *ServiceWorkerGlobalScope) void {
    const arena = self._script_arena orelse return;
    self._script_arena = null;
    self._script_buffer = .empty;
    arena.release();
}

fn getRegistration(self: *ServiceWorkerGlobalScope) !*ServiceWorkerRegistration {
    if (self._registration) |registration| return registration;
    const registration = try ServiceWorkerRegistration.init(self, self._proto.page);
    self._registration = registration;
    return registration;
}

fn getServiceWorker(self: *ServiceWorkerGlobalScope) !*@import("ServiceWorker.zig") {
    return (try self.getRegistration())._worker;
}

fn skipWaiting(_: *ServiceWorkerGlobalScope, exec: *const js.Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

/// Queue a structured-cloned page message in this worker realm. The source is
/// a real WindowClient whose postMessage path targets the originating
/// ServiceWorkerContainer.
pub fn receiveMessage(self: *ServiceWorkerGlobalScope, data: js.Value, target: Client.MessageTarget) !void {
    const wgs = self._proto;
    const message_arena = try wgs._session.getArena(.tiny, "ServiceWorkerGlobalScope.receiveMessage");
    errdefer message_arena.release();

    var ls: js.Local.Scope = undefined;
    wgs.js.localScope(&ls);
    defer ls.deinit();

    const cloned_data = data.structuredCloneTo(&ls.local) catch |err| {
        const callback = try message_arena.create(ReceiveMessageCallback);
        callback.* = .{ .arena = message_arena, .scope = self, .data = err, .source = null };
        try wgs.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
            .name = "ServiceWorkerGlobalScope.messageerror",
            .finalizer = ReceiveMessageCallback.cancelled,
        });
        return;
    };
    const persisted_data = try cloned_data.persist();
    errdefer persisted_data.release();

    const source = try wgs._factory.chained(.{
        Client{
            ._target = target,
            ._id = try message_arena.dupe(u8, "lightpanda-window-client"),
            ._url = try message_arena.dupe(u8, wgs._frame.url),
        },
        WindowClient{ ._proto = undefined },
    });
    const source_value = try (try ls.local.zigValueToJs(source, .{})).persist();
    errdefer source_value.release();

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .arena = message_arena,
        .scope = self,
        .data = persisted_data,
        .source = source_value,
    };
    try wgs.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "ServiceWorkerGlobalScope.message",
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

const ReceiveMessageCallback = struct {
    arena: *lp.Arena,
    scope: *ServiceWorkerGlobalScope,
    data: anyerror!js.Value.Global,
    source: ?js.Value.Global,

    fn releaseValues(self: *ReceiveMessageCallback) void {
        if (self.data) |data| data.release() else |_| {}
        if (self.source) |source| source.release();
    }

    fn cancelled(context: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(context));
        self.releaseValues();
        self.arena.release();
    }

    fn run(context: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(context));
        defer self.arena.release();

        const scope = self.scope;
        const wgs = scope._proto;
        const target = wgs.asEventTarget();
        const data = self.data catch |err| {
            if (!wgs.hasDirectListeners(target, "messageerror", scope._on_messageerror)) return null;
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .data = .{ .string = @errorName(err) },
                .bubbles = false,
                .cancelable = false,
            }, wgs.page)).asEvent();
            try wgs.dispatch(target, event, scope._on_messageerror, .{ .context = "ServiceWorkerGlobalScope.messageerror" });
            return null;
        };

        if (!wgs.hasDirectListeners(target, "message", scope._on_message)) {
            data.release();
            if (self.source) |source| source.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = data },
            .source = if (self.source) |source| .{ .value = source } else null,
            .bubbles = false,
            .cancelable = false,
        }, wgs.page)).asEvent();
        try wgs.dispatch(target, event, scope._on_message, .{ .context = "ServiceWorkerGlobalScope.message" });
        return null;
    }
};

fn getHandler(comptime field: []const u8) fn (*const ServiceWorkerGlobalScope) ?js.Function.Global {
    return struct {
        fn get(self: *const ServiceWorkerGlobalScope) ?js.Function.Global {
            return @field(self, field);
        }
    }.get;
}

fn setHandler(comptime field: []const u8) fn (*ServiceWorkerGlobalScope, ?WorkerGlobalScope.FunctionSetter) void {
    return struct {
        fn set(self: *ServiceWorkerGlobalScope, setter: ?WorkerGlobalScope.FunctionSetter) void {
            @field(self, field) = WorkerGlobalScope.getFunctionFromSetter(setter);
        }
    }.set;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ServiceWorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "ServiceWorkerGlobalScope";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const registration = bridge.accessor(ServiceWorkerGlobalScope.getRegistration, null, .{});
    pub const serviceWorker = bridge.accessor(ServiceWorkerGlobalScope.getServiceWorker, null, .{});
    pub const skipWaiting = bridge.function(ServiceWorkerGlobalScope.skipWaiting, .{});
    pub const onactivate = bridge.accessor(getHandler("_on_activate"), setHandler("_on_activate"), .{});
    pub const onfetch = bridge.accessor(getHandler("_on_fetch"), setHandler("_on_fetch"), .{});
    pub const oninstall = bridge.accessor(getHandler("_on_install"), setHandler("_on_install"), .{});
    pub const onmessage = bridge.accessor(getHandler("_on_message"), setHandler("_on_message"), .{});
    pub const onmessageerror = bridge.accessor(getHandler("_on_messageerror"), setHandler("_on_messageerror"), .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ServiceWorker" {
    testing.silenceLog(&.{.http});
    try testing.htmlRunner("service_worker", .{ .timeout_ms = 8000 });
}
