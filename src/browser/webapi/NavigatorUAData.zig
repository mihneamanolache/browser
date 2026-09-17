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

const js = @import("../js/js.zig");
const Execution = js.Execution;

const fingerprint = lp.fingerprint;

const NavigatorUAData = @This();

_pad: bool = false,

const Brand = struct {
    brand: []const u8,
    version: []const u8,
};

fn getBrands(_: *const NavigatorUAData) []const Brand {
    return brandList(.version);
}

fn getMobile(_: *const NavigatorUAData) bool {
    return fingerprint.mobile;
}

fn getPlatform(_: *const NavigatorUAData) []const u8 {
    return fingerprint.ua_platform;
}

pub fn toJSON(_: *const NavigatorUAData) struct {
    brands: []const Brand,
    mobile: bool,
    platform: []const u8,
} {
    return .{
        .mobile = fingerprint.mobile,
        .brands = brandList(.version),
        .platform = fingerprint.ua_platform,
    };
}

fn getHighEntropyValues(_: *const NavigatorUAData, hints: []const []const u8, exec: *const Execution) !js.Promise {
    // Per spec this always returns `brands` + `mobile` + `platform` plus
    // whichever "hints" were asked for. Returning everything regardless is
    // also valid, and is what Chrome does for the low-entropy set.
    _ = hints;

    return exec.js.local.?.resolvePromise(.{
        .brands = brandList(.version),
        .mobile = fingerprint.mobile,
        .platform = fingerprint.ua_platform,
        .architecture = fingerprint.architecture,
        .bitness = fingerprint.bitness,
        .model = fingerprint.model,
        .platformVersion = fingerprint.platform_version,
        .uaFullVersion = fingerprint.chrome_full_version,
        .fullVersionList = brandList(.full_version),
        .wow64 = fingerprint.wow64,
        .formFactor = fingerprint.form_factors,
    });
}

/// Projects the shared brand list onto the two-field shape this API exposes,
/// picking either the significant or the four-part version. The `Sec-Ch-Ua`
/// headers project the same list, so the two can never disagree.
fn brandList(comptime which: enum { version, full_version }) []const Brand {
    const out = comptime blk: {
        var arr: [fingerprint.brands.len]Brand = undefined;
        for (fingerprint.brands, 0..) |b, i| {
            arr[i] = .{
                .brand = b.brand,
                .version = switch (which) {
                    .version => b.version,
                    .full_version => b.full_version,
                },
            };
        }
        const final = arr;
        break :blk final;
    };
    return &out;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigatorUAData);

    pub const Meta = struct {
        pub const name = "NavigatorUAData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const brands = bridge.accessor(NavigatorUAData.getBrands, null, .{});
    pub const mobile = bridge.accessor(NavigatorUAData.getMobile, null, .{});
    pub const platform = bridge.accessor(NavigatorUAData.getPlatform, null, .{});
    pub const toJSON = bridge.function(NavigatorUAData.toJSON, .{});
    pub const getHighEntropyValues = bridge.function(NavigatorUAData.getHighEntropyValues, .{});
};
