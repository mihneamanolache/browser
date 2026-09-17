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

//! Turns the `--fingerprint*` flags into the one identity this process keeps.
//!
//! Lives outside `fingerprint.zig` because it is the only part that needs to
//! know about `Config` and about the network, and `Config` reads the profile.
//!
//! Call `apply` exactly once, from `main`, before anything reads a profile
//! value: `Config.HttpHeaders` bakes the UA and Accept-Language, and
//! `Platform.init` hands the locale and time zone to ICU. Selecting after
//! either of those would leave the HTTP side describing one machine and the
//! JS side another, which is worse than any single wrong value.

const std = @import("std");

const Certificates = @import("../network/Certificates.zig");
const Config = @import("../Config.zig");
const fingerprint = @import("../fingerprint.zig");
const geo = @import("geo.zig");
const machines = @import("machines.zig");

const Allocator = std.mem.Allocator;

const log = @import("../log.zig");
const io = @import("../lightpanda.zig").io;

/// How long the exit-IP lookup may take before the seeded region is kept. Two
/// seconds is generous for a single small GET and short enough that a dead
/// endpoint does not become a visible startup stall.
const geo_timeout_ms: u31 = 2000;

pub fn apply(allocator: Allocator, config: *const Config) void {
    // --fingerprint-list prints a table and exits; resolving an exit IP for a
    // run that will not browse is a pointless couple of seconds.
    if (config.fingerprintList()) return;

    const seed = config.fingerprintSeed() orelse randomSeed();
    fingerprint.select(seed);

    // An explicit machine wins over the seed; an explicit region wins over
    // both the seed and the exit IP. Someone who names a value is reproducing
    // a run or matching a cookie jar, and neither survives being overridden.
    if (config.fingerprintMachine()) |name| {
        if (!fingerprint.selectNamed(name, null)) {
            log.fatal(.app, "unknown fingerprint machine", .{
                .name = name,
                .hint = "run with --fingerprint-list to see the available profiles",
            });
            std.process.exit(1);
        }
    }

    const region_flag = config.fingerprintRegion();
    const auto = if (region_flag) |name| std.mem.eql(u8, name, "auto") else config.httpProxy() != null;

    if (region_flag) |name| {
        if (!auto and !fingerprint.selectNamed(null, name)) {
            log.fatal(.app, "unknown fingerprint region", .{
                .name = name,
                .hint = "run with --fingerprint-list to see the available regions, or pass \"auto\" to follow the proxy's exit IP",
            });
            std.process.exit(1);
        }
    }

    if (auto) applyExitCountry(allocator, config, seed);

    const m = fingerprint.machine();
    const r = fingerprint.region();
    log.info(.app, "fingerprint profile", .{
        .machine = m.name,
        .region = r.name,
        .timezone = r.timezone,
        .locale = r.locale,
        // Printed so a run that hit something interesting can be repeated
        // exactly with --fingerprint-seed.
        .seed = seed,
    });
}

/// Moves the region to the proxy's exit country. Every failure here is a
/// no-op: the seeded region stays, and the run continues.
fn applyExitCountry(allocator: Allocator, config: *const Config, seed: u64) void {
    const proxy = config.httpProxy();
    if (proxy == null) {
        log.debug(.app, "fingerprint region auto without a proxy", .{
            .note = "resolving the host's own exit IP",
        });
    }

    // Its own store: Network does not exist yet, and this one is thrown away
    // as soon as the lookup returns.
    const certificates = Certificates.init(allocator, config) catch |err| {
        log.warn(.app, "exit country lookup skipped", .{ .err = err, .note = "no CA store" });
        return;
    };
    defer certificates.deinit();

    const found = geo.lookup(certificates, proxy, geo_timeout_ms) orelse {
        log.warn(.app, "exit country lookup failed", .{
            .region = fingerprint.region().name,
            .note = "keeping the seeded region; the time zone may not match the exit IP",
        });
        return;
    };

    const country = &found.country;
    const region = fingerprint.selectRegionForCountry(country, seed) orelse {
        log.warn(.app, "no region for exit country", .{
            .country = country,
            .region = fingerprint.region().name,
            .hint = "add the country to a region in src/fingerprint/machines.zig",
        });
        return;
    };

    log.debug(.app, "region follows exit ip", .{
        .country = country,
        .region = region.name,
        .source = found.source,
    });
}

/// A fresh identity per process unless `--fingerprint-seed` says otherwise, so
/// two crawlers started from the same command line are not the same machine in
/// the same city. The seed is logged, which is what makes a run repeatable.
fn randomSeed() u64 {
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    return seed;
}

/// `--fingerprint-list`: the names `--fingerprint` and `--fingerprint-region`
/// accept, with enough detail to choose between them.
pub fn list(writer: *std.Io.Writer) !void {
    try writer.writeAll("machines (--fingerprint <NAME>)\n");
    for (machines.machines) |m| {
        try writer.print("  {s: <22} {d}x{d}  {d} cores  {d}GB  {s}\n", .{
            m.name,
            m.screen_width,
            m.screen_height,
            m.hardware_concurrency,
            @as(u32, @intFromFloat(m.device_memory)),
            m.gpu_renderer,
        });
    }

    try writer.writeAll("\nregions (--fingerprint-region <NAME>, or \"auto\" to follow the proxy's exit IP)\n");
    for (machines.regions) |r| {
        try writer.print("  {s: <12} {s: <32} {s: <6} {s}\n", .{
            r.name,
            r.timezone,
            r.locale,
            r.accept_language,
        });
    }
}
