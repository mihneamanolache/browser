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

//! A WebGL 1.0 context that answers questions but never draws.
//!
//! `getContext('webgl')` used to return null, because a context that
//! answered `getParameter` and then threw on `createTexture` was worse than
//! no context at all: apps with an error boundary above the WebGL widget
//! caught the throw, reset, re-rendered and looped forever. The fix for that
//! is not to withhold the context — it is to stop throwing. Every entry
//! point in the WebGL 1.0 surface exists here and returns something a
//! consumer can proceed with: object creators hand back live handles,
//! `COMPILE_STATUS` and `LINK_STATUS` report success, `getError` reports
//! `NO_ERROR`, and the draw calls are no-ops. A renderer runs its whole
//! setup path and draws nothing, which is the same outcome as before for
//! pixels and a much better one for control flow.
//!
//! Nothing here touches a GPU. The `getParameter` table is the fixed
//! profile's, so the reported limits describe the machine the profile
//! claims rather than whatever the host happens to have — the same reason
//! `navigator.platform` is fixed.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Canvas = @import("../element/html/Canvas.zig");

const fingerprint = lp.fingerprint;
const webgl = fingerprint.webgl;

pub fn registerTypes() []const type {
    return &.{
        WebGLRenderingContext,
        WebGLBuffer,
        WebGLFramebuffer,
        WebGLProgram,
        WebGLRenderbuffer,
        WebGLShader,
        WebGLTexture,
        WebGLUniformLocation,
        WebGLActiveInfo,
        WebGLShaderPrecisionFormat,
        // Extension types should be runtime generated. We might want
        // to revisit this.
        Extension.Type.WEBGL_debug_renderer_info,
        Extension.Type.WEBGL_lose_context,
    };
}

const WebGLRenderingContext = @This();

/// Reference to the parent canvas element, for `gl.canvas` and for the
/// drawing buffer size.
_canvas: *Canvas,

fn getCanvas(self: *const WebGLRenderingContext) *Canvas {
    return self._canvas;
}

/// Without a real drawing buffer these track the canvas exactly. A real
/// context can come back smaller when the canvas exceeds MAX_TEXTURE_SIZE;
/// nothing here allocates, so it never does.
fn getDrawingBufferWidth(self: *const WebGLRenderingContext) u32 {
    return self._canvas.getWidth();
}

fn getDrawingBufferHeight(self: *const WebGLRenderingContext) u32 {
    return self._canvas.getHeight();
}

// -- GLenum values we actually answer for ------------------------------------

const GL = struct {
    const NO_ERROR: u32 = 0;
    const POINTS: u32 = 0x0000;
    const FUNC_ADD: u32 = 0x8006;
    const ZERO: u32 = 0;
    const ONE: u32 = 1;
    const FRONT: u32 = 0x0404;
    const BACK: u32 = 0x0405;
    const CCW: u32 = 0x0901;
    const LESS: u32 = 0x0201;
    const ALWAYS: u32 = 0x0207;
    const KEEP: u32 = 0x1E00;
    const FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
    const RGBA: u32 = 0x1908;
    const UNSIGNED_BYTE: u32 = 0x1401;
    const BROWSER_DEFAULT_WEBGL: u32 = 0x9244;
    const NONE: u32 = 0;

    // getParameter pnames
    const ACTIVE_TEXTURE: u32 = 0x84E0;
    const ALIASED_LINE_WIDTH_RANGE: u32 = 0x846E;
    const ALIASED_POINT_SIZE_RANGE: u32 = 0x846D;
    const ALPHA_BITS: u32 = 0x0D55;
    const BLEND: u32 = 0x0BE2;
    const BLEND_COLOR: u32 = 0x8005;
    const BLUE_BITS: u32 = 0x0D54;
    const COLOR_CLEAR_VALUE: u32 = 0x0C22;
    const COLOR_WRITEMASK: u32 = 0x0C23;
    const CULL_FACE: u32 = 0x0B44;
    const CULL_FACE_MODE: u32 = 0x0B45;
    const DEPTH_BITS: u32 = 0x0D56;
    const DEPTH_CLEAR_VALUE: u32 = 0x0B73;
    const DEPTH_FUNC: u32 = 0x0B74;
    const DEPTH_RANGE: u32 = 0x0B70;
    const DEPTH_TEST: u32 = 0x0B71;
    const DEPTH_WRITEMASK: u32 = 0x0B72;
    const DITHER: u32 = 0x0BD0;
    const FRONT_FACE: u32 = 0x0B46;
    const GREEN_BITS: u32 = 0x0D53;
    const IMPLEMENTATION_COLOR_READ_FORMAT: u32 = 0x8B9B;
    const IMPLEMENTATION_COLOR_READ_TYPE: u32 = 0x8B9A;
    const LINE_WIDTH: u32 = 0x0B21;
    const MAX_COMBINED_TEXTURE_IMAGE_UNITS: u32 = 0x8B4D;
    const MAX_CUBE_MAP_TEXTURE_SIZE: u32 = 0x851C;
    const MAX_FRAGMENT_UNIFORM_VECTORS: u32 = 0x8DFD;
    const MAX_RENDERBUFFER_SIZE: u32 = 0x84E8;
    const MAX_TEXTURE_IMAGE_UNITS: u32 = 0x8872;
    const MAX_TEXTURE_SIZE: u32 = 0x0D33;
    const MAX_VARYING_VECTORS: u32 = 0x8DFC;
    const MAX_VERTEX_ATTRIBS: u32 = 0x8869;
    const MAX_VERTEX_TEXTURE_IMAGE_UNITS: u32 = 0x8B4C;
    const MAX_VERTEX_UNIFORM_VECTORS: u32 = 0x8DFB;
    const MAX_VIEWPORT_DIMS: u32 = 0x0D3A;
    const MAX_TEXTURE_MAX_ANISOTROPY_EXT: u32 = 0x84FF;
    const PACK_ALIGNMENT: u32 = 0x0D05;
    const RED_BITS: u32 = 0x0D52;
    const RENDERER: u32 = 0x1F01;
    const SAMPLES: u32 = 0x80A9;
    const SAMPLE_BUFFERS: u32 = 0x80A8;
    const SCISSOR_BOX: u32 = 0x0C10;
    const SCISSOR_TEST: u32 = 0x0C11;
    const SHADING_LANGUAGE_VERSION: u32 = 0x8B8C;
    const STENCIL_BITS: u32 = 0x0D57;
    const STENCIL_TEST: u32 = 0x0B90;
    const SUBPIXEL_BITS: u32 = 0x0D50;
    const UNMASKED_RENDERER_WEBGL: u32 = 0x9246;
    const UNMASKED_VENDOR_WEBGL: u32 = 0x9245;
    const UNPACK_ALIGNMENT: u32 = 0x0CF5;
    const UNPACK_COLORSPACE_CONVERSION_WEBGL: u32 = 0x9243;
    const VENDOR: u32 = 0x1F00;
    const VERSION: u32 = 0x1F02;
    const VIEWPORT: u32 = 0x0BA2;

    // getShaderParameter / getProgramParameter pnames
    const COMPILE_STATUS: u32 = 0x8B81;
    const DELETE_STATUS: u32 = 0x8B80;
    const LINK_STATUS: u32 = 0x8B82;
    const VALIDATE_STATUS: u32 = 0x8B83;
    const ATTACHED_SHADERS: u32 = 0x8B85;
    const ACTIVE_ATTRIBUTES: u32 = 0x8B89;
    const ACTIVE_UNIFORMS: u32 = 0x8B86;
    const SHADER_TYPE: u32 = 0x8B4F;
};

/// What `getParameter` can hand back. The bridge serializes a tagged union
/// by its active field, and typed-array variants matter: Chrome returns an
/// Int32Array for MAX_VIEWPORT_DIMS and a Float32Array for the range
/// parameters, and code does `gl.getParameter(...)[0]` on them.
const Parameter = union(enum) {
    boolean: bool,
    number: f64,
    string: []const u8,
    int32_array: js.TypedArray(i32),
    float32_array: js.TypedArray(f32),
    bool_array: []const bool,
};

fn int(value: i64) Parameter {
    return .{ .number = @floatFromInt(value) };
}

/// Returns null for an unrecognized pname, which is what a real context does
/// (after raising INVALID_ENUM, which nothing here reads).
fn getParameter(self: *const WebGLRenderingContext, pname: u32) ?Parameter {
    return switch (pname) {
        // Identity. Chrome masks the real GPU behind VENDOR/RENDERER and
        // only reveals the true strings through WEBGL_debug_renderer_info.
        GL.VENDOR => .{ .string = webgl.vendor },
        GL.RENDERER => .{ .string = webgl.renderer },
        GL.VERSION => .{ .string = webgl.version },
        GL.SHADING_LANGUAGE_VERSION => .{ .string = webgl.shading_language_version },
        GL.UNMASKED_VENDOR_WEBGL => .{ .string = webgl.unmaskedVendor() },
        GL.UNMASKED_RENDERER_WEBGL => .{ .string = webgl.unmaskedRenderer() },

        // Limits. These are the values the claimed GPU reports; a
        // fingerprinter that reads them and cross-checks against the
        // renderer string has to find them consistent.
        GL.MAX_TEXTURE_SIZE => int(webgl.max_texture_size),
        GL.MAX_CUBE_MAP_TEXTURE_SIZE => int(webgl.max_texture_size),
        GL.MAX_RENDERBUFFER_SIZE => int(webgl.max_renderbuffer_size),
        GL.MAX_VERTEX_ATTRIBS => int(webgl.max_vertex_attribs),
        GL.MAX_VERTEX_UNIFORM_VECTORS => int(4096),
        GL.MAX_VARYING_VECTORS => int(webgl.max_varying_vectors),
        GL.MAX_FRAGMENT_UNIFORM_VECTORS => int(1024),
        GL.MAX_TEXTURE_IMAGE_UNITS => int(16),
        GL.MAX_VERTEX_TEXTURE_IMAGE_UNITS => int(16),
        GL.MAX_COMBINED_TEXTURE_IMAGE_UNITS => int(webgl.max_combined_texture_image_units),
        GL.MAX_TEXTURE_MAX_ANISOTROPY_EXT => int(16),
        GL.MAX_VIEWPORT_DIMS => .{ .int32_array = .{ .values = webgl.maxViewportDims() } },
        GL.ALIASED_LINE_WIDTH_RANGE => .{ .float32_array = .{ .values = &webgl.aliased_line_width_range } },
        GL.ALIASED_POINT_SIZE_RANGE => .{ .float32_array = .{ .values = webgl.aliasedPointSizeRange() } },

        // Drawing buffer format. The default context attributes ask for
        // alpha and depth but not stencil or antialiasing-by-samples.
        GL.RED_BITS, GL.GREEN_BITS, GL.BLUE_BITS, GL.ALPHA_BITS => int(8),
        GL.DEPTH_BITS => int(webgl.depth_bits),
        GL.STENCIL_BITS => int(webgl.stencil_bits),
        GL.SUBPIXEL_BITS => int(4),
        GL.SAMPLES, GL.SAMPLE_BUFFERS => int(0),
        GL.IMPLEMENTATION_COLOR_READ_FORMAT => int(GL.RGBA),
        GL.IMPLEMENTATION_COLOR_READ_TYPE => int(GL.UNSIGNED_BYTE),

        // Initial pipeline state, per the GLES 2.0 defaults.
        GL.ACTIVE_TEXTURE => int(0x84C0),
        GL.BLEND, GL.CULL_FACE, GL.DEPTH_TEST, GL.SCISSOR_TEST, GL.STENCIL_TEST => .{ .boolean = false },
        GL.DITHER, GL.DEPTH_WRITEMASK => .{ .boolean = true },
        GL.BLEND_COLOR, GL.COLOR_CLEAR_VALUE => .{ .float32_array = .{ .values = &.{ 0, 0, 0, 0 } } },
        GL.COLOR_WRITEMASK => .{ .bool_array = &.{ true, true, true, true } },
        GL.CULL_FACE_MODE => int(GL.BACK),
        GL.FRONT_FACE => int(GL.CCW),
        GL.DEPTH_FUNC => int(GL.LESS),
        GL.DEPTH_CLEAR_VALUE => .{ .number = 1 },
        GL.DEPTH_RANGE => .{ .float32_array = .{ .values = &.{ 0, 1 } } },
        GL.LINE_WIDTH => .{ .number = 1 },
        GL.PACK_ALIGNMENT, GL.UNPACK_ALIGNMENT => int(4),
        GL.UNPACK_COLORSPACE_CONVERSION_WEBGL => int(GL.BROWSER_DEFAULT_WEBGL),
        GL.VIEWPORT, GL.SCISSOR_BOX => .{ .int32_array = .{ .values = &.{
            0,
            0,
            @intCast(self._canvas.getWidth()),
            @intCast(self._canvas.getHeight()),
        } } },

        else => null,
    };
}

/// Every compile and link "succeeds". A renderer that is told its shader
/// failed reads `getShaderInfoLog` and throws; telling it the shader is fine
/// lets it proceed to draw calls that do nothing.
fn getShaderParameter(_: *const WebGLRenderingContext, shader: *WebGLShader, pname: u32) ?Parameter {
    return switch (pname) {
        GL.COMPILE_STATUS => .{ .boolean = true },
        GL.DELETE_STATUS => .{ .boolean = false },
        GL.SHADER_TYPE => int(shader._type),
        else => null,
    };
}

fn getProgramParameter(_: *const WebGLRenderingContext, _: *WebGLProgram, pname: u32) ?Parameter {
    return switch (pname) {
        GL.LINK_STATUS, GL.VALIDATE_STATUS => .{ .boolean = true },
        GL.DELETE_STATUS => .{ .boolean = false },
        // No shader is ever really compiled, so the program has no
        // introspectable attributes or uniforms. Renderers look these up by
        // name (getUniformLocation) rather than enumerating them.
        GL.ATTACHED_SHADERS => int(2),
        GL.ACTIVE_ATTRIBUTES, GL.ACTIVE_UNIFORMS => int(0),
        else => null,
    };
}

fn getShaderInfoLog(_: *const WebGLRenderingContext, _: *WebGLShader) []const u8 {
    return "";
}

fn getProgramInfoLog(_: *const WebGLRenderingContext, _: *WebGLProgram) []const u8 {
    return "";
}

fn getShaderSource(_: *const WebGLRenderingContext, shader: *WebGLShader) []const u8 {
    return shader._source;
}

fn shaderSource(_: *const WebGLRenderingContext, shader: *WebGLShader, source: []const u8, frame: *Frame) !void {
    // Kept so getShaderSource round-trips, which some engines rely on when
    // they cache compiled programs.
    shader._source = try frame.arena.dupe(u8, source);
}

fn getError(_: *const WebGLRenderingContext) u32 {
    return GL.NO_ERROR;
}

fn isContextLost(_: *const WebGLRenderingContext) bool {
    return false;
}

const ContextAttributes = struct {
    alpha: bool = true,
    antialias: bool = true,
    depth: bool = true,
    desynchronized: bool = false,
    failIfMajorPerformanceCaveat: bool = false,
    powerPreference: []const u8 = "default",
    premultipliedAlpha: bool = true,
    preserveDrawingBuffer: bool = false,
    stencil: bool = false,
    xrCompatible: bool = false,
};

/// The WebGL defaults. A page that passed its own attributes to getContext
/// does not get them back here; nothing consumes them, so there is nothing
/// for them to change.
fn getContextAttributes(_: *const WebGLRenderingContext) ContextAttributes {
    return .{};
}

const PrecisionFormat = struct {
    rangeMin: i32,
    rangeMax: i32,
    precision: i32,
};

/// IEEE-754 single precision for the float types, 32-bit for the int types —
/// what every desktop GPU reports.
fn getShaderPrecisionFormat(_: *const WebGLRenderingContext, _: u32, precision_type: u32) PrecisionFormat {
    // 0x8DF0..0x8DF2 are LOW/MEDIUM/HIGH_FLOAT; 0x8DF3..0x8DF5 are the int
    // ones. Only the int types have zero fractional precision.
    const LOW_INT: u32 = 0x8DF3;
    const MEDIUM_INT: u32 = 0x8DF4;
    const HIGH_INT: u32 = 0x8DF5;
    return switch (precision_type) {
        LOW_INT, MEDIUM_INT, HIGH_INT => .{ .rangeMin = 31, .rangeMax = 30, .precision = 0 },
        else => .{ .rangeMin = 127, .rangeMax = 127, .precision = 23 },
    };
}

fn checkFramebufferStatus(_: *const WebGLRenderingContext, _: u32) u32 {
    return GL.FRAMEBUFFER_COMPLETE;
}

// -- Object creation ---------------------------------------------------------
//
// Each creator hands back a live handle. Returning null here is what a real
// context does only when it is lost, and a renderer that gets null throws.

fn createBuffer(_: *WebGLRenderingContext, frame: *Frame) !*WebGLBuffer {
    return frame._factory.create(WebGLBuffer{});
}

fn createFramebuffer(_: *WebGLRenderingContext, frame: *Frame) !*WebGLFramebuffer {
    return frame._factory.create(WebGLFramebuffer{});
}

fn createRenderbuffer(_: *WebGLRenderingContext, frame: *Frame) !*WebGLRenderbuffer {
    return frame._factory.create(WebGLRenderbuffer{});
}

fn createProgram(_: *WebGLRenderingContext, frame: *Frame) !*WebGLProgram {
    return frame._factory.create(WebGLProgram{});
}

fn createShader(_: *WebGLRenderingContext, shader_type: u32, frame: *Frame) !*WebGLShader {
    return frame._factory.create(WebGLShader{ ._type = shader_type });
}

fn createTexture(_: *WebGLRenderingContext, frame: *Frame) !*WebGLTexture {
    return frame._factory.create(WebGLTexture{});
}

/// Never null. A renderer treats a null location as "uniform optimized out"
/// and skips the upload, which is harmless, but three.js asserts on a null
/// location for required uniforms in some paths.
fn getUniformLocation(_: *WebGLRenderingContext, _: *WebGLProgram, _: []const u8, frame: *Frame) !*WebGLUniformLocation {
    return frame._factory.create(WebGLUniformLocation{});
}

/// -1 means "no such attribute", which is the honest answer when no shader
/// was ever compiled, and is a value every consumer already handles (it is
/// what an unused attribute returns on a real GPU).
fn getAttribLocation(_: *const WebGLRenderingContext, _: *WebGLProgram, _: []const u8) i32 {
    return -1;
}

/// The program reports zero active attributes and uniforms, so any index is
/// out of range and null is the correct answer.
fn getActiveAttrib(_: *WebGLRenderingContext, _: *WebGLProgram, _: u32) ?*WebGLActiveInfo {
    return null;
}

fn getActiveUniform(_: *WebGLRenderingContext, _: *WebGLProgram, _: u32) ?*WebGLActiveInfo {
    return null;
}

fn getAttachedShaders(_: *WebGLRenderingContext, _: *WebGLProgram) []const *WebGLShader {
    return &.{};
}

/// Nothing is ever bound, so every "is this mine?" answer is no. Consumers
/// use these for asserts and cleanup guards.
fn isFalse(_: *const WebGLRenderingContext, _: js.Value) bool {
    return false;
}

fn isEnabled(_: *const WebGLRenderingContext, cap: u32) bool {
    // Matches the getParameter defaults: only DITHER starts enabled.
    return cap == GL.DITHER;
}

/// Null for every query against state that was never really set.
fn getNull(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) ?Parameter {
    return null;
}

// -- Extensions --------------------------------------------------------------

/// On Chrome and Safari, a call to `getSupportedExtensions` returns total of 39.
/// The reference for it lists lesser number of extensions:
/// https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Using_Extensions#extension_list
const Extension = union(enum) {
    ANGLE_instanced_arrays: void,
    EXT_blend_minmax: void,
    EXT_clip_control: void,
    EXT_color_buffer_half_float: void,
    EXT_depth_clamp: void,
    EXT_disjoint_timer_query: void,
    EXT_float_blend: void,
    EXT_frag_depth: void,
    EXT_polygon_offset_clamp: void,
    EXT_shader_texture_lod: void,
    EXT_texture_compression_bptc: void,
    EXT_texture_compression_rgtc: void,
    EXT_texture_filter_anisotropic: void,
    EXT_texture_mirror_clamp_to_edge: void,
    EXT_sRGB: void,
    KHR_parallel_shader_compile: void,
    OES_element_index_uint: void,
    OES_fbo_render_mipmap: void,
    OES_standard_derivatives: void,
    OES_texture_float: void,
    OES_texture_float_linear: void,
    OES_texture_half_float: void,
    OES_texture_half_float_linear: void,
    OES_vertex_array_object: void,
    WEBGL_blend_func_extended: void,
    WEBGL_color_buffer_float: void,
    WEBGL_compressed_texture_astc: void,
    WEBGL_compressed_texture_etc: void,
    WEBGL_compressed_texture_etc1: void,
    WEBGL_compressed_texture_pvrtc: void,
    WEBGL_compressed_texture_s3tc: void,
    WEBGL_compressed_texture_s3tc_srgb: void,
    WEBGL_debug_renderer_info: *Type.WEBGL_debug_renderer_info,
    WEBGL_debug_shaders: void,
    WEBGL_depth_texture: void,
    WEBGL_draw_buffers: void,
    WEBGL_lose_context: *Type.WEBGL_lose_context,
    WEBGL_multi_draw: void,
    WEBGL_polygon_mode: void,

    /// Reified enum type from the fields of this union.
    const Kind = blk: {
        const info = @typeInfo(Extension).@"union";
        const fields = info.fields;
        const Tag = std.math.IntFittingRange(0, if (fields.len == 0) 0 else fields.len - 1);
        var names: [fields.len][:0]const u8 = undefined;
        for (fields, 0..) |field, i| {
            names[i] = field.name;
        }

        break :blk @Enum(Tag, .exhaustive, &names, &std.simd.iota(Tag, fields.len));
    };

    /// Returns the `Extension.Kind` by its name.
    fn find(name: []const u8) ?Kind {
        // Just to make you really sad, this function has to be case-insensitive.
        // So here we copy what's being done in `std.meta.stringToEnum` but replace
        // the comparison function.
        const kvs = comptime build_kvs: {
            const T = Extension.Kind;
            const EnumKV = struct { []const u8, T };
            var kvs_array: [@typeInfo(T).@"enum".fields.len]EnumKV = undefined;
            for (@typeInfo(T).@"enum".fields, 0..) |enumField, i| {
                kvs_array[i] = .{ enumField.name, @field(T, enumField.name) };
            }
            break :build_kvs kvs_array[0..];
        };
        const Map = std.StaticStringMapWithEql(Extension.Kind, std.static_string_map.eqlAsciiIgnoreCase);
        const map = Map.initComptime(kvs);
        return map.get(name);
    }

    /// Extension types.
    pub const Type = struct {
        pub const WEBGL_debug_renderer_info = struct {
            _: u8 = 0,
            const UNMASKED_VENDOR_WEBGL: u64 = 0x9245;
            const UNMASKED_RENDERER_WEBGL: u64 = 0x9246;

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_debug_renderer_info);

                pub const Meta = struct {
                    pub const name = "WEBGL_debug_renderer_info";

                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const UNMASKED_VENDOR_WEBGL = bridge.property(WEBGL_debug_renderer_info.UNMASKED_VENDOR_WEBGL, .{ .template = false, .readonly = true });
                pub const UNMASKED_RENDERER_WEBGL = bridge.property(WEBGL_debug_renderer_info.UNMASKED_RENDERER_WEBGL, .{ .template = false, .readonly = true });
            };
        };

        pub const WEBGL_lose_context = struct {
            _: u8 = 0,
            fn loseContext(_: *const WEBGL_lose_context) void {}
            fn restoreContext(_: *const WEBGL_lose_context) void {}

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_lose_context);

                pub const Meta = struct {
                    pub const name = "WEBGL_lose_context";

                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const loseContext = bridge.function(WEBGL_lose_context.loseContext, .{ .noop = true });
                pub const restoreContext = bridge.function(WEBGL_lose_context.restoreContext, .{ .noop = true });
            };
        };
    };
};

/// Enables a WebGL extension.
fn getExtension(_: *const WebGLRenderingContext, name: []const u8, frame: *Frame) !?Extension {
    const tag = Extension.find(name) orelse return null;

    return switch (tag) {
        .WEBGL_debug_renderer_info => {
            const info = try frame._factory.create(Extension.Type.WEBGL_debug_renderer_info{});
            return .{ .WEBGL_debug_renderer_info = info };
        },
        .WEBGL_lose_context => {
            const ctx = try frame._factory.create(Extension.Type.WEBGL_lose_context{});
            return .{ .WEBGL_lose_context = ctx };
        },
        inline else => |comptime_enum| @unionInit(Extension, @tagName(comptime_enum), {}),
    };
}

/// Returns a list of all the supported WebGL extensions.
fn getSupportedExtensions(_: *const WebGLRenderingContext) []const []const u8 {
    return std.meta.fieldNames(Extension.Kind);
}

// -- Opaque resource handles -------------------------------------------------

/// Declares an opaque WebGL object type: a name, a prototype, and nothing
/// else. A real one wraps a GL name; these only need distinct identity.
fn OpaqueResource(comptime type_name: [:0]const u8) type {
    return struct {
        const Self = @This();

        _pad: bool = false,

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = type_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };
        };
    };
}

const WebGLBuffer = OpaqueResource("WebGLBuffer");
const WebGLFramebuffer = OpaqueResource("WebGLFramebuffer");
const WebGLProgram = OpaqueResource("WebGLProgram");
const WebGLRenderbuffer = OpaqueResource("WebGLRenderbuffer");
const WebGLTexture = OpaqueResource("WebGLTexture");
const WebGLUniformLocation = OpaqueResource("WebGLUniformLocation");

const WebGLShader = struct {
    _type: u32,
    _source: []const u8 = "",

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLShader);

        pub const Meta = struct {
            pub const name = "WebGLShader";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

/// Only ever returned by getActiveAttrib/getActiveUniform, which always
/// return null here — but the constructor has to exist on the global for
/// feature detection to find it.
const WebGLActiveInfo = struct {
    _name: []const u8 = "",
    _size: i32 = 0,
    _type: u32 = 0,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLActiveInfo);

        pub const Meta = struct {
            pub const name = "WebGLActiveInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(struct {
            fn get(self: *const WebGLActiveInfo) []const u8 {
                return self._name;
            }
        }.get, null, .{});
        pub const size = bridge.accessor(struct {
            fn get(self: *const WebGLActiveInfo) i32 {
                return self._size;
            }
        }.get, null, .{});
        pub const @"type" = bridge.accessor(struct {
            fn get(self: *const WebGLActiveInfo) u32 {
                return self._type;
            }
        }.get, null, .{});
    };
};

/// getShaderPrecisionFormat returns a plain object here rather than an
/// instance, so this type exists only so the constructor is on the global.
const WebGLShaderPrecisionFormat = struct {
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLShaderPrecisionFormat);

        pub const Meta = struct {
            pub const name = "WebGLShaderPrecisionFormat";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

// -- No-op commands ----------------------------------------------------------
//
// Everything below draws, uploads or changes state, none of which this
// context does. They are declared with their real parameter counts so
// `gl.drawArrays.length` is 3 the way it is in Chrome, and marked noop so
// the bridge installs a callback that ignores its arguments entirely —
// nothing is marshalled, and no argument can be the wrong type.

const commands = struct {
    fn @"0"(_: *WebGLRenderingContext) void {}
    fn @"1"(_: *WebGLRenderingContext, _: js.Value) void {}
    fn @"2"(_: *WebGLRenderingContext, _: js.Value, _: js.Value) void {}
    fn @"3"(_: *WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
    fn @"4"(_: *WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
    fn @"5"(_: *WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
    fn @"6"(_: *WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
    fn @"7"(_: *WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
    fn @"8"(_: *WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
    fn @"9"(_: *WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
};

/// Void WebGL commands, indexed by argument count. These are comptime
/// constants rather than the return value of a helper because the bridge
/// reflects over each function's parameter list to derive its JS `length`,
/// and that reflection only works in a comptime context.
const noop = struct {
    const @"0" = JsApi.bridge.function(commands.@"0", .{ .noop = true });
    const @"1" = JsApi.bridge.function(commands.@"1", .{ .noop = true });
    const @"2" = JsApi.bridge.function(commands.@"2", .{ .noop = true });
    const @"3" = JsApi.bridge.function(commands.@"3", .{ .noop = true });
    const @"4" = JsApi.bridge.function(commands.@"4", .{ .noop = true });
    const @"5" = JsApi.bridge.function(commands.@"5", .{ .noop = true });
    const @"6" = JsApi.bridge.function(commands.@"6", .{ .noop = true });
    const @"7" = JsApi.bridge.function(commands.@"7", .{ .noop = true });
    const @"8" = JsApi.bridge.function(commands.@"8", .{ .noop = true });
    const @"9" = JsApi.bridge.function(commands.@"9", .{ .noop = true });
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebGLRenderingContext);

    pub const Meta = struct {
        pub const name = "WebGLRenderingContext";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // The WebGL 1.0 enum surface. Every renderer reads these off the
    // context (`gl.TRIANGLES`, `gl.FLOAT`), and a detector reads them too:
    // a context missing them, or reporting a wrong one, is not a browser.

    // Clearing buffers.
    pub const DEPTH_BUFFER_BIT = bridge.property(@as(u32, 0x100), .{ .template = false, .readonly = true });
    pub const STENCIL_BUFFER_BIT = bridge.property(@as(u32, 0x400), .{ .template = false, .readonly = true });
    pub const COLOR_BUFFER_BIT = bridge.property(@as(u32, 0x4000), .{ .template = false, .readonly = true });

    // Rendering primitives.
    pub const POINTS = bridge.property(@as(u32, 0x0), .{ .template = false, .readonly = true });
    pub const LINES = bridge.property(@as(u32, 0x1), .{ .template = false, .readonly = true });
    pub const LINE_LOOP = bridge.property(@as(u32, 0x2), .{ .template = false, .readonly = true });
    pub const LINE_STRIP = bridge.property(@as(u32, 0x3), .{ .template = false, .readonly = true });
    pub const TRIANGLES = bridge.property(@as(u32, 0x4), .{ .template = false, .readonly = true });
    pub const TRIANGLE_STRIP = bridge.property(@as(u32, 0x5), .{ .template = false, .readonly = true });
    pub const TRIANGLE_FAN = bridge.property(@as(u32, 0x6), .{ .template = false, .readonly = true });

    // Blending modes.
    pub const ZERO = bridge.property(@as(u32, 0x0), .{ .template = false, .readonly = true });
    pub const ONE = bridge.property(@as(u32, 0x1), .{ .template = false, .readonly = true });
    pub const SRC_COLOR = bridge.property(@as(u32, 0x300), .{ .template = false, .readonly = true });
    pub const ONE_MINUS_SRC_COLOR = bridge.property(@as(u32, 0x301), .{ .template = false, .readonly = true });
    pub const SRC_ALPHA = bridge.property(@as(u32, 0x302), .{ .template = false, .readonly = true });
    pub const ONE_MINUS_SRC_ALPHA = bridge.property(@as(u32, 0x303), .{ .template = false, .readonly = true });
    pub const DST_ALPHA = bridge.property(@as(u32, 0x304), .{ .template = false, .readonly = true });
    pub const ONE_MINUS_DST_ALPHA = bridge.property(@as(u32, 0x305), .{ .template = false, .readonly = true });
    pub const DST_COLOR = bridge.property(@as(u32, 0x306), .{ .template = false, .readonly = true });
    pub const ONE_MINUS_DST_COLOR = bridge.property(@as(u32, 0x307), .{ .template = false, .readonly = true });
    pub const SRC_ALPHA_SATURATE = bridge.property(@as(u32, 0x308), .{ .template = false, .readonly = true });
    pub const CONSTANT_COLOR = bridge.property(@as(u32, 0x8001), .{ .template = false, .readonly = true });
    pub const ONE_MINUS_CONSTANT_COLOR = bridge.property(@as(u32, 0x8002), .{ .template = false, .readonly = true });
    pub const CONSTANT_ALPHA = bridge.property(@as(u32, 0x8003), .{ .template = false, .readonly = true });
    pub const ONE_MINUS_CONSTANT_ALPHA = bridge.property(@as(u32, 0x8004), .{ .template = false, .readonly = true });

    // Blending equations.
    pub const FUNC_ADD = bridge.property(@as(u32, 0x8006), .{ .template = false, .readonly = true });
    pub const FUNC_SUBTRACT = bridge.property(@as(u32, 0x800A), .{ .template = false, .readonly = true });
    pub const FUNC_REVERSE_SUBTRACT = bridge.property(@as(u32, 0x800B), .{ .template = false, .readonly = true });
    pub const BLEND_EQUATION = bridge.property(@as(u32, 0x8009), .{ .template = false, .readonly = true });
    pub const BLEND_EQUATION_RGB = bridge.property(@as(u32, 0x8009), .{ .template = false, .readonly = true });
    pub const BLEND_EQUATION_ALPHA = bridge.property(@as(u32, 0x883D), .{ .template = false, .readonly = true });
    pub const BLEND_DST_RGB = bridge.property(@as(u32, 0x80C8), .{ .template = false, .readonly = true });
    pub const BLEND_SRC_RGB = bridge.property(@as(u32, 0x80C9), .{ .template = false, .readonly = true });
    pub const BLEND_DST_ALPHA = bridge.property(@as(u32, 0x80CA), .{ .template = false, .readonly = true });
    pub const BLEND_SRC_ALPHA = bridge.property(@as(u32, 0x80CB), .{ .template = false, .readonly = true });
    pub const BLEND_COLOR = bridge.property(@as(u32, 0x8005), .{ .template = false, .readonly = true });

    // Buffers.
    pub const ARRAY_BUFFER = bridge.property(@as(u32, 0x8892), .{ .template = false, .readonly = true });
    pub const ELEMENT_ARRAY_BUFFER = bridge.property(@as(u32, 0x8893), .{ .template = false, .readonly = true });
    pub const ARRAY_BUFFER_BINDING = bridge.property(@as(u32, 0x8894), .{ .template = false, .readonly = true });
    pub const ELEMENT_ARRAY_BUFFER_BINDING = bridge.property(@as(u32, 0x8895), .{ .template = false, .readonly = true });
    pub const STREAM_DRAW = bridge.property(@as(u32, 0x88E0), .{ .template = false, .readonly = true });
    pub const STATIC_DRAW = bridge.property(@as(u32, 0x88E4), .{ .template = false, .readonly = true });
    pub const DYNAMIC_DRAW = bridge.property(@as(u32, 0x88E8), .{ .template = false, .readonly = true });
    pub const BUFFER_SIZE = bridge.property(@as(u32, 0x8764), .{ .template = false, .readonly = true });
    pub const BUFFER_USAGE = bridge.property(@as(u32, 0x8765), .{ .template = false, .readonly = true });
    pub const CURRENT_VERTEX_ATTRIB = bridge.property(@as(u32, 0x8626), .{ .template = false, .readonly = true });

    // Culling and capabilities.
    pub const FRONT = bridge.property(@as(u32, 0x404), .{ .template = false, .readonly = true });
    pub const BACK = bridge.property(@as(u32, 0x405), .{ .template = false, .readonly = true });
    pub const FRONT_AND_BACK = bridge.property(@as(u32, 0x408), .{ .template = false, .readonly = true });
    pub const CULL_FACE = bridge.property(@as(u32, 0xB44), .{ .template = false, .readonly = true });
    pub const BLEND = bridge.property(@as(u32, 0xBE2), .{ .template = false, .readonly = true });
    pub const DITHER = bridge.property(@as(u32, 0xBD0), .{ .template = false, .readonly = true });
    pub const STENCIL_TEST = bridge.property(@as(u32, 0xB90), .{ .template = false, .readonly = true });
    pub const DEPTH_TEST = bridge.property(@as(u32, 0xB71), .{ .template = false, .readonly = true });
    pub const SCISSOR_TEST = bridge.property(@as(u32, 0xC11), .{ .template = false, .readonly = true });
    pub const POLYGON_OFFSET_FILL = bridge.property(@as(u32, 0x8037), .{ .template = false, .readonly = true });
    pub const SAMPLE_ALPHA_TO_COVERAGE = bridge.property(@as(u32, 0x809E), .{ .template = false, .readonly = true });
    pub const SAMPLE_COVERAGE = bridge.property(@as(u32, 0x80A0), .{ .template = false, .readonly = true });

    // Errors.
    pub const NO_ERROR = bridge.property(@as(u32, 0x0), .{ .template = false, .readonly = true });
    pub const INVALID_ENUM = bridge.property(@as(u32, 0x500), .{ .template = false, .readonly = true });
    pub const INVALID_VALUE = bridge.property(@as(u32, 0x501), .{ .template = false, .readonly = true });
    pub const INVALID_OPERATION = bridge.property(@as(u32, 0x502), .{ .template = false, .readonly = true });
    pub const OUT_OF_MEMORY = bridge.property(@as(u32, 0x505), .{ .template = false, .readonly = true });
    pub const INVALID_FRAMEBUFFER_OPERATION = bridge.property(@as(u32, 0x506), .{ .template = false, .readonly = true });
    pub const CONTEXT_LOST_WEBGL = bridge.property(@as(u32, 0x9242), .{ .template = false, .readonly = true });

    // Front face directions.
    pub const CW = bridge.property(@as(u32, 0x900), .{ .template = false, .readonly = true });
    pub const CCW = bridge.property(@as(u32, 0x901), .{ .template = false, .readonly = true });

    // Hints.
    pub const DONT_CARE = bridge.property(@as(u32, 0x1100), .{ .template = false, .readonly = true });
    pub const FASTEST = bridge.property(@as(u32, 0x1101), .{ .template = false, .readonly = true });
    pub const NICEST = bridge.property(@as(u32, 0x1102), .{ .template = false, .readonly = true });
    pub const GENERATE_MIPMAP_HINT = bridge.property(@as(u32, 0x8192), .{ .template = false, .readonly = true });

    // Data types.
    pub const BYTE = bridge.property(@as(u32, 0x1400), .{ .template = false, .readonly = true });
    pub const UNSIGNED_BYTE = bridge.property(@as(u32, 0x1401), .{ .template = false, .readonly = true });
    pub const SHORT = bridge.property(@as(u32, 0x1402), .{ .template = false, .readonly = true });
    pub const UNSIGNED_SHORT = bridge.property(@as(u32, 0x1403), .{ .template = false, .readonly = true });
    pub const INT = bridge.property(@as(u32, 0x1404), .{ .template = false, .readonly = true });
    pub const UNSIGNED_INT = bridge.property(@as(u32, 0x1405), .{ .template = false, .readonly = true });
    pub const FLOAT = bridge.property(@as(u32, 0x1406), .{ .template = false, .readonly = true });

    // Pixel formats.
    pub const DEPTH_COMPONENT = bridge.property(@as(u32, 0x1902), .{ .template = false, .readonly = true });
    pub const ALPHA = bridge.property(@as(u32, 0x1906), .{ .template = false, .readonly = true });
    pub const RGB = bridge.property(@as(u32, 0x1907), .{ .template = false, .readonly = true });
    pub const RGBA = bridge.property(@as(u32, 0x1908), .{ .template = false, .readonly = true });
    pub const LUMINANCE = bridge.property(@as(u32, 0x1909), .{ .template = false, .readonly = true });
    pub const LUMINANCE_ALPHA = bridge.property(@as(u32, 0x190A), .{ .template = false, .readonly = true });

    // Pixel types.
    pub const UNSIGNED_SHORT_4_4_4_4 = bridge.property(@as(u32, 0x8033), .{ .template = false, .readonly = true });
    pub const UNSIGNED_SHORT_5_5_5_1 = bridge.property(@as(u32, 0x8034), .{ .template = false, .readonly = true });
    pub const UNSIGNED_SHORT_5_6_5 = bridge.property(@as(u32, 0x8363), .{ .template = false, .readonly = true });

    // Shaders.
    pub const FRAGMENT_SHADER = bridge.property(@as(u32, 0x8B30), .{ .template = false, .readonly = true });
    pub const VERTEX_SHADER = bridge.property(@as(u32, 0x8B31), .{ .template = false, .readonly = true });
    pub const COMPILE_STATUS = bridge.property(@as(u32, 0x8B81), .{ .template = false, .readonly = true });
    pub const DELETE_STATUS = bridge.property(@as(u32, 0x8B80), .{ .template = false, .readonly = true });
    pub const LINK_STATUS = bridge.property(@as(u32, 0x8B82), .{ .template = false, .readonly = true });
    pub const VALIDATE_STATUS = bridge.property(@as(u32, 0x8B83), .{ .template = false, .readonly = true });
    pub const ATTACHED_SHADERS = bridge.property(@as(u32, 0x8B85), .{ .template = false, .readonly = true });
    pub const ACTIVE_ATTRIBUTES = bridge.property(@as(u32, 0x8B89), .{ .template = false, .readonly = true });
    pub const ACTIVE_UNIFORMS = bridge.property(@as(u32, 0x8B86), .{ .template = false, .readonly = true });
    pub const MAX_VERTEX_ATTRIBS = bridge.property(@as(u32, 0x8869), .{ .template = false, .readonly = true });
    pub const MAX_VERTEX_UNIFORM_VECTORS = bridge.property(@as(u32, 0x8DFB), .{ .template = false, .readonly = true });
    pub const MAX_VARYING_VECTORS = bridge.property(@as(u32, 0x8DFC), .{ .template = false, .readonly = true });
    pub const MAX_COMBINED_TEXTURE_IMAGE_UNITS = bridge.property(@as(u32, 0x8B4D), .{ .template = false, .readonly = true });
    pub const MAX_VERTEX_TEXTURE_IMAGE_UNITS = bridge.property(@as(u32, 0x8B4C), .{ .template = false, .readonly = true });
    pub const MAX_TEXTURE_IMAGE_UNITS = bridge.property(@as(u32, 0x8872), .{ .template = false, .readonly = true });
    pub const MAX_FRAGMENT_UNIFORM_VECTORS = bridge.property(@as(u32, 0x8DFD), .{ .template = false, .readonly = true });
    pub const SHADER_TYPE = bridge.property(@as(u32, 0x8B4F), .{ .template = false, .readonly = true });
    pub const SHADING_LANGUAGE_VERSION = bridge.property(@as(u32, 0x8B8C), .{ .template = false, .readonly = true });
    pub const CURRENT_PROGRAM = bridge.property(@as(u32, 0x8B8D), .{ .template = false, .readonly = true });

    // Depth and stencil functions.
    pub const NEVER = bridge.property(@as(u32, 0x200), .{ .template = false, .readonly = true });
    pub const LESS = bridge.property(@as(u32, 0x201), .{ .template = false, .readonly = true });
    pub const EQUAL = bridge.property(@as(u32, 0x202), .{ .template = false, .readonly = true });
    pub const LEQUAL = bridge.property(@as(u32, 0x203), .{ .template = false, .readonly = true });
    pub const GREATER = bridge.property(@as(u32, 0x204), .{ .template = false, .readonly = true });
    pub const NOTEQUAL = bridge.property(@as(u32, 0x205), .{ .template = false, .readonly = true });
    pub const GEQUAL = bridge.property(@as(u32, 0x206), .{ .template = false, .readonly = true });
    pub const ALWAYS = bridge.property(@as(u32, 0x207), .{ .template = false, .readonly = true });

    // Stencil actions.
    pub const KEEP = bridge.property(@as(u32, 0x1E00), .{ .template = false, .readonly = true });
    pub const REPLACE = bridge.property(@as(u32, 0x1E01), .{ .template = false, .readonly = true });
    pub const INCR = bridge.property(@as(u32, 0x1E02), .{ .template = false, .readonly = true });
    pub const DECR = bridge.property(@as(u32, 0x1E03), .{ .template = false, .readonly = true });
    pub const INVERT = bridge.property(@as(u32, 0x150A), .{ .template = false, .readonly = true });
    pub const INCR_WRAP = bridge.property(@as(u32, 0x8507), .{ .template = false, .readonly = true });
    pub const DECR_WRAP = bridge.property(@as(u32, 0x8508), .{ .template = false, .readonly = true });

    // Textures.
    pub const NEAREST = bridge.property(@as(u32, 0x2600), .{ .template = false, .readonly = true });
    pub const LINEAR = bridge.property(@as(u32, 0x2601), .{ .template = false, .readonly = true });
    pub const NEAREST_MIPMAP_NEAREST = bridge.property(@as(u32, 0x2700), .{ .template = false, .readonly = true });
    pub const LINEAR_MIPMAP_NEAREST = bridge.property(@as(u32, 0x2701), .{ .template = false, .readonly = true });
    pub const NEAREST_MIPMAP_LINEAR = bridge.property(@as(u32, 0x2702), .{ .template = false, .readonly = true });
    pub const LINEAR_MIPMAP_LINEAR = bridge.property(@as(u32, 0x2703), .{ .template = false, .readonly = true });
    pub const TEXTURE_MAG_FILTER = bridge.property(@as(u32, 0x2800), .{ .template = false, .readonly = true });
    pub const TEXTURE_MIN_FILTER = bridge.property(@as(u32, 0x2801), .{ .template = false, .readonly = true });
    pub const TEXTURE_WRAP_S = bridge.property(@as(u32, 0x2802), .{ .template = false, .readonly = true });
    pub const TEXTURE_WRAP_T = bridge.property(@as(u32, 0x2803), .{ .template = false, .readonly = true });
    pub const TEXTURE_2D = bridge.property(@as(u32, 0xDE1), .{ .template = false, .readonly = true });
    pub const TEXTURE = bridge.property(@as(u32, 0x1702), .{ .template = false, .readonly = true });
    pub const TEXTURE_CUBE_MAP = bridge.property(@as(u32, 0x8513), .{ .template = false, .readonly = true });
    pub const TEXTURE_BINDING_CUBE_MAP = bridge.property(@as(u32, 0x8514), .{ .template = false, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_X = bridge.property(@as(u32, 0x8515), .{ .template = false, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_X = bridge.property(@as(u32, 0x8516), .{ .template = false, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_Y = bridge.property(@as(u32, 0x8517), .{ .template = false, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_Y = bridge.property(@as(u32, 0x8518), .{ .template = false, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_Z = bridge.property(@as(u32, 0x8519), .{ .template = false, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_Z = bridge.property(@as(u32, 0x851A), .{ .template = false, .readonly = true });
    pub const MAX_CUBE_MAP_TEXTURE_SIZE = bridge.property(@as(u32, 0x851C), .{ .template = false, .readonly = true });
    pub const TEXTURE_BINDING_2D = bridge.property(@as(u32, 0x8069), .{ .template = false, .readonly = true });
    pub const REPEAT = bridge.property(@as(u32, 0x2901), .{ .template = false, .readonly = true });
    pub const CLAMP_TO_EDGE = bridge.property(@as(u32, 0x812F), .{ .template = false, .readonly = true });
    pub const MIRRORED_REPEAT = bridge.property(@as(u32, 0x8370), .{ .template = false, .readonly = true });
    pub const MAX_TEXTURE_SIZE = bridge.property(@as(u32, 0xD33), .{ .template = false, .readonly = true });
    pub const ACTIVE_TEXTURE = bridge.property(@as(u32, 0x84E0), .{ .template = false, .readonly = true });

    // Uniform types.
    pub const FLOAT_VEC2 = bridge.property(@as(u32, 0x8B50), .{ .template = false, .readonly = true });
    pub const FLOAT_VEC3 = bridge.property(@as(u32, 0x8B51), .{ .template = false, .readonly = true });
    pub const FLOAT_VEC4 = bridge.property(@as(u32, 0x8B52), .{ .template = false, .readonly = true });
    pub const INT_VEC2 = bridge.property(@as(u32, 0x8B53), .{ .template = false, .readonly = true });
    pub const INT_VEC3 = bridge.property(@as(u32, 0x8B54), .{ .template = false, .readonly = true });
    pub const INT_VEC4 = bridge.property(@as(u32, 0x8B55), .{ .template = false, .readonly = true });
    pub const BOOL = bridge.property(@as(u32, 0x8B56), .{ .template = false, .readonly = true });
    pub const BOOL_VEC2 = bridge.property(@as(u32, 0x8B57), .{ .template = false, .readonly = true });
    pub const BOOL_VEC3 = bridge.property(@as(u32, 0x8B58), .{ .template = false, .readonly = true });
    pub const BOOL_VEC4 = bridge.property(@as(u32, 0x8B59), .{ .template = false, .readonly = true });
    pub const FLOAT_MAT2 = bridge.property(@as(u32, 0x8B5A), .{ .template = false, .readonly = true });
    pub const FLOAT_MAT3 = bridge.property(@as(u32, 0x8B5B), .{ .template = false, .readonly = true });
    pub const FLOAT_MAT4 = bridge.property(@as(u32, 0x8B5C), .{ .template = false, .readonly = true });
    pub const SAMPLER_2D = bridge.property(@as(u32, 0x8B5E), .{ .template = false, .readonly = true });
    pub const SAMPLER_CUBE = bridge.property(@as(u32, 0x8B60), .{ .template = false, .readonly = true });

    // Vertex attributes.
    pub const VERTEX_ATTRIB_ARRAY_ENABLED = bridge.property(@as(u32, 0x8622), .{ .template = false, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_SIZE = bridge.property(@as(u32, 0x8623), .{ .template = false, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_STRIDE = bridge.property(@as(u32, 0x8624), .{ .template = false, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_TYPE = bridge.property(@as(u32, 0x8625), .{ .template = false, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_NORMALIZED = bridge.property(@as(u32, 0x886A), .{ .template = false, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_POINTER = bridge.property(@as(u32, 0x8645), .{ .template = false, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_BUFFER_BINDING = bridge.property(@as(u32, 0x889F), .{ .template = false, .readonly = true });

    // Framebuffers and renderbuffers.
    pub const FRAMEBUFFER = bridge.property(@as(u32, 0x8D40), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER = bridge.property(@as(u32, 0x8D41), .{ .template = false, .readonly = true });
    pub const RGBA4 = bridge.property(@as(u32, 0x8056), .{ .template = false, .readonly = true });
    pub const RGB5_A1 = bridge.property(@as(u32, 0x8057), .{ .template = false, .readonly = true });
    pub const RGB565 = bridge.property(@as(u32, 0x8D62), .{ .template = false, .readonly = true });
    pub const DEPTH_COMPONENT16 = bridge.property(@as(u32, 0x81A5), .{ .template = false, .readonly = true });
    pub const STENCIL_INDEX8 = bridge.property(@as(u32, 0x8D48), .{ .template = false, .readonly = true });
    pub const DEPTH_STENCIL = bridge.property(@as(u32, 0x84F9), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_WIDTH = bridge.property(@as(u32, 0x8D42), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_HEIGHT = bridge.property(@as(u32, 0x8D43), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_INTERNAL_FORMAT = bridge.property(@as(u32, 0x8D44), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_RED_SIZE = bridge.property(@as(u32, 0x8D50), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_GREEN_SIZE = bridge.property(@as(u32, 0x8D51), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_BLUE_SIZE = bridge.property(@as(u32, 0x8D52), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_ALPHA_SIZE = bridge.property(@as(u32, 0x8D53), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_DEPTH_SIZE = bridge.property(@as(u32, 0x8D54), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_STENCIL_SIZE = bridge.property(@as(u32, 0x8D55), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE = bridge.property(@as(u32, 0x8CD0), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_OBJECT_NAME = bridge.property(@as(u32, 0x8CD1), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL = bridge.property(@as(u32, 0x8CD2), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE = bridge.property(@as(u32, 0x8CD3), .{ .template = false, .readonly = true });
    pub const COLOR_ATTACHMENT0 = bridge.property(@as(u32, 0x8CE0), .{ .template = false, .readonly = true });
    pub const DEPTH_ATTACHMENT = bridge.property(@as(u32, 0x8D00), .{ .template = false, .readonly = true });
    pub const STENCIL_ATTACHMENT = bridge.property(@as(u32, 0x8D20), .{ .template = false, .readonly = true });
    pub const DEPTH_STENCIL_ATTACHMENT = bridge.property(@as(u32, 0x821A), .{ .template = false, .readonly = true });
    pub const NONE = bridge.property(@as(u32, 0x0), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_COMPLETE = bridge.property(@as(u32, 0x8CD5), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_ATTACHMENT = bridge.property(@as(u32, 0x8CD6), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT = bridge.property(@as(u32, 0x8CD7), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_DIMENSIONS = bridge.property(@as(u32, 0x8CD9), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_UNSUPPORTED = bridge.property(@as(u32, 0x8CDD), .{ .template = false, .readonly = true });
    pub const FRAMEBUFFER_BINDING = bridge.property(@as(u32, 0x8CA6), .{ .template = false, .readonly = true });
    pub const RENDERBUFFER_BINDING = bridge.property(@as(u32, 0x8CA7), .{ .template = false, .readonly = true });
    pub const MAX_RENDERBUFFER_SIZE = bridge.property(@as(u32, 0x84E8), .{ .template = false, .readonly = true });

    // Pixel storage.
    pub const UNPACK_ALIGNMENT = bridge.property(@as(u32, 0xCF5), .{ .template = false, .readonly = true });
    pub const PACK_ALIGNMENT = bridge.property(@as(u32, 0xD05), .{ .template = false, .readonly = true });
    pub const UNPACK_FLIP_Y_WEBGL = bridge.property(@as(u32, 0x9240), .{ .template = false, .readonly = true });
    pub const UNPACK_PREMULTIPLY_ALPHA_WEBGL = bridge.property(@as(u32, 0x9241), .{ .template = false, .readonly = true });
    pub const UNPACK_COLORSPACE_CONVERSION_WEBGL = bridge.property(@as(u32, 0x9243), .{ .template = false, .readonly = true });
    pub const BROWSER_DEFAULT_WEBGL = bridge.property(@as(u32, 0x9244), .{ .template = false, .readonly = true });

    // Getting GL parameter information.
    pub const LINE_WIDTH = bridge.property(@as(u32, 0xB21), .{ .template = false, .readonly = true });
    pub const ALIASED_POINT_SIZE_RANGE = bridge.property(@as(u32, 0x846D), .{ .template = false, .readonly = true });
    pub const ALIASED_LINE_WIDTH_RANGE = bridge.property(@as(u32, 0x846E), .{ .template = false, .readonly = true });
    pub const CULL_FACE_MODE = bridge.property(@as(u32, 0xB45), .{ .template = false, .readonly = true });
    pub const FRONT_FACE = bridge.property(@as(u32, 0xB46), .{ .template = false, .readonly = true });
    pub const DEPTH_RANGE = bridge.property(@as(u32, 0xB70), .{ .template = false, .readonly = true });
    pub const DEPTH_WRITEMASK = bridge.property(@as(u32, 0xB72), .{ .template = false, .readonly = true });
    pub const DEPTH_CLEAR_VALUE = bridge.property(@as(u32, 0xB73), .{ .template = false, .readonly = true });
    pub const DEPTH_FUNC = bridge.property(@as(u32, 0xB74), .{ .template = false, .readonly = true });
    pub const STENCIL_CLEAR_VALUE = bridge.property(@as(u32, 0xB91), .{ .template = false, .readonly = true });
    pub const STENCIL_FUNC = bridge.property(@as(u32, 0xB92), .{ .template = false, .readonly = true });
    pub const STENCIL_FAIL = bridge.property(@as(u32, 0xB94), .{ .template = false, .readonly = true });
    pub const STENCIL_PASS_DEPTH_FAIL = bridge.property(@as(u32, 0xB95), .{ .template = false, .readonly = true });
    pub const STENCIL_PASS_DEPTH_PASS = bridge.property(@as(u32, 0xB96), .{ .template = false, .readonly = true });
    pub const STENCIL_REF = bridge.property(@as(u32, 0xB97), .{ .template = false, .readonly = true });
    pub const STENCIL_VALUE_MASK = bridge.property(@as(u32, 0xB93), .{ .template = false, .readonly = true });
    pub const STENCIL_WRITEMASK = bridge.property(@as(u32, 0xB98), .{ .template = false, .readonly = true });
    pub const STENCIL_BACK_FUNC = bridge.property(@as(u32, 0x8800), .{ .template = false, .readonly = true });
    pub const STENCIL_BACK_FAIL = bridge.property(@as(u32, 0x8801), .{ .template = false, .readonly = true });
    pub const STENCIL_BACK_PASS_DEPTH_FAIL = bridge.property(@as(u32, 0x8802), .{ .template = false, .readonly = true });
    pub const STENCIL_BACK_PASS_DEPTH_PASS = bridge.property(@as(u32, 0x8803), .{ .template = false, .readonly = true });
    pub const STENCIL_BACK_REF = bridge.property(@as(u32, 0x8CA3), .{ .template = false, .readonly = true });
    pub const STENCIL_BACK_VALUE_MASK = bridge.property(@as(u32, 0x8CA4), .{ .template = false, .readonly = true });
    pub const STENCIL_BACK_WRITEMASK = bridge.property(@as(u32, 0x8CA5), .{ .template = false, .readonly = true });
    pub const VIEWPORT = bridge.property(@as(u32, 0xBA2), .{ .template = false, .readonly = true });
    pub const SCISSOR_BOX = bridge.property(@as(u32, 0xC10), .{ .template = false, .readonly = true });
    pub const COLOR_CLEAR_VALUE = bridge.property(@as(u32, 0xC22), .{ .template = false, .readonly = true });
    pub const COLOR_WRITEMASK = bridge.property(@as(u32, 0xC23), .{ .template = false, .readonly = true });
    pub const UNPACK_ROW_LENGTH = bridge.property(@as(u32, 0xCF2), .{ .template = false, .readonly = true });
    pub const MAX_VIEWPORT_DIMS = bridge.property(@as(u32, 0xD3A), .{ .template = false, .readonly = true });
    pub const SUBPIXEL_BITS = bridge.property(@as(u32, 0xD50), .{ .template = false, .readonly = true });
    pub const RED_BITS = bridge.property(@as(u32, 0xD52), .{ .template = false, .readonly = true });
    pub const GREEN_BITS = bridge.property(@as(u32, 0xD53), .{ .template = false, .readonly = true });
    pub const BLUE_BITS = bridge.property(@as(u32, 0xD54), .{ .template = false, .readonly = true });
    pub const ALPHA_BITS = bridge.property(@as(u32, 0xD55), .{ .template = false, .readonly = true });
    pub const DEPTH_BITS = bridge.property(@as(u32, 0xD56), .{ .template = false, .readonly = true });
    pub const STENCIL_BITS = bridge.property(@as(u32, 0xD57), .{ .template = false, .readonly = true });
    pub const POLYGON_OFFSET_UNITS = bridge.property(@as(u32, 0x2A00), .{ .template = false, .readonly = true });
    pub const POLYGON_OFFSET_FACTOR = bridge.property(@as(u32, 0x8038), .{ .template = false, .readonly = true });
    pub const SAMPLE_BUFFERS = bridge.property(@as(u32, 0x80A8), .{ .template = false, .readonly = true });
    pub const SAMPLES = bridge.property(@as(u32, 0x80A9), .{ .template = false, .readonly = true });
    pub const SAMPLE_COVERAGE_VALUE = bridge.property(@as(u32, 0x80AA), .{ .template = false, .readonly = true });
    pub const SAMPLE_COVERAGE_INVERT = bridge.property(@as(u32, 0x80AB), .{ .template = false, .readonly = true });
    pub const COMPRESSED_TEXTURE_FORMATS = bridge.property(@as(u32, 0x86A3), .{ .template = false, .readonly = true });
    pub const VENDOR = bridge.property(@as(u32, 0x1F00), .{ .template = false, .readonly = true });
    pub const RENDERER = bridge.property(@as(u32, 0x1F01), .{ .template = false, .readonly = true });
    pub const VERSION = bridge.property(@as(u32, 0x1F02), .{ .template = false, .readonly = true });
    pub const IMPLEMENTATION_COLOR_READ_TYPE = bridge.property(@as(u32, 0x8B9A), .{ .template = false, .readonly = true });
    pub const IMPLEMENTATION_COLOR_READ_FORMAT = bridge.property(@as(u32, 0x8B9B), .{ .template = false, .readonly = true });

    // Texture units.
    pub const TEXTURE0 = bridge.property(@as(u32, 0x84C0), .{ .template = false, .readonly = true });
    pub const TEXTURE1 = bridge.property(@as(u32, 0x84C1), .{ .template = false, .readonly = true });
    pub const TEXTURE2 = bridge.property(@as(u32, 0x84C2), .{ .template = false, .readonly = true });
    pub const TEXTURE3 = bridge.property(@as(u32, 0x84C3), .{ .template = false, .readonly = true });
    pub const TEXTURE4 = bridge.property(@as(u32, 0x84C4), .{ .template = false, .readonly = true });
    pub const TEXTURE5 = bridge.property(@as(u32, 0x84C5), .{ .template = false, .readonly = true });
    pub const TEXTURE6 = bridge.property(@as(u32, 0x84C6), .{ .template = false, .readonly = true });
    pub const TEXTURE7 = bridge.property(@as(u32, 0x84C7), .{ .template = false, .readonly = true });
    pub const TEXTURE8 = bridge.property(@as(u32, 0x84C8), .{ .template = false, .readonly = true });
    pub const TEXTURE9 = bridge.property(@as(u32, 0x84C9), .{ .template = false, .readonly = true });
    pub const TEXTURE10 = bridge.property(@as(u32, 0x84CA), .{ .template = false, .readonly = true });
    pub const TEXTURE11 = bridge.property(@as(u32, 0x84CB), .{ .template = false, .readonly = true });
    pub const TEXTURE12 = bridge.property(@as(u32, 0x84CC), .{ .template = false, .readonly = true });
    pub const TEXTURE13 = bridge.property(@as(u32, 0x84CD), .{ .template = false, .readonly = true });
    pub const TEXTURE14 = bridge.property(@as(u32, 0x84CE), .{ .template = false, .readonly = true });
    pub const TEXTURE15 = bridge.property(@as(u32, 0x84CF), .{ .template = false, .readonly = true });
    pub const TEXTURE16 = bridge.property(@as(u32, 0x84D0), .{ .template = false, .readonly = true });
    pub const TEXTURE17 = bridge.property(@as(u32, 0x84D1), .{ .template = false, .readonly = true });
    pub const TEXTURE18 = bridge.property(@as(u32, 0x84D2), .{ .template = false, .readonly = true });
    pub const TEXTURE19 = bridge.property(@as(u32, 0x84D3), .{ .template = false, .readonly = true });
    pub const TEXTURE20 = bridge.property(@as(u32, 0x84D4), .{ .template = false, .readonly = true });
    pub const TEXTURE21 = bridge.property(@as(u32, 0x84D5), .{ .template = false, .readonly = true });
    pub const TEXTURE22 = bridge.property(@as(u32, 0x84D6), .{ .template = false, .readonly = true });
    pub const TEXTURE23 = bridge.property(@as(u32, 0x84D7), .{ .template = false, .readonly = true });
    pub const TEXTURE24 = bridge.property(@as(u32, 0x84D8), .{ .template = false, .readonly = true });
    pub const TEXTURE25 = bridge.property(@as(u32, 0x84D9), .{ .template = false, .readonly = true });
    pub const TEXTURE26 = bridge.property(@as(u32, 0x84DA), .{ .template = false, .readonly = true });
    pub const TEXTURE27 = bridge.property(@as(u32, 0x84DB), .{ .template = false, .readonly = true });
    pub const TEXTURE28 = bridge.property(@as(u32, 0x84DC), .{ .template = false, .readonly = true });
    pub const TEXTURE29 = bridge.property(@as(u32, 0x84DD), .{ .template = false, .readonly = true });
    pub const TEXTURE30 = bridge.property(@as(u32, 0x84DE), .{ .template = false, .readonly = true });
    pub const TEXTURE31 = bridge.property(@as(u32, 0x84DF), .{ .template = false, .readonly = true });

    pub const canvas = bridge.accessor(WebGLRenderingContext.getCanvas, null, .{});
    pub const drawingBufferWidth = bridge.accessor(WebGLRenderingContext.getDrawingBufferWidth, null, .{});
    pub const drawingBufferHeight = bridge.accessor(WebGLRenderingContext.getDrawingBufferHeight, null, .{});

    pub const getParameter = bridge.function(WebGLRenderingContext.getParameter, .{});
    pub const getExtension = bridge.function(WebGLRenderingContext.getExtension, .{});
    pub const getSupportedExtensions = bridge.function(WebGLRenderingContext.getSupportedExtensions, .{});
    pub const getContextAttributes = bridge.function(WebGLRenderingContext.getContextAttributes, .{});
    pub const getShaderPrecisionFormat = bridge.function(WebGLRenderingContext.getShaderPrecisionFormat, .{});
    pub const getError = bridge.function(WebGLRenderingContext.getError, .{});
    pub const isContextLost = bridge.function(WebGLRenderingContext.isContextLost, .{});
    pub const checkFramebufferStatus = bridge.function(WebGLRenderingContext.checkFramebufferStatus, .{});

    // Object lifecycle.
    pub const createBuffer = bridge.function(WebGLRenderingContext.createBuffer, .{});
    pub const createFramebuffer = bridge.function(WebGLRenderingContext.createFramebuffer, .{});
    pub const createRenderbuffer = bridge.function(WebGLRenderingContext.createRenderbuffer, .{});
    pub const createProgram = bridge.function(WebGLRenderingContext.createProgram, .{});
    pub const createShader = bridge.function(WebGLRenderingContext.createShader, .{});
    pub const createTexture = bridge.function(WebGLRenderingContext.createTexture, .{});
    pub const deleteBuffer = noop.@"1";
    pub const deleteFramebuffer = noop.@"1";
    pub const deleteProgram = noop.@"1";
    pub const deleteRenderbuffer = noop.@"1";
    pub const deleteShader = noop.@"1";
    pub const deleteTexture = noop.@"1";

    // Shaders and programs.
    pub const shaderSource = bridge.function(WebGLRenderingContext.shaderSource, .{});
    pub const getShaderSource = bridge.function(WebGLRenderingContext.getShaderSource, .{});
    pub const getShaderParameter = bridge.function(WebGLRenderingContext.getShaderParameter, .{});
    pub const getProgramParameter = bridge.function(WebGLRenderingContext.getProgramParameter, .{});
    pub const getShaderInfoLog = bridge.function(WebGLRenderingContext.getShaderInfoLog, .{});
    pub const getProgramInfoLog = bridge.function(WebGLRenderingContext.getProgramInfoLog, .{});
    pub const getAttribLocation = bridge.function(WebGLRenderingContext.getAttribLocation, .{});
    pub const getUniformLocation = bridge.function(WebGLRenderingContext.getUniformLocation, .{});
    pub const getActiveAttrib = bridge.function(WebGLRenderingContext.getActiveAttrib, .{});
    pub const getActiveUniform = bridge.function(WebGLRenderingContext.getActiveUniform, .{});
    pub const getAttachedShaders = bridge.function(WebGLRenderingContext.getAttachedShaders, .{});
    pub const compileShader = noop.@"1";
    pub const linkProgram = noop.@"1";
    pub const useProgram = noop.@"1";
    pub const validateProgram = noop.@"1";
    pub const attachShader = noop.@"2";
    pub const detachShader = noop.@"2";
    pub const bindAttribLocation = noop.@"3";

    // "is" queries. Nothing is ever really created, so nothing is ever ours.
    pub const isBuffer = bridge.function(WebGLRenderingContext.isFalse, .{});
    pub const isFramebuffer = bridge.function(WebGLRenderingContext.isFalse, .{});
    pub const isProgram = bridge.function(WebGLRenderingContext.isFalse, .{});
    pub const isRenderbuffer = bridge.function(WebGLRenderingContext.isFalse, .{});
    pub const isShader = bridge.function(WebGLRenderingContext.isFalse, .{});
    pub const isTexture = bridge.function(WebGLRenderingContext.isFalse, .{});
    pub const isEnabled = bridge.function(WebGLRenderingContext.isEnabled, .{});

    // Introspection of state that was never set.
    pub const getBufferParameter = bridge.function(WebGLRenderingContext.getNull, .{});
    pub const getFramebufferAttachmentParameter = bridge.function(WebGLRenderingContext.getNull, .{});
    pub const getRenderbufferParameter = bridge.function(WebGLRenderingContext.getNull, .{});
    pub const getTexParameter = bridge.function(WebGLRenderingContext.getNull, .{});
    pub const getUniform = bridge.function(WebGLRenderingContext.getNull, .{});
    pub const getVertexAttrib = bridge.function(WebGLRenderingContext.getNull, .{});

    // Binding and buffer data.
    pub const bindBuffer = noop.@"2";
    pub const bindFramebuffer = noop.@"2";
    pub const bindRenderbuffer = noop.@"2";
    pub const bindTexture = noop.@"2";
    pub const bufferData = noop.@"3";
    pub const bufferSubData = noop.@"3";
    pub const renderbufferStorage = noop.@"4";
    pub const framebufferRenderbuffer = noop.@"4";
    pub const framebufferTexture2D = noop.@"5";

    // Textures.
    pub const activeTexture = noop.@"1";
    pub const generateMipmap = noop.@"1";
    pub const texParameterf = noop.@"3";
    pub const texParameteri = noop.@"3";
    pub const pixelStorei = noop.@"2";
    pub const copyTexImage2D = noop.@"8";
    pub const copyTexSubImage2D = noop.@"8";
    pub const compressedTexImage2D = noop.@"7";
    pub const compressedTexSubImage2D = noop.@"8";
    // texImage2D and texSubImage2D are overloaded: Chrome reports the arity
    // of the shortest form.
    pub const texImage2D = noop.@"6";
    pub const texSubImage2D = noop.@"7";

    // Vertex attributes.
    pub const enableVertexAttribArray = noop.@"1";
    pub const disableVertexAttribArray = noop.@"1";
    pub const vertexAttribPointer = noop.@"6";
    pub const getVertexAttribOffset = bridge.function(struct {
        fn wrap(_: *const WebGLRenderingContext, _: u32, _: u32) u32 {
            return 0;
        }
    }.wrap, .{});
    pub const vertexAttrib1f = noop.@"2";
    pub const vertexAttrib2f = noop.@"3";
    pub const vertexAttrib3f = noop.@"4";
    pub const vertexAttrib4f = noop.@"5";
    pub const vertexAttrib1fv = noop.@"2";
    pub const vertexAttrib2fv = noop.@"2";
    pub const vertexAttrib3fv = noop.@"2";
    pub const vertexAttrib4fv = noop.@"2";

    // Uniforms.
    pub const uniform1f = noop.@"2";
    pub const uniform1i = noop.@"2";
    pub const uniform2f = noop.@"3";
    pub const uniform2i = noop.@"3";
    pub const uniform3f = noop.@"4";
    pub const uniform3i = noop.@"4";
    pub const uniform4f = noop.@"5";
    pub const uniform4i = noop.@"5";
    pub const uniform1fv = noop.@"2";
    pub const uniform1iv = noop.@"2";
    pub const uniform2fv = noop.@"2";
    pub const uniform2iv = noop.@"2";
    pub const uniform3fv = noop.@"2";
    pub const uniform3iv = noop.@"2";
    pub const uniform4fv = noop.@"2";
    pub const uniform4iv = noop.@"2";
    pub const uniformMatrix2fv = noop.@"3";
    pub const uniformMatrix3fv = noop.@"3";
    pub const uniformMatrix4fv = noop.@"3";

    // Per-fragment operations and pipeline state.
    pub const blendColor = noop.@"4";
    pub const blendEquation = noop.@"1";
    pub const blendEquationSeparate = noop.@"2";
    pub const blendFunc = noop.@"2";
    pub const blendFuncSeparate = noop.@"4";
    pub const colorMask = noop.@"4";
    pub const cullFace = noop.@"1";
    pub const depthFunc = noop.@"1";
    pub const depthMask = noop.@"1";
    pub const depthRange = noop.@"2";
    pub const disable = noop.@"1";
    pub const enable = noop.@"1";
    pub const frontFace = noop.@"1";
    pub const hint = noop.@"2";
    pub const lineWidth = noop.@"1";
    pub const polygonOffset = noop.@"2";
    pub const sampleCoverage = noop.@"2";
    pub const scissor = noop.@"4";
    pub const stencilFunc = noop.@"3";
    pub const stencilFuncSeparate = noop.@"4";
    pub const stencilMask = noop.@"1";
    pub const stencilMaskSeparate = noop.@"2";
    pub const stencilOp = noop.@"3";
    pub const stencilOpSeparate = noop.@"4";
    pub const viewport = noop.@"4";

    // Drawing. These are the ones that would have produced pixels.
    pub const clear = noop.@"1";
    pub const clearColor = noop.@"4";
    pub const clearDepth = noop.@"1";
    pub const clearStencil = noop.@"1";
    pub const drawArrays = noop.@"3";
    pub const drawElements = noop.@"4";
    pub const finish = noop.@"0";
    pub const flush = noop.@"0";
    pub const readPixels = noop.@"7";
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGLRenderingContext" {
    try testing.htmlRunner("canvas/webgl_rendering_context.html", .{});
}
