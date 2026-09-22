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

const std = @import("std");
const js = @import("../../js/js.zig");

const Blob = @import("../Blob.zig");
const OffscreenCanvasRenderingContext2D = @import("OffscreenCanvasRenderingContext2D.zig");
const context2d = @import("context2d.zig");
const Bitmap = @import("Bitmap.zig");
const WebGLRenderingContext = @import("WebGLRenderingContext.zig");
const WebGL2RenderingContext = WebGLRenderingContext.WebGL2RenderingContext;

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas
const OffscreenCanvas = @This();

pub const _prototype_root = true;

_width: u32,
_height: u32,
_cached: ?DrawingContext = null,

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *OffscreenCanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
    webgl2: *WebGL2RenderingContext,
};

pub fn constructor(width: u32, height: u32, exec: *Execution) !*OffscreenCanvas {
    return exec._factory.create(OffscreenCanvas{
        ._width = width,
        ._height = height,
    });
}

pub fn getWidth(self: *const OffscreenCanvas) u32 {
    return self._width;
}

fn setWidth(self: *OffscreenCanvas, value: u32) void {
    self._width = value;
    self.resetBitmap();
}

pub fn getHeight(self: *const OffscreenCanvas) u32 {
    return self._height;
}

fn setHeight(self: *OffscreenCanvas, value: u32) void {
    self._height = value;
    self.resetBitmap();
}

fn resetBitmap(self: *OffscreenCanvas) void {
    const cached = self._cached orelse return;
    switch (cached) {
        .@"2d" => |ctx| {
            ctx._bitmap.reset();
            ctx._state = .{};
            ctx._state_stack.clearRetainingCapacity();
        },
        .webgl => |ctx| {
            ctx._drawing_buffer_width = self._width;
            ctx._drawing_buffer_height = self._height;
            ctx.resetDrawingBuffer();
        },
        .webgl2 => |ctx| {
            ctx._proto._drawing_buffer_width = self._width;
            ctx._proto._drawing_buffer_height = self._height;
            ctx._proto.resetDrawingBuffer();
        },
    }
}

fn getContext(self: *OffscreenCanvas, context_type: []const u8, options: ?context2d.ContextOptions, exec: *Execution) !?DrawingContext {
    if (self._cached) |cached| {
        return switch (cached) {
            .@"2d" => if (std.mem.eql(u8, context_type, "2d")) cached else null,
            .webgl => if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) cached else null,
            .webgl2 => if (std.mem.eql(u8, context_type, "webgl2")) cached else null,
        };
    }

    if (std.mem.eql(u8, context_type, "2d")) {
        const ctx = try exec._factory.create(OffscreenCanvasRenderingContext2D{
            ._canvas = self,
            ._software_raster = if (options) |o| o.willReadFrequently else false,
            ._context_options = options orelse .{},
            ._bitmap = .{
                ._opaque = if (options) |o| !o.alpha else false,
                ._opaque_activated = if (options) |o| !o.alpha else false,
                ._preserve_raw_put = if (options) |o| !o.alpha and !o.willReadFrequently else false,
                ._put_unpremultiplied = if (options) |o| !o.alpha and o.willReadFrequently else false,
            },
        });
        self._cached = .{ .@"2d" = ctx };
        return self._cached;
    }

    if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
        const ctx = try exec._factory.create(WebGLRenderingContext{
            ._canvas = null,
            ._offscreen_canvas = self,
            ._drawing_buffer_width = self._width,
            ._drawing_buffer_height = self._height,
            ._attributes = .{
                .alpha = if (options) |o| o.alpha else true,
                .premultipliedAlpha = if (options) |o| o.premultipliedAlpha else true,
            },
        });
        self._cached = .{ .webgl = ctx };
        return self._cached;
    }

    if (std.mem.eql(u8, context_type, "webgl2")) {
        const ctx = try exec._factory.chained(.{
            WebGLRenderingContext{
                ._canvas = null,
                ._offscreen_canvas = self,
                ._drawing_buffer_width = self._width,
                ._drawing_buffer_height = self._height,
                ._version = .webgl2,
                ._attributes = .{
                    .alpha = if (options) |o| o.alpha else true,
                    .premultipliedAlpha = if (options) |o| o.premultipliedAlpha else true,
                },
            },
            WebGL2RenderingContext{ ._proto = undefined },
        });
        self._cached = .{ .webgl2 = ctx };
        return self._cached;
    }

    return null;
}

/// Encode the current bitmap. A canvas with no pixels rejects with
/// IndexSizeError, per spec.
fn convertToBlob(self: *OffscreenCanvas, exec: *Execution) !js.Promise {
    if (!BlankPNG.hasBitmap(self._width, self._height)) {
        return error.IndexSizeError;
    }
    const bytes = blk: {
        if (self._cached) |cached| {
            switch (cached) {
                .@"2d" => |ctx| break :blk try ctx._bitmap.png(self._width, self._height, exec.arena, exec.local_arena),
                .webgl => |ctx| break :blk try ctx.png(exec.local_arena, exec),
                .webgl2 => |ctx| break :blk try ctx._proto.png(exec.local_arena, exec),
            }
        }
        var blank: Bitmap = .{};
        break :blk try blank.png(self._width, self._height, exec.local_arena, exec.local_arena);
    };
    const blob = try Blob.initFromBytes(bytes, "image/png", exec);
    return exec.js.local.?.resolvePromise(blob);
}

/// Returns an ImageBitmap with the rendered content (stub).
fn transferToImageBitmap(_: *OffscreenCanvas) ?void {
    // ImageBitmap not implemented yet, return null
    return null;
}

pub const BlankPNG = struct {
    const mime = "image/png";

    const base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==";

    pub const data_url = "data:" ++ mime ++ ";base64," ++ base64;

    pub const bytes = blk: {
        const decoder = std.base64.standard.Decoder;
        var buf: [decoder.calcSizeForSlice(base64) catch unreachable]u8 = undefined;
        decoder.decode(&buf, base64) catch unreachable;
        break :blk buf;
    };

    /// Largest canvas Chrome backs with a bitmap (16384 x 16384). Past that, and
    /// at zero size, there are no pixels to serialize and the serializers answer
    /// with the spec's "no data" values.
    const max_area = 16384 * 16384;

    pub fn hasBitmap(width: u32, height: u32) bool {
        return width > 0 and height > 0 and @as(u64, width) * height <= max_area;
    }

    pub fn blob(exec: *js.Execution) !*Blob {
        return Blob.initFromBytes(&BlankPNG.bytes, BlankPNG.mime, exec);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(OffscreenCanvas);

    pub const Meta = struct {
        pub const name = "OffscreenCanvas";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(OffscreenCanvas.constructor, .{});
    pub const width = bridge.accessor(OffscreenCanvas.getWidth, OffscreenCanvas.setWidth, .{});
    pub const height = bridge.accessor(OffscreenCanvas.getHeight, OffscreenCanvas.setHeight, .{});
    pub const getContext = bridge.function(OffscreenCanvas.getContext, .{});
    pub const convertToBlob = bridge.function(OffscreenCanvas.convertToBlob, .{});
    pub const transferToImageBitmap = bridge.function(OffscreenCanvas.transferToImageBitmap, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: OffscreenCanvas" {
    try testing.htmlRunner("canvas/offscreen_canvas.html", .{});
}
