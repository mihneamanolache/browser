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
//! WHY MOST CAPABILITY REQUESTS REJECT INSTEAD OF PRETENDING
//!
//! Every method here fails the way a real Chrome fails when it has no
//! permission and no hardware: a rejected promise, an empty list. That is a
//! state Chrome is in constantly, so it is unremarkable. Resolving with an
//! fabricated USB device list would be a much larger claim and a much easier
//! one to catch -- the follow-up call would have to keep the story straight.
//! WebGPU is the exception: the selected fingerprint profile already claims
//! an exact GPU, so its adapter metadata, features and limits must tell the
//! same story. Device/queue execution remains unsupported until it can do so.
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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Execution = js.Execution;
const Frame = @import("../Frame.zig");
const URL = @import("../URL.zig");
const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const ServiceWorker = @import("ServiceWorker.zig");
const ServiceWorkerRegistration = @import("ServiceWorkerRegistration.zig");
const ServiceWorkerGlobalScope = @import("ServiceWorkerGlobalScope.zig");

pub fn registerTypes() []const type {
    return &.{
        Bluetooth,
        Clipboard,
        CredentialsContainer,
        DevicePosture,
        GPU,
        GPUAdapter,
        GPUAdapterInfo,
        GPUSupportedFeatures,
        GPUSupportedFeatures.KeyIterator,
        GPUSupportedFeatures.ValueIterator,
        GPUSupportedFeatures.EntryIterator,
        GPUSupportedLimits,
        HID,
        Ink,
        LockManager,
        NavigatorLogin,
        NavigatorManagedData,
        MediaCapabilities,
        MediaDeviceInfo,
        InputDeviceInfo,
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
        WGSLLanguageFeatures,
        WGSLLanguageFeatures.KeyIterator,
        WGSLLanguageFeatures.ValueIterator,
        WGSLLanguageFeatures.EntryIterator,
        DeprecatedStorageQuota,
        WindowControlsOverlay,
        XRSystem,
    };
}

/// An empty JS array. Typed as a slice of slices so the bridge maps it to
/// an array rather than to an empty string, which is what a bare `&[_]u8{}`
/// would become.
const no_items: []const []const u8 = &.{};

const wgsl_language_features: []const []const u8 = &.{
    "packed_4x8_integer_dot_product",
    "subgroup_uniformity",
    "immediate_address_space",
    "linear_indexing",
    "subgroup_id",
    "readonly_and_readwrite_storage_textures",
    "unrestricted_pointer_parameters",
    "texture_and_sampler_let",
    "pointer_composite_access",
    "uniform_buffer_standard_layout",
};

const gpu_adapter_features: []const []const u8 = &.{
    "depth32float-stencil8",
    "rg11b10ufloat-renderable",
    "bgra8unorm-storage",
    "texture-formats-tier1",
    "texture-compression-bc",
    "dual-source-blending",
    "core-features-and-limits",
    "float32-filterable",
    "indirect-first-instance",
    "texture-compression-astc-sliced-3d",
    "float32-blendable",
    "texture-compression-astc",
    "texture-compression-etc2",
    "depth-clip-control",
    "texture-compression-bc-sliced-3d",
    "timestamp-query",
    "clip-distances",
    "texture-formats-tier2",
    "shader-f16",
    "primitive-index",
    "texture-component-swizzle",
    "subgroups",
};

fn StringSet(comptime class_name: []const u8, comptime items: []const []const u8) type {
    return struct {
        _pad: bool = false,

        const Self = @This();
        const GenericIterator = @import("collections/iterator.zig").Entry;

        pub const Iterator = struct {
            index: u32 = 0,

            pub const Entry = struct { []const u8, []const u8 };

            pub fn next(self: *Iterator, _: *const Execution) ?Entry {
                const index = self.index;
                if (index >= items.len) return null;
                self.index = index + 1;
                return .{ items[index], items[index] };
            }
        };

        pub const KeyIterator = GenericIterator(Iterator, "0");
        pub const ValueIterator = GenericIterator(Iterator, "1");
        pub const EntryIterator = GenericIterator(Iterator, null);

        fn size(_: *const Self) u32 {
            return items.len;
        }

        fn has(_: *const Self, value: []const u8) bool {
            for (items) |item| {
                if (std.mem.eql(u8, item, value)) return true;
            }
            return false;
        }

        fn keys(_: *Self, exec: *const Execution) !*KeyIterator {
            return .init(.{}, exec);
        }

        fn values(_: *Self, exec: *const Execution) !*ValueIterator {
            return .init(.{}, exec);
        }

        fn entries(_: *Self, exec: *const Execution) !*EntryIterator {
            return .init(.{}, exec);
        }

        fn forEach(self: *Self, callback_: js.Function, this_: ?js.Object) !void {
            const callback = if (this_) |this| try callback_.withThis(this) else callback_;
            for (items) |item| {
                var caught: js.TryCatch.Caught = .{};
                callback.tryCall(void, .{ item, item, self }, &caught) catch {
                    lp.log.debug(.js, "forEach callback", .{ .caught = caught, .source = class_name });
                };
            }
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);
            pub const Meta = struct {
                pub const name = class_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
                pub const empty_with_no_proto = true;
            };

            pub const size = bridge.accessor(Self.size, null, .{});
            pub const entries = bridge.function(Self.entries, .{});
            pub const forEach = bridge.function(Self.forEach, .{});
            pub const has = bridge.function(Self.has, .{});
            pub const keys = bridge.function(Self.keys, .{});
            pub const values = bridge.function(Self.values, .{});
            pub const symbol_iterator = bridge.iterator(Self.values, .{});
        };
    };
}

pub const WGSLLanguageFeatures = StringSet("WGSLLanguageFeatures", wgsl_language_features);
pub const GPUSupportedFeatures = StringSet("GPUSupportedFeatures", gpu_adapter_features);

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
    _wgsl_language_features: ?*WGSLLanguageFeatures = null,

    /// WebGPU's canvas format is platform-fixed: bgra8unorm everywhere
    /// Chrome ships it, and it is readable without an adapter.
    fn getPreferredCanvasFormat(_: *const GPU) []const u8 {
        return "bgra8unorm";
    }
    fn requestAdapter(_: *const GPU, exec: *const Execution) !js.Promise {
        // Each request returns a distinct adapter in Chrome.
        const adapter = try exec._factory.create(GPUAdapter{});
        return exec.js.local.?.resolvePromise(adapter);
    }

    fn getWgslLanguageFeatures(self: *GPU, exec: *const Execution) !*WGSLLanguageFeatures {
        if (self._wgsl_language_features) |features| return features;
        const features = try exec._factory.create(WGSLLanguageFeatures{});
        self._wgsl_language_features = features;
        return features;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPU);
        pub const Meta = struct {
            pub const name = "GPU";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const getPreferredCanvasFormat = bridge.function(GPU.getPreferredCanvasFormat, .{});
        pub const requestAdapter = bridge.function(GPU.requestAdapter, .{});
        pub const wgslLanguageFeatures = bridge.accessor(GPU.getWgslLanguageFeatures, null, .{});
    };
};

pub const GPUAdapter = struct {
    _features: ?*GPUSupportedFeatures = null,
    _limits: ?*GPUSupportedLimits = null,
    _info: ?*GPUAdapterInfo = null,

    fn getFeatures(self: *GPUAdapter, exec: *const Execution) !*GPUSupportedFeatures {
        if (self._features) |features| return features;
        const features = try exec._factory.create(GPUSupportedFeatures{});
        self._features = features;
        return features;
    }

    fn getLimits(self: *GPUAdapter, exec: *const Execution) !*GPUSupportedLimits {
        if (self._limits) |limits| return limits;
        const limits = try exec._factory.create(GPUSupportedLimits{});
        self._limits = limits;
        return limits;
    }

    fn getInfo(self: *GPUAdapter, exec: *const Execution) !*GPUAdapterInfo {
        if (self._info) |info| return info;
        const info = try exec._factory.create(GPUAdapterInfo{});
        self._info = info;
        return info;
    }

    fn requestDevice(_: *const GPUAdapter, exec: *const Execution) js.Promise {
        // Device/queue/command execution is not implemented yet. Preserve the
        // asynchronous contract instead of inventing a half-functional device.
        return unsupported(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUAdapter);
        pub const Meta = struct {
            pub const name = "GPUAdapter";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const features = bridge.accessor(GPUAdapter.getFeatures, null, .{});
        pub const limits = bridge.accessor(GPUAdapter.getLimits, null, .{});
        pub const info = bridge.accessor(GPUAdapter.getInfo, null, .{});
        pub const requestDevice = bridge.function(GPUAdapter.requestDevice, .{});
    };
};

pub const GPUAdapterInfo = struct {
    _pad: bool = false,

    fn getVendor(_: *const GPUAdapterInfo) []const u8 {
        return switch (lp.fingerprint.machine().os) {
            .macos => "apple",
            .windows => if (std.mem.indexOf(u8, lp.fingerprint.machine().gpu_vendor, "NVIDIA") != null)
                "nvidia"
            else if (std.mem.indexOf(u8, lp.fingerprint.machine().gpu_vendor, "Intel") != null)
                "intel"
            else
                "amd",
        };
    }

    fn getArchitecture(_: *const GPUAdapterInfo) []const u8 {
        return if (lp.fingerprint.machine().os == .macos) "metal-3" else "";
    }

    fn getEmpty(_: *const GPUAdapterInfo) []const u8 {
        return "";
    }

    fn getSubgroupSize(_: *const GPUAdapterInfo) u32 {
        return 32;
    }

    fn getIsFallbackAdapter(_: *const GPUAdapterInfo) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUAdapterInfo);
        pub const Meta = struct {
            pub const name = "GPUAdapterInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const vendor = bridge.accessor(GPUAdapterInfo.getVendor, null, .{});
        pub const architecture = bridge.accessor(GPUAdapterInfo.getArchitecture, null, .{});
        pub const device = bridge.accessor(GPUAdapterInfo.getEmpty, null, .{});
        pub const description = bridge.accessor(GPUAdapterInfo.getEmpty, null, .{});
        pub const subgroupMinSize = bridge.accessor(GPUAdapterInfo.getSubgroupSize, null, .{});
        pub const subgroupMaxSize = bridge.accessor(GPUAdapterInfo.getSubgroupSize, null, .{});
        pub const isFallbackAdapter = bridge.accessor(GPUAdapterInfo.getIsFallbackAdapter, null, .{});
    };
};

pub const GPUSupportedLimits = struct {
    _pad: bool = false,

    const values = .{
        .maxTextureDimension1D = 16384,
        .maxTextureDimension2D = 16384,
        .maxTextureDimension3D = 2048,
        .maxTextureArrayLayers = 2048,
        .maxBindGroups = 4,
        .maxBindGroupsPlusVertexBuffers = 24,
        .maxBindingsPerBindGroup = 1000,
        .maxDynamicUniformBuffersPerPipelineLayout = 10,
        .maxDynamicStorageBuffersPerPipelineLayout = 8,
        .maxSampledTexturesPerShaderStage = 48,
        .maxSamplersPerShaderStage = 16,
        .maxStorageBuffersPerShaderStage = 10,
        .maxStorageTexturesPerShaderStage = 8,
        .maxUniformBuffersPerShaderStage = 12,
        .maxUniformBufferBindingSize = 65536,
        .maxStorageBufferBindingSize = 4294967292,
        .minUniformBufferOffsetAlignment = 256,
        .minStorageBufferOffsetAlignment = 256,
        .maxVertexBuffers = 8,
        .maxBufferSize = 4294967292,
        .maxVertexAttributes = 30,
        .maxVertexBufferArrayStride = 2048,
        .maxInterStageShaderVariables = 28,
        .maxColorAttachments = 8,
        .maxColorAttachmentBytesPerSample = 128,
        .maxComputeWorkgroupStorageSize = 32768,
        .maxComputeInvocationsPerWorkgroup = 1024,
        .maxComputeWorkgroupSizeX = 1024,
        .maxComputeWorkgroupSizeY = 1024,
        .maxComputeWorkgroupSizeZ = 64,
        .maxComputeWorkgroupsPerDimension = 65535,
        .maxImmediateSize = 64,
        .maxStorageBuffersInFragmentStage = 10,
        .maxStorageTexturesInFragmentStage = 8,
        .maxStorageBuffersInVertexStage = 10,
        .maxStorageTexturesInVertexStage = 8,
    };

    fn getter(comptime name: []const u8) fn (*const GPUSupportedLimits) u64 {
        return struct {
            fn get(_: *const GPUSupportedLimits) u64 {
                return @field(values, name);
            }
        }.get;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUSupportedLimits);
        pub const Meta = struct {
            pub const name = "GPUSupportedLimits";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const maxTextureDimension1D = bridge.accessor(getter("maxTextureDimension1D"), null, .{});
        pub const maxTextureDimension2D = bridge.accessor(getter("maxTextureDimension2D"), null, .{});
        pub const maxTextureDimension3D = bridge.accessor(getter("maxTextureDimension3D"), null, .{});
        pub const maxTextureArrayLayers = bridge.accessor(getter("maxTextureArrayLayers"), null, .{});
        pub const maxBindGroups = bridge.accessor(getter("maxBindGroups"), null, .{});
        pub const maxBindGroupsPlusVertexBuffers = bridge.accessor(getter("maxBindGroupsPlusVertexBuffers"), null, .{});
        pub const maxBindingsPerBindGroup = bridge.accessor(getter("maxBindingsPerBindGroup"), null, .{});
        pub const maxDynamicUniformBuffersPerPipelineLayout = bridge.accessor(getter("maxDynamicUniformBuffersPerPipelineLayout"), null, .{});
        pub const maxDynamicStorageBuffersPerPipelineLayout = bridge.accessor(getter("maxDynamicStorageBuffersPerPipelineLayout"), null, .{});
        pub const maxSampledTexturesPerShaderStage = bridge.accessor(getter("maxSampledTexturesPerShaderStage"), null, .{});
        pub const maxSamplersPerShaderStage = bridge.accessor(getter("maxSamplersPerShaderStage"), null, .{});
        pub const maxStorageBuffersPerShaderStage = bridge.accessor(getter("maxStorageBuffersPerShaderStage"), null, .{});
        pub const maxStorageTexturesPerShaderStage = bridge.accessor(getter("maxStorageTexturesPerShaderStage"), null, .{});
        pub const maxUniformBuffersPerShaderStage = bridge.accessor(getter("maxUniformBuffersPerShaderStage"), null, .{});
        pub const maxUniformBufferBindingSize = bridge.accessor(getter("maxUniformBufferBindingSize"), null, .{});
        pub const maxStorageBufferBindingSize = bridge.accessor(getter("maxStorageBufferBindingSize"), null, .{});
        pub const minUniformBufferOffsetAlignment = bridge.accessor(getter("minUniformBufferOffsetAlignment"), null, .{});
        pub const minStorageBufferOffsetAlignment = bridge.accessor(getter("minStorageBufferOffsetAlignment"), null, .{});
        pub const maxVertexBuffers = bridge.accessor(getter("maxVertexBuffers"), null, .{});
        pub const maxBufferSize = bridge.accessor(getter("maxBufferSize"), null, .{});
        pub const maxVertexAttributes = bridge.accessor(getter("maxVertexAttributes"), null, .{});
        pub const maxVertexBufferArrayStride = bridge.accessor(getter("maxVertexBufferArrayStride"), null, .{});
        pub const maxInterStageShaderVariables = bridge.accessor(getter("maxInterStageShaderVariables"), null, .{});
        pub const maxColorAttachments = bridge.accessor(getter("maxColorAttachments"), null, .{});
        pub const maxColorAttachmentBytesPerSample = bridge.accessor(getter("maxColorAttachmentBytesPerSample"), null, .{});
        pub const maxComputeWorkgroupStorageSize = bridge.accessor(getter("maxComputeWorkgroupStorageSize"), null, .{});
        pub const maxComputeInvocationsPerWorkgroup = bridge.accessor(getter("maxComputeInvocationsPerWorkgroup"), null, .{});
        pub const maxComputeWorkgroupSizeX = bridge.accessor(getter("maxComputeWorkgroupSizeX"), null, .{});
        pub const maxComputeWorkgroupSizeY = bridge.accessor(getter("maxComputeWorkgroupSizeY"), null, .{});
        pub const maxComputeWorkgroupSizeZ = bridge.accessor(getter("maxComputeWorkgroupSizeZ"), null, .{});
        pub const maxComputeWorkgroupsPerDimension = bridge.accessor(getter("maxComputeWorkgroupsPerDimension"), null, .{});
        pub const maxImmediateSize = bridge.accessor(getter("maxImmediateSize"), null, .{});
        pub const maxStorageBuffersInFragmentStage = bridge.accessor(getter("maxStorageBuffersInFragmentStage"), null, .{});
        pub const maxStorageTexturesInFragmentStage = bridge.accessor(getter("maxStorageTexturesInFragmentStage"), null, .{});
        pub const maxStorageBuffersInVertexStage = bridge.accessor(getter("maxStorageBuffersInVertexStage"), null, .{});
        pub const maxStorageTexturesInVertexStage = bridge.accessor(getter("maxStorageTexturesInVertexStage"), null, .{});
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

    fn enumerateDevices(_: *const MediaDevices, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        const audio_input = try exec._factory.chained(.{
            MediaDeviceInfo{ ._kind = "audioinput" },
            InputDeviceInfo{ ._proto = undefined },
        });
        const video_input = try exec._factory.chained(.{
            MediaDeviceInfo{ ._kind = "videoinput" },
            InputDeviceInfo{ ._proto = undefined },
        });
        const audio_output = try exec._factory.create(MediaDeviceInfo{ ._kind = "audiooutput" });

        const devices = local.newArray(3);
        _ = try devices.set(0, audio_input, .{});
        _ = try devices.set(1, video_input, .{});
        _ = try devices.set(2, audio_output, .{});
        return local.resolvePromise(devices.toValue());
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

pub const MediaDeviceInfo = struct {
    pub const _prototype_root = true;

    _kind: []const u8,

    fn getDeviceId(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }

    fn getKind(self: *const MediaDeviceInfo) []const u8 {
        return self._kind;
    }

    fn getLabel(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }

    fn getGroupId(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }

    const JSON = struct {
        deviceId: []const u8,
        kind: []const u8,
        label: []const u8,
        groupId: []const u8,
    };

    fn toJSON(self: *const MediaDeviceInfo) JSON {
        return .{
            .deviceId = "",
            .kind = self._kind,
            .label = "",
            .groupId = "",
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaDeviceInfo);
        pub const Meta = struct {
            pub const name = "MediaDeviceInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const deviceId = bridge.accessor(MediaDeviceInfo.getDeviceId, null, .{});
        pub const kind = bridge.accessor(MediaDeviceInfo.getKind, null, .{});
        pub const label = bridge.accessor(MediaDeviceInfo.getLabel, null, .{});
        pub const groupId = bridge.accessor(MediaDeviceInfo.getGroupId, null, .{});
        pub const toJSON = bridge.function(MediaDeviceInfo.toJSON, .{});
    };
};

pub const InputDeviceInfo = struct {
    pub const Proto = MediaDeviceInfo;
    _proto: *MediaDeviceInfo,

    fn getCapabilities(_: *const InputDeviceInfo) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(InputDeviceInfo);
        pub const Meta = struct {
            pub const name = "InputDeviceInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getCapabilities = bridge.function(InputDeviceInfo.getCapabilities, .{});
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
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _frame: *Frame,
    _ready_resolver: ?js.PromiseResolver.Global = null,
    _ready_registration: ?*ServiceWorkerRegistration = null,
    _on_controller_change: ?js.Function.Global = null,
    _on_message: ?js.Function.Global = null,
    _on_message_error: ?js.Function.Global = null,

    /// No worker controls this page, which is the truth on a first load even
    /// in a browser that supports them.
    fn getController(_: *const ServiceWorkerContainer) ?*ServiceWorker {
        return null;
    }

    fn getReady(self: *ServiceWorkerContainer, exec: *const Execution) !js.Promise {
        if (self._ready_registration) |registration| {
            if (registration._scope._state == .activated) {
                return exec.js.local.?.resolvePromise(registration);
            }
        }
        if (self._ready_resolver) |resolver| {
            return resolver.local(exec.js.local.?).promise();
        }
        const resolver = exec.js.local.?.createPromiseResolver();
        self._ready_resolver = try resolver.persist();
        return resolver.promise();
    }

    fn register(
        self: *ServiceWorkerContainer,
        script_url: []const u8,
        options_: ?ServiceWorkerGlobalScope.RegistrationOptions,
        exec: *const Execution,
    ) !js.Promise {
        const frame = self._frame;
        const options: ServiceWorkerGlobalScope.RegistrationOptions = options_ orelse .{};
        const worker_type: @import("Worker.zig").WorkerType = if (options.type) |value|
            if (std.mem.eql(u8, value, "module")) .module else .classic
        else
            .classic;
        const update_via_cache: ServiceWorkerGlobalScope.UpdateViaCache = if (options.updateViaCache) |value|
            if (std.mem.eql(u8, value, "all"))
                .all
            else if (std.mem.eql(u8, value, "none"))
                .none
            else
                .imports
        else
            .imports;
        const resolved_script = try URL.resolve(frame.call_arena, frame.base(), script_url, .{ .encoding = frame.charset });
        if (!frame.isSameOrigin(resolved_script)) {
            return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.SecurityError } });
        }

        const raw_scope = options.scope orelse defaultScope(resolved_script);
        const resolved_scope = try URL.resolve(frame.call_arena, frame.base(), raw_scope, .{ .encoding = frame.charset });
        if (!frame.isSameOrigin(resolved_scope)) {
            return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.SecurityError } });
        }

        const session = frame._session;
        const scope = session.service_workers.get(resolved_scope) orelse create: {
            const created = try ServiceWorkerGlobalScope.init(frame, resolved_script, resolved_scope, worker_type, update_via_cache);
            errdefer created.deinit();
            try frame.page.service_workers.append(frame.page.frame_arena, created);
            errdefer _ = frame.page.service_workers.pop();
            try created.register();
            break :create created;
        };

        const registration = try ServiceWorkerRegistration.init(scope, frame.page);
        registration._worker.setMessageTarget(.{
            .context = self,
            .callback = receiveWorkerMessage,
        });
        self._ready_registration = registration;

        if (scope._state == .activated) {
            if (self._ready_resolver) |ready| {
                ready.local(exec.js.local.?).resolve("ServiceWorkerContainer.ready", registration);
                ready.deinit();
                self._ready_resolver = null;
            }
            return exec.js.local.?.resolvePromise(registration);
        }

        const resolver = exec.js.local.?.createPromiseResolver();
        const persisted = try resolver.persist();
        const ready = self._ready_resolver;
        self._ready_resolver = null;
        try scope.addWaiter(registration, persisted, ready);
        return resolver.promise();
    }

    fn getRegistration(self: *ServiceWorkerContainer, document_url_: ?[]const u8, exec: *const Execution) !js.Promise {
        const frame = self._frame;
        const document_url = document_url_ orelse "";
        const resolved = if (document_url.len == 0)
            frame.url
        else
            try URL.resolve(frame.call_arena, frame.base(), document_url, .{ .encoding = frame.charset });

        var best: ?*ServiceWorkerGlobalScope = null;
        var it = frame._session.service_workers.valueIterator();
        while (it.next()) |candidate| {
            if (std.mem.startsWith(u8, resolved, candidate.*._scope) and
                (best == null or candidate.*._scope.len > best.?._scope.len))
            {
                best = candidate.*;
            }
        }
        const scope = best orelse return exec.js.local.?.resolvePromise(js.Undefined{});
        return exec.js.local.?.resolvePromise(try ServiceWorkerRegistration.init(scope, frame.page));
    }

    fn getRegistrations(self: *ServiceWorkerContainer, exec: *const Execution) !js.Promise {
        const frame = self._frame;
        const registrations = try frame.call_arena.alloc(*ServiceWorkerRegistration, frame._session.service_workers.count());
        var i: usize = 0;
        var it = frame._session.service_workers.valueIterator();
        while (it.next()) |scope| : (i += 1) {
            registrations[i] = try ServiceWorkerRegistration.init(scope.*, frame.page);
        }
        return exec.js.local.?.resolvePromise(registrations);
    }
    fn startMessages(_: *const ServiceWorkerContainer) void {}

    fn receiveWorkerMessage(
        context: *anyopaque,
        source: *ServiceWorker,
        data: js.Value,
    ) !void {
        const self: *ServiceWorkerContainer = @ptrCast(@alignCast(context));
        const frame = self._frame;
        const message_arena = try frame.getArena(.tiny, "ServiceWorkerContainer.receiveMessage");
        errdefer message_arena.release();

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const cloned = data.structuredCloneTo(&ls.local) catch |err| {
            const callback = try message_arena.create(ContainerMessageCallback);
            callback.* = .{ .arena = message_arena, .container = self, .source = source, .data = err };
            try frame.js.scheduler.add(callback, ContainerMessageCallback.run, 0, .{
                .name = "ServiceWorkerContainer.messageerror",
                .finalizer = ContainerMessageCallback.cancelled,
            });
            return;
        };
        const persisted = try cloned.persist();
        errdefer persisted.release();

        const callback = try message_arena.create(ContainerMessageCallback);
        callback.* = .{ .arena = message_arena, .container = self, .source = source, .data = persisted };
        try frame.js.scheduler.add(callback, ContainerMessageCallback.run, 0, .{
            .name = "ServiceWorkerContainer.message",
            .finalizer = ContainerMessageCallback.cancelled,
        });
    }

    const ContainerMessageCallback = struct {
        arena: *@import("../../Arena.zig"),
        container: *ServiceWorkerContainer,
        source: *ServiceWorker,
        data: anyerror!js.Value.Global,

        fn cancelled(context: *anyopaque) void {
            const self: *ContainerMessageCallback = @ptrCast(@alignCast(context));
            if (self.data) |data| data.release() else |_| {}
            self.arena.release();
        }

        fn run(context: *anyopaque) !?u32 {
            const self: *ContainerMessageCallback = @ptrCast(@alignCast(context));
            defer self.arena.release();

            const container = self.container;
            const frame = container._frame;
            const target = container._proto;
            const data = self.data catch |err| {
                if (!frame._event_manager.hasDirectListeners(target, "messageerror", container._on_message_error)) return null;
                const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                    .data = .{ .string = @errorName(err) },
                    .bubbles = false,
                    .cancelable = false,
                }, frame.page)).asEvent();
                try frame._event_manager.dispatchDirect(target, event, container._on_message_error, .{ .context = "ServiceWorkerContainer.messageerror" });
                return null;
            };

            if (!frame._event_manager.hasDirectListeners(target, "message", container._on_message)) {
                data.release();
                return null;
            }

            var ls: js.Local.Scope = undefined;
            frame.js.localScope(&ls);
            defer ls.deinit();
            const source = try (try ls.local.zigValueToJs(self.source, .{})).persist();
            errdefer source.release();
            const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
                .data = .{ .value = data },
                .source = .{ .value = source },
                .bubbles = false,
                .cancelable = false,
            }, frame.page)).asEvent();
            try frame._event_manager.dispatchDirect(target, event, container._on_message, .{ .context = "ServiceWorkerContainer.message" });
            return null;
        }
    };

    fn defaultScope(script_url: []const u8) []const u8 {
        const end = std.mem.indexOfAny(u8, script_url, "?#") orelse script_url.len;
        const slash = std.mem.lastIndexOfScalar(u8, script_url[0..end], '/') orelse return script_url[0..end];
        return script_url[0 .. slash + 1];
    }

    fn getOnControllerChange(self: *const ServiceWorkerContainer) ?js.Function.Global {
        return self._on_controller_change;
    }
    fn setOnControllerChange(self: *ServiceWorkerContainer, setter: ?FunctionSetter) void {
        self._on_controller_change = getFunctionFromSetter(setter);
    }
    fn getOnMessage(self: *const ServiceWorkerContainer) ?js.Function.Global {
        return self._on_message;
    }
    fn setOnMessage(self: *ServiceWorkerContainer, setter: ?FunctionSetter) void {
        self._on_message = getFunctionFromSetter(setter);
    }
    fn getOnMessageError(self: *const ServiceWorkerContainer) ?js.Function.Global {
        return self._on_message_error;
    }
    fn setOnMessageError(self: *ServiceWorkerContainer, setter: ?FunctionSetter) void {
        self._on_message_error = getFunctionFromSetter(setter);
    }

    const FunctionSetter = union(enum) {
        func: js.Function.Global,
        anything: js.Value,
    };

    fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
        const setter = setter_ orelse return null;
        return switch (setter) {
            .func => |func| func,
            .anything => null,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ServiceWorkerContainer);
        pub const Meta = struct {
            pub const name = "ServiceWorkerContainer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const controller = bridge.accessor(ServiceWorkerContainer.getController, null, .{});
        pub const ready = bridge.accessor(ServiceWorkerContainer.getReady, null, .{});
        pub const register = bridge.function(ServiceWorkerContainer.register, .{});
        pub const getRegistration = bridge.function(ServiceWorkerContainer.getRegistration, .{});
        pub const getRegistrations = bridge.function(ServiceWorkerContainer.getRegistrations, .{});
        pub const startMessages = bridge.function(ServiceWorkerContainer.startMessages, .{});
        pub const oncontrollerchange = bridge.accessor(ServiceWorkerContainer.getOnControllerChange, ServiceWorkerContainer.setOnControllerChange, .{});
        pub const onmessage = bridge.accessor(ServiceWorkerContainer.getOnMessage, ServiceWorkerContainer.setOnMessage, .{});
        pub const onmessageerror = bridge.accessor(ServiceWorkerContainer.getOnMessageError, ServiceWorkerContainer.setOnMessageError, .{});
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
            pub const expose_global = false;
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

test "WebApi: WebGPU" {
    const testing = @import("../../testing.zig");
    try testing.htmlRunner("webgpu.html", .{});
}
