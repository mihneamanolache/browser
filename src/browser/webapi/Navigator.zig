// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Execution = js.Execution;

const HttpClient = @import("../../network/HttpClient.zig");
const URL = @import("../URL.zig");
const body_init = @import("net/body_init.zig");
const BodyInit = body_init.BodyInit;
const PluginArray = @import("PluginArray.zig");
const MimeTypeArray = PluginArray.MimeTypeArray;
const Permissions = @import("Permissions.zig");
const NetworkInformation = @import("net/NetworkInformation.zig");
const UserActivation = @import("UserActivation.zig");
const BatteryManager = @import("BatteryManager.zig");
const ModelContext = @import("ModelContext.zig");
const StorageManager = @import("StorageManager.zig");
const Keyboard = @import("Keyboard.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");
const Geolocation = @import("geolocation/Geolocation.zig");

const fingerprint = lp.fingerprint;

const Navigator = @This();

comptime {
    // Ensure we don't cause an identity map conflict. Because _geolocation is
    // lazy and, for now, Zig orders the highest-aligned field first, none of
    // the other fields land at offset 0.
    for ([_][]const u8{ "_permissions", "_storage", "_ua_data", "_user_activation", "_keyboard" }) |name| {
        if (@offsetOf(Navigator, name) == 0) @compileError(name ++ " aliases the Navigator");
    }
}

_plugins: ?*PluginArray = null,
_permissions: Permissions = .{},
_geolocation: ?*Geolocation = null,
_storage: StorageManager = .{},
_ua_data: NavigatorUAData = .{},
_user_activation: UserActivation = .{},
_keyboard: Keyboard = .{},
_connection: ?*NetworkInformation = null,

pub const init: Navigator = .{};

pub fn getUserAgent(_: *const Navigator, exec: *const Execution) []const u8 {
    return exec.session.browser.http_client.getUserAgent();
}

pub fn getLanguages(_: *const Navigator, exec: *const Execution) []const []const u8 {
    return exec.session.browser.http_client.getLanguages();
}

fn getDoNotTrack(_: *const Navigator) ?[]const u8 {
    return null;
}

pub fn getAppName(_: *const Navigator) []const u8 {
    return fingerprint.app_name;
}

pub fn getAppCodeName(_: *const Navigator) []const u8 {
    return fingerprint.app_code_name;
}

/// The UA string minus its "Mozilla/" prefix, as every browser reports it.
/// Derived from the same constant `getUserAgent` serves, so a `--user-agent`
/// override that changes one without the other is impossible.
pub fn getAppVersion(self: *const Navigator, exec: *const Execution) []const u8 {
    const ua = self.getUserAgent(exec);
    const prefix = "Mozilla/";
    return if (std.mem.startsWith(u8, ua, prefix)) ua[prefix.len..] else ua;
}

pub fn getLanguage(self: *const Navigator, exec: *const Execution) []const u8 {
    const languages = self.getLanguages(exec);
    return if (languages.len == 0) "" else languages[0];
}

pub fn getOnLine(_: *const Navigator) bool {
    return true;
}

fn getCookieEnabled(_: *const Navigator) bool {
    return true;
}

pub fn getHardwareConcurrency(_: *const Navigator) u32 {
    return fingerprint.hardwareConcurrency();
}

pub fn getDeviceMemory(_: *const Navigator) f64 {
    return fingerprint.deviceMemory();
}

fn getMaxTouchPoints(_: *const Navigator) u32 {
    return fingerprint.max_touch_points;
}

pub fn getVendor(_: *const Navigator) []const u8 {
    return fingerprint.vendor;
}

pub fn getProduct(_: *const Navigator) []const u8 {
    return fingerprint.product;
}

/// Frozen constants on every Chromium build. All three of CreepJS,
/// BrowserLeaks and bot.sannysoft read productSub, and a browser claiming
/// Chrome without it is caught on the first check.
pub fn getProductSub(_: *const Navigator) []const u8 {
    return fingerprint.product_sub;
}

pub fn getVendorSub(_: *const Navigator) []const u8 {
    return fingerprint.vendor_sub;
}

/// Chrome bundles a PDF viewer, so this is true there and has been since
/// the plugin list was frozen. It is also what `navigator.plugins` being
/// non-empty implies, and detectors cross-check the two.
pub fn getPdfViewerEnabled(_: *const Navigator) bool {
    return fingerprint.pdf_viewer_enabled;
}

fn getWebdriver(_: *const Navigator) bool {
    return false;
}

/// Fixed, not read from `builtin.os.tag`: the whole point of the profile is
/// that a Linux and a macOS build are indistinguishable from a page.
pub fn getPlatform(_: *const Navigator) []const u8 {
    return fingerprint.platform();
}

/// Returns whether Java is enabled (always false)
fn javaEnabled(_: *const Navigator) bool {
    return false;
}

/// `navigator.sendBeacon(url, data)` — a POST the page does not wait for.
///
/// Analytics use it on unload, where a normal fetch would be cancelled. It is
/// also what a page uses to say "my JS ran": Google's search shell fires
/// `/gen_204?cad=sg_trbl&ei=...` through it two seconds after load, and a
/// client that never sends that has announced itself. This used to return
/// true without sending anything, which kept callers off their sync-XHR
/// fallback but told the server nothing.
///
/// Fire-and-forget by definition: the response is discarded and a transport
/// error is not reported back to the page, because the spec gives the caller
/// no way to observe either. The return value only says whether the beacon
/// was *queued*.
///
/// One departure from the spec: the transfer is owned by the frame, so
/// navigating away cancels it. A real beacon is meant to outlive unload,
/// which is its whole point on `pagehide`. Nothing here has a detached-owner
/// path today, and a beacon that survives the page would outlive the arena
/// its body lives in, so the narrower behaviour is deliberate: beacons sent
/// while the page is alive -- which is every one that matters to us -- go
/// out.
fn sendBeacon(_: *const Navigator, url: []const u8, data: ?BodyInit, frame: *Frame) !bool {
    // Short-lived: the transfer dupes the body and the headers it keeps.
    const arena = try frame.getArena(.small, "Navigator.sendBeacon");
    defer arena.release();
    const allocator = arena.allocator();

    // A URL that will not parse is a TypeError, not a false return: the spec
    // separates "you called this wrong" from "the data did not fit".
    const resolved = try URL.resolve(allocator, frame.base(), url, .{ .encoding = frame.charset });
    if (!isHttpScheme(resolved)) {
        return error.TypeError;
    }

    const body: ?body_init.Extracted = if (data) |d| try d.extract(allocator) else null;
    if (body) |b| {
        // Over the quota the beacon is refused, and the page is told so it
        // can fall back. Chrome's limit, shared across in-flight beacons; we
        // apply it per call, which is the common case and never over-admits
        // a single oversized payload.
        if (b.bytes.len > beacon_max_bytes) {
            return false;
        }
    }

    const transfer = try frame.newRequest(.{
        .url = resolved,
        .method = .POST,
        .body = if (body) |b| b.bytes else null,
        .origin = frame.origin,
        // Per the Beacon spec the request is no-cors with credentials
        // included, which is what makes it useful for session-scoped pings.
        .request_mode = .no_cors,
        .credentials_mode = .include,
        .resource_type = .ping,
        .shutdown_callback = HttpClient.noopShutdown,
    });
    {
        errdefer transfer.deinit();
        // BodyInit derives this the same way fetch does, so a Blob keeps its
        // own type and a string gets text/plain.
        if (body) |b| {
            if (b.content_type) |ct| try transfer.setHeader("Content-Type", ct, .{ .source = .author });
        }
        try frame.headersForRequest(transfer);
    }
    // Errors are swallowed on purpose; see the doc comment.
    transfer.submit() catch {};
    return true;
}

/// Chrome's per-beacon payload cap.
const beacon_max_bytes = 64 * 1024;

/// The spec allows any scheme but requires http(s) in practice: a beacon to
/// file:// or data:// has no server to reach.
fn isHttpScheme(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or
        std.ascii.startsWithIgnoreCase(url, "https://");
}

test "Navigator: only http(s) beacons have somewhere to go" {
    const expect = std.testing.expect;
    try expect(isHttpScheme("http://example.com/gen_204"));
    try expect(isHttpScheme("https://example.com/gen_204"));
    // URL.resolve normalises the scheme's case, but this is cheap to hold.
    try expect(isHttpScheme("HTTPS://example.com/"));

    try expect(!isHttpScheme("ftp://example.com/"));
    try expect(!isHttpScheme("data:text/plain,hi"));
    try expect(!isHttpScheme("file:///etc/passwd"));
    try expect(!isHttpScheme("javascript:void(0)"));
    // "https" is a prefix of neither, and a bare path never reaches here.
    try expect(!isHttpScheme("https"));
    try expect(!isHttpScheme(""));
    // A scheme that merely starts with http is not http.
    try expect(!isHttpScheme("httpx://example.com/"));
}

/// Lazy: the plugin graph is a handful of allocations that most pages never
/// touch, and building it needs a frame anyway.
fn getPlugins(self: *Navigator, frame: *Frame) !*PluginArray {
    if (self._plugins) |p| {
        return p;
    }
    const p = try PluginArray.init(frame);
    self._plugins = p;
    return p;
}

/// The same array every `Plugin` exposes, so `navigator.mimeTypes[0]` and
/// `navigator.plugins[0][0]` are the one object Chrome reports them as.
fn getMimeTypes(self: *Navigator, frame: *Frame) !*MimeTypeArray {
    const plugins = try self.getPlugins(frame);
    return plugins.getMimeTypes();
}

/// Lazy, like _geolocation: NetworkInformation is an EventTarget, so it has
/// to come from the factory with a prototype chain rather than live inline.
fn getUserActivation(self: *Navigator) *UserActivation {
    return &self._user_activation;
}

/// Resolves immediately. Chromium ships this and Firefox removed it, so a
/// browser claiming Chrome has to have it — reCAPTCHA calls it.
fn getBattery(_: *const Navigator, frame: *Frame) !js.Promise {
    const manager = try BatteryManager.init(frame);
    return frame.js.local.?.resolvePromise(manager);
}

fn getConnection(self: *Navigator, frame: *Frame) !*NetworkInformation {
    if (self._connection) |c| {
        return c;
    }
    const c = try NetworkInformation.init(frame);
    self._connection = c;
    return c;
}

fn getPermissions(self: *Navigator) *Permissions {
    return &self._permissions;
}

fn getGeolocation(self: *Navigator, exec: *Execution) !*Geolocation {
    if (self._geolocation) |g| {
        return g;
    }
    const g = try exec._factory.create(Geolocation{});
    self._geolocation = g;
    return g;
}

fn getStorage(self: *Navigator) *StorageManager {
    return &self._storage;
}

fn getUserAgentData(self: *Navigator) *NavigatorUAData {
    return &self._ua_data;
}

/// Desktop Chrome only, which is the point: a page that reads the layout map
/// learns which physical keyboard is attached, and the profile's region
/// decides that (see fingerprint/keyboard.zig).
fn getKeyboard(self: *Navigator) *Keyboard {
    return &self._keyboard;
}

pub fn getModelContext(_: *const Navigator, frame: *Frame) *ModelContext {
    return &frame.window._model_context;
}

fn registerProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}
fn unregisterProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}

fn validateProtocolHandlerScheme(scheme: []const u8) !void {
    const allowed = std.StaticStringMap(void).initComptime(.{
        .{ "bitcoin", {} },
        .{ "cabal", {} },
        .{ "dat", {} },
        .{ "did", {} },
        .{ "dweb", {} },
        .{ "ethereum", .{} },
        .{ "ftp", {} },
        .{ "ftps", {} },
        .{ "geo", {} },
        .{ "im", {} },
        .{ "ipfs", {} },
        .{ "ipns", .{} },
        .{ "irc", {} },
        .{ "ircs", {} },
        .{ "hyper", {} },
        .{ "magnet", {} },
        .{ "mailto", {} },
        .{ "matrix", {} },
        .{ "mms", {} },
        .{ "news", {} },
        .{ "nntp", {} },
        .{ "openpgp4fpr", {} },
        .{ "sftp", {} },
        .{ "sip", {} },
        .{ "sms", {} },
        .{ "smsto", {} },
        .{ "ssb", {} },
        .{ "ssh", {} },
        .{ "tel", {} },
        .{ "urn", {} },
        .{ "webcal", {} },
        .{ "wtai", {} },
        .{ "xmpp", {} },
    });
    if (allowed.has(scheme)) {
        return;
    }

    if (scheme.len < 5 or !std.mem.startsWith(u8, scheme, "web+")) {
        return error.SecurityError;
    }
    for (scheme[4..]) |b| {
        if (std.ascii.isLower(b) == false) {
            return error.SecurityError;
        }
    }
}

fn validateProtocolHandlerURL(url: [:0]const u8, frame: *const Frame) !void {
    if (std.mem.indexOf(u8, url, "%s") == null) {
        return error.SyntaxError;
    }
    if (frame.isSameOrigin(url) == false) {
        return error.SyntaxError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigator);

    pub const Meta = struct {
        pub const name = "Navigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const userAgent = bridge.accessor(Navigator.getUserAgent, null, .{});
    pub const appName = bridge.accessor(Navigator.getAppName, null, .{});
    pub const appCodeName = bridge.accessor(Navigator.getAppCodeName, null, .{});
    pub const appVersion = bridge.accessor(Navigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(Navigator.getPlatform, null, .{});
    pub const language = bridge.accessor(Navigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{});
    pub const onLine = bridge.accessor(Navigator.getOnLine, null, .{});
    pub const cookieEnabled = bridge.accessor(Navigator.getCookieEnabled, null, .{});
    pub const hardwareConcurrency = bridge.accessor(Navigator.getHardwareConcurrency, null, .{});
    pub const deviceMemory = bridge.accessor(Navigator.getDeviceMemory, null, .{});
    pub const maxTouchPoints = bridge.accessor(Navigator.getMaxTouchPoints, null, .{});
    pub const pdfViewerEnabled = bridge.accessor(Navigator.getPdfViewerEnabled, null, .{});
    pub const vendor = bridge.accessor(Navigator.getVendor, null, .{});
    pub const product = bridge.accessor(Navigator.getProduct, null, .{});
    pub const productSub = bridge.accessor(Navigator.getProductSub, null, .{});
    pub const vendorSub = bridge.accessor(Navigator.getVendorSub, null, .{});
    pub const webdriver = bridge.accessor(Navigator.getWebdriver, null, .{});
    pub const doNotTrack = bridge.accessor(Navigator.getDoNotTrack, null, .{});

    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
    pub const sendBeacon = bridge.function(Navigator.sendBeacon, .{});
    pub const permissions = bridge.accessor(Navigator.getPermissions, null, .{});
    pub const storage = bridge.accessor(Navigator.getStorage, null, .{});
    pub const userAgentData = bridge.accessor(Navigator.getUserAgentData, null, .{});
    pub const keyboard = bridge.accessor(Navigator.getKeyboard, null, .{});
    pub const plugins = bridge.accessor(Navigator.getPlugins, null, .{});
    pub const mimeTypes = bridge.accessor(Navigator.getMimeTypes, null, .{});
    pub const connection = bridge.accessor(Navigator.getConnection, null, .{});
    pub const userActivation = bridge.accessor(Navigator.getUserActivation, null, .{});
    pub const getBattery = bridge.function(Navigator.getBattery, .{});
    pub const geolocation = bridge.accessor(Navigator.getGeolocation, null, .{});
    pub const modelContext = bridge.accessor(Navigator.getModelContext, null, .{});
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{});
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Navigator" {
    try testing.htmlRunner("navigator", .{});
}
