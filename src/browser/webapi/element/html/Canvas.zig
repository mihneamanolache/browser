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

const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Blob = @import("../../Blob.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const WebGL2RenderingContext = WebGLRenderingContext.WebGL2RenderingContext;
const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const context2d = @import("../../canvas/context2d.zig");
const Bitmap = @import("../../canvas/Bitmap.zig");
const FileReader = @import("../../FileReader.zig");

const HtmlElement = @import("../Html.zig");

const js = lp.js;
const log = lp.log;
const Execution = js.Execution;
const BlankPNG = OffscreenCanvas.BlankPNG;

const Canvas = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_cached: ?DrawingContext = null,

pub fn asElement(self: *Canvas) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeInterned("width") orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeInterned("height") orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
    webgl2: *WebGL2RenderingContext,
};

fn getContext(self: *Canvas, context_type: []const u8, options: ?context2d.ContextOptions, frame: *Frame) !?DrawingContext {
    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => std.mem.eql(u8, context_type, "2d"),
            .webgl => std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl"),
            .webgl2 => std.mem.eql(u8, context_type, "webgl2"),
        };
        return if (matches) cached else null;
    }

    const drawing_context: DrawingContext = blk: {
        if (std.mem.eql(u8, context_type, "2d")) {
            const ctx = try frame._factory.create(CanvasRenderingContext2D{
                ._canvas = self,
                ._software_raster = if (options) |o| o.willReadFrequently else false,
                ._context_options = options orelse .{},
                ._bitmap = .{
                    ._opaque = if (options) |o| !o.alpha else false,
                    ._preserve_raw_put = if (options) |o| !o.alpha else false,
                },
            });
            break :blk .{ .@"2d" = ctx };
        }

        // The whole WebGL 1.0 surface is implemented (see
        // WebGLRenderingContext), so a consumer like Three.js runs its setup
        // path to completion instead of throwing on the first call we never
        // stubbed. Shader draws still need a backend — but returning null
        // here would be a louder signal, since a desktop Chrome that
        // cannot do WebGL is close to unheard of.
        if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
            const ctx = try frame._factory.create(WebGLRenderingContext{
                ._canvas = self,
                ._offscreen_canvas = null,
                ._drawing_buffer_width = self.getWidth(),
                ._drawing_buffer_height = self.getHeight(),
                ._attributes = .{
                    .alpha = if (options) |o| o.alpha else true,
                    .premultipliedAlpha = if (options) |o| o.premultipliedAlpha else true,
                },
            });
            break :blk .{ .webgl = ctx };
        }

        if (std.mem.eql(u8, context_type, "webgl2")) {
            const ctx = try frame._factory.chained(.{
                WebGLRenderingContext{
                    ._canvas = self,
                    ._offscreen_canvas = null,
                    ._drawing_buffer_width = self.getWidth(),
                    ._drawing_buffer_height = self.getHeight(),
                    ._version = .webgl2,
                    ._attributes = .{
                        .alpha = if (options) |o| o.alpha else true,
                        .premultipliedAlpha = if (options) |o| o.premultipliedAlpha else true,
                    },
                },
                WebGL2RenderingContext{ ._proto = undefined },
            });
            break :blk .{ .webgl2 = ctx };
        }

        // WebGPU remains genuinely absent.
        return null;
    };
    self._cached = drawing_context;
    return drawing_context;
}

fn hasBitmap(self: *const Canvas) bool {
    return BlankPNG.hasBitmap(self.getWidth(), self.getHeight());
}

fn resetBitmap(self: *Canvas) void {
    const cached = self._cached orelse return;
    switch (cached) {
        .@"2d" => |ctx| {
            ctx._bitmap.reset();
            ctx._state = .{};
            ctx._state_stack.clearRetainingCapacity();
        },
        .webgl => |ctx| {
            ctx._drawing_buffer_width = self.getWidth();
            ctx._drawing_buffer_height = self.getHeight();
            ctx.resetDrawingBuffer();
        },
        .webgl2 => |ctx| {
            ctx._proto._drawing_buffer_width = self.getWidth();
            ctx._proto._drawing_buffer_height = self.getHeight();
            ctx._proto.resetDrawingBuffer();
        },
    }
}

pub const Build = struct {
    pub fn attributeChange(element: *Element, name: lp.String, _: lp.String, _: *Frame) !void {
        if (name.eql(comptime .wrap("width")) or name.eql(comptime .wrap("height"))) {
            element.as(Canvas).resetBitmap();
        }
    }

    pub fn attributeRemove(element: *Element, name: lp.String, _: *Frame) !void {
        if (name.eql(comptime .wrap("width")) or name.eql(comptime .wrap("height"))) {
            element.as(Canvas).resetBitmap();
        }
    }
};

fn pngBytes(self: *Canvas, output_arena: std.mem.Allocator, exec: *Execution) !?[]const u8 {
    if (!self.hasBitmap()) return null;
    const width = self.getWidth();
    const height = self.getHeight();
    if (self._cached) |cached| {
        switch (cached) {
            .@"2d" => |ctx| return try ctx._bitmap.png(width, height, exec.arena, output_arena),
            .webgl => |ctx| return try ctx.png(output_arena, exec),
            .webgl2 => |ctx| return try ctx._proto.png(output_arena, exec),
        }
    }
    var blank: Bitmap = .{};
    return try blank.png(width, height, output_arena, output_arena);
}

/// Unsupported MIME types fall back to PNG. Encoding comes from the current
/// bitmap dimensions and pixels rather than a fixed transparent 1x1 image.
fn toDataURL(self: *Canvas, _: ?[]const u8, _: ?f64, exec: *Execution) ![]const u8 {
    const bytes = try self.pngBytes(exec.local_arena, exec) orelse return "data:,";
    return FileReader.encodeDataURL(exec.local_arena, "image/png", bytes);
}

/// Same image as `toDataURL`, handed to `callback` as a Blob from a task.
/// A canvas with no pixels calls back with null, per spec.
pub fn toBlob(self: *Canvas, callback: js.Function.Global, _: ?[]const u8, _: ?f64, exec: *Execution) !void {
    const bytes = try self.pngBytes(exec.arena, exec);
    const task = try exec._factory.create(ToBlobCallback{
        .exec = exec,
        // Snapshot the encoded bitmap before the asynchronous callback.
        .png_bytes = bytes,
        .callback = callback,
    });
    errdefer exec._factory.destroy(task);

    try exec._scheduler.add(task, ToBlobCallback.run, 0, .{
        .name = "canvas.toBlob",
        .finalizer = ToBlobCallback.cancelled,
    });
}

const ToBlobCallback = struct {
    exec: *Execution,
    png_bytes: ?[]const u8,
    callback: js.Function.Global,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ToBlobCallback = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn deinit(self: *ToBlobCallback) void {
        self.callback.release();
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ToBlobCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();
        const exec = self.exec;

        var blob: ?*Blob = null;
        if (self.png_bytes) |bytes| {
            const b = try Blob.initFromBytes(bytes, "image/png", exec);
            // The page can hold on to the Blob, in which case the JS wrapper
            // takes its own ref; ours only has to cover the call.
            b.acquireRef();
            blob = b;
        }
        defer if (blob) |b| {
            b.releaseRef(exec.page);
        };

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();

        ls.toLocal(self.callback).call(void, .{blob}) catch |err| {
            exec.page.recordJsError(err);
            log.warn(.js, "canvas.toBlob", .{ .err = err });
        };
        ls.local.runMicrotasks();
        return null;
    }
};

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
fn transferControlToOffscreen(self: *Canvas, exec: *Execution) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    return OffscreenCanvas.constructor(width, height, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Canvas);

    pub const Meta = struct {
        pub const name = "HTMLCanvasElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Canvas);

    pub const width = reflect.unsignedLong("width", .{ .default = 300 });
    pub const height = reflect.unsignedLong("height", .{ .default = 150 });
    pub const getContext = bridge.function(Canvas.getContext, .{});
    pub const toDataURL = bridge.function(Canvas.toDataURL, .{});
    pub const toBlob = bridge.function(Canvas.toBlob, .{});
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTMLCanvasElement serialization" {
    try testing.htmlRunner("canvas/canvas_serialization.html", .{});
}
