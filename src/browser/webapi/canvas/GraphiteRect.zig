// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.

//! Identity-transform filled-rectangle coverage from Skia Graphite's
//! AnalyticRRectRenderStep. Chrome 151 on macOS uses GraphiteDawnMetal for
//! the default Canvas 2D context; the software context has a different path.
//! This reproduces the all-AA rect's mesh and coverage shader, not a sampled
//! lookup table. Metal interpolation/readback still differs by one byte for
//! some edge pixels in the measured Chrome reference grid.

const std = @import("std");
const GraphiteRect = @This();

const Vertex = struct {
    x: f64,
    y: f64,
    distances: [4]f64,
    full: f64,
};

const Point = struct { x: f64, y: f64 };

vertices: [36]Vertex,
scale: f64,
bounds: [4]f64,

const indices = [_]u8{
    0,  4,  1,  5,  2,  3,  5,
    9,  13, 10, 14, 11, 12, 14,
    18, 22, 19, 23, 20, 21, 23,
    27, 31, 28, 32, 29, 30, 32,
    0,  4,  4,  6,  5,  7,  13,
    15, 14, 16, 22, 24, 23, 25,
    31, 33, 32, 34, 4,  6,  6,
    8,  7,  7,  17, 15, 17, 16,
    16, 26, 24, 26, 25, 25, 35,
    33, 35, 34, 34, 8,  6,
};

pub fn init(left: f64, top: f64, right: f64, bottom: f64) GraphiteRect {
    const width = right - left;
    const height = bottom - top;
    const complex = @min(width, height) <= 2.0;
    const corners = [_]Point{
        .{ .x = left, .y = top },
        .{ .x = right, .y = top },
        .{ .x = right, .y = bottom },
        .{ .x = left, .y = bottom },
    };
    const x_axes = [_]Point{
        .{ .x = -1, .y = 0 }, .{ .x = 0, .y = -1 },
        .{ .x = 1, .y = 0 },  .{ .x = 0, .y = 1 },
    };
    const y_axes = [_]Point{
        .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 0 },
        .{ .x = 0, .y = 1 },  .{ .x = -1, .y = 0 },
    };
    const half_root_two = 0.7071067811865476;
    const normals = [_]Point{
        .{ .x = 1, .y = 0 },
        .{ .x = half_root_two, .y = half_root_two },
        .{ .x = half_root_two, .y = half_root_two },
        .{ .x = 0, .y = 1 },
    };
    var result: GraphiteRect = .{
        .vertices = undefined,
        .scale = @min(1.0, @min(width, height)),
        .bounds = .{ left, top, right, bottom },
    };
    for (corners, 0..) |corner, ci| {
        for (0..9) |vi| {
            const outer = vi < 4;
            const center = vi == 8;
            var px: f64 = undefined;
            var py: f64 = undefined;
            if (center or (vi >= 6 and complex)) {
                px = left + width / 2.0;
                py = top + height / 2.0;
            } else if (outer) {
                const normal = normals[vi];
                px = corner.x + x_axes[ci].x * normal.x + y_axes[ci].x * normal.y;
                py = corner.y + x_axes[ci].y * normal.x + y_axes[ci].y * normal.y;
            } else if (vi < 6) {
                px = corner.x;
                py = corner.y;
            } else {
                px = corner.x - x_axes[ci].x - y_axes[ci].x;
                py = corner.y - x_axes[ci].y - y_axes[ci].y;
            }
            const base_x = if (outer) corner.x else px;
            const base_y = if (outer) corner.y else py;
            const outset: f64 = if (outer) 1 else 0;
            result.vertices[ci * 9 + vi] = .{
                .x = px,
                .y = py,
                .distances = .{
                    base_x - left - outset,
                    base_y - top - outset,
                    right - base_x - outset,
                    bottom - base_y - outset,
                },
                .full = if (center) 1 else 0,
            };
        }
    }
    return result;
}

pub fn coverage(self: *const GraphiteRect, x: f64, y: f64) u8 {
    const left = self.bounds[0];
    const top = self.bounds[1];
    const right = self.bounds[2];
    const bottom = self.bounds[3];
    if (x < left - 1 or x > right + 1 or y < top - 1 or y > bottom + 1) return 0;
    if (x >= left + 1 and x <= right - 1 and y >= top + 1 and y <= bottom - 1) return 255;
    const bias = 1.0 - 0.5 * self.scale;
    var best: f64 = 0;
    for (2..indices.len) |i| {
        const a = self.vertices[indices[i - 2]];
        const b = self.vertices[indices[i - 1]];
        const c = self.vertices[indices[i]];
        const denominator = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
        if (@abs(denominator) < 1e-12) continue;
        const wa = ((b.y - c.y) * (x - c.x) + (c.x - b.x) * (y - c.y)) / denominator;
        const wb = ((c.y - a.y) * (x - c.x) + (a.x - c.x) * (y - c.y)) / denominator;
        const wc = 1.0 - wa - wb;
        if (wa < -1e-7 or wb < -1e-7 or wc < -1e-7) continue;
        const full = wa * a.full + wb * b.full + wc * c.full;
        var alpha: f64 = 1;
        if (full <= 0) {
            var min_dist = std.math.inf(f64);
            for (0..4) |edge| {
                min_dist = @min(min_dist, wa * a.distances[edge] + wb * b.distances[edge] + wc * c.distances[edge]);
            }
            alpha = std.math.clamp(self.scale * (min_dist + bias), 0, 1);
        }
        best = @max(best, alpha);
    }
    return @intFromFloat(@floor(best * 255.0 + 0.5));
}

test "GraphiteRect: headed Chrome 151 fractional alpha samples" {
    const cases = [_]struct { rect: [4]f64, pixel: [2]f64, expected: u8 }{
        .{ .rect = .{ 0, 0, 0.2, 0.2 }, .pixel = .{ 0.5, 0.5 }, .expected = 24 },
        .{ .rect = .{ 0, 0, 0.5, 0.5 }, .pixel = .{ 0.5, 0.5 }, .expected = 96 },
        .{ .rect = .{ 0, 0, 0.2, 1 }, .pixel = .{ 0.5, 1.5 }, .expected = 14 },
        .{ .rect = .{ 0.25, 0, 0.5, 1 }, .pixel = .{ 0.5, 0.5 }, .expected = 128 },
    };
    for (cases) |case| {
        const shape = GraphiteRect.init(case.rect[0], case.rect[1], case.rect[0] + case.rect[2], case.rect[1] + case.rect[3]);
        try std.testing.expectEqual(case.expected, shape.coverage(case.pixel[0], case.pixel[1]));
    }
    const large = GraphiteRect.init(0, 0, 10, 10);
    try std.testing.expectEqual(@as(u8, 255), large.coverage(5.5, 5.5));
    try std.testing.expectEqual(@as(u8, 0), large.coverage(11.5, 5.5));
}
