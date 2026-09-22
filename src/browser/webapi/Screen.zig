// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const EventTarget = @import("EventTarget.zig");

const fingerprint = lp.fingerprint;

pub fn registerTypes() []const type {
    return &.{
        Screen,
        Orientation,
    };
}

const Screen = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_orientation: ?*Orientation = null,
_on_change: ?js.Function.Global = null,

pub fn asEventTarget(self: *Screen) *EventTarget {
    return self._proto;
}

fn getOrientation(self: *Screen, frame: *Frame) !*Orientation {
    if (self._orientation) |orientation| {
        return orientation;
    }
    const orientation = try Orientation.init(frame);
    self._orientation = orientation;
    return orientation;
}

pub fn getWidth(_: *const Screen, frame: *Frame) u32 {
    const viewport = frame.page.getViewport();
    return viewport.screen_width orelse viewport.width;
}

pub fn getHeight(_: *const Screen, frame: *Frame) u32 {
    const viewport = frame.page.getViewport();
    return viewport.screen_height orelse viewport.height;
}

/// Screen minus the OS taskbar. Derived rather than fixed so an emulated
/// screen size (Emulation.setDeviceMetricsOverride) still yields a
/// self-consistent avail size instead of a constant that contradicts it.
pub fn getAvailWidth(self: *const Screen, frame: *Frame) u32 {
    return fingerprint.availWidth(self.getWidth(frame));
}

pub fn getAvailHeight(self: *const Screen, frame: *Frame) u32 {
    return fingerprint.availHeight(self.getHeight(frame));
}

/// Where the usable area starts. On macOS the menu bar pushes it down; on
/// Windows both are 0. CreepJS, BrowserLeaks and FingerprintJS each read
/// these, and a browser reporting 0/0 while claiming macOS contradicts its
/// own availHeight.
fn getAvailLeft(_: *const Screen) i32 {
    return fingerprint.avail_left;
}

fn getAvailTop(_: *const Screen) i32 {
    return fingerprint.availTop();
}

fn getLeft(_: *const Screen) i32 {
    return 0;
}

fn getTop(_: *const Screen) i32 {
    return 0;
}

/// Whether a second display is attached. Part of the Window Management API
/// and readable without permission.
fn getIsExtended(_: *const Screen) bool {
    return fingerprint.is_extended;
}

/// 30 on a wide-gamut Apple panel, 24 on typical Windows, and never the 32 a
/// lot of spoofing code assumes. `pixelDepth` has reported the same number as
/// `colorDepth` on every desktop Chrome.
fn getColorDepth(_: *const Screen) u32 {
    return fingerprint.colorDepth();
}

fn getPixelDepth(_: *const Screen) u32 {
    return fingerprint.pixelDepth();
}

fn getOnChange(self: *const Screen) ?js.Function.Global {
    return self._on_change;
}

fn setOnChange(self: *Screen, cb: ?js.Function.Global) void {
    self._on_change = cb;
}

// The property handler for a JS-side dispatchEvent (see EventManager.dispatch).
pub fn inlineHandler(self: *const Screen, typ: lp.String) ?js.Function.Global {
    if (typ.eql(.wrap("change"))) return self._on_change;
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Screen);

    pub const Meta = struct {
        pub const name = "Screen";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(Screen.getWidth, null, .{});
    pub const height = bridge.accessor(Screen.getHeight, null, .{});
    pub const availWidth = bridge.accessor(Screen.getAvailWidth, null, .{});
    pub const availHeight = bridge.accessor(Screen.getAvailHeight, null, .{});
    pub const availLeft = bridge.accessor(Screen.getAvailLeft, null, .{});
    pub const availTop = bridge.accessor(Screen.getAvailTop, null, .{});
    pub const left = bridge.accessor(Screen.getLeft, null, .{});
    pub const top = bridge.accessor(Screen.getTop, null, .{});
    pub const isExtended = bridge.accessor(Screen.getIsExtended, null, .{});
    pub const onchange = bridge.accessor(Screen.getOnChange, Screen.setOnChange, .{});
    pub const colorDepth = bridge.accessor(Screen.getColorDepth, null, .{});
    pub const pixelDepth = bridge.accessor(Screen.getPixelDepth, null, .{});
    pub const orientation = bridge.accessor(Screen.getOrientation, null, .{});
};

pub const Orientation = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _on_change: ?js.Function.Global = null,

    pub fn init(frame: *Frame) !*Orientation {
        return frame._factory.eventTarget(Orientation{
            ._proto = undefined,
        });
    }

    pub fn asEventTarget(self: *Orientation) *EventTarget {
        return self._proto;
    }

    pub fn inlineHandler(self: *const Orientation, typ: lp.String) ?js.Function.Global {
        if (typ.eql(.wrap("change"))) return self._on_change;
        return null;
    }

    fn getOnChange(self: *const Orientation) ?js.Function.Global {
        return self._on_change;
    }

    fn setOnChange(self: *Orientation, cb: ?js.Function.Global) void {
        self._on_change = cb;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Orientation);

        pub const Meta = struct {
            pub const name = "ScreenOrientation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const angle = bridge.property(0, .{ .template = false });
        pub const @"type" = bridge.property("landscape-primary", .{ .template = false });
        pub const onchange = bridge.accessor(Orientation.getOnChange, Orientation.setOnChange, .{});
    };
};
