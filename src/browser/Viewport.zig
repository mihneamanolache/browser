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

/// The selected profile's maximized window: the screen is the full panel,
/// while the layout viewport is what is left after the taskbar (or Dock) and
/// the browser's own UI. Keeping the two distinct is what lets
/// `screen.height` and `innerHeight` differ the way they do in a real
/// maximized Chrome, instead of being the same number.
///
/// A function and not a constant because the profile is chosen at startup;
/// every caller reads it after that, so the value is stable for the process.
pub fn default() Viewport {
    const w = fingerprint.screenWidth();
    const h = fingerprint.screenHeight();
    return .{
        .width = w,
        .height = fingerprint.outerHeight(h) - fingerprint.browser_chrome_height,
        .screen_width = w,
        .screen_height = h,
    };
}
