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

//! A partial WebGL context with a CPU-backed default drawing buffer and an
//! optional ANGLE/Metal backend loaded from the local Chrome installation.
//!
//! `getContext('webgl')` used to return null, because a context that
//! answered `getParameter` and then threw on `createTexture` was worse than
//! no context at all: apps with an error boundary above the WebGL widget
//! caught the throw, reset, re-rendered and looped forever. The fix for that
//! is not to withhold the context — it is to stop throwing. Every entry
//! point in the WebGL 1.0 surface exists here and returns something a
//! consumer can proceed with: object creators hand back live handles,
//! `COMPILE_STATUS` and `LINK_STATUS` report success when no backend exists.
//! A subset of shader/program/buffer/draw calls uses the native backend when
//! available. The `getParameter` limits table is still the selected profile's;
//! it is not yet a complete reflection of the backend's actual capabilities.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Canvas = @import("../element/html/Canvas.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");
const Bitmap = @import("Bitmap.zig");
const NativeANGLE = @import("NativeANGLE.zig");
const Execution = js.Execution;

const fingerprint = lp.fingerprint;
const webgl = fingerprint.webgl;

pub fn registerTypes() []const type {
    return &.{
        WebGLRenderingContext,
        WebGL2RenderingContext,
        WebGLObject,
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
_canvas: ?*Canvas,
_offscreen_canvas: ?*OffscreenCanvas,
_drawing_buffer_width: u32,
_drawing_buffer_height: u32,
_version: enum { webgl1, webgl2 } = .webgl1,
_attributes: ContextAttributes = .{},
_clear_color: [4]f32 = .{ 0, 0, 0, 0 },
_pixels: []u8 = &.{},
_pixel_width: u32 = 0,
_pixel_height: u32 = 0,
_native: ?*NativeANGLE.Context = null,
_native_unavailable: bool = false,
_native_drawn: bool = false,
_has_cleared: bool = false,
_current_program: ?*WebGLProgram = null,
_bound_array_buffer: ?*WebGLBuffer = null,
_bound_element_array_buffer: ?*WebGLBuffer = null,
_bound_framebuffer: ?*WebGLFramebuffer = null,
_bound_renderbuffer: ?*WebGLRenderbuffer = null,
_bound_textures: [32]?*WebGLTexture = [_]?*WebGLTexture{null} ** 32,
_active_texture: u32 = 0x84C0,
_viewport: [4]i32 = .{ 0, 0, 0, 0 },
_viewport_set: bool = false,
_pack_alignment: i32 = 4,
_unpack_alignment: i32 = 4,
_unpack_flip_y: bool = false,
_unpack_premultiply_alpha: bool = false,
_unpack_colorspace_conversion: u32 = GL.BROWSER_DEFAULT_WEBGL,
_webgl_error: u32 = GL.NO_ERROR,

fn native(self: *WebGLRenderingContext, exec: *Execution) !?*NativeANGLE.Context {
    if (self._native) |context| return context;
    if (self._native_unavailable) return null;
    const width = self.getDrawingBufferWidth();
    const height = self.getDrawingBufferHeight();
    if (width == 0 or height == 0) return null;
    const context = NativeANGLE.lp_angle_create(width, height, @intFromBool(self._version == .webgl2)) orelse {
        self._native_unavailable = true;
        return null;
    };
    errdefer NativeANGLE.lp_angle_destroy(context);
    try exec._factory.registerAngleContext(@ptrCast(context));
    self._native = context;
    NativeANGLE.lp_angle_clear_color(context, self._clear_color[0], self._clear_color[1], self._clear_color[2], self._clear_color[3]);
    if (self._has_cleared) NativeANGLE.lp_angle_clear(context, 0x4000);
    return context;
}

fn syncNativePixels(self: *WebGLRenderingContext, exec: *Execution) !void {
    const context = self._native orelse return;
    if (!self._native_drawn) return;
    try self.ensureDrawingBuffer(exec.arena);
    if (self._pixels.len == 0) return;
    const width = self.getDrawingBufferWidth();
    const height = self.getDrawingBufferHeight();
    if (width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int)) return;
    _ = NativeANGLE.lp_angle_read_pixels(context, 0, 0, @intCast(width), @intCast(height), self._pixels.ptr);
    if (!self._attributes.alpha) {
        var offset: usize = 3;
        while (offset < self._pixels.len) : (offset += 4) self._pixels[offset] = 255;
    }
}

pub fn resetDrawingBuffer(self: *WebGLRenderingContext) void {
    self._pixels = &.{};
    self._pixel_width = 0;
    self._pixel_height = 0;
    self._native_drawn = false;
    self._has_cleared = false;
    if (self._native) |context| {
        _ = NativeANGLE.lp_angle_resize(context, self.getDrawingBufferWidth(), self.getDrawingBufferHeight());
    }
}

fn ensureDrawingBuffer(self: *WebGLRenderingContext, arena: std.mem.Allocator) !void {
    const width = self.getDrawingBufferWidth();
    const height = self.getDrawingBufferHeight();
    if (self._pixel_width == width and self._pixel_height == height and (width == 0 or height == 0 or self._pixels.len != 0)) return;
    self._pixel_width = width;
    self._pixel_height = height;
    self._pixels = &.{};
    if (width == 0 or height == 0) return;
    const count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.OutOfMemory;
    const len = std.math.mul(usize, count, 4) catch return error.OutOfMemory;
    self._pixels = try arena.alloc(u8, len);
    @memset(self._pixels, 0);
    if (!self._attributes.alpha) {
        var offset: usize = 3;
        while (offset < len) : (offset += 4) self._pixels[offset] = 255;
    }
}

fn clampColor(value: f64) f32 {
    if (std.math.isNan(value)) return 0;
    return @floatCast(@max(0.0, @min(1.0, value)));
}

fn clearColor(self: *WebGLRenderingContext, red: f64, green: f64, blue: f64, alpha: f64) void {
    self._clear_color = .{ clampColor(red), clampColor(green), clampColor(blue), clampColor(alpha) };
    if (self._native) |context| NativeANGLE.lp_angle_clear_color(context, self._clear_color[0], self._clear_color[1], self._clear_color[2], self._clear_color[3]);
}

fn clear(self: *WebGLRenderingContext, mask: u32, exec: *Execution) !void {
    if (mask & 0x4000 == 0) return;
    if (self._native) |context| NativeANGLE.lp_angle_clear(context, mask);
    // An offscreen framebuffer clear must not overwrite the canvas's default
    // drawing-buffer snapshot.
    if (self._bound_framebuffer != null) return;
    self._has_cleared = true;
    try self.ensureDrawingBuffer(exec.arena);
    const color: [4]u8 = .{
        @intFromFloat(@round(@as(f64, self._clear_color[0]) * 255.0)),
        @intFromFloat(@round(@as(f64, self._clear_color[1]) * 255.0)),
        @intFromFloat(@round(@as(f64, self._clear_color[2]) * 255.0)),
        if (self._attributes.alpha) @intFromFloat(@round(@as(f64, self._clear_color[3]) * 255.0)) else 255,
    };
    var offset: usize = 0;
    while (offset < self._pixels.len) : (offset += 4) {
        @memcpy(self._pixels[offset..][0..4], &color);
    }
}

fn readPixels(self: *WebGLRenderingContext, x: i32, y: i32, width: i32, height: i32, format: u32, pixel_type: u32, pixels: []u8, exec: *Execution) !void {
    if (format != GL.RGBA or pixel_type != GL.UNSIGNED_BYTE or width < 0 or height < 0) return;
    const row_bytes = std.math.mul(usize, @as(usize, @intCast(width)), 4) catch return;
    const needed = std.math.mul(usize, row_bytes, @as(usize, @intCast(height))) catch return;
    if (needed > pixels.len) return;
    if (self._bound_framebuffer != null) {
        if (self._native) |context| {
            _ = NativeANGLE.lp_angle_read_pixels(context, x, y, width, height, pixels.ptr);
        }
        return;
    }
    try self.syncNativePixels(exec);
    try self.ensureDrawingBuffer(exec.arena);
    for (0..@intCast(height)) |row| {
        const source_y = @as(i64, y) + @as(i64, @intCast(row));
        for (0..@intCast(width)) |column| {
            const source_x = @as(i64, x) + @as(i64, @intCast(column));
            const dest = row * row_bytes + column * 4;
            if (source_x < 0 or source_y < 0 or source_x >= self._pixel_width or source_y >= self._pixel_height) {
                @memset(pixels[dest..][0..4], 0);
                continue;
            }
            const source = (@as(usize, @intCast(source_y)) * self._pixel_width + @as(usize, @intCast(source_x))) * 4;
            @memcpy(pixels[dest..][0..4], self._pixels[source..][0..4]);
        }
    }
}

pub fn png(self: *WebGLRenderingContext, output_arena: std.mem.Allocator, exec: *Execution) ![]const u8 {
    try self.syncNativePixels(exec);
    try self.ensureDrawingBuffer(exec.arena);
    const width = self.getDrawingBufferWidth();
    const height = self.getDrawingBufferHeight();
    const rgba = try output_arena.alloc(u8, self._pixels.len);
    const row_bytes = @as(usize, width) * 4;
    for (0..height) |row| {
        const source = (@as(usize, height) - row - 1) * row_bytes;
        const dest = row * row_bytes;
        @memcpy(rgba[dest..][0..row_bytes], self._pixels[source..][0..row_bytes]);
    }
    // Chrome's WebGL canvas compositor serializes the default buffer through
    // a premultiplied surface. readPixels returns the original RGBA bytes,
    // while toDataURL unpremultiplies the RGB channels before PNG encoding.
    if (self._attributes.premultipliedAlpha) {
        for (0..rgba.len / 4) |pixel| {
            const offset = pixel * 4;
            const alpha = rgba[offset + 3];
            for (0..3) |channel| {
                rgba[offset + channel] = Bitmap.unpremultiply(rgba[offset + channel], alpha);
            }
        }
    }
    return Bitmap.encodeRGBA(width, height, rgba, output_arena);
}

fn getCanvas(self: *const WebGLRenderingContext, exec: *Execution) !js.Value {
    const local = exec.js.local.?;
    if (self._canvas) |canvas| return local.zigValueToJs(canvas, .{});
    return local.zigValueToJs(self._offscreen_canvas.?, .{});
}

/// These currently track the canvas exactly. A real GPU context can come
/// back smaller when the canvas exceeds MAX_TEXTURE_SIZE.
fn getDrawingBufferWidth(self: *const WebGLRenderingContext) u32 {
    return if (self._canvas) |canvas| canvas.getWidth() else self._drawing_buffer_width;
}

fn getDrawingBufferHeight(self: *const WebGLRenderingContext) u32 {
    return if (self._canvas) |canvas| canvas.getHeight() else self._drawing_buffer_height;
}

fn getColorSpace(_: *const WebGLRenderingContext) []const u8 {
    return "srgb";
}

fn setColorSpace(_: *WebGLRenderingContext, _: []const u8) void {}

// -- GLenum values we actually answer for ------------------------------------

const GL = struct {
    const NO_ERROR: u32 = 0;
    const INVALID_VALUE: u32 = 0x0501;
    const INVALID_OPERATION: u32 = 0x0502;
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
    const ARRAY_BUFFER_BINDING: u32 = 0x8894;
    const ELEMENT_ARRAY_BUFFER_BINDING: u32 = 0x8895;
    const CURRENT_PROGRAM: u32 = 0x8B8D;
    const TEXTURE_BINDING_2D: u32 = 0x8069;
    const FRAMEBUFFER_BINDING: u32 = 0x8CA6;
    const RENDERBUFFER_BINDING: u32 = 0x8CA7;
    const FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: u32 = 0x8CD0;
    const FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: u32 = 0x8CD1;
    const FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL: u32 = 0x8CD2;
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
    const MAX_3D_TEXTURE_SIZE: u32 = 0x8073;
    const MAX_ARRAY_TEXTURE_LAYERS: u32 = 0x88FF;
    const MAX_COLOR_ATTACHMENTS: u32 = 0x8CDF;
    const MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS: u32 = 0x8A33;
    const MAX_COMBINED_UNIFORM_BLOCKS: u32 = 0x8A2E;
    const MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS: u32 = 0x8A31;
    const MAX_DRAW_BUFFERS: u32 = 0x8824;
    const MAX_ELEMENTS_INDICES: u32 = 0x80E9;
    const MAX_ELEMENTS_VERTICES: u32 = 0x80E8;
    const MAX_ELEMENT_INDEX: u32 = 0x8D6B;
    const MAX_FRAGMENT_INPUT_COMPONENTS: u32 = 0x9125;
    const MAX_FRAGMENT_UNIFORM_BLOCKS: u32 = 0x8A2D;
    const MAX_FRAGMENT_UNIFORM_COMPONENTS: u32 = 0x8B49;
    const MAX_PROGRAM_TEXEL_OFFSET: u32 = 0x8905;
    const MIN_PROGRAM_TEXEL_OFFSET: u32 = 0x8904;
    const MAX_SAMPLES: u32 = 0x8D57;
    const MAX_TEXTURE_LOD_BIAS: u32 = 0x84FD;
    const MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS: u32 = 0x8C8A;
    const MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS: u32 = 0x8C8B;
    const MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS: u32 = 0x8C80;
    const MAX_UNIFORM_BLOCK_SIZE: u32 = 0x8A30;
    const MAX_UNIFORM_BUFFER_BINDINGS: u32 = 0x8A2F;
    const MAX_VARYING_COMPONENTS: u32 = 0x8B4B;
    const MAX_VERTEX_OUTPUT_COMPONENTS: u32 = 0x9122;
    const MAX_VERTEX_UNIFORM_BLOCKS: u32 = 0x8A2B;
    const MAX_VERTEX_UNIFORM_COMPONENTS: u32 = 0x8B4A;
    const UNIFORM_BUFFER_OFFSET_ALIGNMENT: u32 = 0x8A34;
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
    const UNPACK_FLIP_Y_WEBGL: u32 = 0x9240;
    const UNPACK_PREMULTIPLY_ALPHA_WEBGL: u32 = 0x9241;
    const UNPACK_COLORSPACE_CONVERSION_WEBGL: u32 = 0x9243;
    const TEXTURE_2D: u32 = 0x0DE1;
    const RENDERBUFFER: u32 = 0x8D41;
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
    const INFO_LOG_LENGTH: u32 = 0x8B84;
};

/// What `getParameter` can hand back. The bridge serializes a tagged union
/// by its active field, and typed-array variants matter: Chrome returns an
/// Int32Array for MAX_VIEWPORT_DIMS and a Float32Array for the range
/// parameters, and code does `gl.getParameter(...)[0]` on them.
const Parameter = union(enum) {
    boolean: bool,
    number: f64,
    string: []const u8,
    buffer: *WebGLBuffer,
    texture: *WebGLTexture,
    framebuffer: *WebGLFramebuffer,
    renderbuffer: *WebGLRenderbuffer,
    program: *WebGLProgram,
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
        GL.VERSION => .{ .string = if (self._version == .webgl2) "WebGL 2.0 (OpenGL ES 3.0 Chromium)" else webgl.version },
        GL.SHADING_LANGUAGE_VERSION => .{ .string = if (self._version == .webgl2) "WebGL GLSL ES 3.00 (OpenGL ES GLSL ES 3.0 Chromium)" else webgl.shading_language_version },
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
        GL.MAX_3D_TEXTURE_SIZE => int(2048),
        GL.MAX_ARRAY_TEXTURE_LAYERS => int(2048),
        GL.MAX_COLOR_ATTACHMENTS, GL.MAX_DRAW_BUFFERS => int(8),
        GL.MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS, GL.MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS => int(69632),
        GL.MAX_COMBINED_UNIFORM_BLOCKS, GL.MAX_UNIFORM_BUFFER_BINDINGS => int(32),
        GL.MAX_ELEMENTS_INDICES, GL.MAX_ELEMENTS_VERTICES => int(2_147_483_647),
        GL.MAX_ELEMENT_INDEX => int(4_294_967_294),
        GL.MAX_FRAGMENT_INPUT_COMPONENTS, GL.MAX_VARYING_COMPONENTS, GL.MAX_VERTEX_OUTPUT_COMPONENTS => int(120),
        GL.MAX_FRAGMENT_UNIFORM_BLOCKS, GL.MAX_VERTEX_UNIFORM_BLOCKS => int(16),
        GL.MAX_FRAGMENT_UNIFORM_COMPONENTS, GL.MAX_VERTEX_UNIFORM_COMPONENTS => int(4096),
        GL.MAX_PROGRAM_TEXEL_OFFSET => int(7),
        GL.MIN_PROGRAM_TEXEL_OFFSET => int(-8),
        GL.MAX_SAMPLES => int(4),
        GL.MAX_TEXTURE_LOD_BIAS => int(15),
        GL.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS => int(128),
        GL.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS, GL.MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS => int(4),
        GL.MAX_UNIFORM_BLOCK_SIZE => int(16384),
        GL.UNIFORM_BUFFER_OFFSET_ALIGNMENT => int(256),
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
        GL.ACTIVE_TEXTURE => int(self._active_texture),
        GL.ARRAY_BUFFER_BINDING => if (self._bound_array_buffer) |object| .{ .buffer = object } else null,
        GL.ELEMENT_ARRAY_BUFFER_BINDING => if (self._bound_element_array_buffer) |object| .{ .buffer = object } else null,
        GL.TEXTURE_BINDING_2D => if (self._bound_textures[self._active_texture - 0x84C0]) |object| .{ .texture = object } else null,
        GL.FRAMEBUFFER_BINDING => if (self._bound_framebuffer) |object| .{ .framebuffer = object } else null,
        GL.RENDERBUFFER_BINDING => if (self._bound_renderbuffer) |object| .{ .renderbuffer = object } else null,
        GL.CURRENT_PROGRAM => if (self._current_program) |object| .{ .program = object } else null,
        GL.BLEND, GL.CULL_FACE, GL.DEPTH_TEST, GL.SCISSOR_TEST, GL.STENCIL_TEST => .{ .boolean = false },
        GL.DITHER, GL.DEPTH_WRITEMASK => .{ .boolean = true },
        GL.BLEND_COLOR => .{ .float32_array = .{ .values = &.{ 0, 0, 0, 0 } } },
        GL.COLOR_CLEAR_VALUE => .{ .float32_array = .{ .values = &self._clear_color } },
        GL.COLOR_WRITEMASK => .{ .bool_array = &.{ true, true, true, true } },
        GL.CULL_FACE_MODE => int(GL.BACK),
        GL.FRONT_FACE => int(GL.CCW),
        GL.DEPTH_FUNC => int(GL.LESS),
        GL.DEPTH_CLEAR_VALUE => .{ .number = 1 },
        GL.DEPTH_RANGE => .{ .float32_array = .{ .values = &.{ 0, 1 } } },
        GL.LINE_WIDTH => .{ .number = 1 },
        GL.PACK_ALIGNMENT => int(self._pack_alignment),
        GL.UNPACK_ALIGNMENT => int(self._unpack_alignment),
        GL.UNPACK_FLIP_Y_WEBGL => .{ .boolean = self._unpack_flip_y },
        GL.UNPACK_PREMULTIPLY_ALPHA_WEBGL => .{ .boolean = self._unpack_premultiply_alpha },
        GL.UNPACK_COLORSPACE_CONVERSION_WEBGL => int(self._unpack_colorspace_conversion),
        GL.VIEWPORT => .{ .int32_array = .{ .values = if (self._viewport_set) &self._viewport else &.{ 0, 0, @intCast(self.getDrawingBufferWidth()), @intCast(self.getDrawingBufferHeight()) } } },
        GL.SCISSOR_BOX => .{ .int32_array = .{ .values = &.{ 0, 0, @intCast(self.getDrawingBufferWidth()), @intCast(self.getDrawingBufferHeight()) } } },

        else => null,
    };
}

fn getShaderParameter(self: *WebGLRenderingContext, shader: *WebGLShader, pname: u32) ?Parameter {
    if (shader._deleted and !self.isShader(shader)) {
        self.setError(GL.INVALID_VALUE);
        return null;
    }
    return switch (pname) {
        GL.COMPILE_STATUS => .{ .boolean = if (self._native) |context| NativeANGLE.lp_angle_shader_parameter(context, shader._native_id, pname) != 0 else true },
        GL.DELETE_STATUS => .{ .boolean = shader._deleted },
        GL.SHADER_TYPE => int(shader._type),
        else => null,
    };
}

fn getProgramParameter(self: *const WebGLRenderingContext, program: *WebGLProgram, pname: u32) ?Parameter {
    return switch (pname) {
        GL.LINK_STATUS => .{ .boolean = if (self._native) |context| NativeANGLE.lp_angle_program_parameter(context, program._native_id, pname) != 0 else true },
        GL.VALIDATE_STATUS => .{ .boolean = if (self._native) |context| NativeANGLE.lp_angle_program_parameter(context, program._native_id, pname) != 0 else false },
        GL.DELETE_STATUS => .{ .boolean = program._deleted },
        GL.ATTACHED_SHADERS, GL.ACTIVE_ATTRIBUTES, GL.ACTIVE_UNIFORMS => int(if (self._native) |context| @intCast(NativeANGLE.lp_angle_program_parameter(context, program._native_id, pname)) else switch (pname) {
            GL.ATTACHED_SHADERS => 2,
            else => 0,
        }),
        else => null,
    };
}

fn getShaderInfoLog(self: *const WebGLRenderingContext, shader: *WebGLShader, exec: *Execution) ![]const u8 {
    const context = self._native orelse return "";
    const capacity = NativeANGLE.lp_angle_shader_parameter(context, shader._native_id, GL.INFO_LOG_LENGTH);
    if (capacity <= 1) return "";
    const output = try exec.arena.alloc(u8, @intCast(capacity));
    const length = NativeANGLE.lp_angle_shader_info_log(context, shader._native_id, output.ptr, capacity);
    return output[0..@intCast(@max(0, @min(capacity, length + 1)))];
}

fn getProgramInfoLog(self: *const WebGLRenderingContext, program: *WebGLProgram, exec: *Execution) ![]const u8 {
    const context = self._native orelse return "";
    const capacity = NativeANGLE.lp_angle_program_parameter(context, program._native_id, GL.INFO_LOG_LENGTH);
    if (capacity <= 1) return "";
    const output = try exec.arena.alloc(u8, @intCast(capacity));
    const length = NativeANGLE.lp_angle_program_info_log(context, program._native_id, output.ptr, capacity);
    return output[0..@intCast(@max(0, @min(capacity, length + 1)))];
}

fn getShaderSource(_: *const WebGLRenderingContext, shader: *WebGLShader) []const u8 {
    return shader._source;
}

fn shaderSource(self: *const WebGLRenderingContext, shader: *WebGLShader, source: []const u8, exec: *Execution) !void {
    // Kept so getShaderSource round-trips, which some engines rely on when
    // they cache compiled programs.
    shader._source = try exec.arena.dupe(u8, source);
    if (self._native) |context| {
        if (shader._native_id != 0 and source.len <= std.math.maxInt(c_int)) NativeANGLE.lp_angle_shader_source(context, shader._native_id, source.ptr, @intCast(source.len));
    }
}

fn setError(self: *WebGLRenderingContext, value: u32) void {
    if (self._webgl_error == GL.NO_ERROR) self._webgl_error = value;
}

fn getError(self: *WebGLRenderingContext) u32 {
    if (self._webgl_error != GL.NO_ERROR) {
        const result = self._webgl_error;
        self._webgl_error = GL.NO_ERROR;
        return result;
    }
    return if (self._native) |context| NativeANGLE.lp_angle_get_error(context) else GL.NO_ERROR;
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

/// Return the attributes used to create this context.
fn getContextAttributes(self: *const WebGLRenderingContext) ContextAttributes {
    return self._attributes;
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

fn checkFramebufferStatus(self: *const WebGLRenderingContext, target: u32) u32 {
    return if (self._native) |context| NativeANGLE.lp_angle_check_framebuffer_status(context, target) else GL.FRAMEBUFFER_COMPLETE;
}

// -- Object creation ---------------------------------------------------------
//
// Each creator hands back a live handle. Returning null here is what a real
// context does only when it is lost, and a renderer that gets null throws.

fn createBuffer(self: *WebGLRenderingContext, exec: *Execution) !*WebGLBuffer {
    const context = try self.native(exec);
    return exec._factory.chained(.{ WebGLObject{}, WebGLBuffer{ ._proto = undefined, ._owner = context, ._native_id = if (context) |c| NativeANGLE.lp_angle_create_buffer(c) else 0 } });
}

fn createFramebuffer(self: *WebGLRenderingContext, exec: *Execution) !*WebGLFramebuffer {
    const context = try self.native(exec);
    return exec._factory.chained(.{ WebGLObject{}, WebGLFramebuffer{ ._proto = undefined, ._owner = context, ._native_id = if (context) |c| NativeANGLE.lp_angle_create_framebuffer(c) else 0 } });
}

fn createRenderbuffer(self: *WebGLRenderingContext, exec: *Execution) !*WebGLRenderbuffer {
    const context = try self.native(exec);
    return exec._factory.chained(.{ WebGLObject{}, WebGLRenderbuffer{ ._proto = undefined, ._owner = context, ._native_id = if (context) |c| NativeANGLE.lp_angle_create_renderbuffer(c) else 0 } });
}

fn createProgram(self: *WebGLRenderingContext, exec: *Execution) !*WebGLProgram {
    const context = try self.native(exec);
    return exec._factory.chained(.{ WebGLObject{}, WebGLProgram{ ._proto = undefined, ._owner = context, ._native_id = if (context) |c| NativeANGLE.lp_angle_create_program(c) else 0 } });
}

fn createShader(self: *WebGLRenderingContext, shader_type: u32, exec: *Execution) !*WebGLShader {
    const context = try self.native(exec);
    return exec._factory.chained(.{ WebGLObject{}, WebGLShader{ ._proto = undefined, ._type = shader_type, ._owner = context, ._native_id = if (context) |c| NativeANGLE.lp_angle_create_shader(c, shader_type) else 0 } });
}

fn createTexture(self: *WebGLRenderingContext, exec: *Execution) !*WebGLTexture {
    const context = try self.native(exec);
    return exec._factory.chained(.{ WebGLObject{}, WebGLTexture{ ._proto = undefined, ._owner = context, ._native_id = if (context) |c| NativeANGLE.lp_angle_create_texture(c) else 0 } });
}

fn getUniformLocation(self: *const WebGLRenderingContext, program: *WebGLProgram, name: []const u8, exec: *Execution) !?*WebGLUniformLocation {
    var location: c_int = -1;
    if (self._native) |context| {
        if (program._native_id == 0) return null;
        const zname = try exec.local_arena.dupeZ(u8, name);
        location = NativeANGLE.lp_angle_uniform_location(context, program._native_id, zname);
        if (location < 0) return null;
    }
    return exec._factory.create(WebGLUniformLocation{ ._native_id = location, ._program = program });
}

/// -1 means "no such attribute", which is the honest answer when no shader
/// was ever compiled, and is a value every consumer already handles (it is
/// what an unused attribute returns on a real GPU).
fn getAttribLocation(self: *const WebGLRenderingContext, program: *WebGLProgram, name: []const u8, exec: *Execution) !i32 {
    if (self._native) |context| {
        if (program._native_id != 0) {
            const zname = try exec.local_arena.dupeZ(u8, name);
            return NativeANGLE.lp_angle_attrib_location(context, program._native_id, zname);
        }
    }
    return -1;
}

fn compileShader(self: *WebGLRenderingContext, shader: *WebGLShader) void {
    if (self._native) |context| NativeANGLE.lp_angle_compile_shader(context, shader._native_id);
}

fn attachShader(self: *WebGLRenderingContext, program: *WebGLProgram, shader: *WebGLShader) void {
    if (self._native) |context| {
        NativeANGLE.lp_angle_attach_shader(context, program._native_id, shader._native_id);
        if (shader._type == 0x8B31) program._attached_shaders[0] = shader;
        if (shader._type == 0x8B30) program._attached_shaders[1] = shader;
    }
}

fn detachShader(self: *WebGLRenderingContext, program: *WebGLProgram, shader: *WebGLShader) void {
    if (self._native) |context| NativeANGLE.lp_angle_detach_shader(context, program._native_id, shader._native_id);
    for (&program._attached_shaders) |*attached| {
        if (attached.* == shader) attached.* = null;
    }
}

fn linkProgram(self: *WebGLRenderingContext, program: *WebGLProgram) void {
    if (self._native) |context| NativeANGLE.lp_angle_link_program(context, program._native_id);
}

fn validateProgram(self: *WebGLRenderingContext, program: *WebGLProgram) void {
    if (self._native) |context| NativeANGLE.lp_angle_validate_program(context, program._native_id);
}

fn useProgram(self: *WebGLRenderingContext, program: ?*WebGLProgram) void {
    if (program != null and self.nativeId(program) == 0 and self._native != null) return;
    self._current_program = program;
    if (self._native) |context| NativeANGLE.lp_angle_use_program(context, if (program) |p| p._native_id else 0);
}

fn nativeId(self: *const WebGLRenderingContext, object: anytype) u32 {
    const value = object orelse return 0;
    const context = self._native orelse return 0;
    if (value._owner != context or value._deleted) return 0;
    return value._native_id;
}

fn uniformId(self: *const WebGLRenderingContext, location: ?*WebGLUniformLocation) ?c_int {
    const value = location orelse return null;
    if (self._native == null or value._native_id < 0 or value._program != self._current_program) return null;
    return value._native_id;
}

fn uniform1f(self: *WebGLRenderingContext, location: ?*WebGLUniformLocation, x: f64) void {
    if (self.uniformId(location)) |id| NativeANGLE.lp_angle_uniform1f(self._native.?, id, @floatCast(x));
}

fn uniform2f(self: *WebGLRenderingContext, location: ?*WebGLUniformLocation, x: f64, y: f64) void {
    if (self.uniformId(location)) |id| NativeANGLE.lp_angle_uniform2f(self._native.?, id, @floatCast(x), @floatCast(y));
}

fn uniform3f(self: *WebGLRenderingContext, location: ?*WebGLUniformLocation, x: f64, y: f64, z: f64) void {
    if (self.uniformId(location)) |id| NativeANGLE.lp_angle_uniform3f(self._native.?, id, @floatCast(x), @floatCast(y), @floatCast(z));
}

fn uniform4f(self: *WebGLRenderingContext, location: ?*WebGLUniformLocation, x: f64, y: f64, z: f64, w: f64) void {
    if (self.uniformId(location)) |id| NativeANGLE.lp_angle_uniform4f(self._native.?, id, @floatCast(x), @floatCast(y), @floatCast(z), @floatCast(w));
}

fn uniform1i(self: *WebGLRenderingContext, location: ?*WebGLUniformLocation, x: i32) void {
    if (self.uniformId(location)) |id| NativeANGLE.lp_angle_uniform1i(self._native.?, id, x);
}

fn uniform2i(self: *WebGLRenderingContext, location: ?*WebGLUniformLocation, x: i32, y: i32) void {
    if (self.uniformId(location)) |id| NativeANGLE.lp_angle_uniform2i(self._native.?, id, x, y);
}

fn uniform3i(self: *WebGLRenderingContext, location: ?*WebGLUniformLocation, x: i32, y: i32, z: i32) void {
    if (self.uniformId(location)) |id| NativeANGLE.lp_angle_uniform3i(self._native.?, id, x, y, z);
}

fn uniform4i(self: *WebGLRenderingContext, location: ?*WebGLUniformLocation, x: i32, y: i32, z: i32, w: i32) void {
    if (self.uniformId(location)) |id| NativeANGLE.lp_angle_uniform4i(self._native.?, id, x, y, z, w);
}

fn bindBuffer(self: *WebGLRenderingContext, target: u32, buffer: ?*WebGLBuffer) void {
    const id = self.nativeId(buffer);
    if (buffer != null and id == 0) return;
    if (self._native) |context| {
        NativeANGLE.lp_angle_bind_buffer(context, target, id);
        if (target == 0x8892) self._bound_array_buffer = buffer;
        if (target == 0x8893) self._bound_element_array_buffer = buffer;
    }
}

fn bindTexture(self: *WebGLRenderingContext, target: u32, texture: ?*WebGLTexture) void {
    const id = self.nativeId(texture);
    if (texture != null and id == 0) return;
    if (self._native) |context| {
        NativeANGLE.lp_angle_bind_texture(context, target, id);
        if (target == GL.TEXTURE_2D) self._bound_textures[self._active_texture - 0x84C0] = texture;
    }
}

fn bindFramebuffer(self: *WebGLRenderingContext, target: u32, framebuffer: ?*WebGLFramebuffer) void {
    const id = self.nativeId(framebuffer);
    if (framebuffer != null and id == 0) return;
    if (self._native) |context| {
        NativeANGLE.lp_angle_bind_framebuffer(context, target, id);
        if (target == 0x8D40) self._bound_framebuffer = framebuffer;
    }
}

fn bindRenderbuffer(self: *WebGLRenderingContext, target: u32, renderbuffer: ?*WebGLRenderbuffer) void {
    const id = self.nativeId(renderbuffer);
    if (renderbuffer != null and id == 0) return;
    if (self._native) |context| {
        NativeANGLE.lp_angle_bind_renderbuffer(context, target, id);
        if (target == GL.RENDERBUFFER) self._bound_renderbuffer = renderbuffer;
    }
}

fn renderbufferStorage(self: *WebGLRenderingContext, target: u32, format: u32, width: i32, height: i32) void {
    if (self._native) |context| NativeANGLE.lp_angle_renderbuffer_storage(context, target, format, width, height);
}

fn framebufferRenderbuffer(self: *WebGLRenderingContext, target: u32, attachment: u32, renderbuffer_target: u32, renderbuffer: ?*WebGLRenderbuffer) void {
    const id = self.nativeId(renderbuffer);
    if (renderbuffer != null and id == 0) return;
    if (self._native) |context| {
        NativeANGLE.lp_angle_framebuffer_renderbuffer(context, target, attachment, renderbuffer_target, id);
        if (target == 0x8D40 and attachment == 0x8CE0 and renderbuffer_target == GL.RENDERBUFFER) {
            if (self._bound_framebuffer) |framebuffer| framebuffer._color_attachment = if (renderbuffer) |object| .{ .renderbuffer = object } else .none;
        }
    }
}

fn framebufferTexture2D(self: *WebGLRenderingContext, target: u32, attachment: u32, texture_target: u32, texture: ?*WebGLTexture, level: i32) void {
    const id = self.nativeId(texture);
    if (texture != null and id == 0) return;
    if (self._native) |context| {
        NativeANGLE.lp_angle_framebuffer_texture2d(context, target, attachment, texture_target, id, level);
        if (target == 0x8D40 and attachment == 0x8CE0 and texture_target == GL.TEXTURE_2D) {
            if (self._bound_framebuffer) |framebuffer| {
                framebuffer._color_attachment = if (texture) |object| .{ .texture = object } else .none;
                framebuffer._color_attachment_level = level;
            }
        }
    }
}

fn getFramebufferAttachmentParameter(self: *WebGLRenderingContext, target: u32, attachment: u32, pname: u32) ?Parameter {
    if (target != 0x8D40 or attachment != 0x8CE0) return null;
    const framebuffer = self._bound_framebuffer orelse {
        self.setError(GL.INVALID_OPERATION);
        return null;
    };
    return switch (pname) {
        GL.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE => switch (framebuffer._color_attachment) {
            .none => int(GL.NONE),
            .texture => int(0x1702),
            .renderbuffer => int(GL.RENDERBUFFER),
        },
        GL.FRAMEBUFFER_ATTACHMENT_OBJECT_NAME => switch (framebuffer._color_attachment) {
            .none => null,
            .texture => |object| .{ .texture = object },
            .renderbuffer => |object| .{ .renderbuffer = object },
        },
        GL.FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL => int(framebuffer._color_attachment_level),
        else => null,
    };
}

fn activeTexture(self: *WebGLRenderingContext, texture: u32) void {
    if (self._native) |context| {
        NativeANGLE.lp_angle_active_texture(context, texture);
        if (texture >= 0x84C0 and texture < 0x84C0 + self._bound_textures.len) self._active_texture = texture;
    }
}

fn getTexParameter(self: *WebGLRenderingContext, target: u32, pname: u32, exec: *Execution) !?Parameter {
    const context = try self.native(exec) orelse return null;
    if (target != GL.TEXTURE_2D) return null;
    if (self._bound_textures[self._active_texture - 0x84C0] == null) {
        self.setError(GL.INVALID_OPERATION);
        return null;
    }
    return int(NativeANGLE.lp_angle_get_tex_parameter(context, target, pname));
}

fn getRenderbufferParameter(self: *WebGLRenderingContext, target: u32, pname: u32, exec: *Execution) !?Parameter {
    const context = try self.native(exec) orelse return null;
    if (target != GL.RENDERBUFFER) return null;
    if (self._bound_renderbuffer == null) {
        self.setError(GL.INVALID_OPERATION);
        return null;
    }
    return int(NativeANGLE.lp_angle_get_renderbuffer_parameter(context, target, pname));
}

fn texParameteri(self: *WebGLRenderingContext, target: u32, pname: u32, value: i32) void {
    if (self._native) |context| NativeANGLE.lp_angle_tex_parameteri(context, target, pname, value);
}

fn texParameterf(self: *WebGLRenderingContext, target: u32, pname: u32, value: f64) void {
    if (self._native) |context| NativeANGLE.lp_angle_tex_parameterf(context, target, pname, @floatCast(value));
}

fn pixelStorei(self: *WebGLRenderingContext, pname: u32, value: i32) void {
    switch (pname) {
        GL.PACK_ALIGNMENT, GL.UNPACK_ALIGNMENT => {
            if (value == 1 or value == 2 or value == 4 or value == 8) {
                if (pname == GL.PACK_ALIGNMENT) self._pack_alignment = value else self._unpack_alignment = value;
            }
            if (self._native) |context| NativeANGLE.lp_angle_pixel_storei(context, pname, value);
        },
        GL.UNPACK_FLIP_Y_WEBGL => self._unpack_flip_y = value != 0,
        GL.UNPACK_PREMULTIPLY_ALPHA_WEBGL => self._unpack_premultiply_alpha = value != 0,
        GL.UNPACK_COLORSPACE_CONVERSION_WEBGL => {
            const converted: u32 = @bitCast(value);
            if (converted == 0 or converted == GL.BROWSER_DEFAULT_WEBGL) {
                self._unpack_colorspace_conversion = converted;
            } else self.setError(GL.INVALID_VALUE);
        },
        else => {},
    }
}

fn convertedTextureBytes(self: *const WebGLRenderingContext, bytes: []const u8, width: usize, height: usize, exec: *Execution) !?[]const u8 {
    const count = std.math.mul(usize, width, height) catch return null;
    const needed = std.math.mul(usize, count, 4) catch return null;
    if (bytes.len < needed) return null;
    if (!self._unpack_flip_y and !self._unpack_premultiply_alpha) return bytes;
    const output = try exec.local_arena.alloc(u8, needed);
    const row_bytes = width * 4;
    for (0..height) |row| {
        const source_row = if (self._unpack_flip_y) height - row - 1 else row;
        const source = bytes[source_row * row_bytes ..][0..row_bytes];
        const dest = output[row * row_bytes ..][0..row_bytes];
        @memcpy(dest, source);
        if (self._unpack_premultiply_alpha) {
            for (0..width) |pixel| {
                const offset = pixel * 4;
                const alpha: u16 = dest[offset + 3];
                for (0..3) |channel| dest[offset + channel] = @intCast(@as(u16, dest[offset + channel]) * alpha / 255);
            }
        }
    }
    return output;
}

fn texImage2D(self: *WebGLRenderingContext, target: u32, level: i32, internal_format: i32, width: i32, height: i32, border: i32, format: u32, pixel_type: u32, pixels: js.Value, exec: *Execution) !void {
    const context = self._native orelse return;
    if (internal_format != format) {
        self.setError(GL.INVALID_OPERATION);
        return;
    }
    if (format != GL.RGBA or pixel_type != GL.UNSIGNED_BYTE or width < 0 or height < 0) return;
    var data: ?[*]const u8 = null;
    if (!pixels.isNullOrUndefined()) {
        const source = try pixels.toZig(js.BufferSource);
        const converted = try self.convertedTextureBytes(source.bytes, @intCast(width), @intCast(height), exec) orelse {
            self.setError(GL.INVALID_OPERATION);
            return;
        };
        data = converted.ptr;
    }
    NativeANGLE.lp_angle_tex_image2d(context, target, level, internal_format, width, height, border, format, pixel_type, data);
}

fn texSubImage2D(self: *WebGLRenderingContext, target: u32, level: i32, x: i32, y: i32, width: i32, height: i32, format: u32, pixel_type: u32, pixels: js.Value, exec: *Execution) !void {
    const context = self._native orelse return;
    if (format != GL.RGBA or pixel_type != GL.UNSIGNED_BYTE or width < 0 or height < 0 or pixels.isNullOrUndefined()) return;
    const source = try pixels.toZig(js.BufferSource);
    const converted = try self.convertedTextureBytes(source.bytes, @intCast(width), @intCast(height), exec) orelse {
        self.setError(GL.INVALID_OPERATION);
        return;
    };
    NativeANGLE.lp_angle_tex_sub_image2d(context, target, level, x, y, width, height, format, pixel_type, converted.ptr);
}

fn bufferData(self: *WebGLRenderingContext, target: u32, data: js.Value, usage: u32) !void {
    const context = self._native orelse return;
    if (data.isNumber()) {
        const size = try data.toZig(u32);
        NativeANGLE.lp_angle_buffer_data(context, target, null, size, usage);
    } else {
        const bytes = try data.toZig(js.BufferSource);
        NativeANGLE.lp_angle_buffer_data(context, target, bytes.bytes.ptr, bytes.bytes.len, usage);
    }
}

fn enableVertexAttribArray(self: *WebGLRenderingContext, index: u32) void {
    if (self._native) |context| NativeANGLE.lp_angle_enable_vertex_attrib(context, index);
}

fn vertexAttribPointer(self: *WebGLRenderingContext, index: u32, size: i32, value_type: u32, normalized: bool, stride: i32, offset: usize) void {
    if (self._native) |context| NativeANGLE.lp_angle_vertex_attrib_pointer(context, index, size, value_type, @intFromBool(normalized), stride, offset);
}

fn viewport(self: *WebGLRenderingContext, x: i32, y: i32, width: i32, height: i32) void {
    if (self._native) |context| NativeANGLE.lp_angle_viewport(context, x, y, width, height);
    if (width >= 0 and height >= 0) {
        self._viewport = .{ x, y, width, height };
        self._viewport_set = true;
    }
}

fn drawArrays(self: *WebGLRenderingContext, mode: u32, first: i32, count: i32, exec: *Execution) !void {
    const context = try self.native(exec) orelse return;
    NativeANGLE.lp_angle_draw_arrays(context, mode, first, count);
    self._native_drawn = true;
    try self.syncNativePixels(exec);
}

fn activeInfo(self: *const WebGLRenderingContext, program: *WebGLProgram, index: u32, uniform: bool, exec: *Execution) !?*WebGLActiveInfo {
    const context = self._native orelse return null;
    if (program._native_id == 0) return null;
    var name: [256]u8 = undefined;
    var size: c_int = 0;
    var info_type: u32 = 0;
    const length = NativeANGLE.lp_angle_active_info(context, program._native_id, index, @intFromBool(uniform), &name, name.len, &size, &info_type);
    if (length < 0) return null;
    return exec._factory.create(WebGLActiveInfo{
        ._name = try exec.arena.dupe(u8, name[0..@intCast(length)]),
        ._size = size,
        ._type = info_type,
    });
}

fn getActiveAttrib(self: *const WebGLRenderingContext, program: *WebGLProgram, index: u32, exec: *Execution) !?*WebGLActiveInfo {
    return self.activeInfo(program, index, false, exec);
}

fn getActiveUniform(self: *const WebGLRenderingContext, program: *WebGLProgram, index: u32, exec: *Execution) !?*WebGLActiveInfo {
    return self.activeInfo(program, index, true, exec);
}

fn getAttachedShaders(_: *WebGLRenderingContext, program: *WebGLProgram, exec: *Execution) ![]const *WebGLShader {
    var count: usize = 0;
    for (program._attached_shaders) |shader| {
        if (shader != null) count += 1;
    }
    const result = try exec.local_arena.alloc(*WebGLShader, count);
    count = 0;
    for (program._attached_shaders) |shader| {
        if (shader) |value| {
            result[count] = value;
            count += 1;
        }
    }
    return result;
}

fn isNativeObject(self: *const WebGLRenderingContext, object: anytype, comptime query: anytype) bool {
    const context = self._native orelse return false;
    const id = self.nativeId(object);
    return id != 0 and query(context, id) != 0;
}

fn isBuffer(self: *const WebGLRenderingContext, object: ?*WebGLBuffer) bool {
    return self.isNativeObject(object, NativeANGLE.lp_angle_is_buffer);
}

fn isFramebuffer(self: *const WebGLRenderingContext, object: ?*WebGLFramebuffer) bool {
    return self.isNativeObject(object, NativeANGLE.lp_angle_is_framebuffer);
}

fn isProgram(self: *const WebGLRenderingContext, object: ?*WebGLProgram) bool {
    return self.isNativeObject(object, NativeANGLE.lp_angle_is_program);
}

fn isRenderbuffer(self: *const WebGLRenderingContext, object: ?*WebGLRenderbuffer) bool {
    return self.isNativeObject(object, NativeANGLE.lp_angle_is_renderbuffer);
}

fn isShader(self: *const WebGLRenderingContext, object: ?*WebGLShader) bool {
    return self.isNativeObject(object, NativeANGLE.lp_angle_is_shader);
}

fn isTexture(self: *const WebGLRenderingContext, object: ?*WebGLTexture) bool {
    return self.isNativeObject(object, NativeANGLE.lp_angle_is_texture);
}

fn deleteNativeObject(self: *WebGLRenderingContext, object: anytype, comptime delete_fn: anytype) void {
    const value = object orelse return;
    if (value._deleted) return;
    if (self._native) |context| {
        if (value._owner != context) return;
        if (value._native_id != 0) delete_fn(context, value._native_id);
    } else if (value._owner != null) return;
    value._deleted = true;
}

fn deleteBuffer(self: *WebGLRenderingContext, object: ?*WebGLBuffer) void {
    self.deleteNativeObject(object, NativeANGLE.lp_angle_delete_buffer);
    if (self._bound_array_buffer == object) self._bound_array_buffer = null;
    if (self._bound_element_array_buffer == object) self._bound_element_array_buffer = null;
}

fn deleteFramebuffer(self: *WebGLRenderingContext, object: ?*WebGLFramebuffer) void {
    self.deleteNativeObject(object, NativeANGLE.lp_angle_delete_framebuffer);
    if (self._bound_framebuffer == object) self._bound_framebuffer = null;
}

fn deleteProgram(self: *WebGLRenderingContext, object: ?*WebGLProgram) void {
    self.deleteNativeObject(object, NativeANGLE.lp_angle_delete_program);
}

fn deleteRenderbuffer(self: *WebGLRenderingContext, object: ?*WebGLRenderbuffer) void {
    self.deleteNativeObject(object, NativeANGLE.lp_angle_delete_renderbuffer);
    if (self._bound_renderbuffer == object) self._bound_renderbuffer = null;
}

fn deleteShader(self: *WebGLRenderingContext, object: ?*WebGLShader) void {
    self.deleteNativeObject(object, NativeANGLE.lp_angle_delete_shader);
}

fn deleteTexture(self: *WebGLRenderingContext, object: ?*WebGLTexture) void {
    self.deleteNativeObject(object, NativeANGLE.lp_angle_delete_texture);
    for (&self._bound_textures) |*bound| {
        if (bound.* == object) bound.* = null;
    }
}

fn isEnabled(_: *const WebGLRenderingContext, cap: u32) bool {
    // Matches the getParameter defaults: only DITHER starts enabled.
    return cap == GL.DITHER;
}

/// Placeholder for state queries not yet forwarded to ANGLE.
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
                    pub const expose_global = false;

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
                    pub const expose_global = false;

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
fn getExtension(_: *const WebGLRenderingContext, name: []const u8, exec: *Execution) !?Extension {
    const tag = Extension.find(name) orelse return null;

    return switch (tag) {
        .WEBGL_debug_renderer_info => {
            const info = try exec._factory.create(Extension.Type.WEBGL_debug_renderer_info{});
            return .{ .WEBGL_debug_renderer_info = info };
        },
        .WEBGL_lose_context => {
            const ctx = try exec._factory.create(Extension.Type.WEBGL_lose_context{});
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
const WebGLObject = struct {
    pub const _prototype_root = true;
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLObject);
        pub const Meta = struct {
            pub const name = "WebGLObject";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

fn OpaqueObject(comptime type_name: [:0]const u8) type {
    return struct {
        const Self = @This();
        pub const Proto = WebGLObject;

        _proto: *WebGLObject,
        _native_id: u32 = 0,
        _owner: ?*NativeANGLE.Context = null,
        _deleted: bool = false,
        _color_attachment: FramebufferAttachment = .none,
        _color_attachment_level: i32 = 0,
        _attached_shaders: [2]?*WebGLShader = .{ null, null },

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

const FramebufferAttachment = union(enum) {
    none,
    texture: *WebGLTexture,
    renderbuffer: *WebGLRenderbuffer,
};

const WebGLBuffer = OpaqueObject("WebGLBuffer");
const WebGLFramebuffer = OpaqueObject("WebGLFramebuffer");
const WebGLProgram = OpaqueObject("WebGLProgram");
const WebGLRenderbuffer = OpaqueObject("WebGLRenderbuffer");
const WebGLTexture = OpaqueObject("WebGLTexture");
const WebGLUniformLocation = struct {
    _native_id: c_int = -1,
    _program: *WebGLProgram,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLUniformLocation);
        pub const Meta = struct {
            pub const name = "WebGLUniformLocation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

const WebGLShader = struct {
    pub const Proto = WebGLObject;
    _proto: *WebGLObject,
    _type: u32,
    _source: []const u8 = "",
    _native_id: u32 = 0,
    _owner: ?*NativeANGLE.Context = null,
    _deleted: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLShader);

        pub const Meta = struct {
            pub const name = "WebGLShader";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

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
    pub const drawingBufferColorSpace = bridge.accessor(WebGLRenderingContext.getColorSpace, WebGLRenderingContext.setColorSpace, .{});
    pub const unpackColorSpace = bridge.accessor(WebGLRenderingContext.getColorSpace, WebGLRenderingContext.setColorSpace, .{});

    pub const LOW_FLOAT = bridge.property(@as(u32, 0x8DF0), .{ .template = false, .readonly = true });
    pub const MEDIUM_FLOAT = bridge.property(@as(u32, 0x8DF1), .{ .template = false, .readonly = true });
    pub const HIGH_FLOAT = bridge.property(@as(u32, 0x8DF2), .{ .template = false, .readonly = true });
    pub const LOW_INT = bridge.property(@as(u32, 0x8DF3), .{ .template = false, .readonly = true });
    pub const MEDIUM_INT = bridge.property(@as(u32, 0x8DF4), .{ .template = false, .readonly = true });
    pub const HIGH_INT = bridge.property(@as(u32, 0x8DF5), .{ .template = false, .readonly = true });

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
    pub const deleteBuffer = bridge.function(WebGLRenderingContext.deleteBuffer, .{ .arity = 1 });
    pub const deleteFramebuffer = bridge.function(WebGLRenderingContext.deleteFramebuffer, .{ .arity = 1 });
    pub const deleteProgram = bridge.function(WebGLRenderingContext.deleteProgram, .{ .arity = 1 });
    pub const deleteRenderbuffer = bridge.function(WebGLRenderingContext.deleteRenderbuffer, .{ .arity = 1 });
    pub const deleteShader = bridge.function(WebGLRenderingContext.deleteShader, .{ .arity = 1 });
    pub const deleteTexture = bridge.function(WebGLRenderingContext.deleteTexture, .{ .arity = 1 });

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
    pub const compileShader = bridge.function(WebGLRenderingContext.compileShader, .{});
    pub const linkProgram = bridge.function(WebGLRenderingContext.linkProgram, .{});
    pub const useProgram = bridge.function(WebGLRenderingContext.useProgram, .{ .arity = 1 });
    pub const validateProgram = bridge.function(WebGLRenderingContext.validateProgram, .{ .arity = 1 });
    pub const attachShader = bridge.function(WebGLRenderingContext.attachShader, .{});
    pub const detachShader = bridge.function(WebGLRenderingContext.detachShader, .{ .arity = 2 });
    pub const bindAttribLocation = noop.@"3";

    pub const isBuffer = bridge.function(WebGLRenderingContext.isBuffer, .{ .arity = 1 });
    pub const isFramebuffer = bridge.function(WebGLRenderingContext.isFramebuffer, .{ .arity = 1 });
    pub const isProgram = bridge.function(WebGLRenderingContext.isProgram, .{ .arity = 1 });
    pub const isRenderbuffer = bridge.function(WebGLRenderingContext.isRenderbuffer, .{ .arity = 1 });
    pub const isShader = bridge.function(WebGLRenderingContext.isShader, .{ .arity = 1 });
    pub const isTexture = bridge.function(WebGLRenderingContext.isTexture, .{ .arity = 1 });
    pub const isEnabled = bridge.function(WebGLRenderingContext.isEnabled, .{});

    // Most mutable-state introspection still needs native forwarding.
    pub const getBufferParameter = bridge.function(WebGLRenderingContext.getNull, .{});
    pub const getFramebufferAttachmentParameter = bridge.function(WebGLRenderingContext.getFramebufferAttachmentParameter, .{ .arity = 3 });
    pub const getRenderbufferParameter = bridge.function(WebGLRenderingContext.getRenderbufferParameter, .{ .arity = 2 });
    pub const getTexParameter = bridge.function(WebGLRenderingContext.getTexParameter, .{ .arity = 2 });
    pub const getUniform = bridge.function(WebGLRenderingContext.getNull, .{});
    pub const getVertexAttrib = bridge.function(WebGLRenderingContext.getNull, .{});

    // Binding and buffer data.
    pub const bindBuffer = bridge.function(WebGLRenderingContext.bindBuffer, .{ .arity = 2 });
    pub const bindFramebuffer = bridge.function(WebGLRenderingContext.bindFramebuffer, .{ .arity = 2 });
    pub const bindRenderbuffer = bridge.function(WebGLRenderingContext.bindRenderbuffer, .{ .arity = 2 });
    pub const bindTexture = bridge.function(WebGLRenderingContext.bindTexture, .{ .arity = 2 });
    pub const bufferData = bridge.function(WebGLRenderingContext.bufferData, .{});
    pub const bufferSubData = noop.@"3";
    pub const renderbufferStorage = bridge.function(WebGLRenderingContext.renderbufferStorage, .{ .arity = 4 });
    pub const framebufferRenderbuffer = bridge.function(WebGLRenderingContext.framebufferRenderbuffer, .{ .arity = 4 });
    pub const framebufferTexture2D = bridge.function(WebGLRenderingContext.framebufferTexture2D, .{ .arity = 5 });

    // Textures.
    pub const activeTexture = bridge.function(WebGLRenderingContext.activeTexture, .{ .arity = 1 });
    pub const generateMipmap = noop.@"1";
    pub const texParameterf = bridge.function(WebGLRenderingContext.texParameterf, .{ .arity = 3 });
    pub const texParameteri = bridge.function(WebGLRenderingContext.texParameteri, .{ .arity = 3 });
    pub const pixelStorei = bridge.function(WebGLRenderingContext.pixelStorei, .{ .arity = 2 });
    pub const copyTexImage2D = noop.@"8";
    pub const copyTexSubImage2D = noop.@"8";
    pub const compressedTexImage2D = noop.@"7";
    pub const compressedTexSubImage2D = noop.@"8";
    // texImage2D and texSubImage2D are overloaded: Chrome reports the arity
    // of the shortest form.
    pub const texImage2D = bridge.function(WebGLRenderingContext.texImage2D, .{ .arity = 6 });
    pub const texSubImage2D = bridge.function(WebGLRenderingContext.texSubImage2D, .{ .arity = 7 });

    // Vertex attributes.
    pub const enableVertexAttribArray = bridge.function(WebGLRenderingContext.enableVertexAttribArray, .{});
    pub const disableVertexAttribArray = noop.@"1";
    pub const vertexAttribPointer = bridge.function(WebGLRenderingContext.vertexAttribPointer, .{});
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
    pub const uniform1f = bridge.function(WebGLRenderingContext.uniform1f, .{});
    pub const uniform1i = bridge.function(WebGLRenderingContext.uniform1i, .{});
    pub const uniform2f = bridge.function(WebGLRenderingContext.uniform2f, .{});
    pub const uniform2i = bridge.function(WebGLRenderingContext.uniform2i, .{});
    pub const uniform3f = bridge.function(WebGLRenderingContext.uniform3f, .{});
    pub const uniform3i = bridge.function(WebGLRenderingContext.uniform3i, .{});
    pub const uniform4f = bridge.function(WebGLRenderingContext.uniform4f, .{});
    pub const uniform4i = bridge.function(WebGLRenderingContext.uniform4i, .{});
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
    pub const viewport = bridge.function(WebGLRenderingContext.viewport, .{});

    // Clear/readback and a subset of shader draws use the native backend.
    pub const clear = bridge.function(WebGLRenderingContext.clear, .{});
    pub const clearColor = bridge.function(WebGLRenderingContext.clearColor, .{});
    pub const clearDepth = noop.@"1";
    pub const clearStencil = noop.@"1";
    pub const drawArrays = bridge.function(WebGLRenderingContext.drawArrays, .{});
    pub const drawElements = noop.@"4";
    pub const finish = noop.@"0";
    pub const flush = noop.@"0";
    pub const readPixels = bridge.function(WebGLRenderingContext.readPixels, .{});
};

/// WebGL 2 has the WebGL 1 surface as its prototype plus its own constants.
/// Shader rendering is still partial, but current Chrome returns a WebGL 2
/// context on supported desktop hardware, and fingerprint probes select it
/// before falling back to WebGL 1.
pub const WebGL2RenderingContext = struct {
    pub const Proto = WebGLRenderingContext;
    _proto: *WebGLRenderingContext,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGL2RenderingContext);

        pub const Meta = struct {
            pub const name = "WebGL2RenderingContext";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const MAX_3D_TEXTURE_SIZE = bridge.property(GL.MAX_3D_TEXTURE_SIZE, .{ .template = false, .readonly = true });
        pub const MAX_ARRAY_TEXTURE_LAYERS = bridge.property(GL.MAX_ARRAY_TEXTURE_LAYERS, .{ .template = false, .readonly = true });
        pub const MAX_COLOR_ATTACHMENTS = bridge.property(GL.MAX_COLOR_ATTACHMENTS, .{ .template = false, .readonly = true });
        pub const MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS = bridge.property(GL.MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS, .{ .template = false, .readonly = true });
        pub const MAX_COMBINED_UNIFORM_BLOCKS = bridge.property(GL.MAX_COMBINED_UNIFORM_BLOCKS, .{ .template = false, .readonly = true });
        pub const MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS = bridge.property(GL.MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS, .{ .template = false, .readonly = true });
        pub const MAX_DRAW_BUFFERS = bridge.property(GL.MAX_DRAW_BUFFERS, .{ .template = false, .readonly = true });
        pub const MAX_ELEMENTS_INDICES = bridge.property(GL.MAX_ELEMENTS_INDICES, .{ .template = false, .readonly = true });
        pub const MAX_ELEMENTS_VERTICES = bridge.property(GL.MAX_ELEMENTS_VERTICES, .{ .template = false, .readonly = true });
        pub const MAX_ELEMENT_INDEX = bridge.property(GL.MAX_ELEMENT_INDEX, .{ .template = false, .readonly = true });
        pub const MAX_FRAGMENT_INPUT_COMPONENTS = bridge.property(GL.MAX_FRAGMENT_INPUT_COMPONENTS, .{ .template = false, .readonly = true });
        pub const MAX_FRAGMENT_UNIFORM_BLOCKS = bridge.property(GL.MAX_FRAGMENT_UNIFORM_BLOCKS, .{ .template = false, .readonly = true });
        pub const MAX_FRAGMENT_UNIFORM_COMPONENTS = bridge.property(GL.MAX_FRAGMENT_UNIFORM_COMPONENTS, .{ .template = false, .readonly = true });
        pub const MAX_PROGRAM_TEXEL_OFFSET = bridge.property(GL.MAX_PROGRAM_TEXEL_OFFSET, .{ .template = false, .readonly = true });
        pub const MIN_PROGRAM_TEXEL_OFFSET = bridge.property(GL.MIN_PROGRAM_TEXEL_OFFSET, .{ .template = false, .readonly = true });
        pub const MAX_SAMPLES = bridge.property(GL.MAX_SAMPLES, .{ .template = false, .readonly = true });
        pub const MAX_TEXTURE_LOD_BIAS = bridge.property(GL.MAX_TEXTURE_LOD_BIAS, .{ .template = false, .readonly = true });
        pub const MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS = bridge.property(GL.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS, .{ .template = false, .readonly = true });
        pub const MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS = bridge.property(GL.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS, .{ .template = false, .readonly = true });
        pub const MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS = bridge.property(GL.MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS, .{ .template = false, .readonly = true });
        pub const MAX_UNIFORM_BLOCK_SIZE = bridge.property(GL.MAX_UNIFORM_BLOCK_SIZE, .{ .template = false, .readonly = true });
        pub const MAX_UNIFORM_BUFFER_BINDINGS = bridge.property(GL.MAX_UNIFORM_BUFFER_BINDINGS, .{ .template = false, .readonly = true });
        pub const MAX_VARYING_COMPONENTS = bridge.property(GL.MAX_VARYING_COMPONENTS, .{ .template = false, .readonly = true });
        pub const MAX_VERTEX_OUTPUT_COMPONENTS = bridge.property(GL.MAX_VERTEX_OUTPUT_COMPONENTS, .{ .template = false, .readonly = true });
        pub const MAX_VERTEX_UNIFORM_BLOCKS = bridge.property(GL.MAX_VERTEX_UNIFORM_BLOCKS, .{ .template = false, .readonly = true });
        pub const MAX_VERTEX_UNIFORM_COMPONENTS = bridge.property(GL.MAX_VERTEX_UNIFORM_COMPONENTS, .{ .template = false, .readonly = true });
        pub const UNIFORM_BUFFER_OFFSET_ALIGNMENT = bridge.property(GL.UNIFORM_BUFFER_OFFSET_ALIGNMENT, .{ .template = false, .readonly = true });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGLRenderingContext" {
    try testing.htmlRunner("canvas/webgl_rendering_context.html", .{});
}
