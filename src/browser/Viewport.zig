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

const lp = @import("lightpanda");

const fingerprint = lp.fingerprint;

const Viewport = @This();

width: u32,
height: u32,
scale: f32 = 1.0, // for screenshot raster
// window.screen dimensions; null means the same as the viewport.
screen_width: ?u32 = null,
screen_height: ?u32 = null,

/// The profile's maximized 1920x1080 window: the screen is the full
/// 1920x1080, while the layout viewport is what is left after the taskbar
/// and the browser's own UI. Keeping the two distinct is what lets
/// `screen.height` (1080) and `innerHeight` (945) differ the way they do in
/// a real maximized Chrome, instead of being the same number.
pub const default = Viewport{
    .width = fingerprint.screen_width,
    .height = fingerprint.outerHeight(fingerprint.screen_height) - fingerprint.browser_chrome_height,
    .screen_width = fingerprint.screen_width,
    .screen_height = fingerprint.screen_height,
};
