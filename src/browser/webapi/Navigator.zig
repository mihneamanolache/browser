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
const napi = @import("navigator_apis.zig");
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

// The Chrome-only surface. Lazy pointers, for the same two reasons
// _geolocation and _connection are: most pages touch none of them, and a
// value field here would join the scramble for offset 0 that the guard above
// polices -- Zig's field order shifts as fields are added, and a JS-visible
// member landing at offset 0 would alias the Navigator itself. Caching the
// pointer is what makes `navigator.gpu === navigator.gpu` hold, as it does in
// Chrome.
_bluetooth: ?*napi.Bluetooth = null,
_clipboard: ?*napi.Clipboard = null,
_credentials: ?*napi.CredentialsContainer = null,
_devicePosture: ?*napi.DevicePosture = null,
_gpu: ?*napi.GPU = null,
_hid: ?*napi.HID = null,
_ink: ?*napi.Ink = null,
_locks: ?*napi.LockManager = null,
_login: ?*napi.NavigatorLogin = null,
_managed: ?*napi.NavigatorManagedData = null,
_mediaCapabilities: ?*napi.MediaCapabilities = null,
_mediaDevices: ?*napi.MediaDevices = null,
_mediaSession: ?*napi.MediaSession = null,
_presentation: ?*napi.Presentation = null,
_protectedAudience: ?*napi.ProtectedAudience = null,
_scheduling: ?*napi.Scheduling = null,
_serial: ?*napi.Serial = null,
_serviceWorker: ?*napi.ServiceWorkerContainer = null,
_storageBuckets: ?*napi.StorageBucketManager = null,
_usb: ?*napi.USB = null,
_virtualKeyboard: ?*napi.VirtualKeyboard = null,
_wakeLock: ?*napi.WakeLock = null,
_webkitTemporaryStorage: ?*napi.DeprecatedStorageQuota = null,
_webkitPersistentStorage: ?*napi.DeprecatedStorageQuota = null,
_windowControlsOverlay: ?*napi.WindowControlsOverlay = null,
_xr: ?*napi.XRSystem = null,

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

fn getBluetooth(self: *Navigator, frame: *Frame) !*napi.Bluetooth {
    if (self._bluetooth) |p| return p;
    const p = try frame._factory.create(napi.Bluetooth{});
    self._bluetooth = p;
    return p;
}

fn getClipboard(self: *Navigator, frame: *Frame) !*napi.Clipboard {
    if (self._clipboard) |p| return p;
    const p = try frame._factory.create(napi.Clipboard{});
    self._clipboard = p;
    return p;
}

fn getCredentials(self: *Navigator, frame: *Frame) !*napi.CredentialsContainer {
    if (self._credentials) |p| return p;
    const p = try frame._factory.create(napi.CredentialsContainer{});
    self._credentials = p;
    return p;
}

fn getDevicePosture(self: *Navigator, frame: *Frame) !*napi.DevicePosture {
    if (self._devicePosture) |p| return p;
    const p = try frame._factory.create(napi.DevicePosture{});
    self._devicePosture = p;
    return p;
}

fn getGpu(self: *Navigator, frame: *Frame) !*napi.GPU {
    if (self._gpu) |p| return p;
    const p = try frame._factory.create(napi.GPU{});
    self._gpu = p;
    return p;
}

fn getHid(self: *Navigator, frame: *Frame) !*napi.HID {
    if (self._hid) |p| return p;
    const p = try frame._factory.create(napi.HID{});
    self._hid = p;
    return p;
}

fn getInk(self: *Navigator, frame: *Frame) !*napi.Ink {
    if (self._ink) |p| return p;
    const p = try frame._factory.create(napi.Ink{});
    self._ink = p;
    return p;
}

fn getLocks(self: *Navigator, frame: *Frame) !*napi.LockManager {
    if (self._locks) |p| return p;
    const p = try frame._factory.create(napi.LockManager{});
    self._locks = p;
    return p;
}

fn getLogin(self: *Navigator, frame: *Frame) !*napi.NavigatorLogin {
    if (self._login) |p| return p;
    const p = try frame._factory.create(napi.NavigatorLogin{});
    self._login = p;
    return p;
}

fn getManaged(self: *Navigator, frame: *Frame) !*napi.NavigatorManagedData {
    if (self._managed) |p| return p;
    const p = try frame._factory.create(napi.NavigatorManagedData{});
    self._managed = p;
    return p;
}

fn getMediaCapabilities(self: *Navigator, frame: *Frame) !*napi.MediaCapabilities {
    if (self._mediaCapabilities) |p| return p;
    const p = try frame._factory.create(napi.MediaCapabilities{});
    self._mediaCapabilities = p;
    return p;
}

fn getMediaDevices(self: *Navigator, frame: *Frame) !*napi.MediaDevices {
    if (self._mediaDevices) |p| return p;
    const p = try frame._factory.create(napi.MediaDevices{});
    self._mediaDevices = p;
    return p;
}

fn getMediaSession(self: *Navigator, frame: *Frame) !*napi.MediaSession {
    if (self._mediaSession) |p| return p;
    const p = try frame._factory.create(napi.MediaSession{});
    self._mediaSession = p;
    return p;
}

fn getPresentation(self: *Navigator, frame: *Frame) !*napi.Presentation {
    if (self._presentation) |p| return p;
    const p = try frame._factory.create(napi.Presentation{});
    self._presentation = p;
    return p;
}

fn getProtectedAudience(self: *Navigator, frame: *Frame) !*napi.ProtectedAudience {
    if (self._protectedAudience) |p| return p;
    const p = try frame._factory.create(napi.ProtectedAudience{});
    self._protectedAudience = p;
    return p;
}

fn getScheduling(self: *Navigator, frame: *Frame) !*napi.Scheduling {
    if (self._scheduling) |p| return p;
    const p = try frame._factory.create(napi.Scheduling{});
    self._scheduling = p;
    return p;
}

fn getSerial(self: *Navigator, frame: *Frame) !*napi.Serial {
    if (self._serial) |p| return p;
    const p = try frame._factory.create(napi.Serial{});
    self._serial = p;
    return p;
}

fn getServiceWorker(self: *Navigator, frame: *Frame) !*napi.ServiceWorkerContainer {
    if (self._serviceWorker) |p| return p;
    const p = try frame._factory.create(napi.ServiceWorkerContainer{});
    self._serviceWorker = p;
    return p;
}

fn getStorageBuckets(self: *Navigator, frame: *Frame) !*napi.StorageBucketManager {
    if (self._storageBuckets) |p| return p;
    const p = try frame._factory.create(napi.StorageBucketManager{});
    self._storageBuckets = p;
    return p;
}

fn getUsb(self: *Navigator, frame: *Frame) !*napi.USB {
    if (self._usb) |p| return p;
    const p = try frame._factory.create(napi.USB{});
    self._usb = p;
    return p;
}

fn getVirtualKeyboard(self: *Navigator, frame: *Frame) !*napi.VirtualKeyboard {
    if (self._virtualKeyboard) |p| return p;
    const p = try frame._factory.create(napi.VirtualKeyboard{});
    self._virtualKeyboard = p;
    return p;
}

fn getWakeLock(self: *Navigator, frame: *Frame) !*napi.WakeLock {
    if (self._wakeLock) |p| return p;
    const p = try frame._factory.create(napi.WakeLock{});
    self._wakeLock = p;
    return p;
}

fn getWebkitTemporaryStorage(self: *Navigator, frame: *Frame) !*napi.DeprecatedStorageQuota {
    if (self._webkitTemporaryStorage) |p| return p;
    const p = try frame._factory.create(napi.DeprecatedStorageQuota{});
    self._webkitTemporaryStorage = p;
    return p;
}

fn getWebkitPersistentStorage(self: *Navigator, frame: *Frame) !*napi.DeprecatedStorageQuota {
    if (self._webkitPersistentStorage) |p| return p;
    const p = try frame._factory.create(napi.DeprecatedStorageQuota{});
    self._webkitPersistentStorage = p;
    return p;
}

fn getWindowControlsOverlay(self: *Navigator, frame: *Frame) !*napi.WindowControlsOverlay {
    if (self._windowControlsOverlay) |p| return p;
    const p = try frame._factory.create(napi.WindowControlsOverlay{});
    self._windowControlsOverlay = p;
    return p;
}

fn getXr(self: *Navigator, frame: *Frame) !*napi.XRSystem {
    if (self._xr) |p| return p;
    const p = try frame._factory.create(napi.XRSystem{});
    self._xr = p;
    return p;
}

// -- The remaining Chrome-only navigator methods -----------------------------
//
// Same reasoning as navigator_apis.zig: present and correctly shaped, failing
// the way a real Chrome fails without permission or hardware. The Protected
// Audience (ad auction) family is the bulk of it; Chrome exposes all of it on
// every page, so its absence is as visible as any missing device API.

fn rejectUnsupported(exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
}

/// No gamepads are ever connected. Chrome hands back a fixed-length array of
/// empty slots rather than a short one.
fn getGamepads(_: *const Navigator) [4]?js.Function.Global {
    return .{ null, null, null, null };
}

/// Desktop has no vibration motor, and Chrome answers false rather than
/// throwing.
fn vibrate(_: *const Navigator) bool {
    return false;
}

fn canShare(_: *const Navigator) bool {
    return false;
}

fn share(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn setAppBadge(_: *const Navigator, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

fn clearAppBadge(_: *const Navigator, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

fn getInstalledRelatedApps(_: *const Navigator, exec: *const Execution) !js.Promise {
    const none: []const []const u8 = &.{};
    return exec.js.local.?.resolvePromise(none);
}

fn requestMIDIAccess(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn requestMediaKeySystemAccess(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

/// The pre-promise getUserMedia, which takes its callbacks as arguments. The
/// error callback is the honest branch: there is no camera.
fn getUserMedia(_: *const Navigator, _: ?js.Value, _: ?js.Function, error_cb: ?js.Function) void {
    const cb = error_cb orelse return;
    var caught: js.TryCatch.Caught = .{};
    cb.tryCall(void, .{}, &caught) catch {};
}

// -- Protected Audience ------------------------------------------------------

/// Chrome reports this as a plain false, not a function.
const deprecated_run_ad_auction_enforces_k_anonymity = false;

fn joinAdInterestGroup(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn leaveAdInterestGroup(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn clearOriginJoinedAdInterestGroups(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn updateAdInterestGroups(_: *const Navigator) void {}

fn runAdAuction(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn createAuctionNonce(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn getInterestGroupAdAuctionData(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn adAuctionComponents(_: *const Navigator) !void {
    // Chrome throws outside a fenced frame, which is everywhere here.
    return error.NotSupported;
}

fn canLoadAdAuctionFencedFrame(_: *const Navigator) bool {
    return false;
}

fn deprecatedReplaceInURN(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
}

fn deprecatedURNToURL(_: *const Navigator, exec: *const Execution) js.Promise {
    return rejectUnsupported(exec);
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

    pub const getGamepads = bridge.function(Navigator.getGamepads, .{});
    pub const vibrate = bridge.function(Navigator.vibrate, .{});
    pub const canShare = bridge.function(Navigator.canShare, .{});
    pub const share = bridge.function(Navigator.share, .{});
    pub const setAppBadge = bridge.function(Navigator.setAppBadge, .{});
    pub const clearAppBadge = bridge.function(Navigator.clearAppBadge, .{});
    pub const getInstalledRelatedApps = bridge.function(Navigator.getInstalledRelatedApps, .{});
    pub const requestMIDIAccess = bridge.function(Navigator.requestMIDIAccess, .{});
    pub const requestMediaKeySystemAccess = bridge.function(Navigator.requestMediaKeySystemAccess, .{});
    pub const getUserMedia = bridge.function(Navigator.getUserMedia, .{});
    pub const webkitGetUserMedia = bridge.function(Navigator.getUserMedia, .{});
    pub const joinAdInterestGroup = bridge.function(Navigator.joinAdInterestGroup, .{});
    pub const leaveAdInterestGroup = bridge.function(Navigator.leaveAdInterestGroup, .{});
    pub const clearOriginJoinedAdInterestGroups = bridge.function(Navigator.clearOriginJoinedAdInterestGroups, .{});
    pub const updateAdInterestGroups = bridge.function(Navigator.updateAdInterestGroups, .{});
    pub const runAdAuction = bridge.function(Navigator.runAdAuction, .{});
    pub const createAuctionNonce = bridge.function(Navigator.createAuctionNonce, .{});
    pub const getInterestGroupAdAuctionData = bridge.function(Navigator.getInterestGroupAdAuctionData, .{});
    pub const adAuctionComponents = bridge.function(Navigator.adAuctionComponents, .{});
    pub const canLoadAdAuctionFencedFrame = bridge.function(Navigator.canLoadAdAuctionFencedFrame, .{});
    pub const deprecatedReplaceInURN = bridge.function(Navigator.deprecatedReplaceInURN, .{});
    pub const deprecatedURNToURL = bridge.function(Navigator.deprecatedURNToURL, .{});
    pub const deprecatedRunAdAuctionEnforcesKAnonymity = bridge.property(deprecated_run_ad_auction_enforces_k_anonymity, .{ .template = false });

    pub const bluetooth = bridge.accessor(Navigator.getBluetooth, null, .{});
    pub const clipboard = bridge.accessor(Navigator.getClipboard, null, .{});
    pub const credentials = bridge.accessor(Navigator.getCredentials, null, .{});
    pub const devicePosture = bridge.accessor(Navigator.getDevicePosture, null, .{});
    pub const gpu = bridge.accessor(Navigator.getGpu, null, .{});
    pub const hid = bridge.accessor(Navigator.getHid, null, .{});
    pub const ink = bridge.accessor(Navigator.getInk, null, .{});
    pub const locks = bridge.accessor(Navigator.getLocks, null, .{});
    pub const login = bridge.accessor(Navigator.getLogin, null, .{});
    pub const managed = bridge.accessor(Navigator.getManaged, null, .{});
    pub const mediaCapabilities = bridge.accessor(Navigator.getMediaCapabilities, null, .{});
    pub const mediaDevices = bridge.accessor(Navigator.getMediaDevices, null, .{});
    pub const mediaSession = bridge.accessor(Navigator.getMediaSession, null, .{});
    pub const presentation = bridge.accessor(Navigator.getPresentation, null, .{});
    pub const protectedAudience = bridge.accessor(Navigator.getProtectedAudience, null, .{});
    pub const scheduling = bridge.accessor(Navigator.getScheduling, null, .{});
    pub const serial = bridge.accessor(Navigator.getSerial, null, .{});
    pub const serviceWorker = bridge.accessor(Navigator.getServiceWorker, null, .{});
    pub const storageBuckets = bridge.accessor(Navigator.getStorageBuckets, null, .{});
    pub const usb = bridge.accessor(Navigator.getUsb, null, .{});
    pub const virtualKeyboard = bridge.accessor(Navigator.getVirtualKeyboard, null, .{});
    pub const wakeLock = bridge.accessor(Navigator.getWakeLock, null, .{});
    pub const webkitTemporaryStorage = bridge.accessor(Navigator.getWebkitTemporaryStorage, null, .{});
    pub const webkitPersistentStorage = bridge.accessor(Navigator.getWebkitPersistentStorage, null, .{});
    pub const windowControlsOverlay = bridge.accessor(Navigator.getWindowControlsOverlay, null, .{});
    pub const xr = bridge.accessor(Navigator.getXr, null, .{});
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
