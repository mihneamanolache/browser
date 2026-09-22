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
//! running on Linux, macOS or Windows presents whichever desktop-Chrome
//! identity was selected, so a page cannot tell the three apart. Every value
//! a page can read — the UA string, client hints, `navigator`, `screen`, the
//! window metrics, the WebGL strings, the plugin list — comes from here, so
//! the JS side and the HTTP side cannot drift.
//!
//! TWO KINDS OF VALUE
//!
//! Constants are the ones that are the same on every desktop Chrome: the
//! version, the brand list, the frozen plugin array, `productSub`. Editing
//! `chrome_major` and `chrome_full_version` moves the whole profile to a new
//! Chrome release and nothing else has to change.
//!
//! Functions are the ones that vary by *which machine* and *which region*
//! this process claims to be — see `fingerprint/machines.zig` for why those
//! are drawn as whole coherent units rather than field by field. They read
//! the selection made once at startup by `select`, `selectNamed` or
//! `selectRegionForCountry`, and never change afterwards.

const std = @import("std");

pub const machines = @import("fingerprint/machines.zig");
pub const startup = @import("fingerprint/startup.zig");
pub const geo = @import("fingerprint/geo.zig");
pub const keyboard_layouts = @import("fingerprint/keyboard.zig");
pub const Machine = machines.Machine;
pub const Region = machines.Region;

/// The identity this process presents. Selected once at startup from a seed
/// (see `select`) and never changed afterwards: an identity that shifts
/// mid-session contradicts itself, and a cookie jar earned under one identity
/// has to be replayed under the same one.
///
/// Indices rather than pointers, because the strings each machine implies --
/// the UA, appVersion, Sec-CH-UA-Platform -- are built at comptime into
/// `derived` below and looked up by the same index. That keeps every accessor
/// a plain lookup returning a sentinel-terminated slice, with no runtime
/// buffer for a caller to own.
var active_machine_index: usize = 0;
var active_region_index: usize = 0;

pub fn machine() *const Machine {
    return &machines.machines[active_machine_index];
}

pub fn region() *const Region {
    return &machines.regions[active_region_index];
}

/// Chooses the identity for this process. Call once, before anything reads a
/// profile value -- in practice from `main`, before Config's HTTP headers and
/// the V8 platform are built from it.
pub fn select(seed: u64) void {
    const p = machines.pick(seed);
    active_machine_index = indexOfMachine(p.machine);
    active_region_index = indexOfRegion(p.region);
}

/// Pins a specific machine and/or region by name, for reproducing a report or
/// matching a jar that was earned elsewhere. Returns false if a name is
/// unknown, so a typo fails loudly rather than silently picking a default.
pub fn selectNamed(machine_name: ?[]const u8, region_name: ?[]const u8) bool {
    const m = if (machine_name) |n| machines.machineByName(n) orelse return false else null;
    const r = if (region_name) |n| machines.regionByName(n) orelse return false else null;
    // Resolved both before assigning either, so a bad region name does not
    // leave a half-applied identity behind.
    if (m) |x| active_machine_index = indexOfMachine(x);
    if (r) |x| active_region_index = indexOfRegion(x);
    return true;
}

/// Moves the region to wherever the exit IP is, leaving the hardware alone.
/// Used by `--fingerprint-region auto`, which resolves the proxy's country at
/// startup: the machine a crawler claims to be is independent of where it is,
/// but the time zone and language are not.
pub fn selectRegionForCountry(country: []const u8, seed: u64) ?*const Region {
    const r = machines.regionForCountry(country, seed) orelse return null;
    active_region_index = indexOfRegion(r);
    return r;
}

fn indexOfMachine(m: *const Machine) usize {
    for (&machines.machines, 0..) |*candidate, i| {
        if (candidate == m) return i;
    }
    unreachable;
}

fn indexOfRegion(r: *const Region) usize {
    for (&machines.regions, 0..) |*candidate, i| {
        if (candidate == r) return i;
    }
    unreachable;
}

/// Marketing version. Drives the UA string and the `brands` list.
pub const chrome_major = "151";

/// The four-part build number. Only client hints expose it; the UA string
/// has reported a frozen `X.0.0.0` since Chrome 101.
pub const chrome_full_version = "151.0.7922.138";

/// The strings a machine implies, built once at comptime for every entry in
/// the table so the accessors below are lookups rather than formatting.
const Derived = struct {
    user_agent: [:0]const u8,
    /// The UA minus its "Mozilla/" prefix, which is all `navigator.appVersion`
    /// is. Derived rather than restated so the two cannot disagree.
    app_version: [:0]const u8,
    /// Sec-CH-UA-Platform, quoted as a structured-field string.
    sec_ch_ua_platform: [:0]const u8,
};

const derived: [machines.machines.len]Derived = blk: {
    var out: [machines.machines.len]Derived = undefined;
    for (machines.machines, 0..) |m, i| {
        // "Intel Mac OS X 10_15_7" and "Windows NT 10.0" are frozen by
        // Chrome: every Mac says 10_15_7 including Apple Silicon, and every
        // 64-bit Windows says the same block including Windows 11. The rest
        // of the string is identical across every desktop Chrome, so only
        // the block varies.
        const app_version = "5.0 (" ++ m.ua_platform_block ++
            ") AppleWebKit/537.36 (KHTML, like Gecko) Chrome/" ++ chrome_major ++ ".0.0.0 Safari/537.36";
        out[i] = .{
            .user_agent = mozilla_prefix ++ app_version,
            .app_version = app_version,
            .sec_ch_ua_platform = "\"" ++ m.ua_platform ++ "\"",
        };
    }
    break :blk out;
};

pub fn userAgent() [:0]const u8 {
    return derived[active_machine_index].user_agent;
}

pub fn appVersion() [:0]const u8 {
    return derived[active_machine_index].app_version;
}

/// Longest UA any entry in the table produces, with headroom. Callers that
/// copy it into a fixed buffer size it from here.
pub const user_agent_max_len = 160;

pub const mozilla_prefix = "Mozilla/";
pub const vendor = "Google Inc.";
pub const product = "Gecko";
pub const app_name = "Netscape";
pub const app_code_name = "Mozilla";

/// The active region's tag. Also the default `--locale`.
pub fn locale() [:0]const u8 {
    return region().locale;
}

/// The Accept-Language header, captured from the reference Chrome rather
/// than derived. Chrome builds this from the OS's preferred-languages list,
/// so a two-tag "en-GB,en;q=0.9" would be a shape Chrome does not produce
/// for this machine. `navigator.languages` is read straight off it, so the
/// two cannot drift. A `--locale` override falls back to the generic
/// derivation in Config.HttpHeaders.
pub fn acceptLanguage() [:0]const u8 {
    return region().accept_language;
}

/// IANA id. Also the default `--timezone`, which becomes ICU's default zone,
/// so `Intl.DateTimeFormat().resolvedOptions().timeZone` and
/// `Date#getTimezoneOffset` agree with it.
pub fn timezone() [:0]const u8 {
    return region().timezone;
}

pub fn hardwareConcurrency() u32 {
    return machine().hardware_concurrency;
}
pub fn deviceMemory() f64 {
    return machine().device_memory;
}
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

/// `navigator.platform`: "MacIntel" or "Win32". Frozen per OS by Chrome, and
/// read by every fingerprinter as a cross-check on the UA string.
pub fn platform() []const u8 {
    return machine().platform;
}

/// `navigator.userAgentData.platform`, and the `Sec-Ch-Ua-Platform` header.
pub fn uaPlatform() [:0]const u8 {
    return machine().ua_platform;
}

/// High-entropy `platformVersion`. The UA string is frozen at 10_15_7, so
/// this hint is the only place the real macOS version appears.
pub fn platformVersion() [:0]const u8 {
    return machine().platform_version;
}

/// Apple Silicon. The UA still says "Intel" because Chrome freezes it there.
pub fn architecture() [:0]const u8 {
    return machine().architecture;
}
pub fn bitness() [:0]const u8 {
    return machine().bitness;
}
pub const model: [:0]const u8 = "";
pub const wow64 = false;
pub const mobile = false;
pub const form_factors = [_][]const u8{"Desktop"};

/// The local reference Chrome was captured with macOS dark appearance.
/// Keep the HTTP client hint and `matchMedia()` on the same value.
pub const prefers_dark_color_scheme = true;

/// Chrome installation headers observed on a fresh stable Chrome 151
/// profile. Google consumes these on its own origins; they are deliberately
/// not sent to the rest of the web.
pub const chrome_channel = "stable";
pub const chrome_year = "2026";
pub const chrome_validation = "1Arh1ZvtrDP7uKgGbOIMaEixXdo=";
pub const chrome_copyright = "Copyright 2026 Google LLC. All Rights Reserved.";
/// A stable Chrome variation seed captured from the same fresh profile.
pub const chrome_client_data = "CPWDywE=";

/// `"Not=A?Brand";v="99", "Google Chrome";v="151", "Chromium";v="151"`
pub const sec_ch_ua: [:0]const u8 = brandListHeader("version");

/// Same shape, four-part versions.
pub const sec_ch_ua_full_version_list: [:0]const u8 = brandListHeader("full_version");

pub const sec_ch_ua_mobile: [:0]const u8 = if (mobile) "?1" else "?0";

/// `Sec-CH-UA-Platform`. Follows the machine, so it is a lookup rather than a
/// constant, and it is always the quoted form of `uaPlatform()`.
pub fn secChUaPlatform() [:0]const u8 {
    return derived[active_machine_index].sec_ch_ua_platform;
}

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
pub fn screenWidth() u32 {
    return machine().screen_width;
}

pub fn screenHeight() u32 {
    return machine().screen_height;
}

/// Vertical space macOS reserves: the menu bar at the top plus the Dock at
/// the bottom. `availHeight` is `height` minus this. Kept as a delta so an
/// emulated screen size still yields a consistent avail size.
pub fn reservedHeight() u32 {
    return machine().reserved_height;
}

/// `screen.availLeft` / `screen.availTop`. The menu bar pushes the usable
/// area down by 38px; nothing reserves space on the left. Read 11 times each
/// by CreepJS, BrowserLeaks and FingerprintJS.
pub const avail_left: i32 = 0;

pub fn availTop() i32 {
    return machine().avail_top;
}

/// `screen.isExtended` — whether a second display is attached. A single
/// built-in panel is the common case and the lower-entropy answer.
pub const is_extended = false;

/// Vertical space the browser's own UI (tab strip, omnibox) takes out of the
/// window: `innerHeight` is `outerHeight` minus this. A maximized window has
/// `outerHeight == availHeight`, which is what the default viewport encodes.
pub const browser_chrome_height: u32 = 87;

/// 30, not 24 or 32: a wide-gamut Apple display reports 10 bits per channel.
pub fn colorDepth() u32 {
    return machine().color_depth;
}

/// `screen.pixelDepth`. Chrome has reported the same number for both this and
/// `colorDepth` on every desktop platform, so it is derived rather than a
/// second field that could drift.
pub fn pixelDepth() u32 {
    return colorDepth();
}

/// Retina. Drives `(resolution: 2dppx)`, which CreepJS matchMedia-probes
/// alongside the exact device-width/height.
pub fn devicePixelRatio() f64 {
    return machine().device_pixel_ratio;
}

/// The physical keyboard layout `navigator.keyboard.getLayoutMap()` reports.
/// Follows the region, not the machine: the layout travels with the person.
pub fn keyboard() machines.Keyboard {
    return region().keyboard;
}

/// The macOS Dock sits at the bottom by default, so nothing is taken off
/// the width.
pub fn availWidth(width: u32) u32 {
    return width;
}

pub fn availHeight(height: u32) u32 {
    return height -| reservedHeight();
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
    pub const downlink: f64 = 1.75;
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
    pub fn unmaskedVendor() []const u8 {
        return machine().gpu_vendor;
    }

    pub fn unmaskedRenderer() []const u8 {
        return machine().gpu_renderer;
    }
    pub const version = "WebGL 1.0 (OpenGL ES 2.0 Chromium)";

    /// getParameter limits, measured on the reference machine. ANGLE-on-Metal
    /// reports a 16384 viewport where the D3D11 backend reports 32767, and a
    /// 511px max point size where D3D11 gives 1024 — both are read by
    /// CreepJS, so they have to match the renderer string above.
    pub const max_texture_size: i64 = 16384;
    pub const max_renderbuffer_size: i64 = 16384;
    pub const max_vertex_attribs: i64 = 16;
    pub const max_varying_vectors: i64 = 30;
    pub const max_combined_texture_image_units: i64 = 32;
    pub const aliased_line_width_range = [2]f32{ 1, 1 };

    /// getParameter hands these back as typed arrays whose backing storage
    /// has to outlive the call, so they are comptime per-machine tables and
    /// these return a pointer into the active entry rather than a temporary.
    const Limits = struct {
        max_viewport_dims: [2]i32,
        aliased_point_size_range: [2]f32,
    };

    const limits: [machines.machines.len]Limits = blk: {
        var out: [machines.machines.len]Limits = undefined;
        for (machines.machines, 0..) |m, i| out[i] = .{
            .max_viewport_dims = .{ m.max_viewport, m.max_viewport },
            .aliased_point_size_range = .{ 1, m.max_point_size },
        };
        break :blk out;
    };

    pub fn maxViewportDims() *const [2]i32 {
        return &limits[active_machine_index].max_viewport_dims;
    }

    pub fn aliasedPointSizeRange() *const [2]f32 {
        return &limits[active_machine_index].aliased_point_size_range;
    }
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

/// `GET /json/version`'s `Protocol-Version`, alongside the two above.
pub const cdp_protocol_version: []const u8 = "1.3";

const testing = std.testing;

test {
    // Pulls in the tests of the submodules this file re-exports; the
    // refAllDecls in lightpanda.zig only reaches one level.
    testing.refAllDecls(@This());
}

/// The active identity, saved and put back. A test that selects a machine to
/// assert against must not leak that choice into the rest of the suite, which
/// runs against the profile test_runner pins at startup.
const Pinned = struct {
    machine_index: usize,
    region_index: usize,

    fn save() Pinned {
        return .{ .machine_index = active_machine_index, .region_index = active_region_index };
    }

    fn restore(self: Pinned) void {
        active_machine_index = self.machine_index;
        active_region_index = self.region_index;
    }
};

test "fingerprint: the UA is built from the active machine's platform block" {
    const pinned = Pinned.save();
    defer pinned.restore();

    try testing.expect(selectNamed("macbook-pro-14-m2pro", null));
    try testing.expectEqualStrings(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
        userAgent(),
    );

    try testing.expect(selectNamed("windows-1080p-intel", null));
    try testing.expectEqualStrings(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
        userAgent(),
    );

    // Every machine's UA must fit the buffer callers size from this constant.
    for (machines.machines, 0..) |_, i| {
        active_machine_index = i;
        try testing.expect(userAgent().len <= user_agent_max_len);
        // appVersion is that string minus the prefix, and nothing else.
        try testing.expect(std.mem.startsWith(u8, userAgent(), mozilla_prefix));
        try testing.expectEqualStrings(appVersion(), userAgent()[mozilla_prefix.len..]);
    }
}

test "fingerprint: client hint headers are built from the brand list" {
    const pinned = Pinned.save();
    defer pinned.restore();

    try testing.expectEqualStrings(
        "\"Not=A?Brand\";v=\"99\", \"Google Chrome\";v=\"151\", \"Chromium\";v=\"151\"",
        sec_ch_ua,
    );
    try testing.expectEqualStrings(
        "\"Not=A?Brand\";v=\"99.0.0.0\", \"Google Chrome\";v=\"151.0.7922.138\", \"Chromium\";v=\"151.0.7922.138\"",
        sec_ch_ua_full_version_list,
    );
    try testing.expectEqualStrings("?0", sec_ch_ua_mobile);

    // Sec-CH-UA-Platform follows the machine, and must agree with what
    // navigator.userAgentData.platform reports.
    try testing.expect(selectNamed("macbook-air-13-m2", null));
    try testing.expectEqualStrings("\"macOS\"", secChUaPlatform());
    try testing.expectEqualStrings("macOS", uaPlatform());

    try testing.expect(selectNamed("windows-1440p-amd", null));
    try testing.expectEqualStrings("\"Windows\"", secChUaPlatform());
    try testing.expectEqualStrings("Windows", uaPlatform());
}

test "fingerprint: window geometry derives from the active screen" {
    const pinned = Pinned.save();
    defer pinned.restore();

    // macOS: 1512x982 panel, 861 usable after the menu bar and Dock.
    try testing.expect(selectNamed("macbook-pro-14-m2pro", null));
    try testing.expectEqual(1512, availWidth(screenWidth()));
    try testing.expectEqual(861, availHeight(screenHeight()));
    try testing.expectEqual(1512, outerWidth(screenWidth()));
    try testing.expectEqual(774, outerHeight(screenHeight()) - browser_chrome_height);

    // Windows: same arithmetic, different reserved height (taskbar only).
    try testing.expect(selectNamed("windows-1080p-intel", null));
    try testing.expectEqual(1920, availWidth(screenWidth()));
    try testing.expectEqual(1032, availHeight(screenHeight()));
    try testing.expectEqual(945, outerHeight(screenHeight()) - browser_chrome_height);

    // Whatever machine is active, the viewport must be a sane slice of it.
    for (machines.machines, 0..) |_, i| {
        active_machine_index = i;
        const inner = outerHeight(screenHeight()) - browser_chrome_height;
        try testing.expect(inner > 0);
        try testing.expect(inner < screenHeight());
        try testing.expect(availHeight(screenHeight()) < screenHeight());
    }
}

test "fingerprint: a seed selects one identity and keeps it" {
    const pinned = Pinned.save();
    defer pinned.restore();

    select(12345);
    const m = machine();
    const r = region();
    select(12345);
    try testing.expectEqual(m, machine());
    try testing.expectEqual(r, region());

    // An unknown name fails loudly rather than silently defaulting.
    try testing.expect(!selectNamed("no-such-machine", null));
    try testing.expect(!selectNamed(null, "no-such-region"));
}

test "fingerprint: a screen shorter than the reserved area saturates instead of wrapping" {
    try testing.expectEqual(0, availHeight(10));
}

test "fingerprint: heap sizes round down to Chrome's 100KB boundary" {
    try testing.expectEqual(5_500_000, quantizeHeapSize(5_506_445));
    try testing.expectEqual(0, quantizeHeapSize(99_999));
}
