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

//! The machines this browser can claim to be, and the regions it can claim to
//! be in.
//!
//! WHY A TABLE AND NOT RANDOM FIELDS
//!
//! Randomising each value independently produces machines that do not exist:
//! ten CPU cores next to an Intel UHD 620, a 30-bit colour depth on Windows,
//! a Retina pixel ratio on a 1366x768 panel. Any one of those is a stronger
//! signal than a fixed profile would have been, because a fingerprinter does
//! not need to recognise *you* -- it only needs to notice that the
//! combination is impossible. CreepJS scores exactly this kind of internal
//! contradiction ("lies") rather than the values themselves.
//!
//! So the unit of randomness is a whole machine. Each entry below is a real,
//! common configuration whose fields were taken together, and the selector
//! picks among entries rather than among fields. Two independent dimensions
//! that genuinely do vary independently -- the hardware and where it is --
//! are separate tables, because a MacBook in Berlin is as real as one in
//! Chicago.
//!
//! ADDING AN ENTRY: copy every field from one real machine. Do not mix and
//! match, and do not invent a resolution. The GPU renderer string in
//! particular has to match the platform *and* the architecture: an
//! "ANGLE (Apple, ANGLE Metal Renderer...)" on a Win32 profile is an instant
//! contradiction, and so is a D3D11 renderer on macOS.

const std = @import("std");

pub const Os = enum { macos, windows };

/// One coherent machine. Every field here was observed together on a real
/// device; see the module comment before editing any of them in isolation.
pub const Machine = struct {
    name: []const u8, // for --fingerprint-list and logs, never exposed to a page
    os: Os,

    /// The frozen platform block of the UA string, e.g.
    /// "Macintosh; Intel Mac OS X 10_15_7". Chrome freezes these: every Mac
    /// says 10_15_7 including Apple Silicon, and every 64-bit Windows says
    /// "Windows NT 10.0; Win64; x64" including Windows 11.
    ua_platform_block: []const u8,
    /// navigator.platform
    platform: []const u8,
    /// navigator.userAgentData.platform and Sec-CH-UA-Platform
    ua_platform: [:0]const u8,
    /// High-entropy platformVersion. On macOS this is the only place the real
    /// OS version appears, because the UA string is frozen.
    platform_version: [:0]const u8,
    architecture: [:0]const u8,
    bitness: [:0]const u8,

    screen_width: u32,
    screen_height: u32,
    /// Screen height minus this is availHeight: menu bar + Dock on macOS,
    /// taskbar on Windows.
    reserved_height: u32,
    /// availTop: the macOS menu bar pushes the usable area down; Windows
    /// keeps its taskbar at the bottom, so availTop is 0 there.
    avail_top: i32,
    /// 30 on a wide-gamut Apple panel, 24 on typical Windows. Never 32 on a
    /// modern Chrome despite what a lot of spoofing code assumes.
    color_depth: u32,
    device_pixel_ratio: f64,

    hardware_concurrency: u32,
    device_memory: f64,

    /// getParameter(UNMASKED_VENDOR_WEBGL / UNMASKED_RENDERER_WEBGL).
    gpu_vendor: []const u8,
    gpu_renderer: []const u8,
    /// MAX_VIEWPORT_DIMS and ALIASED_POINT_SIZE_RANGE differ by backend:
    /// ANGLE-on-Metal reports 16384 and 511 where D3D11 reports 32767 and
    /// 1024. Both are read, so they travel with the renderer string.
    max_viewport: i32,
    max_point_size: f32,
};

/// Real configurations, each captured as a whole. The macOS entries use the
/// logical (CSS) resolution Chrome reports, not the physical panel size.
pub const machines = [_]Machine{
    .{
        .name = "macbook-pro-14-m2pro",
        .os = .macos,
        .ua_platform_block = "Macintosh; Intel Mac OS X 10_15_7",
        .platform = "MacIntel",
        .ua_platform = "macOS",
        .platform_version = "14.8.1",
        .architecture = "arm",
        .bitness = "64",
        .screen_width = 1512,
        .screen_height = 982,
        .reserved_height = 121,
        .avail_top = 38,
        .color_depth = 30,
        .device_pixel_ratio = 2,
        .hardware_concurrency = 10,
        .device_memory = 16,
        .gpu_vendor = "Google Inc. (Apple)",
        .gpu_renderer = "ANGLE (Apple, ANGLE Metal Renderer: Apple M2 Pro, Unspecified Version)",
        .max_viewport = 16384,
        .max_point_size = 511,
    },
    .{
        .name = "macbook-air-13-m2",
        .os = .macos,
        .ua_platform_block = "Macintosh; Intel Mac OS X 10_15_7",
        .platform = "MacIntel",
        .ua_platform = "macOS",
        .platform_version = "14.7.2",
        .architecture = "arm",
        .bitness = "64",
        .screen_width = 1470,
        .screen_height = 956,
        .reserved_height = 121,
        .avail_top = 38,
        .color_depth = 30,
        .device_pixel_ratio = 2,
        .hardware_concurrency = 8,
        .device_memory = 8,
        .gpu_vendor = "Google Inc. (Apple)",
        .gpu_renderer = "ANGLE (Apple, ANGLE Metal Renderer: Apple M2, Unspecified Version)",
        .max_viewport = 16384,
        .max_point_size = 511,
    },
    .{
        .name = "macbook-pro-16-m3pro",
        .os = .macos,
        .ua_platform_block = "Macintosh; Intel Mac OS X 10_15_7",
        .platform = "MacIntel",
        .ua_platform = "macOS",
        .platform_version = "15.1.0",
        .architecture = "arm",
        .bitness = "64",
        .screen_width = 1728,
        .screen_height = 1117,
        .reserved_height = 121,
        .avail_top = 38,
        .color_depth = 30,
        .device_pixel_ratio = 2,
        .hardware_concurrency = 12,
        .device_memory = 16,
        .gpu_vendor = "Google Inc. (Apple)",
        .gpu_renderer = "ANGLE (Apple, ANGLE Metal Renderer: Apple M3 Pro, Unspecified Version)",
        .max_viewport = 16384,
        .max_point_size = 511,
    },
    .{
        // The most common desktop configuration on the web by a wide margin.
        .name = "windows-1080p-intel",
        .os = .windows,
        .ua_platform_block = "Windows NT 10.0; Win64; x64",
        .platform = "Win32",
        .ua_platform = "Windows",
        .platform_version = "19.0.0",
        .architecture = "x86",
        .bitness = "64",
        .screen_width = 1920,
        .screen_height = 1080,
        .reserved_height = 48,
        .avail_top = 0,
        .color_depth = 24,
        .device_pixel_ratio = 1,
        .hardware_concurrency = 8,
        .device_memory = 8,
        .gpu_vendor = "Google Inc. (Intel)",
        .gpu_renderer = "ANGLE (Intel, Intel(R) UHD Graphics 620 (0x00005917) Direct3D11 vs_5_0 ps_5_0, D3D11)",
        .max_viewport = 32767,
        .max_point_size = 1024,
    },
    .{
        .name = "windows-1080p-nvidia",
        .os = .windows,
        .ua_platform_block = "Windows NT 10.0; Win64; x64",
        .platform = "Win32",
        .ua_platform = "Windows",
        .platform_version = "15.0.0",
        .architecture = "x86",
        .bitness = "64",
        .screen_width = 1920,
        .screen_height = 1080,
        .reserved_height = 48,
        .avail_top = 0,
        .color_depth = 24,
        .device_pixel_ratio = 1,
        .hardware_concurrency = 16,
        .device_memory = 8,
        .gpu_vendor = "Google Inc. (NVIDIA)",
        .gpu_renderer = "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 (0x00002503) Direct3D11 vs_5_0 ps_5_0, D3D11)",
        .max_viewport = 32767,
        .max_point_size = 1024,
    },
    .{
        // 1536x864 is a 1920x1080 panel at Windows' 125% default scaling,
        // which is why the pixel ratio is 1.25 and not 1.
        .name = "windows-laptop-scaled",
        .os = .windows,
        .ua_platform_block = "Windows NT 10.0; Win64; x64",
        .platform = "Win32",
        .ua_platform = "Windows",
        .platform_version = "19.0.0",
        .architecture = "x86",
        .bitness = "64",
        .screen_width = 1536,
        .screen_height = 864,
        .reserved_height = 48,
        .avail_top = 0,
        .color_depth = 24,
        .device_pixel_ratio = 1.25,
        .hardware_concurrency = 8,
        .device_memory = 8,
        .gpu_vendor = "Google Inc. (Intel)",
        .gpu_renderer = "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics (0x000046A8) Direct3D11 vs_5_0 ps_5_0, D3D11)",
        .max_viewport = 32767,
        .max_point_size = 1024,
    },
    .{
        .name = "windows-1440p-amd",
        .os = .windows,
        .ua_platform_block = "Windows NT 10.0; Win64; x64",
        .platform = "Win32",
        .ua_platform = "Windows",
        .platform_version = "15.0.0",
        .architecture = "x86",
        .bitness = "64",
        .screen_width = 2560,
        .screen_height = 1440,
        .reserved_height = 48,
        .avail_top = 0,
        .color_depth = 24,
        .device_pixel_ratio = 1,
        .hardware_concurrency = 12,
        .device_memory = 16,
        .gpu_vendor = "Google Inc. (AMD)",
        .gpu_renderer = "ANGLE (AMD, AMD Radeon RX 6600 (0x000073FF) Direct3D11 vs_5_0 ps_5_0, D3D11)",
        .max_viewport = 32767,
        .max_point_size = 1024,
    },
};

/// Where the machine is. Separate from the hardware because the two really
/// are independent -- a MacBook in Berlin is as real as one in Chicago -- and
/// because for crawling this dimension should follow the exit IP, not the
/// machine. `--timezone` and `--locale` override it.
///
/// `countries` is what makes that possible: with `--fingerprint-region auto`
/// the exit IP's country is resolved through the proxy and mapped here, so a
/// German proxy gets Europe/Berlin and de-DE rather than whatever the seed
/// happened to draw. A timezone that contradicts the IP is one of the first
/// things a fingerprinter checks, and the cheapest to get right.
pub const Region = struct {
    name: []const u8,
    /// ISO 3166-1 alpha-2 codes this region is a plausible identity for.
    /// Several regions may claim the same country (a US exit could be in any
    /// of three zones); the seed breaks the tie.
    countries: []const []const u8,
    /// IANA id; becomes ICU's default zone, so Date#getTimezoneOffset and
    /// Intl both follow it.
    timezone: [:0]const u8,
    /// BCP 47 tag, reported as navigator.language.
    locale: [:0]const u8,
    /// The full Accept-Language header. Chrome builds this from the OS
    /// preferred-languages list, so it is captured rather than derived: a
    /// naive "tag,primary;q=0.9" is a shape Chrome often does not produce.
    /// navigator.languages is read straight off it, so the two cannot drift.
    accept_language: [:0]const u8,
    /// Physical keyboard layout, as `navigator.keyboard.getLayoutMap()`
    /// reports it. It travels with the region and not the machine because it
    /// follows the person, and a QWERTY layout under a fr-FR locale is the
    /// kind of contradiction CreepJS scores.
    keyboard: Keyboard,
};

/// The layouts `navigator.keyboard.getLayoutMap()` can report. Only the keys
/// that actually move between layouts are modelled; see keyboard.zig.
pub const Keyboard = enum { qwerty, qwertz, azerty, qwerty_uk };

/// Ordered roughly by how much proxy traffic exits there, which matters only
/// for readability -- `pick` treats every entry the same.
pub const regions = [_]Region{
    .{ .name = "us-east", .countries = &.{"US"}, .timezone = "America/New_York", .locale = "en-US", .accept_language = "en-US,en;q=0.9", .keyboard = .qwerty },
    .{ .name = "us-central", .countries = &.{"US"}, .timezone = "America/Chicago", .locale = "en-US", .accept_language = "en-US,en;q=0.9", .keyboard = .qwerty },
    .{ .name = "us-west", .countries = &.{"US"}, .timezone = "America/Los_Angeles", .locale = "en-US", .accept_language = "en-US,en;q=0.9", .keyboard = .qwerty },
    .{ .name = "ca-en", .countries = &.{"CA"}, .timezone = "America/Toronto", .locale = "en-CA", .accept_language = "en-CA,en-US;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "ca-fr", .countries = &.{"CA"}, .timezone = "America/Montreal", .locale = "fr-CA", .accept_language = "fr-CA,fr;q=0.9,en-CA;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "mx", .countries = &.{"MX"}, .timezone = "America/Mexico_City", .locale = "es-MX", .accept_language = "es-MX,es;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "br", .countries = &.{"BR"}, .timezone = "America/Sao_Paulo", .locale = "pt-BR", .accept_language = "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "ar", .countries = &.{"AR"}, .timezone = "America/Argentina/Buenos_Aires", .locale = "es-AR", .accept_language = "es-AR,es;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "cl", .countries = &.{"CL"}, .timezone = "America/Santiago", .locale = "es-CL", .accept_language = "es-CL,es;q=0.9,en;q=0.8", .keyboard = .qwerty },

    .{ .name = "uk", .countries = &.{"GB"}, .timezone = "Europe/London", .locale = "en-GB", .accept_language = "en-GB,en-US;q=0.9,en;q=0.8", .keyboard = .qwerty_uk },
    .{ .name = "ie", .countries = &.{"IE"}, .timezone = "Europe/Dublin", .locale = "en-IE", .accept_language = "en-IE,en-GB;q=0.9,en;q=0.8", .keyboard = .qwerty_uk },
    .{ .name = "de", .countries = &.{"DE"}, .timezone = "Europe/Berlin", .locale = "de-DE", .accept_language = "de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwertz },
    .{ .name = "at", .countries = &.{"AT"}, .timezone = "Europe/Vienna", .locale = "de-AT", .accept_language = "de-AT,de;q=0.9,en;q=0.8", .keyboard = .qwertz },
    .{ .name = "ch", .countries = &.{"CH"}, .timezone = "Europe/Zurich", .locale = "de-CH", .accept_language = "de-CH,de;q=0.9,en;q=0.8", .keyboard = .qwertz },
    .{ .name = "fr", .countries = &.{"FR"}, .timezone = "Europe/Paris", .locale = "fr-FR", .accept_language = "fr-FR,fr;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .azerty },
    .{ .name = "be", .countries = &.{"BE"}, .timezone = "Europe/Brussels", .locale = "fr-BE", .accept_language = "fr-BE,fr;q=0.9,nl;q=0.8,en;q=0.7", .keyboard = .azerty },
    .{ .name = "nl", .countries = &.{"NL"}, .timezone = "Europe/Amsterdam", .locale = "nl-NL", .accept_language = "nl-NL,nl;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "es", .countries = &.{"ES"}, .timezone = "Europe/Madrid", .locale = "es-ES", .accept_language = "es-ES,es;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "pt", .countries = &.{"PT"}, .timezone = "Europe/Lisbon", .locale = "pt-PT", .accept_language = "pt-PT,pt;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "it", .countries = &.{"IT"}, .timezone = "Europe/Rome", .locale = "it-IT", .accept_language = "it-IT,it;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "pl", .countries = &.{"PL"}, .timezone = "Europe/Warsaw", .locale = "pl-PL", .accept_language = "pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "cz", .countries = &.{"CZ"}, .timezone = "Europe/Prague", .locale = "cs-CZ", .accept_language = "cs-CZ,cs;q=0.9,en;q=0.8", .keyboard = .qwertz },
    .{ .name = "se", .countries = &.{"SE"}, .timezone = "Europe/Stockholm", .locale = "sv-SE", .accept_language = "sv-SE,sv;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "no", .countries = &.{"NO"}, .timezone = "Europe/Oslo", .locale = "nb-NO", .accept_language = "nb-NO,nb;q=0.9,no;q=0.8,en-US;q=0.7,en;q=0.6", .keyboard = .qwerty },
    .{ .name = "dk", .countries = &.{"DK"}, .timezone = "Europe/Copenhagen", .locale = "da-DK", .accept_language = "da-DK,da;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "fi", .countries = &.{"FI"}, .timezone = "Europe/Helsinki", .locale = "fi-FI", .accept_language = "fi-FI,fi;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "ro", .countries = &.{"RO"}, .timezone = "Europe/Bucharest", .locale = "ro-RO", .accept_language = "ro-RO,ro;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "gr", .countries = &.{"GR"}, .timezone = "Europe/Athens", .locale = "el-GR", .accept_language = "el-GR,el;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "tr", .countries = &.{"TR"}, .timezone = "Europe/Istanbul", .locale = "tr-TR", .accept_language = "tr-TR,tr;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "ua", .countries = &.{"UA"}, .timezone = "Europe/Kyiv", .locale = "uk-UA", .accept_language = "uk-UA,uk;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "ru", .countries = &.{"RU"}, .timezone = "Europe/Moscow", .locale = "ru-RU", .accept_language = "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },

    .{ .name = "au", .countries = &.{"AU"}, .timezone = "Australia/Sydney", .locale = "en-AU", .accept_language = "en-AU,en-GB;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "nz", .countries = &.{"NZ"}, .timezone = "Pacific/Auckland", .locale = "en-NZ", .accept_language = "en-NZ,en-AU;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "jp", .countries = &.{"JP"}, .timezone = "Asia/Tokyo", .locale = "ja-JP", .accept_language = "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "kr", .countries = &.{"KR"}, .timezone = "Asia/Seoul", .locale = "ko-KR", .accept_language = "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "sg", .countries = &.{"SG"}, .timezone = "Asia/Singapore", .locale = "en-SG", .accept_language = "en-SG,en-GB;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "hk", .countries = &.{"HK"}, .timezone = "Asia/Hong_Kong", .locale = "zh-HK", .accept_language = "zh-HK,zh;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "tw", .countries = &.{"TW"}, .timezone = "Asia/Taipei", .locale = "zh-TW", .accept_language = "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "in", .countries = &.{"IN"}, .timezone = "Asia/Kolkata", .locale = "en-IN", .accept_language = "en-IN,en-GB;q=0.9,en;q=0.8,hi;q=0.7", .keyboard = .qwerty },
    .{ .name = "id", .countries = &.{"ID"}, .timezone = "Asia/Jakarta", .locale = "id-ID", .accept_language = "id-ID,id;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "th", .countries = &.{"TH"}, .timezone = "Asia/Bangkok", .locale = "th-TH", .accept_language = "th-TH,th;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "vn", .countries = &.{"VN"}, .timezone = "Asia/Ho_Chi_Minh", .locale = "vi-VN", .accept_language = "vi-VN,vi;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "ph", .countries = &.{"PH"}, .timezone = "Asia/Manila", .locale = "en-PH", .accept_language = "en-PH,en-US;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "my", .countries = &.{"MY"}, .timezone = "Asia/Kuala_Lumpur", .locale = "en-MY", .accept_language = "en-MY,en-GB;q=0.9,en;q=0.8,ms;q=0.7", .keyboard = .qwerty },
    .{ .name = "ae", .countries = &.{"AE"}, .timezone = "Asia/Dubai", .locale = "en-AE", .accept_language = "en-AE,en-GB;q=0.9,en;q=0.8,ar;q=0.7", .keyboard = .qwerty },
    .{ .name = "il", .countries = &.{"IL"}, .timezone = "Asia/Jerusalem", .locale = "he-IL", .accept_language = "he-IL,he;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
    .{ .name = "za", .countries = &.{"ZA"}, .timezone = "Africa/Johannesburg", .locale = "en-ZA", .accept_language = "en-ZA,en-GB;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "ng", .countries = &.{"NG"}, .timezone = "Africa/Lagos", .locale = "en-NG", .accept_language = "en-NG,en-GB;q=0.9,en;q=0.8", .keyboard = .qwerty },
    .{ .name = "eg", .countries = &.{"EG"}, .timezone = "Africa/Cairo", .locale = "ar-EG", .accept_language = "ar-EG,ar;q=0.9,en-US;q=0.8,en;q=0.7", .keyboard = .qwerty },
};

/// Picks a machine and a region from a seed.
///
/// The two dimensions are drawn from different parts of the seed so that
/// nearby seeds do not produce correlated pairs, and a seed is required
/// rather than optional: a crawl that changes identity mid-session, or
/// between earning a cookie jar and replaying it, contradicts itself. Callers
/// that want a fresh identity ask for one explicitly.
pub fn pick(seed: u64) struct { machine: *const Machine, region: *const Region } {
    const z = mix(seed);
    return .{
        .machine = &machines[@intCast(z % machines.len)],
        .region = &regions[@intCast((z >> 32) % regions.len)],
    };
}

/// SplitMix64 finalizer: cheap, and it decorrelates the low bits that a plain
/// modulo would otherwise expose for small sequential seeds.
fn mix(seed: u64) u64 {
    var z = seed +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn machineByName(name: []const u8) ?*const Machine {
    for (&machines) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

pub fn regionByName(name: []const u8) ?*const Region {
    for (&regions) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// The region to claim for an exit IP in `country` (ISO 3166-1 alpha-2, case
/// insensitive). Where several regions serve one country -- the US has three
/// time zones in this table -- the seed picks among them, so two crawlers
/// behind the same US proxy pool are not both in New York.
///
/// Returns null for a country the table does not cover, which the caller
/// should treat as "keep the seeded region" rather than as an error: an
/// unknown country is not a reason to refuse to browse.
pub fn regionForCountry(country: []const u8, seed: u64) ?*const Region {
    if (country.len != 2) return null;

    var matches: [regions.len]*const Region = undefined;
    var n: usize = 0;
    for (&regions) |*r| {
        for (r.countries) |c| {
            if (std.ascii.eqlIgnoreCase(c, country)) {
                matches[n] = r;
                n += 1;
                break;
            }
        }
    }
    if (n == 0) return null;
    return matches[@intCast(mix(seed) % n)];
}

const testing = std.testing;

test "machines: every entry is internally coherent" {
    for (machines) |m| {
        // The platform triple has to agree with itself.
        switch (m.os) {
            .macos => {
                try testing.expectEqualStrings("MacIntel", m.platform);
                try testing.expectEqualStrings("macOS", m.ua_platform);
                try testing.expect(std.mem.indexOf(u8, m.ua_platform_block, "Macintosh") != null);
                // ANGLE-on-Metal limits travel with an Apple renderer.
                try testing.expect(std.mem.indexOf(u8, m.gpu_renderer, "Metal") != null);
                try testing.expectEqual(@as(i32, 16384), m.max_viewport);
                // Only Apple panels report 30-bit colour here.
                try testing.expectEqual(@as(u32, 30), m.color_depth);
                // The menu bar is why availTop is non-zero.
                try testing.expect(m.avail_top > 0);
            },
            .windows => {
                try testing.expectEqualStrings("Win32", m.platform);
                try testing.expectEqualStrings("Windows", m.ua_platform);
                try testing.expect(std.mem.indexOf(u8, m.ua_platform_block, "Windows NT") != null);
                try testing.expect(std.mem.indexOf(u8, m.gpu_renderer, "D3D11") != null);
                try testing.expectEqual(@as(i32, 32767), m.max_viewport);
                try testing.expectEqual(@as(u32, 24), m.color_depth);
                // The taskbar sits at the bottom, so nothing is reserved at the top.
                try testing.expectEqual(@as(i32, 0), m.avail_top);
            },
        }

        // A screen smaller than its own reserved area would make availHeight
        // saturate to zero, which no real machine reports.
        try testing.expect(m.screen_height > m.reserved_height);
        try testing.expect(m.screen_width > 0);

        // Plausible hardware. Chrome caps deviceMemory at 8 on most builds but
        // reports higher on some; either way these are powers of two and the
        // core count is even.
        try testing.expect(m.hardware_concurrency >= 4 and m.hardware_concurrency <= 32);
        try testing.expectEqual(@as(u32, 0), m.hardware_concurrency % 2);
        try testing.expect(m.device_memory >= 4 and m.device_memory <= 32);

        try testing.expect(m.device_pixel_ratio >= 1 and m.device_pixel_ratio <= 3);
        // Retina is an Apple thing in this table; a 2x Windows panel would
        // need its own entry with a matching resolution.
        if (m.device_pixel_ratio == 2) try testing.expectEqual(Os.macos, m.os);
    }
}

test "machines: every region's accept-language leads with its own locale" {
    for (regions) |r| {
        try testing.expect(std.mem.startsWith(u8, r.accept_language, r.locale));
        try testing.expect(std.mem.indexOf(u8, r.timezone, "/") != null);
        // A region nothing can map an exit IP to is dead weight.
        try testing.expect(r.countries.len > 0);
        for (r.countries) |c| try testing.expectEqual(@as(usize, 2), c.len);
    }
}

test "machines: an exit country maps to a region that claims it" {
    const de = regionForCountry("DE", 0).?;
    try testing.expectEqualStrings("Europe/Berlin", de.timezone);
    // Case is whatever the geo service felt like sending.
    try testing.expectEqual(de, regionForCountry("de", 0).?);

    // Every US region is reachable, and none of them is somewhere else.
    var seen: [3]bool = @splat(false);
    for (0..256) |i| {
        const r = regionForCountry("US", i).?;
        try testing.expectEqualStrings("en-US", r.locale);
        if (std.mem.eql(u8, r.name, "us-east")) seen[0] = true;
        if (std.mem.eql(u8, r.name, "us-central")) seen[1] = true;
        if (std.mem.eql(u8, r.name, "us-west")) seen[2] = true;
    }
    for (seen) |s| try testing.expect(s);

    // An uncovered or malformed country is a miss, not a wrong answer.
    try testing.expectEqual(@as(?*const Region, null), regionForCountry("ZZ", 0));
    try testing.expectEqual(@as(?*const Region, null), regionForCountry("", 0));
    try testing.expectEqual(@as(?*const Region, null), regionForCountry("USA", 0));
}

test "machines: pick is deterministic and spreads across the tables" {
    // Same seed, same identity -- a jar earned under one seed has to replay
    // under it.
    const a = pick(42);
    const b = pick(42);
    try testing.expectEqual(a.machine, b.machine);
    try testing.expectEqual(a.region, b.region);

    // And sequential seeds must not collapse onto one entry.
    var seen_machines: [machines.len]bool = @splat(false);
    var seen_regions: [regions.len]bool = @splat(false);
    for (0..512) |i| {
        const p = pick(i);
        for (&machines, 0..) |*m, j| if (m == p.machine) {
            seen_machines[j] = true;
        };
        for (&regions, 0..) |*r, j| if (r == p.region) {
            seen_regions[j] = true;
        };
    }
    for (seen_machines) |s| try testing.expect(s);
    for (seen_regions) |s| try testing.expect(s);
}
