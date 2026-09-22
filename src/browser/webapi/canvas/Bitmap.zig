// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.

//! Shared premultiplied-RGBA pixel storage for HTML and offscreen 2D canvases.
//! Canvas dimensions are observed lazily so a width/height assignment resets
//! the bitmap before the next drawing or readback operation.

const std = @import("std");
const color = @import("../../color.zig");
const GraphiteRect = @import("GraphiteRect.zig");
const context2d = @import("context2d.zig");

const Bitmap = @This();

width: u32 = 0,
height: u32 = 0,
pixels: []u8 = &.{},
/// Chromium's opaque HTML 2D context reads back putImageData's straight RGBA
/// bytes, while alpha:true contexts read back through a premultiplied surface.
/// Keep opaque put bytes until that pixel is drawn over.
raw_put_pixels: []u8 = &.{},
raw_put_valid: []bool = &.{},
/// An alpha:false context uses an opaque black rendering surface once it is
/// materialized. HTMLCanvasElement starts lazily transparent in Chrome until
/// a drawing operation; OffscreenCanvas starts opaque immediately.
_opaque: bool = false,
_opaque_activated: bool = false,
_preserve_raw_put: bool = false,
_put_unpremultiplied: bool = false,

fn initializePixels(self: *Bitmap) void {
    @memset(self.pixels, 0);
    if (self._opaque_activated) {
        var i: usize = 3;
        while (i < self.pixels.len) : (i += 4) self.pixels[i] = 255;
    }
}

fn activateOpaque(self: *Bitmap) void {
    if (!self._opaque or self._opaque_activated) return;
    self._opaque_activated = true;
    var i: usize = 3;
    while (i < self.pixels.len) : (i += 4) self.pixels[i] = 255;
}

fn clearPixel(self: *Bitmap, offset: usize) void {
    if (self.raw_put_valid.len != 0) self.raw_put_valid[offset / 4] = false;
    @memset(self.pixels[offset..][0..4], 0);
    if (self._opaque) self.pixels[offset + 3] = 255;
}

fn invalidateRawBounds(self: *Bitmap, left: f64, top: f64, right: f64, bottom: f64) void {
    if (self.raw_put_valid.len == 0) return;
    const x0: usize = @intFromFloat(@max(0.0, @min(@floor(left), @as(f64, @floatFromInt(self.width)))));
    const y0: usize = @intFromFloat(@max(0.0, @min(@floor(top), @as(f64, @floatFromInt(self.height)))));
    const x1: usize = @intFromFloat(@max(0.0, @min(@ceil(right), @as(f64, @floatFromInt(self.width)))));
    const y1: usize = @intFromFloat(@max(0.0, @min(@ceil(bottom), @as(f64, @floatFromInt(self.height)))));
    for (y0..y1) |row| {
        @memset(self.raw_put_valid[row * self.width + x0 .. row * self.width + x1], false);
    }
}

pub fn ensure(self: *Bitmap, width: u32, height: u32, arena: std.mem.Allocator) !void {
    if (self.width == width and self.height == height) return;
    self.width = width;
    self.height = height;
    self.pixels = &.{};
    self.raw_put_pixels = &.{};
    self.raw_put_valid = &.{};
    if (width == 0 or height == 0) return;

    const count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.OutOfMemory;
    const bytes = std.math.mul(usize, count, 4) catch return error.OutOfMemory;
    self.pixels = try arena.alloc(u8, bytes);
    self.initializePixels();
}

pub fn reset(self: *Bitmap) void {
    // Assigning either canvas dimension resets the bitmap even when the
    // assigned value is identical to the old one.
    self._opaque_activated = self._opaque;
    self.initializePixels();
    @memset(self.raw_put_valid, false);
}

pub fn fillText(self: *Bitmap, text: []const u8, font: context2d.NativeFont, size: f64, x: f64, y: f64, max_width: ?f64, fill: color.RGBA) bool {
    if (self.pixels.len == 0 or text.len == 0) return false;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(size)) return false;
    if (max_width) |limit| if (!std.math.isFinite(limit) or limit <= 0) return false;
    self.activateOpaque();
    const drawn = lp_font_draw_utf8(self.pixels.ptr, self.pixels.len, self.width, self.height, text.ptr, text.len, font.family.ptr, font.family.len, size, font.bold, font.italic, x, y, max_width orelse 0, fill.r, fill.g, fill.b, fill.a) != 0;
    if (drawn) self.invalidateRawBounds(0, 0, @floatFromInt(self.width), @floatFromInt(self.height));
    return drawn;
}

fn premultiply(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u32, channel) * alpha + 127) / 255);
}

/// Skia's ARM64 `rgbA_to_RGBA` path simulates its raster pipeline in float32,
/// then rounds to nearest even. Keep the stages separate: algebraically
/// equivalent integer division differs at some half-way byte values.
pub fn unpremultiply(channel: u8, alpha: u8) u8 {
    if (alpha == 0) return 0;
    const one_over_255: f32 = 1.0 / 255.0;
    const normalized_alpha: f32 = @as(f32, @floatFromInt(alpha)) * one_over_255;
    const reciprocal_alpha: f32 = 1.0 / normalized_alpha;
    const normalized_channel: f32 = @as(f32, @floatFromInt(channel)) * one_over_255;
    const answer: f32 = @min(255.0, (normalized_channel * reciprocal_alpha) * 255.0);
    const lower: f32 = @floor(answer);
    const integer: u32 = @intFromFloat(lower);
    const fraction = answer - lower;
    return @intCast(integer + @intFromBool(fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)));
}

pub fn read(self: *const Bitmap, sx: i64, sy: i64, sw: u32, sh: u32, out: []u8) void {
    std.debug.assert(out.len == @as(usize, sw) * @as(usize, sh) * 4);
    if (self.pixels.len == 0) return;

    for (0..sh) |row| {
        const y = sy + @as(i64, @intCast(row));
        if (y < 0 or y >= self.height) continue;
        for (0..sw) |column| {
            const x = sx + @as(i64, @intCast(column));
            if (x < 0 or x >= self.width) continue;
            const src = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
            const dst = (row * @as(usize, sw) + column) * 4;
            if (self.raw_put_valid.len != 0 and self.raw_put_valid[src / 4]) {
                @memcpy(out[dst..][0..4], self.raw_put_pixels[src..][0..4]);
                continue;
            }
            const alpha = self.pixels[src + 3];
            for (0..3) |channel| {
                out[dst + channel] = unpremultiply(self.pixels[src + channel], alpha);
            }
            out[dst + 3] = alpha;
        }
    }
}

pub fn write(
    self: *Bitmap,
    data: []const u8,
    source_width: u32,
    source_height: u32,
    dx: i32,
    dy: i32,
    dirty_x: i32,
    dirty_y: i32,
    dirty_width: i32,
    dirty_height: i32,
    arena: std.mem.Allocator,
) !void {
    if (self.pixels.len == 0) return;
    std.debug.assert(data.len == @as(usize, source_width) * @as(usize, source_height) * 4);

    const dirty_x_end = @as(i64, dirty_x) + dirty_width;
    const dirty_y_end = @as(i64, dirty_y) + dirty_height;
    const x0 = @max(@as(i64, 0), @min(@as(i64, dirty_x), dirty_x_end));
    const y0 = @max(@as(i64, 0), @min(@as(i64, dirty_y), dirty_y_end));
    const x1 = @min(@as(i64, source_width), @max(@as(i64, dirty_x), dirty_x_end));
    const y1 = @min(@as(i64, source_height), @max(@as(i64, dirty_y), dirty_y_end));
    if (x1 <= x0 or y1 <= y0) return;

    self.activateOpaque();
    if (self._preserve_raw_put and self.raw_put_valid.len == 0) {
        self.raw_put_pixels = try arena.alloc(u8, self.pixels.len);
        self.raw_put_valid = try arena.alloc(bool, self.pixels.len / 4);
        @memset(self.raw_put_valid, false);
    }

    var y = y0;
    while (y < y1) : (y += 1) {
        const target_y = @as(i64, dy) + y;
        if (target_y < 0 or target_y >= self.height) continue;
        var x = x0;
        while (x < x1) : (x += 1) {
            const target_x = @as(i64, dx) + x;
            if (target_x < 0 or target_x >= self.width) continue;
            const src = (@as(usize, @intCast(y)) * source_width + @as(usize, @intCast(x))) * 4;
            const dst = (@as(usize, @intCast(target_y)) * self.width + @as(usize, @intCast(target_x))) * 4;
            const alpha = data[src + 3];
            if (self.raw_put_valid.len != 0) {
                @memcpy(self.raw_put_pixels[dst..][0..4], data[src..][0..4]);
                self.raw_put_valid[dst / 4] = true;
            }
            for (0..3) |channel| {
                self.pixels[dst + channel] = if (self._put_unpremultiplied) data[src + channel] else premultiply(data[src + channel], alpha);
            }
            self.pixels[dst + 3] = alpha;
        }
    }
}

/// Draw an untransformed rectangle into premultiplied storage. Chrome's
/// software and default Graphite canvas contexts use different AA paths.
pub fn rect(self: *Bitmap, x: f64, y: f64, width: f64, height: f64, rgba: ?color.RGBA, software_raster: bool) void {
    if (self.pixels.len == 0) return;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(width) or !std.math.isFinite(height)) return;
    const x_end = x + width;
    const y_end = y + height;
    if (!std.math.isFinite(x_end) or !std.math.isFinite(y_end)) return;
    const left = @min(x, x_end);
    const top = @min(y, y_end);
    const right = @max(x, x_end);
    const bottom = @max(y, y_end);
    if (left == right or top == bottom) return;
    self.activateOpaque();
    if (software_raster) {
        if (rgba == null) {
            // Chrome's software clearRect uses pixel-center coverage without
            // antialiasing, unlike fillRect's coverage rasterizer.
            const x0: usize = @intFromFloat(@max(0.0, @min(@floor(left), @as(f64, @floatFromInt(self.width)))));
            const y0: usize = @intFromFloat(@max(0.0, @min(@floor(top), @as(f64, @floatFromInt(self.height)))));
            const x1: usize = @intFromFloat(@max(0.0, @min(@ceil(right), @as(f64, @floatFromInt(self.width)))));
            const y1: usize = @intFromFloat(@max(0.0, @min(@ceil(bottom), @as(f64, @floatFromInt(self.height)))));
            for (y0..y1) |row| {
                const center_y = @as(f64, @floatFromInt(row)) + 0.5;
                if (center_y < top or center_y >= bottom) continue;
                for (x0..x1) |column| {
                    const center_x = @as(f64, @floatFromInt(column)) + 0.5;
                    if (center_x < left or center_x >= right) continue;
                    const dst = (row * self.width + column) * 4;
                    self.clearPixel(dst);
                }
            }
            return;
        }
        const source = rgba.?;
        self.invalidateRawBounds(left, top, right, bottom);
        _ = lp_canvas_rect(
            self.pixels.ptr,
            self.pixels.len,
            self.width,
            self.height,
            @floatCast(left),
            @floatCast(top),
            @floatCast(right - left),
            @floatCast(bottom - top),
            source.r,
            source.g,
            source.b,
            source.a,
        );
        return;
    }
    if (left != @trunc(left) or top != @trunc(top) or right != @trunc(right) or bottom != @trunc(bottom)) {
        if (rgba) |source| self.graphiteFillRect(left, top, right, bottom, source);
        return;
    }
    const x0: usize = @intFromFloat(@max(0.0, @min(left, @as(f64, @floatFromInt(self.width)))));
    const y0: usize = @intFromFloat(@max(0.0, @min(top, @as(f64, @floatFromInt(self.height)))));
    const x1: usize = @intFromFloat(@max(0.0, @min(right, @as(f64, @floatFromInt(self.width)))));
    const y1: usize = @intFromFloat(@max(0.0, @min(bottom, @as(f64, @floatFromInt(self.height)))));
    if (x0 >= x1 or y0 >= y1) return;

    self.invalidateRawBounds(left, top, right, bottom);

    for (y0..y1) |row| {
        for (x0..x1) |column| {
            const dst = (row * self.width + column) * 4;
            if (rgba) |source| {
                const inverse = @as(u32, 255) - source.a;
                const channels = [3]u8{ source.r, source.g, source.b };
                for (channels, 0..) |channel, i| {
                    const src = premultiply(channel, source.a);
                    self.pixels[dst + i] = @intCast(@as(u32, src) + (@as(u32, self.pixels[dst + i]) * inverse + 127) / 255);
                }
                self.pixels[dst + 3] = @intCast(@as(u32, source.a) + (@as(u32, self.pixels[dst + 3]) * inverse + 127) / 255);
            } else {
                self.clearPixel(dst);
            }
        }
    }
}

fn graphiteFillRect(self: *Bitmap, left: f64, top: f64, right: f64, bottom: f64, source: color.RGBA) void {
    const x0: usize = @intFromFloat(@max(0.0, @min(@floor(left - 1.0), @as(f64, @floatFromInt(self.width)))));
    const y0: usize = @intFromFloat(@max(0.0, @min(@floor(top - 1.0), @as(f64, @floatFromInt(self.height)))));
    const x1: usize = @intFromFloat(@max(0.0, @min(@ceil(right + 1.0), @as(f64, @floatFromInt(self.width)))));
    const y1: usize = @intFromFloat(@max(0.0, @min(@ceil(bottom + 1.0), @as(f64, @floatFromInt(self.height)))));
    if (x0 >= x1 or y0 >= y1) return;

    self.invalidateRawBounds(@as(f64, @floatFromInt(x0)), @as(f64, @floatFromInt(y0)), @as(f64, @floatFromInt(x1)), @as(f64, @floatFromInt(y1)));
    const shape = GraphiteRect.init(left, top, right, bottom);
    for (y0..y1) |row| {
        for (x0..x1) |column| {
            const coverage = shape.coverage(@as(f64, @floatFromInt(column)) + 0.5, @as(f64, @floatFromInt(row)) + 0.5);
            if (coverage == 0) continue;
            const alpha = @as(f64, @floatFromInt(source.a)) * @as(f64, @floatFromInt(coverage)) / (255.0 * 255.0);
            const inverse = 1.0 - alpha;
            const dst = (row * self.width + column) * 4;
            const channels = [3]u8{ source.r, source.g, source.b };
            for (channels, 0..) |channel, i| {
                // Graphite composites premultiplied source and destination
                // before quantizing the destination surface. Rounding either
                // contribution first can move low-alpha edge colors by many
                // bytes after unpremultiplication.
                const blended = @as(f64, @floatFromInt(channel)) * alpha +
                    @as(f64, @floatFromInt(self.pixels[dst + i])) * inverse;
                self.pixels[dst + i] = @intFromFloat(@floor(blended + 0.5));
            }
            const blended_alpha = 255.0 * alpha + @as(f64, @floatFromInt(self.pixels[dst + 3])) * inverse;
            self.pixels[dst + 3] = @intFromFloat(@floor(blended_alpha + 0.5));
        }
    }
}

/// Encode the current dimensions and pixels, including a transparent canvas
/// that has not been painted yet. Callers handle the spec's zero-size `data:,`
/// case before calling this.
pub fn png(self: *Bitmap, width: u32, height: u32, pixel_arena: std.mem.Allocator, output_arena: std.mem.Allocator) ![]const u8 {
    try self.ensure(width, height, pixel_arena);
    const straight_pixels = try output_arena.alloc(u8, self.pixels.len);
    self.read(0, 0, width, height, straight_pixels);
    return encodeRGBA(width, height, straight_pixels, output_arena);
}

/// Encode straight, top-down RGBA bytes. WebGL readback and Canvas 2D use
/// different storage conventions, but share Chrome-compatible PNG encoding.
pub fn encodeRGBA(width: u32, height: u32, straight_pixels: []const u8, output_arena: std.mem.Allocator) ![]const u8 {
    const count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.OutOfMemory;
    const expected = std.math.mul(usize, count, 4) catch return error.OutOfMemory;
    std.debug.assert(straight_pixels.len == expected);
    var output: std.Io.Writer.Allocating = .init(output_arena);
    var sink = Sink{ .writer = &output.writer };
    const rc = lp_canvas_png(width, height, straight_pixels.ptr, straight_pixels.len, &sink, Sink.write);
    if (rc != 0) return error.CanvasPNGEncodeFailed;
    return output.written();
}

const Sink = struct {
    writer: *std.Io.Writer,

    fn write(ctx: *anyopaque, data: [*]const u8, len: usize) callconv(.c) bool {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.writer.writeAll(data[0..len]) catch return false;
        return true;
    }
};

extern "c" fn lp_canvas_rect(
    pixels: [*]u8,
    pixels_len: usize,
    canvas_width: u32,
    canvas_height: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
) i32;

extern "c" fn lp_font_draw_utf8(
    pixels: [*]u8,
    pixels_len: usize,
    canvas_width: u32,
    canvas_height: u32,
    text: [*]const u8,
    text_len: usize,
    family: [*]const u8,
    family_len: usize,
    size: f64,
    bold: c_int,
    italic: c_int,
    x: f64,
    y: f64,
    max_width: f64,
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
) c_int;

extern "c" fn lp_canvas_png(
    width: u32,
    height: u32,
    pixels: [*]const u8,
    pixels_len: usize,
    ctx: *anyopaque,
    write_callback: *const fn (ctx: *anyopaque, data: [*]const u8, len: usize) callconv(.c) bool,
) i32;

const testing = std.testing;
test "Bitmap: clipped ImageData round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bitmap: Bitmap = .{};
    try bitmap.ensure(2, 2, arena.allocator());

    const red = [_]u8{ 255, 0, 0, 255 };
    try bitmap.write(&red, 1, 1, 1, 1, 0, 0, 1, 1, arena.allocator());
    var out = [_]u8{0} ** 16;
    bitmap.read(0, 0, 2, 2, &out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 255 }, &out);

    try bitmap.ensure(1, 1, arena.allocator());
    var cleared = [_]u8{0} ** 4;
    bitmap.read(0, 0, 1, 1, &cleared);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &cleared);

    try bitmap.write(&red, 1, 1, 0, 0, 1, 1, -1, -1, arena.allocator());
    bitmap.read(0, 0, 1, 1, &cleared);
    try testing.expectEqualSlices(u8, &red, &cleared);
    bitmap.reset();
    bitmap.read(0, 0, 1, 1, &cleared);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &cleared);
}

test "Bitmap: headful Chrome premultiplied readback" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bitmap: Bitmap = .{};
    try bitmap.ensure(3, 1, arena.allocator());
    const input = [_]u8{ 127, 64, 32, 128, 22, 0, 0, 6, 64, 0, 0, 10 };
    try bitmap.write(&input, 3, 1, 0, 0, 0, 0, 3, 1, arena.allocator());
    var output = [_]u8{0} ** input.len;
    bitmap.read(0, 0, 3, 1, &output);
    try testing.expectEqualSlices(u8, &[_]u8{ 128, 64, 32, 128, 42, 0, 0, 6, 77, 0, 0, 10 }, &output);

    // Headful Chrome wrote a 256x256 ImageData grid containing every
    // (channel, alpha) byte pair and read back its red channel. This checksum
    // covers the full conversion table, not just the examples above.
    var fnv32: u32 = 2166136261;
    var sum: u64 = 0;
    for (0..256) |a| {
        for (0..256) |c| {
            const channel = unpremultiply(premultiply(@intCast(c), @intCast(a)), @intCast(a));
            fnv32 = (fnv32 ^ channel) *% 16777619;
            sum += channel;
        }
    }
    try testing.expectEqual(@as(u32, 0x23c0cf87), fnv32);
    try testing.expectEqual(@as(u64, 8323406), sum);
}

test "Bitmap: opaque putImageData preserves straight bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var bitmap: Bitmap = .{ ._opaque = true, ._preserve_raw_put = true };
    try bitmap.ensure(1, 1, alloc);
    const input = [_]u8{ 255, 0, 0, 0 };
    try bitmap.write(&input, 1, 1, 0, 0, 0, 0, 1, 1, alloc);
    var output = [_]u8{0} ** 4;
    bitmap.read(0, 0, 1, 1, &output);
    try testing.expectEqualSlices(u8, &input, &output);
    bitmap.rect(0, 0, 1, 1, null, false);
    bitmap.read(0, 0, 1, 1, &output);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, &output);
}

test "Bitmap: fractional default rect uses Graphite coverage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bitmap: Bitmap = .{};
    try bitmap.ensure(3, 3, arena.allocator());
    bitmap.rect(0, 0, 0.5, 0.5, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, false);
    var output = [_]u8{0} ** 36;
    bitmap.read(0, 0, 3, 3, &output);
    try testing.expectEqual(@as(u8, 96), output[3]);
    for (1..9) |pixel| try testing.expectEqual(@as(u8, 0), output[pixel * 4 + 3]);

    bitmap.reset();
    bitmap.rect(0, 0, 0.2, 0.2, .{ .r = 12, .g = 200, .b = 33, .a = 77 }, false);
    bitmap.read(0, 0, 3, 3, &output);
    try testing.expectEqualSlices(u8, &.{ 0, 219, 36, 7 }, output[0..4]);

    bitmap.reset();
    bitmap.rect(0, 0, 3, 3, .{ .r = 18, .g = 52, .b = 86, .a = 255 }, false);
    bitmap.rect(0, 0, 0.2, 0.2, .{ .r = 12, .g = 200, .b = 33, .a = 77 }, false);
    bitmap.read(0, 0, 3, 3, &output);
    try testing.expectEqualSlices(u8, &.{ 18, 56, 84, 255 }, output[0..4]);
}

test "Bitmap: headful Chrome PNG bytes for simple canvases" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var bitmap: Bitmap = .{};

    const transparent = try bitmap.png(1, 1, alloc, alloc);
    const encoder = std.base64.standard.Encoder;
    const transparent_b64 = try alloc.alloc(u8, encoder.calcSize(transparent.len));
    _ = encoder.encode(transparent_b64, transparent);
    try testing.expectEqualStrings(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4AWJiYGBgAAAAAP//XRcpzQAAAAZJREFUAwAADwADJDd96QAAAABJRU5ErkJggg==",
        transparent_b64,
    );

    const red = [_]u8{ 255, 0, 0, 255 };
    try bitmap.write(&red, 1, 1, 0, 0, 0, 0, 1, 1, alloc);
    const red_png = try bitmap.png(1, 1, alloc, alloc);
    const red_b64 = try alloc.alloc(u8, encoder.calcSize(red_png.len));
    _ = encoder.encode(red_b64, red_png);
    try testing.expectEqualStrings(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4AWL6z8DwHwAAAP//A3ONEwAAAAZJREFUAwAFCgIByRpMngAAAABJRU5ErkJggg==",
        red_b64,
    );

    const blank_ten = try bitmap.png(10, 10, alloc, alloc);
    const blank_ten_b64 = try alloc.alloc(u8, encoder.calcSize(blank_ten.len));
    _ = encoder.encode(blank_ten_b64, blank_ten);
    try testing.expectEqualStrings(
        "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAIElEQVR4AezQoQ0AAADCMML/R/MBQSA3PVVrjLFC/XkCAAD//3Nn3qIAAAAGSURBVAMAEzgAFbNrw9wAAAAASUVORK5CYII=",
        blank_ten_b64,
    );

    try bitmap.ensure(2, 2, alloc);
    const colors = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    try bitmap.write(&colors, 2, 2, 0, 0, 0, 0, 2, 2, alloc);
    const colors_png = try bitmap.png(2, 2, alloc, alloc);
    const colors_b64 = try alloc.alloc(u8, encoder.calcSize(colors_png.len));
    _ = encoder.encode(colors_b64, colors_png);
    try testing.expectEqualStrings(
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4AWL6z8DwHwSZGEEkw38GAAAAAP//4+5legAAAAZJREFUAwBBDwb/5c5bAAAAAABJRU5ErkJggg==",
        colors_b64,
    );

    try bitmap.ensure(1, 1, alloc);
    const translucent = [_]u8{ 127, 64, 32, 128 };
    try bitmap.write(&translucent, 1, 1, 0, 0, 0, 0, 1, 1, alloc);
    const translucent_png = try bitmap.png(1, 1, alloc, alloc);
    const translucent_b64 = try alloc.alloc(u8, encoder.calcSize(translucent_png.len));
    _ = encoder.encode(translucent_b64, translucent_png);
    try testing.expectEqualStrings(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4AWJqcFBoAAAAAP//VCI2UgAAAAZJREFUAwADjwFjgx6ZngAAAABJRU5ErkJggg==",
        translucent_b64,
    );
}
