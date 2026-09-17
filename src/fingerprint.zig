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

//! The one profile every observable identity surface reports, on every host.
//!
//! Nothing here consults `builtin.os.tag` or `builtin.cpu.arch`: a build
//! running on Linux, macOS or Windows presents the same Chrome-on-Windows
//! identity, so a page cannot tell the three apart. Every value a page can
//! read — the UA string, client hints, `navigator`, `screen`, the window
//! metrics, the WebGL strings, the plugin list — is derived from the
//! constants below, so the JS side and the HTTP side cannot drift.
//!
//! Anything derived (`app_version` from `user_agent`, the `Sec-Ch-Ua`
//! headers from `brands`) is computed here rather than restated, so a single
//! edit moves the whole profile. Changing the Chrome version means editing
//! `chrome_major` and `chrome_full_version`, and nothing else.

const std = @import("std");

/// Marketing version. Drives the UA string and the `brands` list.
pub const chrome_major = "151";

/// The four-part build number. Only client hints expose it; the UA string
/// has reported a frozen `X.0.0.0` since Chrome 101.
pub const chrome_full_version = "151.0.7922.138";

/// Chrome on macOS. The "Intel Mac OS X 10_15_7" is frozen: Chrome has
/// reported that exact string on every Mac since 10.15, Apple Silicon
/// included, so an honest "14_8_1" or "arm64" here would be the anomaly.
pub const user_agent: [:0]const u8 =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " ++
    "Chrome/" ++ chrome_major ++ ".0.0.0 Safari/537.36";

/// `navigator.appVersion` is the UA string with the leading "Mozilla/"
/// removed. Slicing keeps the two in step by construction.
pub const app_version: []const u8 = user_agent["Mozilla/".len..];

pub const platform = "MacIntel";
pub const vendor = "Google Inc.";
pub const product = "Gecko";
pub const app_name = "Netscape";
pub const app_code_name = "Mozilla";

/// BCP 47 tag. Also the default `--locale`, which produces the
/// Accept-Language header and `navigator.languages`.
pub const locale: [:0]const u8 = "en-GB";

/// The Accept-Language header, captured from the reference Chrome rather
/// than derived. Chrome builds this from the OS's preferred-languages list,
/// so a two-tag "en-GB,en;q=0.9" would be a shape Chrome does not produce
/// for this machine. `navigator.languages` is read straight off it, so the
/// two cannot drift. A `--locale` override falls back to the generic
/// derivation in Config.HttpHeaders.
pub const accept_language: [:0]const u8 = "en-GB,en-US;q=0.9,en;q=0.8";

/// IANA id. Also the default `--timezone`, which becomes ICU's default zone,
/// so `Intl.DateTimeFormat().resolvedOptions().timeZone` and
/// `Date#getTimezoneOffset` agree with it.
pub const timezone: [:0]const u8 = "Europe/Bucharest";

pub const hardware_concurrency: u32 = 10;
pub const device_memory: f64 = 16.0;
pub const max_touch_points: u32 = 0;

/// Chrome ships a built-in PDF viewer and has reported this as true since
/// the plugin list was frozen in Chrome 94.
pub const pdf_viewer_enabled = true;

/// `navigator.productSub` and `vendorSub`. Frozen constants on every
/// Chromium build; CreepJS, BrowserLeaks and bot.sannysoft all read them,
/// and a browser claiming Chrome without them is trivially caught.
pub const product_sub = "20030107";
pub const vendor_sub = "";

// -- User-Agent Client Hints -------------------------------------------------

pub const Brand = struct {
    brand: [:0]const u8,
    /// Significant version, as reported by `navigator.userAgentData.brands`
    /// and `Sec-Ch-Ua`.
    version: [:0]const u8,
    /// Four-part version, as reported by `fullVersionList` and
    /// `Sec-Ch-Ua-Full-Version-List`.
    full_version: [:0]const u8,
};

/// Source of truth for client-hint brand data. The `Sec-Ch-Ua` headers and
/// `navigator.userAgentData` both derive from this list, so the HTTP side
/// and the JS side cannot disagree.
///
/// The "Not=A?Brand" entry is GREASE: Chrome injects a deliberately
/// odd-looking brand so servers are forced to parse the list properly
/// rather than string-match one known name. Real Chrome varies the
/// punctuation and position per build; we pin one shape because a stable
/// profile is the point here.
pub const brands = [_]Brand{
    .{ .brand = "Not=A?Brand", .version = "99", .full_version = "99.0.0.0" },
    .{ .brand = "Google Chrome", .version = chrome_major, .full_version = chrome_full_version },
    .{ .brand = "Chromium", .version = chrome_major, .full_version = chrome_full_version },
};

/// `navigator.userAgentData.platform`, and the `Sec-Ch-Ua-Platform` header.
pub const ua_platform: [:0]const u8 = "macOS";

/// High-entropy `platformVersion`. The UA string is frozen at 10_15_7, so
/// this hint is the only place the real macOS version appears.
pub const platform_version: [:0]const u8 = "14.8.1";

/// Apple Silicon. The UA still says "Intel" because Chrome freezes it there.
pub const architecture: [:0]const u8 = "arm";
pub const bitness: [:0]const u8 = "64";
pub const model: [:0]const u8 = "";
pub const wow64 = false;
pub const mobile = false;
pub const form_factors = [_][]const u8{"Desktop"};

/// `"Not=A?Brand";v="99", "Google Chrome";v="151", "Chromium";v="151"`
pub const sec_ch_ua: [:0]const u8 = brandListHeader("version");

/// Same shape, four-part versions.
pub const sec_ch_ua_full_version_list: [:0]const u8 = brandListHeader("full_version");

pub const sec_ch_ua_mobile: [:0]const u8 = if (mobile) "?1" else "?0";
pub const sec_ch_ua_platform: [:0]const u8 = "\"" ++ ua_platform ++ "\"";

fn brandListHeader(comptime field: []const u8) [:0]const u8 {
    comptime {
        var out: [:0]const u8 = "";
        for (brands, 0..) |b, i| {
            const sep = if (i == 0) "" else ", ";
            out = out ++ sep ++ "\"" ++ b.brand ++ "\";v=\"" ++ @field(b, field) ++ "\"";
        }
        return out;
    }
}

// -- Screen and window geometry ----------------------------------------------

/// `screen.width` / `screen.height`. Also the default viewport's screen
/// dimensions, so `Emulation.setDeviceMetricsOverride` can still move them.
pub const screen_width: u32 = 1512;
pub const screen_height: u32 = 982;

/// Vertical space macOS reserves: the menu bar at the top plus the Dock at
/// the bottom. `availHeight` is `height` minus this. Kept as a delta so an
/// emulated screen size still yields a consistent avail size.
pub const taskbar_height: u32 = 121;

/// `screen.availLeft` / `screen.availTop`. The menu bar pushes the usable
/// area down by 38px; nothing reserves space on the left. Read 11 times each
/// by CreepJS, BrowserLeaks and FingerprintJS.
pub const avail_left: i32 = 0;
pub const avail_top: i32 = 38;

/// `screen.isExtended` — whether a second display is attached. A single
/// built-in panel is the common case and the lower-entropy answer.
pub const is_extended = false;

/// Vertical space the browser's own UI (tab strip, omnibox) takes out of the
/// window: `innerHeight` is `outerHeight` minus this. A maximized window has
/// `outerHeight == availHeight`, which is what the default viewport encodes.
pub const browser_chrome_height: u32 = 87;

/// 30, not 24 or 32: a wide-gamut Apple display reports 10 bits per channel.
pub const color_depth: u32 = 30;
pub const pixel_depth: u32 = 30;

/// Retina. Drives `(resolution: 2dppx)`, which CreepJS matchMedia-probes
/// alongside the exact device-width/height.
pub const device_pixel_ratio: f64 = 2.0;

/// The macOS Dock sits at the bottom by default, so nothing is taken off
/// the width.
pub fn availWidth(width: u32) u32 {
    return width;
}

pub fn availHeight(height: u32) u32 {
    return height -| taskbar_height;
}

/// A maximized window fills the available screen area.
pub fn outerWidth(width: u32) u32 {
    return availWidth(width);
}

pub fn outerHeight(height: u32) u32 {
    return availHeight(height);
}

// -- performance.memory ------------------------------------------------------

/// V8's default heap cap on 64-bit desktop Chrome (~4GB). Reported verbatim;
/// the other two `performance.memory` fields are read from the live isolate
/// so a page that allocates sees the numbers move, as it would in Chrome.
pub const js_heap_size_limit: f64 = 4395630592;

/// Chrome rounds `performance.memory` sizes down to a 100KB boundary so the
/// exact allocation pattern isn't readable as a side channel.
pub const heap_size_granularity: u64 = 100_000;

pub fn quantizeHeapSize(bytes: u64) f64 {
    return @floatFromInt(bytes / heap_size_granularity * heap_size_granularity);
}

// -- navigator.getBattery ----------------------------------------------------

/// A desktop on mains power, matching the rest of the profile (Win32, no
/// touch, 1920x1080). A draining laptop battery would be higher entropy and
/// would contradict the machine this profile claims to be.
pub const battery = struct {
    pub const charging = true;
    pub const charging_time: f64 = 0;
    pub const discharging_time: f64 = std.math.inf(f64);
    pub const level: f64 = 1.0;
};

// -- navigator.connection ----------------------------------------------------

pub const connection = struct {
    pub const effective_type = "4g";
    pub const downlink: f64 = 1.5;
    pub const rtt: u32 = 100;
    pub const save_data = false;
    /// Chrome reports "unknown" for `type` on desktop unless the platform
    /// exposes the link kind, which Windows does not.
    pub const kind = "unknown";
    /// Theoretical downlink cap, in Mbps. Chrome caps the reported value at
    /// 10 for the 4g bucket.
    pub const downlink_max: f64 = 10.0;
};

// -- WebGL -------------------------------------------------------------------

pub const webgl = struct {
    /// `getParameter(VENDOR)` / `getParameter(RENDERER)`. Chrome masks the
    /// real GPU behind these fixed strings; the true values are only
    /// reachable through the WEBGL_debug_renderer_info extension below.
    pub const vendor = "WebKit";
    pub const renderer = "WebKit WebGL";
    pub const unmasked_vendor = "Google Inc. (Apple)";
    pub const unmasked_renderer =
        "ANGLE (Apple, ANGLE Metal Renderer: Apple M2 Pro, Unspecified Version)";
    pub const version = "WebGL 1.0 (OpenGL ES 2.0 Chromium)";

    /// getParameter limits, measured on the reference machine. ANGLE-on-Metal
    /// reports a 16384 viewport where the D3D11 backend reports 32767, and a
    /// 511px max point size where D3D11 gives 1024 — both are read by
    /// CreepJS, so they have to match the renderer string above.
    pub const max_texture_size: i64 = 16384;
    pub const max_viewport_dims = [2]i32{ 16384, 16384 };
    pub const max_renderbuffer_size: i64 = 16384;
    pub const max_vertex_attribs: i64 = 16;
    pub const max_varying_vectors: i64 = 30;
    pub const max_combined_texture_image_units: i64 = 32;
    pub const aliased_line_width_range = [2]f32{ 1, 1 };
    pub const aliased_point_size_range = [2]f32{ 1, 511 };
    pub const depth_bits: i64 = 24;
    pub const stencil_bits: i64 = 0;
    pub const shading_language_version = "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)";
};

// -- Plugins and MIME types --------------------------------------------------

pub const Plugin = struct {
    name: []const u8,
    filename: []const u8,
    description: []const u8,
};

pub const MimeType = struct {
    type: []const u8,
    suffixes: []const u8,
    description: []const u8,
};

/// Chrome 94 froze the plugin list to exactly these five entries, all of
/// them aliases for the same built-in PDF viewer. A page reading
/// `navigator.plugins` learns nothing about the machine, which is the point:
/// an empty list is the anomaly, not this.
pub const plugins = [_]Plugin{
    .{ .name = "PDF Viewer", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
    .{ .name = "Chrome PDF Viewer", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
    .{ .name = "Chromium PDF Viewer", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
    .{ .name = "Microsoft Edge PDF Viewer", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
    .{ .name = "WebKit built-in PDF", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
};

/// Every plugin above advertises both of these, and every one of them is
/// reachable from `navigator.mimeTypes`.
pub const mime_types = [_]MimeType{
    .{ .type = "application/pdf", .suffixes = "pdf", .description = "Portable Document Format" },
    .{ .type = "text/pdf", .suffixes = "pdf", .description = "Portable Document Format" },
};

// -- CDP /json/version -------------------------------------------------------

/// What Chrome puts in the `Browser` field of `GET /json/version`. Automation
/// detectors read this endpoint too, so it carries the same version as the
/// UA string rather than the Lightpanda build id.
pub const cdp_browser: []const u8 = "Chrome/" ++ chrome_full_version;

const testing = std.testing;

test "fingerprint: appVersion is the UA minus its Mozilla prefix" {
    try testing.expectEqualStrings(
        "5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
        app_version,
    );
    try testing.expectEqualStrings(user_agent, "Mozilla/" ++ app_version);
}

test "fingerprint: client hint headers are built from the brand list" {
    try testing.expectEqualStrings(
        "\"Not=A?Brand\";v=\"99\", \"Google Chrome\";v=\"151\", \"Chromium\";v=\"151\"",
        sec_ch_ua,
    );
    try testing.expectEqualStrings(
        "\"Not=A?Brand\";v=\"99.0.0.0\", \"Google Chrome\";v=\"151.0.7922.138\", \"Chromium\";v=\"151.0.7922.138\"",
        sec_ch_ua_full_version_list,
    );
    try testing.expectEqualStrings("\"macOS\"", sec_ch_ua_platform);
    try testing.expectEqualStrings("?0", sec_ch_ua_mobile);
}

test "fingerprint: window geometry derives from the screen size" {
    // Measured on the reference MacBook: 1512x982 panel, 861 usable after the
    // menu bar and Dock, and 87px of browser chrome above the content.
    try testing.expectEqual(1512, availWidth(screen_width));
    try testing.expectEqual(861, availHeight(screen_height));
    try testing.expectEqual(1512, outerWidth(screen_width));
    try testing.expectEqual(861, outerHeight(screen_height));
    try testing.expectEqual(774, outerHeight(screen_height) - browser_chrome_height);
}

test "fingerprint: a screen shorter than the taskbar saturates instead of wrapping" {
    try testing.expectEqual(0, availHeight(10));
}

test "fingerprint: heap sizes round down to Chrome's 100KB boundary" {
    try testing.expectEqual(5_500_000, quantizeHeapSize(5_506_445));
    try testing.expectEqual(0, quantizeHeapSize(99_999));
}
