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

//! `navigator.getBattery()` and the `BatteryManager` it resolves to.
//!
//! Chromium ships this and Firefox removed it, so the previous decision to
//! omit it gave the browser a Firefox-shaped hole while the rest of the
//! profile claimed Chrome. A live capture of Chrome 151 on Google showed
//! reCAPTCHA calling `navigator.getBattery()`, so the hole was on a path
//! that gets exercised.
//!
//! The values describe a desktop on mains power, which is what the rest of
//! the profile claims to be (Win32, no touch points, 1920x1080). A real
//! laptop's draining battery would be higher entropy and would contradict
//! the machine we say we are.

const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const EventTarget = @import("EventTarget.zig");

const fingerprint = lp.fingerprint;

const BatteryManager = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_on_charging_change: ?js.Function.Global = null,
_on_charging_time_change: ?js.Function.Global = null,
_on_discharging_time_change: ?js.Function.Global = null,
_on_level_change: ?js.Function.Global = null,

pub fn init(frame: *Frame) !*BatteryManager {
    return frame._factory.eventTarget(BatteryManager{ ._proto = undefined });
}

pub fn asEventTarget(self: *BatteryManager) *EventTarget {
    return self._proto;
}

// The property handler for a JS-side dispatchEvent (see EventManager.dispatch).
pub fn inlineHandler(self: *const BatteryManager, typ: lp.String) ?js.Function.Global {
    if (typ.eql(.wrap("chargingchange"))) return self._on_charging_change;
    if (typ.eql(.wrap("chargingtimechange"))) return self._on_charging_time_change;
    if (typ.eql(.wrap("dischargingtimechange"))) return self._on_discharging_time_change;
    if (typ.eql(.wrap("levelchange"))) return self._on_level_change;
    return null;
}

fn getCharging(_: *const BatteryManager) bool {
    return fingerprint.battery.charging;
}

/// Seconds until full. Zero when already full, which is what mains power on
/// a desktop reports.
fn getChargingTime(_: *const BatteryManager) f64 {
    return fingerprint.battery.charging_time;
}

/// Seconds until empty. Infinity on mains power — it never discharges.
fn getDischargingTime(_: *const BatteryManager) f64 {
    return fingerprint.battery.discharging_time;
}

/// 0.0 to 1.0. Chrome rounds this to two decimals.
fn getLevel(_: *const BatteryManager) f64 {
    return fingerprint.battery.level;
}

fn getOnChargingChange(self: *const BatteryManager) ?js.Function.Global {
    return self._on_charging_change;
}
fn setOnChargingChange(self: *BatteryManager, cb: ?js.Function.Global) void {
    self._on_charging_change = cb;
}
fn getOnChargingTimeChange(self: *const BatteryManager) ?js.Function.Global {
    return self._on_charging_time_change;
}
fn setOnChargingTimeChange(self: *BatteryManager, cb: ?js.Function.Global) void {
    self._on_charging_time_change = cb;
}
fn getOnDischargingTimeChange(self: *const BatteryManager) ?js.Function.Global {
    return self._on_discharging_time_change;
}
fn setOnDischargingTimeChange(self: *BatteryManager, cb: ?js.Function.Global) void {
    self._on_discharging_time_change = cb;
}
fn getOnLevelChange(self: *const BatteryManager) ?js.Function.Global {
    return self._on_level_change;
}
fn setOnLevelChange(self: *BatteryManager, cb: ?js.Function.Global) void {
    self._on_level_change = cb;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BatteryManager);

    pub const Meta = struct {
        pub const name = "BatteryManager";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const charging = bridge.accessor(BatteryManager.getCharging, null, .{});
    pub const chargingTime = bridge.accessor(BatteryManager.getChargingTime, null, .{});
    pub const dischargingTime = bridge.accessor(BatteryManager.getDischargingTime, null, .{});
    pub const level = bridge.accessor(BatteryManager.getLevel, null, .{});

    pub const onchargingchange = bridge.accessor(BatteryManager.getOnChargingChange, BatteryManager.setOnChargingChange, .{});
    pub const onchargingtimechange = bridge.accessor(BatteryManager.getOnChargingTimeChange, BatteryManager.setOnChargingTimeChange, .{});
    pub const ondischargingtimechange = bridge.accessor(BatteryManager.getOnDischargingTimeChange, BatteryManager.setOnDischargingTimeChange, .{});
    pub const onlevelchange = bridge.accessor(BatteryManager.getOnLevelChange, BatteryManager.setOnLevelChange, .{});
};
