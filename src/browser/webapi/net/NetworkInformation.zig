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

//! `navigator.connection` — the Network Information API.
//!
//! Chromium exposes this and Firefox and Safari do not, so its absence is a
//! clear "not Chrome" signal on its own. The values are the fixed profile
//! ones rather than measurements of the real link: Chrome deliberately
//! coarsens them (`rtt` to the nearest 25ms, `downlink` to 25kbps) so the
//! connection cannot be used to follow a user between sites, and reporting a
//! crawler's actual datacentre link would stand out badly against the 4g
//! bucket most real traffic falls into.
//!
//! It is an EventTarget in Chrome, so `addEventListener('change', ...)` and
//! `onchange` have to exist and not throw. The values never move, so nothing
//! ever dispatches — but a page that wires up a listener must not break.

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");

const fingerprint = lp.fingerprint;
const connection = fingerprint.connection;

const NetworkInformation = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_on_change: ?js.Function.Global = null,

pub fn init(frame: *Frame) !*NetworkInformation {
    return frame._factory.eventTarget(NetworkInformation{ ._proto = undefined });
}

pub fn asEventTarget(self: *NetworkInformation) *EventTarget {
    return self._proto;
}

// The property handler for a JS-side dispatchEvent (see EventManager.dispatch).
pub fn inlineHandler(self: *const NetworkInformation, typ: lp.String) ?js.Function.Global {
    if (typ.eql(.wrap("change"))) return self._on_change;
    return null;
}

fn getOnChange(self: *const NetworkInformation) ?js.Function.Global {
    return self._on_change;
}

fn setOnChange(self: *NetworkInformation, cb: ?js.Function.Global) void {
    self._on_change = cb;
}

fn getEffectiveType(_: *const NetworkInformation) []const u8 {
    return connection.effective_type;
}

/// Estimated downlink, in Mbps.
fn getDownlink(_: *const NetworkInformation) f64 {
    return connection.downlink;
}

/// Theoretical maximum downlink for the connection type, in Mbps.
fn getDownlinkMax(_: *const NetworkInformation) f64 {
    return connection.downlink_max;
}

/// Estimated round-trip time, in milliseconds.
fn getRtt(_: *const NetworkInformation) u32 {
    return connection.rtt;
}

/// Whether the user asked for reduced data usage. Chrome removed the Data
/// Saver feature from desktop, so this is false there.
fn getSaveData(_: *const NetworkInformation) bool {
    return connection.save_data;
}

/// The physical link kind. Desktop Chrome cannot tell ethernet from wifi on
/// Windows and reports "unknown".
fn getType(_: *const NetworkInformation) []const u8 {
    return connection.kind;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NetworkInformation);

    pub const Meta = struct {
        pub const name = "NetworkInformation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const effectiveType = bridge.accessor(NetworkInformation.getEffectiveType, null, .{});
    pub const downlink = bridge.accessor(NetworkInformation.getDownlink, null, .{});
    pub const downlinkMax = bridge.accessor(NetworkInformation.getDownlinkMax, null, .{});
    pub const rtt = bridge.accessor(NetworkInformation.getRtt, null, .{});
    pub const saveData = bridge.accessor(NetworkInformation.getSaveData, null, .{});
    pub const @"type" = bridge.accessor(NetworkInformation.getType, null, .{});
    pub const onchange = bridge.accessor(NetworkInformation.getOnChange, NetworkInformation.setOnChange, .{});
};
