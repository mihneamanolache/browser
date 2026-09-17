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

//! The `navigator` members desktop Chrome has and we did not.
//!
//! WHY THESE EXIST
//!
//! Chrome 151 exposes 83 properties on `navigator`; we exposed 35. That gap
//! is not cosmetic. Instrumenting Google's search shell showed it reading
//! `navigator.sendBeacon`, then `navigator.webkitTemporaryStorage`, and in
//! this browser the second read returned undefined -- one property, and the
//! page had learned it was not talking to Chrome. Anything that enumerates
//! `navigator` learns far more than that.
//!
//! WHY THEY REJECT INSTEAD OF PRETENDING
//!
//! Every method here fails the way a real Chrome fails when it has no
//! permission and no hardware: a rejected promise, an empty list. That is a
//! state Chrome is in constantly, so it is unremarkable. Resolving with an
//! invented GPU adapter or a fabricated USB device list would be a much
//! larger claim and a much easier one to catch -- the follow-up call would
//! have to keep the story straight, and it cannot.
//!
//! So these are presence and shape, honestly empty. `navigator.usb` is a
//! `USB` whose `getDevices()` resolves to nothing, which is exactly what
//! Chrome on a machine with no paired device returns.
//!
//! The class names are load-bearing: fingerprinters read
//! `navigator.gpu.constructor.name`, not just `typeof navigator.gpu`. Every
//! name and every prototype member list below was read out of a running
//! Chrome 151, not off a spec.

const std = @import("std");

const js = @import("../js/js.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        Bluetooth,
        Clipboard,
        CredentialsContainer,
        DevicePosture,
        GPU,
        HID,
        Ink,
        LockManager,
        NavigatorLogin,
        NavigatorManagedData,
        MediaCapabilities,
        MediaDevices,
        MediaSession,
        Presentation,
        ProtectedAudience,
        Scheduling,
        Serial,
        ServiceWorkerContainer,
        StorageBucketManager,
        USB,
        VirtualKeyboard,
        WakeLock,
        DeprecatedStorageQuota,
        WindowControlsOverlay,
        XRSystem,
    };
}

/// An empty JS array. Typed as a slice of slices so the bridge maps it to
/// an array rather than to an empty string, which is what a bare `&[_]u8{}`
/// would become.
const no_items: []const []const u8 = &.{};

/// Shared rejection for "the feature is here, the capability is not".
fn unsupported(exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
}

/// Boilerplate every type below repeats: a one-byte body so the instance is
/// not zero-sized, and the Meta block the bridge needs.
fn ApiMeta(comptime T: type, comptime class_name: []const u8) type {
    return struct {
        pub const bridge = js.Bridge(T);
        pub const Meta = struct {
            pub const name = class_name;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
    };
}

pub const Bluetooth = struct {
    _pad: bool = false,

    fn getAvailability(_: *const Bluetooth, exec: *const Execution) !js.Promise {
        // No adapter, which is what a desktop without Bluetooth reports.
        return exec.js.local.?.resolvePromise(false);
    }
    fn requestDevice(_: *const Bluetooth, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }

    pub const JsApi = struct {
        const M = ApiMeta(Bluetooth, "Bluetooth");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const getAvailability = bridge.function(Bluetooth.getAvailability, .{});
        pub const requestDevice = bridge.function(Bluetooth.requestDevice, .{});
    };
};

pub const Clipboard = struct {
    _pad: bool = false,

    fn read(_: *const Clipboard, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn readText(_: *const Clipboard, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn write(_: *const Clipboard, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn writeText(_: *const Clipboard, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn getOnClipboardChange(_: *const Clipboard) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(Clipboard, "Clipboard");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const read = bridge.function(Clipboard.read, .{});
        pub const readText = bridge.function(Clipboard.readText, .{});
        pub const write = bridge.function(Clipboard.write, .{});
        pub const writeText = bridge.function(Clipboard.writeText, .{});
        pub const onclipboardchange = bridge.accessor(Clipboard.getOnClipboardChange, null, .{});
    };
};

pub const CredentialsContainer = struct {
    _pad: bool = false,

    fn create(_: *const CredentialsContainer, exec: *const Execution) !js.Promise {
        // Chrome resolves with null when nothing matches, rather than
        // rejecting; a rejection here would be the louder answer.
        return exec.js.local.?.resolvePromise(null);
    }
    fn get(_: *const CredentialsContainer, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(null);
    }
    fn preventSilentAccess(_: *const CredentialsContainer, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }
    fn store(_: *const CredentialsContainer, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        const M = ApiMeta(CredentialsContainer, "CredentialsContainer");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const create = bridge.function(CredentialsContainer.create, .{});
        pub const get = bridge.function(CredentialsContainer.get, .{});
        pub const preventSilentAccess = bridge.function(CredentialsContainer.preventSilentAccess, .{});
        pub const store = bridge.function(CredentialsContainer.store, .{});
    };
};

pub const DevicePosture = struct {
    _pad: bool = false,

    /// A laptop is never folded.
    fn getType(_: *const DevicePosture) []const u8 {
        return "continuous";
    }
    fn getOnChange(_: *const DevicePosture) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(DevicePosture, "DevicePosture");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const @"type" = bridge.accessor(DevicePosture.getType, null, .{});
        pub const onchange = bridge.accessor(DevicePosture.getOnChange, null, .{});
    };
};

pub const GPU = struct {
    _pad: bool = false,

    /// WebGPU's canvas format is platform-fixed: bgra8unorm everywhere
    /// Chrome ships it, and it is readable without an adapter.
    fn getPreferredCanvasFormat(_: *const GPU) []const u8 {
        return "bgra8unorm";
    }
    fn requestAdapter(_: *const GPU, exec: *const Execution) !js.Promise {
        // Chrome resolves with null when no adapter is available rather than
        // rejecting, and callers are written for that.
        return exec.js.local.?.resolvePromise(null);
    }
    fn getWgslLanguageFeatures(_: *const GPU, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(no_items);
    }

    pub const JsApi = struct {
        const M = ApiMeta(GPU, "GPU");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const getPreferredCanvasFormat = bridge.function(GPU.getPreferredCanvasFormat, .{});
        pub const requestAdapter = bridge.function(GPU.requestAdapter, .{});
        pub const wgslLanguageFeatures = bridge.accessor(GPU.getWgslLanguageFeatures, null, .{});
    };
};

/// USB, HID and Serial are the same shape: a device list that is empty until
/// the user pairs something, and a request that needs a user gesture.
fn DeviceHub(comptime class_name: []const u8) type {
    return struct {
        const Self = @This();
        _pad: bool = false,

        fn getDevices(_: *const Self, exec: *const Execution) !js.Promise {
            return exec.js.local.?.resolvePromise(no_items);
        }
        fn requestDevice(_: *const Self, exec: *const Execution) js.Promise {
            return unsupported(exec);
        }
        fn getOnConnect(_: *const Self) ?js.Function.Global {
            return null;
        }
        fn getOnDisconnect(_: *const Self) ?js.Function.Global {
            return null;
        }

        pub const JsApi = struct {
            const M = ApiMeta(Self, class_name);
            pub const bridge = M.bridge;
            pub const Meta = M.Meta;
            pub const getDevices = bridge.function(Self.getDevices, .{});
            pub const requestDevice = bridge.function(Self.requestDevice, .{});
            pub const onconnect = bridge.accessor(Self.getOnConnect, null, .{});
            pub const ondisconnect = bridge.accessor(Self.getOnDisconnect, null, .{});
        };
    };
}

pub const USB = DeviceHub("USB");
pub const HID = DeviceHub("HID");

pub const Serial = struct {
    _pad: bool = false,

    fn getPorts(_: *const Serial, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(no_items);
    }
    fn requestPort(_: *const Serial, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn getOnConnect(_: *const Serial) ?js.Function.Global {
        return null;
    }
    fn getOnDisconnect(_: *const Serial) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(Serial, "Serial");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const getPorts = bridge.function(Serial.getPorts, .{});
        pub const requestPort = bridge.function(Serial.requestPort, .{});
        pub const onconnect = bridge.accessor(Serial.getOnConnect, null, .{});
        pub const ondisconnect = bridge.accessor(Serial.getOnDisconnect, null, .{});
    };
};

pub const Ink = struct {
    _pad: bool = false,

    fn requestPresenter(_: *const Ink, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }

    pub const JsApi = struct {
        const M = ApiMeta(Ink, "Ink");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const requestPresenter = bridge.function(Ink.requestPresenter, .{});
    };
};

pub const LockManager = struct {
    _pad: bool = false,

    fn query(_: *const LockManager, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(.{
            .held = no_items,
            .pending = no_items,
        });
    }
    fn request(_: *const LockManager, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }

    pub const JsApi = struct {
        const M = ApiMeta(LockManager, "LockManager");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const query = bridge.function(LockManager.query, .{});
        pub const request = bridge.function(LockManager.request, .{});
    };
};

pub const NavigatorLogin = struct {
    _pad: bool = false,

    fn setStatus(_: *const NavigatorLogin) void {}

    pub const JsApi = struct {
        const M = ApiMeta(NavigatorLogin, "NavigatorLogin");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const setStatus = bridge.function(NavigatorLogin.setStatus, .{});
    };
};

pub const NavigatorManagedData = struct {
    _pad: bool = false,

    fn getManagedConfiguration(_: *const NavigatorManagedData, exec: *const Execution) js.Promise {
        // Not an enterprise-managed browser, which is the common case.
        return unsupported(exec);
    }
    fn getOnManagedConfigurationChange(_: *const NavigatorManagedData) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(NavigatorManagedData, "NavigatorManagedData");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const getManagedConfiguration = bridge.function(NavigatorManagedData.getManagedConfiguration, .{});
        pub const onmanagedconfigurationchange = bridge.accessor(NavigatorManagedData.getOnManagedConfigurationChange, null, .{});
    };
};

pub const MediaCapabilities = struct {
    _pad: bool = false,

    /// Chrome answers these without hardware: it reports whether the codec is
    /// supported, and "not smooth, not power efficient" is the honest answer
    /// for a browser that will never actually decode anything.
    fn decodingInfo(_: *const MediaCapabilities, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(.{
            .supported = false,
            .smooth = false,
            .powerEfficient = false,
        });
    }
    fn encodingInfo(_: *const MediaCapabilities, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(.{
            .supported = false,
            .smooth = false,
            .powerEfficient = false,
        });
    }

    pub const JsApi = struct {
        const M = ApiMeta(MediaCapabilities, "MediaCapabilities");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const decodingInfo = bridge.function(MediaCapabilities.decodingInfo, .{});
        pub const encodingInfo = bridge.function(MediaCapabilities.encodingInfo, .{});
    };
};

pub const MediaDevices = struct {
    _pad: bool = false,

    /// Empty until a page has camera or microphone permission, which is what
    /// Chrome returns on a fresh profile. Inventing devices here would be
    /// caught by the first getUserMedia that followed.
    fn enumerateDevices(_: *const MediaDevices, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(no_items);
    }
    fn getSupportedConstraints(_: *const MediaDevices) struct {
        width: bool,
        height: bool,
        aspectRatio: bool,
        frameRate: bool,
        facingMode: bool,
        resizeMode: bool,
        sampleRate: bool,
        sampleSize: bool,
        echoCancellation: bool,
        autoGainControl: bool,
        noiseSuppression: bool,
        latency: bool,
        channelCount: bool,
        deviceId: bool,
        groupId: bool,
    } {
        return .{
            .width = true,
            .height = true,
            .aspectRatio = true,
            .frameRate = true,
            .facingMode = true,
            .resizeMode = true,
            .sampleRate = true,
            .sampleSize = true,
            .echoCancellation = true,
            .autoGainControl = true,
            .noiseSuppression = true,
            .latency = true,
            .channelCount = true,
            .deviceId = true,
            .groupId = true,
        };
    }
    fn getUserMedia(_: *const MediaDevices, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn getDisplayMedia(_: *const MediaDevices, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn setCaptureHandleConfig(_: *const MediaDevices) void {}
    fn getOnDeviceChange(_: *const MediaDevices) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(MediaDevices, "MediaDevices");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const enumerateDevices = bridge.function(MediaDevices.enumerateDevices, .{});
        pub const getSupportedConstraints = bridge.function(MediaDevices.getSupportedConstraints, .{});
        pub const getUserMedia = bridge.function(MediaDevices.getUserMedia, .{});
        pub const getDisplayMedia = bridge.function(MediaDevices.getDisplayMedia, .{});
        pub const setCaptureHandleConfig = bridge.function(MediaDevices.setCaptureHandleConfig, .{});
        pub const ondevicechange = bridge.accessor(MediaDevices.getOnDeviceChange, null, .{});
    };
};

pub const MediaSession = struct {
    _pad: bool = false,

    fn getMetadata(_: *const MediaSession) ?js.Function.Global {
        return null;
    }
    fn getPlaybackState(_: *const MediaSession) []const u8 {
        return "none";
    }
    fn setActionHandler(_: *const MediaSession) void {}
    fn setCameraActive(_: *const MediaSession) void {}
    fn setMicrophoneActive(_: *const MediaSession) void {}
    fn setPositionState(_: *const MediaSession) void {}

    pub const JsApi = struct {
        const M = ApiMeta(MediaSession, "MediaSession");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const metadata = bridge.accessor(MediaSession.getMetadata, null, .{});
        pub const playbackState = bridge.accessor(MediaSession.getPlaybackState, null, .{});
        pub const setActionHandler = bridge.function(MediaSession.setActionHandler, .{});
        pub const setCameraActive = bridge.function(MediaSession.setCameraActive, .{});
        pub const setMicrophoneActive = bridge.function(MediaSession.setMicrophoneActive, .{});
        pub const setPositionState = bridge.function(MediaSession.setPositionState, .{});
    };
};

pub const Presentation = struct {
    _pad: bool = false,

    fn getDefaultRequest(_: *const Presentation) ?js.Function.Global {
        return null;
    }
    fn getReceiver(_: *const Presentation) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(Presentation, "Presentation");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const defaultRequest = bridge.accessor(Presentation.getDefaultRequest, null, .{});
        pub const receiver = bridge.accessor(Presentation.getReceiver, null, .{});
    };
};

pub const ProtectedAudience = struct {
    _pad: bool = false,

    fn queryFeatureSupport(_: *const ProtectedAudience, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(.{});
    }

    pub const JsApi = struct {
        const M = ApiMeta(ProtectedAudience, "ProtectedAudience");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const queryFeatureSupport = bridge.function(ProtectedAudience.queryFeatureSupport, .{});
    };
};

pub const Scheduling = struct {
    _pad: bool = false,

    /// Nothing is ever queued, because nothing here has an input queue.
    fn isInputPending(_: *const Scheduling) bool {
        return false;
    }

    pub const JsApi = struct {
        const M = ApiMeta(Scheduling, "Scheduling");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const isInputPending = bridge.function(Scheduling.isInputPending, .{});
    };
};

pub const ServiceWorkerContainer = struct {
    _pad: bool = false,

    /// No worker controls this page, which is the truth on a first load even
    /// in a browser that supports them.
    fn getController(_: *const ServiceWorkerContainer) ?js.Function.Global {
        return null;
    }
    fn getReady(_: *const ServiceWorkerContainer, exec: *const Execution) js.Promise {
        // Chrome's `ready` never settles until a worker is active, and a
        // pending promise is exactly what a page with no registration sees.
        return exec.js.local.?.createPromiseResolver().promise();
    }
    fn register(_: *const ServiceWorkerContainer, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn getRegistration(_: *const ServiceWorkerContainer, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(null);
    }
    fn getRegistrations(_: *const ServiceWorkerContainer, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(no_items);
    }
    fn startMessages(_: *const ServiceWorkerContainer) void {}
    fn getOnControllerChange(_: *const ServiceWorkerContainer) ?js.Function.Global {
        return null;
    }
    fn getOnMessage(_: *const ServiceWorkerContainer) ?js.Function.Global {
        return null;
    }
    fn getOnMessageError(_: *const ServiceWorkerContainer) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(ServiceWorkerContainer, "ServiceWorkerContainer");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const controller = bridge.accessor(ServiceWorkerContainer.getController, null, .{});
        pub const ready = bridge.accessor(ServiceWorkerContainer.getReady, null, .{});
        pub const register = bridge.function(ServiceWorkerContainer.register, .{});
        pub const getRegistration = bridge.function(ServiceWorkerContainer.getRegistration, .{});
        pub const getRegistrations = bridge.function(ServiceWorkerContainer.getRegistrations, .{});
        pub const startMessages = bridge.function(ServiceWorkerContainer.startMessages, .{});
        pub const oncontrollerchange = bridge.accessor(ServiceWorkerContainer.getOnControllerChange, null, .{});
        pub const onmessage = bridge.accessor(ServiceWorkerContainer.getOnMessage, null, .{});
        pub const onmessageerror = bridge.accessor(ServiceWorkerContainer.getOnMessageError, null, .{});
    };
};

pub const StorageBucketManager = struct {
    _pad: bool = false,

    fn open(_: *const StorageBucketManager, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn keys(_: *const StorageBucketManager, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(no_items);
    }
    fn delete(_: *const StorageBucketManager, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        const M = ApiMeta(StorageBucketManager, "StorageBucketManager");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const open = bridge.function(StorageBucketManager.open, .{});
        pub const keys = bridge.function(StorageBucketManager.keys, .{});
        pub const delete = bridge.function(StorageBucketManager.delete, .{});
    };
};

pub const VirtualKeyboard = struct {
    _pad: bool = false,

    fn getOverlaysContent(_: *const VirtualKeyboard) bool {
        return false;
    }
    fn getBoundingRect(_: *const VirtualKeyboard) struct { x: u32, y: u32, width: u32, height: u32 } {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    fn show(_: *const VirtualKeyboard) void {}
    fn hide(_: *const VirtualKeyboard) void {}
    fn getOnGeometryChange(_: *const VirtualKeyboard) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(VirtualKeyboard, "VirtualKeyboard");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const overlaysContent = bridge.accessor(VirtualKeyboard.getOverlaysContent, null, .{});
        pub const boundingRect = bridge.accessor(VirtualKeyboard.getBoundingRect, null, .{});
        pub const show = bridge.function(VirtualKeyboard.show, .{});
        pub const hide = bridge.function(VirtualKeyboard.hide, .{});
        pub const ongeometrychange = bridge.accessor(VirtualKeyboard.getOnGeometryChange, null, .{});
    };
};

pub const WakeLock = struct {
    _pad: bool = false,

    fn request(_: *const WakeLock, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }

    pub const JsApi = struct {
        const M = ApiMeta(WakeLock, "WakeLock");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const request = bridge.function(WakeLock.request, .{});
    };
};

/// `webkitTemporaryStorage` and `webkitPersistentStorage`.
///
/// NOT named "Object", however much the probe suggested it. Registering a
/// class by that name replaces the global `Object` constructor, and with it
/// every static -- defineProperty, entries, keys, assign, getOwnPropertyNames.
/// Pages break instantly and spectacularly, and a browser whose
/// Object.defineProperty is undefined is not fooling anybody.
pub const DeprecatedStorageQuota = struct {
    _pad: bool = false,

    const quota_bytes: u64 = 1024 * 1024 * 1024;

    fn queryUsageAndQuota(_: *const DeprecatedStorageQuota, cb: ?js.Function) !void {
        const f = cb orelse return;
        var caught: js.TryCatch.Caught = .{};
        f.tryCall(void, .{ @as(u64, 0), quota_bytes }, &caught) catch {};
    }
    fn requestQuota(_: *const DeprecatedStorageQuota, requested: u64, cb: ?js.Function) !void {
        const f = cb orelse return;
        var caught: js.TryCatch.Caught = .{};
        f.tryCall(void, .{@as(u64, @min(requested, quota_bytes))}, &caught) catch {};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DeprecatedStorageQuota);
        pub const Meta = struct {
            pub const name = "DeprecatedStorageQuota";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
        pub const queryUsageAndQuota = bridge.function(DeprecatedStorageQuota.queryUsageAndQuota, .{});
        pub const requestQuota = bridge.function(DeprecatedStorageQuota.requestQuota, .{});
    };
};

pub const WindowControlsOverlay = struct {
    _pad: bool = false,

    /// Only true in an installed PWA with a custom titlebar.
    fn getVisible(_: *const WindowControlsOverlay) bool {
        return false;
    }
    fn getTitlebarAreaRect(_: *const WindowControlsOverlay) struct { x: u32, y: u32, width: u32, height: u32 } {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    fn getOnGeometryChange(_: *const WindowControlsOverlay) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(WindowControlsOverlay, "WindowControlsOverlay");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const visible = bridge.accessor(WindowControlsOverlay.getVisible, null, .{});
        pub const getTitlebarAreaRect = bridge.function(WindowControlsOverlay.getTitlebarAreaRect, .{});
        pub const ongeometrychange = bridge.accessor(WindowControlsOverlay.getOnGeometryChange, null, .{});
    };
};

pub const XRSystem = struct {
    _pad: bool = false,

    fn isSessionSupported(_: *const XRSystem, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(false);
    }
    fn requestSession(_: *const XRSystem, exec: *const Execution) js.Promise {
        return unsupported(exec);
    }
    fn getOnDeviceChange(_: *const XRSystem) ?js.Function.Global {
        return null;
    }

    pub const JsApi = struct {
        const M = ApiMeta(XRSystem, "XRSystem");
        pub const bridge = M.bridge;
        pub const Meta = M.Meta;
        pub const isSessionSupported = bridge.function(XRSystem.isSessionSupported, .{});
        pub const requestSession = bridge.function(XRSystem.requestSession, .{});
        pub const ondevicechange = bridge.accessor(XRSystem.getOnDeviceChange, null, .{});
    };
};
