// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)

//! Service-worker client handles. A MessageEvent delivered to a service worker
//! exposes the originating document as a WindowClient; posting to that client
//! delivers a MessageEvent on the document's ServiceWorkerContainer.

const js = @import("../js/js.zig");

const Client = @This();

pub const _prototype_root = true;

pub const MessageTarget = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, js.Value) anyerror!void,
};

_target: MessageTarget,
_id: []const u8,
_url: []const u8,

fn getId(self: *const Client) []const u8 {
    return self._id;
}

fn getType(_: *const Client) []const u8 {
    return "window";
}

fn getUrl(self: *const Client) []const u8 {
    return self._url;
}

fn postMessage(self: *Client, data: js.Value) !void {
    try self._target.callback(self._target.context, data);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Client);

    pub const Meta = struct {
        pub const name = "Client";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const id = bridge.accessor(Client.getId, null, .{});
    pub const @"type" = bridge.accessor(Client.getType, null, .{});
    pub const url = bridge.accessor(Client.getUrl, null, .{});
    pub const postMessage = bridge.function(Client.postMessage, .{});
};

pub const WindowClient = struct {
    pub const Proto = Client;

    _proto: *Client,

    fn getAncestorOrigins(_: *const WindowClient) []const []const u8 {
        return &.{};
    }

    fn getFocused(_: *const WindowClient) bool {
        return true;
    }

    fn getFrameType(_: *const WindowClient) []const u8 {
        return "top-level";
    }

    fn getVisibilityState(_: *const WindowClient) []const u8 {
        return "visible";
    }

    fn focus(self: *WindowClient, exec: *const js.Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(self);
    }

    fn navigate(self: *WindowClient, _: []const u8, exec: *const js.Execution) !js.Promise {
        // Navigation from a worker is deliberately not initiated until worker
        // ownership survives page replacement. The observable result remains a
        // WindowClient instead of a fabricated navigation side effect.
        return exec.js.local.?.resolvePromise(self);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WindowClient);

        pub const Meta = struct {
            pub const name = "WindowClient";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const ancestorOrigins = bridge.accessor(WindowClient.getAncestorOrigins, null, .{});
        pub const focused = bridge.accessor(WindowClient.getFocused, null, .{});
        pub const frameType = bridge.accessor(WindowClient.getFrameType, null, .{});
        pub const visibilityState = bridge.accessor(WindowClient.getVisibilityState, null, .{});
        pub const focus = bridge.function(WindowClient.focus, .{});
        pub const navigate = bridge.function(WindowClient.navigate, .{});
    };
};
