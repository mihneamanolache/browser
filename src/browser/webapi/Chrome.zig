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

//! `window.chrome`.
//!
//! Every Chrome page has this, extension or not, and its absence is one of
//! the oldest and cheapest automation checks there is — `'app' in
//! window.chrome` throws a TypeError when the object is missing, which is a
//! far louder signal than a false. A live capture of Chrome 151 running the
//! Google SERP showed reCAPTCHA reading exactly this.
//!
//! Shape taken from that capture rather than from memory:
//!
//!   Object.keys(chrome)     -> ["loadTimes", "csi", "app"]
//!   Object.keys(chrome.app) -> ["isInstalled", "getDetails", "getIsInstalled",
//!                               "installState", "runningState",
//!                               "InstallState", "RunningState"]
//!   typeof chrome.runtime   -> "undefined"
//!   toString.call(chrome)   -> "[object Object]"
//!
//! `chrome.runtime` deliberately does not exist. It is present only in an
//! extension context, and stealth tooling that adds it unconditionally is
//! *more* detectable than tooling that omits it.

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

pub fn registerTypes() []const type {
    return &.{ Chrome, App };
}

const Chrome = @This();

_pad: bool = false,
_app: App = .{},

fn getApp(self: *Chrome) *App {
    return &self._app;
}

/// Client-Side Instrumentation. Long deprecated, still present, still read.
/// Real Chrome reports these in milliseconds relative to the navigation.
const Csi = struct {
    startE: f64,
    onloadT: f64,
    pageT: f64,
    /// Navigation type. 15 is what a normal in-tab navigation reports.
    tran: u8,
};

fn csi(_: *const Chrome, frame: *Frame) Csi {
    const timing = frame.window._performance;
    const origin = timing.getTimeOrigin();
    const now = timing.now();
    return .{
        .startE = origin,
        .onloadT = origin + now,
        .pageT = now,
        .tran = 15,
    };
}

/// The legacy page-timing object. Chrome still ships all thirteen fields.
const LoadTimes = struct {
    requestTime: f64,
    startLoadTime: f64,
    commitLoadTime: f64,
    finishDocumentLoadTime: f64,
    finishLoadTime: f64,
    firstPaintTime: f64,
    firstPaintAfterLoadTime: f64,
    navigationType: []const u8,
    wasFetchedViaSpdy: bool,
    wasNpnNegotiated: bool,
    npnNegotiatedProtocol: []const u8,
    wasAlternateProtocolAvailable: bool,
    connectionInfo: []const u8,
};

fn loadTimes(_: *const Chrome, frame: *Frame) LoadTimes {
    const timing = frame.window._performance;
    // Seconds since the epoch, which is the unit this API predates
    // performance.now() with.
    const start = timing.getTimeOrigin() / 1000.0;
    const now = start + timing.now() / 1000.0;
    return .{
        .requestTime = start,
        .startLoadTime = start,
        .commitLoadTime = start,
        .finishDocumentLoadTime = now,
        .finishLoadTime = now,
        .firstPaintTime = now,
        .firstPaintAfterLoadTime = 0,
        .navigationType = "Other",
        // We speak HTTP/2 wherever the server offers it, and these two
        // fields are how this API spelled that before the names settled.
        .wasFetchedViaSpdy = true,
        .wasNpnNegotiated = true,
        .npnNegotiatedProtocol = "h2",
        .wasAlternateProtocolAvailable = false,
        .connectionInfo = "h2",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Chrome);

    pub const Meta = struct {
        pub const name = "Chrome";
        // Not an interface: a page sees a bare object, so it must report as
        // one and carry its members as own properties.
        pub const class_string = "Object";
        pub const own_properties = true;
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    // Declaration order is key order, and the capture says loadTimes, csi, app.
    pub const loadTimes = bridge.function(Chrome.loadTimes, .{});
    pub const csi = bridge.function(Chrome.csi, .{});
    pub const app = bridge.accessor(Chrome.getApp, null, .{});
};

/// `chrome.app`. Reports "not installed", which is what every ordinary page
/// sees — the API only says otherwise for a Chrome App, which no longer
/// exists as a product.
const App = struct {
    _pad: bool = false,

    const Details = struct {};

    fn getIsInstalled(_: *const App) bool {
        return false;
    }

    /// Null for a page that is not a Chrome App, which is all of them.
    fn getDetails(_: *const App) ?Details {
        return null;
    }

    fn installState(_: *const App) []const u8 {
        return "not_installed";
    }

    fn runningState(_: *const App) []const u8 {
        return "cannot_run";
    }

    const InstallStateEnum = struct {
        DISABLED: []const u8 = "disabled",
        INSTALLED: []const u8 = "installed",
        NOT_INSTALLED: []const u8 = "not_installed",
    };

    const RunningStateEnum = struct {
        CANNOT_RUN: []const u8 = "cannot_run",
        READY_TO_RUN: []const u8 = "ready_to_run",
        RUNNING: []const u8 = "running",
    };

    fn getInstallStateEnum(_: *const App) InstallStateEnum {
        return .{};
    }

    fn getRunningStateEnum(_: *const App) RunningStateEnum {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(App);

        pub const Meta = struct {
            pub const name = "ChromeApp";
            pub const class_string = "Object";
            pub const own_properties = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const isInstalled = bridge.accessor(App.getIsInstalled, null, .{});
        pub const getDetails = bridge.function(App.getDetails, .{});
        pub const getIsInstalled = bridge.function(App.getIsInstalled, .{});
        pub const installState = bridge.function(App.installState, .{});
        pub const runningState = bridge.function(App.runningState, .{});
        pub const InstallState = bridge.accessor(App.getInstallStateEnum, null, .{});
        pub const RunningState = bridge.accessor(App.getRunningStateEnum, null, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: window.chrome" {
    try testing.htmlRunner("chrome_namespace.html", .{});
}
