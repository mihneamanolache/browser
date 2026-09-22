// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const std = @import("std");

const js = @import("../js/js.zig");
const Execution = js.Execution;

const FeaturePolicy = @This();

// Blink exposes this legacy interface alongside Permissions Policy. The
// sequence is observable and varies as Chromium adds origin-trial features,
// so keep it aligned with the project's Chrome 151 reference build.
const features_: []const []const u8 = &.{
    "geolocation",
    "ch-ua-full-version-list",
    "cross-origin-isolated",
    "screen-wake-lock",
    "on-device-speech-recognition",
    "translator",
    "publickey-credentials-get",
    "shared-storage-select-url",
    "ch-ua-arch",
    "bluetooth",
    "compute-pressure",
    "ch-prefers-reduced-transparency",
    "deferred-fetch",
    "usb",
    "ch-save-data",
    "publickey-credentials-create",
    "shared-storage",
    "deferred-fetch-minimal",
    "run-ad-auction",
    "ch-downlink",
    "ch-ua-form-factors",
    "otp-credentials",
    "payment",
    "ch-ua",
    "ch-ua-model",
    "ch-ect",
    "autoplay",
    "camera",
    "language-detector",
    "private-state-token-issuance",
    "digital-credentials-get",
    "accelerometer",
    "ch-ua-platform-version",
    "idle-detection",
    "language-model",
    "private-aggregation",
    "interest-cohort",
    "ch-viewport-height",
    "captured-surface-control",
    "local-fonts",
    "ch-ua-platform",
    "midi",
    "ch-ua-full-version",
    "xr-spatial-tracking",
    "clipboard-read",
    "gamepad",
    "display-capture",
    "keyboard-map",
    "join-ad-interest-group",
    "aria-notify",
    "local-network",
    "ch-ua-high-entropy-values",
    "ch-width",
    "ch-prefers-reduced-motion",
    "browsing-topics",
    "encrypted-media",
    "local-network-access",
    "gyroscope",
    "serial",
    "ch-rtt",
    "ch-ua-mobile",
    "window-management",
    "unload",
    "ch-dpr",
    "ch-prefers-color-scheme",
    "ch-ua-wow64",
    "attribution-reporting",
    "fullscreen",
    "identity-credentials-get",
    "private-state-token-redemption",
    "hid",
    "summarizer",
    "ch-ua-bitness",
    "storage-access",
    "sync-xhr",
    "ch-device-memory",
    "ch-viewport-width",
    "picture-in-picture",
    "loopback-network",
    "magnetometer",
    "clipboard-write",
    "microphone",
};

// A top-level Chrome 151 document exposes every feature above except unload,
// whose default allowlist is empty. Response-header and iframe allowlist
// restrictions can narrow this baseline in a future policy parser.
const disabled_by_default: []const []const u8 = &.{"unload"};

_origin: ?[]const u8,

fn isKnown(feature: []const u8) bool {
    for (features_) |candidate| {
        if (std.mem.eql(u8, candidate, feature)) return true;
    }
    return false;
}

fn isAllowed(feature: []const u8) bool {
    if (!isKnown(feature)) return false;
    for (disabled_by_default) |candidate| {
        if (std.mem.eql(u8, candidate, feature)) return false;
    }
    return true;
}

fn features(_: *const FeaturePolicy) []const []const u8 {
    return features_;
}

fn allowedFeatures(_: *const FeaturePolicy, exec: *const Execution) ![]const []const u8 {
    const result = try exec.local_arena.alloc([]const u8, features_.len - disabled_by_default.len);
    var index: usize = 0;
    for (features_) |feature| {
        if (!isAllowed(feature)) continue;
        result[index] = feature;
        index += 1;
    }
    return result[0..index];
}

fn allowsFeature(self: *const FeaturePolicy, feature: []const u8, origin: ?[]const u8) bool {
    if (!isAllowed(feature)) return false;
    const document_origin = self._origin orelse return false;
    const requested_origin = origin orelse document_origin;
    return std.mem.eql(u8, document_origin, requested_origin);
}

fn getAllowlistForFeature(self: *const FeaturePolicy, feature: []const u8, exec: *const Execution) ![]const []const u8 {
    if (!isAllowed(feature)) return &.{};
    const origin = self._origin orelse return &.{};
    const result = try exec.local_arena.alloc([]const u8, 1);
    result[0] = origin;
    return result;
}

fn constructor(exec: *const Execution) !*FeaturePolicy {
    return exec.js.typeError("Illegal constructor");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FeaturePolicy);

    pub const Meta = struct {
        pub const name = "FeaturePolicy";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FeaturePolicy.constructor, .{});
    pub const allowedFeatures = bridge.function(FeaturePolicy.allowedFeatures, .{});
    pub const allowsFeature = bridge.function(FeaturePolicy.allowsFeature, .{});
    pub const features = bridge.function(FeaturePolicy.features, .{});
    pub const getAllowlistForFeature = bridge.function(FeaturePolicy.getAllowlistForFeature, .{});
};

test "WebApi: FeaturePolicy" {
    const testing = @import("../../testing.zig");
    try testing.htmlRunner("feature_policy.html", .{});
}
