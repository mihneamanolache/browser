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

//! `navigator.userActivation` — whether the page has ever seen a user
//! gesture, and whether one is currently in effect.
//!
//! Worth having because it is read, not because it is interesting: a live
//! capture of Chrome 151 on Google showed reCAPTCHA reading it six times in
//! a single run, more often than screen size or hardware concurrency. An
//! `undefined` here is a missing Chrome interface.
//!
//! Both values are false, which is what a freshly loaded page reports in
//! real Chrome — measured, not assumed: a navigation is not itself an
//! activation of the document it loads. Nothing in this browser synthesises
//! user gestures, so there is no path that would flip them.

const js = @import("../js/js.zig");

const UserActivation = @This();

_pad: bool = false,

/// Whether a user gesture is in effect right now (the transient window that
/// gates popups, fullscreen and autoplay).
fn getIsActive(_: *const UserActivation) bool {
    return false;
}

/// Whether the page has received a user gesture at any point (sticky).
fn getHasBeenActive(_: *const UserActivation) bool {
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(UserActivation);

    pub const Meta = struct {
        pub const name = "UserActivation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const isActive = bridge.accessor(UserActivation.getIsActive, null, .{});
    pub const hasBeenActive = bridge.accessor(UserActivation.getHasBeenActive, null, .{});
};
