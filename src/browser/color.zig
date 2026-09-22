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
const Io = std.Io;

fn isHexColor(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }

    if (value[0] != '#') {
        return false;
    }

    const hex_part = value[1..];
    switch (hex_part.len) {
        3, 4, 6, 8 => for (hex_part) |c| if (!std.ascii.isHex(c)) return false,
        else => return false,
    }

    return true;
}

pub const RGBA = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    /// Opaque by default.
    a: u8 = std.math.maxInt(u8),

    pub const Named = struct {
        // Basic colors (CSS Level 1)
        pub const black: RGBA = .init(0, 0, 0, 1);
        pub const silver: RGBA = .init(192, 192, 192, 1);
        pub const gray: RGBA = .init(128, 128, 128, 1);
        pub const white: RGBA = .init(255, 255, 255, 1);
        pub const maroon: RGBA = .init(128, 0, 0, 1);
        pub const red: RGBA = .init(255, 0, 0, 1);
        pub const purple: RGBA = .init(128, 0, 128, 1);
        pub const fuchsia: RGBA = .init(255, 0, 255, 1);
        pub const green: RGBA = .init(0, 128, 0, 1);
        pub const lime: RGBA = .init(0, 255, 0, 1);
        pub const olive: RGBA = .init(128, 128, 0, 1);
        pub const yellow: RGBA = .init(255, 255, 0, 1);
        pub const navy: RGBA = .init(0, 0, 128, 1);
        pub const blue: RGBA = .init(0, 0, 255, 1);
        pub const teal: RGBA = .init(0, 128, 128, 1);
        pub const aqua: RGBA = .init(0, 255, 255, 1);

        // Extended colors (CSS Level 2+)
        pub const aliceblue: RGBA = .init(240, 248, 255, 1);
        pub const antiquewhite: RGBA = .init(250, 235, 215, 1);
        pub const aquamarine: RGBA = .init(127, 255, 212, 1);
        pub const azure: RGBA = .init(240, 255, 255, 1);
        pub const beige: RGBA = .init(245, 245, 220, 1);
        pub const bisque: RGBA = .init(255, 228, 196, 1);
        pub const blanchedalmond: RGBA = .init(255, 235, 205, 1);
        pub const blueviolet: RGBA = .init(138, 43, 226, 1);
        pub const brown: RGBA = .init(165, 42, 42, 1);
        pub const burlywood: RGBA = .init(222, 184, 135, 1);
        pub const cadetblue: RGBA = .init(95, 158, 160, 1);
        pub const chartreuse: RGBA = .init(127, 255, 0, 1);
        pub const chocolate: RGBA = .init(210, 105, 30, 1);
        pub const coral: RGBA = .init(255, 127, 80, 1);
        pub const cornflowerblue: RGBA = .init(100, 149, 237, 1);
        pub const cornsilk: RGBA = .init(255, 248, 220, 1);
        pub const crimson: RGBA = .init(220, 20, 60, 1);
        pub const cyan: RGBA = .init(0, 255, 255, 1); // Synonym of aqua
        pub const darkblue: RGBA = .init(0, 0, 139, 1);
        pub const darkcyan: RGBA = .init(0, 139, 139, 1);
        pub const darkgoldenrod: RGBA = .init(184, 134, 11, 1);
        pub const darkgray: RGBA = .init(169, 169, 169, 1);
        pub const darkgreen: RGBA = .init(0, 100, 0, 1);
        pub const darkgrey: RGBA = .init(169, 169, 169, 1); // Synonym of darkgray
        pub const darkkhaki: RGBA = .init(189, 183, 107, 1);
        pub const darkmagenta: RGBA = .init(139, 0, 139, 1);
        pub const darkolivegreen: RGBA = .init(85, 107, 47, 1);
        pub const darkorange: RGBA = .init(255, 140, 0, 1);
        pub const darkorchid: RGBA = .init(153, 50, 204, 1);
        pub const darkred: RGBA = .init(139, 0, 0, 1);
        pub const darksalmon: RGBA = .init(233, 150, 122, 1);
        pub const darkseagreen: RGBA = .init(143, 188, 143, 1);
        pub const darkslateblue: RGBA = .init(72, 61, 139, 1);
        pub const darkslategray: RGBA = .init(47, 79, 79, 1);
        pub const darkslategrey: RGBA = .init(47, 79, 79, 1); // Synonym of darkslategray
        pub const darkturquoise: RGBA = .init(0, 206, 209, 1);
        pub const darkviolet: RGBA = .init(148, 0, 211, 1);
        pub const deeppink: RGBA = .init(255, 20, 147, 1);
        pub const deepskyblue: RGBA = .init(0, 191, 255, 1);
        pub const dimgray: RGBA = .init(105, 105, 105, 1);
        pub const dimgrey: RGBA = .init(105, 105, 105, 1); // Synonym of dimgray
        pub const dodgerblue: RGBA = .init(30, 144, 255, 1);
        pub const firebrick: RGBA = .init(178, 34, 34, 1);
        pub const floralwhite: RGBA = .init(255, 250, 240, 1);
        pub const forestgreen: RGBA = .init(34, 139, 34, 1);
        pub const gainsboro: RGBA = .init(220, 220, 220, 1);
        pub const ghostwhite: RGBA = .init(248, 248, 255, 1);
        pub const gold: RGBA = .init(255, 215, 0, 1);
        pub const goldenrod: RGBA = .init(218, 165, 32, 1);
        pub const greenyellow: RGBA = .init(173, 255, 47, 1);
        pub const grey: RGBA = .init(128, 128, 128, 1); // Synonym of gray
        pub const honeydew: RGBA = .init(240, 255, 240, 1);
        pub const hotpink: RGBA = .init(255, 105, 180, 1);
        pub const indianred: RGBA = .init(205, 92, 92, 1);
        pub const indigo: RGBA = .init(75, 0, 130, 1);
        pub const ivory: RGBA = .init(255, 255, 240, 1);
        pub const khaki: RGBA = .init(240, 230, 140, 1);
        pub const lavender: RGBA = .init(230, 230, 250, 1);
        pub const lavenderblush: RGBA = .init(255, 240, 245, 1);
        pub const lawngreen: RGBA = .init(124, 252, 0, 1);
        pub const lemonchiffon: RGBA = .init(255, 250, 205, 1);
        pub const lightblue: RGBA = .init(173, 216, 230, 1);
        pub const lightcoral: RGBA = .init(240, 128, 128, 1);
        pub const lightcyan: RGBA = .init(224, 255, 255, 1);
        pub const lightgoldenrodyellow: RGBA = .init(250, 250, 210, 1);
        pub const lightgray: RGBA = .init(211, 211, 211, 1);
        pub const lightgreen: RGBA = .init(144, 238, 144, 1);
        pub const lightgrey: RGBA = .init(211, 211, 211, 1); // Synonym of lightgray
        pub const lightpink: RGBA = .init(255, 182, 193, 1);
        pub const lightsalmon: RGBA = .init(255, 160, 122, 1);
        pub const lightseagreen: RGBA = .init(32, 178, 170, 1);
        pub const lightskyblue: RGBA = .init(135, 206, 250, 1);
        pub const lightslategray: RGBA = .init(119, 136, 153, 1);
        pub const lightslategrey: RGBA = .init(119, 136, 153, 1); // Synonym of lightslategray
        pub const lightsteelblue: RGBA = .init(176, 196, 222, 1);
        pub const lightyellow: RGBA = .init(255, 255, 224, 1);
        pub const limegreen: RGBA = .init(50, 205, 50, 1);
        pub const linen: RGBA = .init(250, 240, 230, 1);
        pub const magenta: RGBA = .init(255, 0, 255, 1); // Synonym of fuchsia
        pub const mediumaquamarine: RGBA = .init(102, 205, 170, 1);
        pub const mediumblue: RGBA = .init(0, 0, 205, 1);
        pub const mediumorchid: RGBA = .init(186, 85, 211, 1);
        pub const mediumpurple: RGBA = .init(147, 112, 219, 1);
        pub const mediumseagreen: RGBA = .init(60, 179, 113, 1);
        pub const mediumslateblue: RGBA = .init(123, 104, 238, 1);
        pub const mediumspringgreen: RGBA = .init(0, 250, 154, 1);
        pub const mediumturquoise: RGBA = .init(72, 209, 204, 1);
        pub const mediumvioletred: RGBA = .init(199, 21, 133, 1);
        pub const midnightblue: RGBA = .init(25, 25, 112, 1);
        pub const mintcream: RGBA = .init(245, 255, 250, 1);
        pub const mistyrose: RGBA = .init(255, 228, 225, 1);
        pub const moccasin: RGBA = .init(255, 228, 181, 1);
        pub const navajowhite: RGBA = .init(255, 222, 173, 1);
        pub const oldlace: RGBA = .init(253, 245, 230, 1);
        pub const olivedrab: RGBA = .init(107, 142, 35, 1);
        pub const orange: RGBA = .init(255, 165, 0, 1);
        pub const orangered: RGBA = .init(255, 69, 0, 1);
        pub const orchid: RGBA = .init(218, 112, 214, 1);
        pub const palegoldenrod: RGBA = .init(238, 232, 170, 1);
        pub const palegreen: RGBA = .init(152, 251, 152, 1);
        pub const paleturquoise: RGBA = .init(175, 238, 238, 1);
        pub const palevioletred: RGBA = .init(219, 112, 147, 1);
        pub const papayawhip: RGBA = .init(255, 239, 213, 1);
        pub const peachpuff: RGBA = .init(255, 218, 185, 1);
        pub const peru: RGBA = .init(205, 133, 63, 1);
        pub const pink: RGBA = .init(255, 192, 203, 1);
        pub const plum: RGBA = .init(221, 160, 221, 1);
        pub const powderblue: RGBA = .init(176, 224, 230, 1);
        pub const rebeccapurple: RGBA = .init(102, 51, 153, 1);
        pub const rosybrown: RGBA = .init(188, 143, 143, 1);
        pub const royalblue: RGBA = .init(65, 105, 225, 1);
        pub const saddlebrown: RGBA = .init(139, 69, 19, 1);
        pub const salmon: RGBA = .init(250, 128, 114, 1);
        pub const sandybrown: RGBA = .init(244, 164, 96, 1);
        pub const seagreen: RGBA = .init(46, 139, 87, 1);
        pub const seashell: RGBA = .init(255, 245, 238, 1);
        pub const sienna: RGBA = .init(160, 82, 45, 1);
        pub const skyblue: RGBA = .init(135, 206, 235, 1);
        pub const slateblue: RGBA = .init(106, 90, 205, 1);
        pub const slategray: RGBA = .init(112, 128, 144, 1);
        pub const slategrey: RGBA = .init(112, 128, 144, 1); // Synonym of slategray
        pub const snow: RGBA = .init(255, 250, 250, 1);
        pub const springgreen: RGBA = .init(0, 255, 127, 1);
        pub const steelblue: RGBA = .init(70, 130, 180, 1);
        pub const tan: RGBA = .init(210, 180, 140, 1);
        pub const thistle: RGBA = .init(216, 191, 216, 1);
        pub const tomato: RGBA = .init(255, 99, 71, 1);
        pub const transparent: RGBA = .init(0, 0, 0, 0);
        pub const turquoise: RGBA = .init(64, 224, 208, 1);
        pub const violet: RGBA = .init(238, 130, 238, 1);
        pub const wheat: RGBA = .init(245, 222, 179, 1);
        pub const whitesmoke: RGBA = .init(245, 245, 245, 1);
        pub const yellowgreen: RGBA = .init(154, 205, 50, 1);
    };

    pub fn init(r: u8, g: u8, b: u8, a: f32) RGBA {
        const clamped = std.math.clamp(a, 0, 1);
        return .{ .r = r, .g = g, .b = b, .a = @trunc(clamped * 255) };
    }

    /// Finds a color by its name.
    pub fn find(name: []const u8) ?RGBA {
        const match = std.meta.stringToEnum(std.meta.DeclEnum(Named), name) orelse return null;

        return switch (match) {
            inline else => |comptime_enum| @field(Named, @tagName(comptime_enum)),
        };
    }

    /// Parses the common sRGB CSS color forms used by canvas styles.
    pub fn parse(input: []const u8) !RGBA {
        const value = std.mem.trim(u8, input, " \t\n\r");
        if (parseFunctional(value)) |functional| return functional;
        if (!isHexColor(value)) {
            // Try named colors.
            return find(value) orelse return error.Invalid;
        }

        const slice = value[1..];
        switch (slice.len) {
            // This means the digit for a color is repeated.
            // Given HEX is #f0c, its interpreted the same as #FF00CC.
            3 => {
                const r = try std.fmt.parseInt(u8, &.{ slice[0], slice[0] }, 16);
                const g = try std.fmt.parseInt(u8, &.{ slice[1], slice[1] }, 16);
                const b = try std.fmt.parseInt(u8, &.{ slice[2], slice[2] }, 16);
                return .{ .r = r, .g = g, .b = b, .a = 255 };
            },
            4 => {
                const r = try std.fmt.parseInt(u8, &.{ slice[0], slice[0] }, 16);
                const g = try std.fmt.parseInt(u8, &.{ slice[1], slice[1] }, 16);
                const b = try std.fmt.parseInt(u8, &.{ slice[2], slice[2] }, 16);
                const a = try std.fmt.parseInt(u8, &.{ slice[3], slice[3] }, 16);
                return .{ .r = r, .g = g, .b = b, .a = a };
            },
            // Regular HEX format.
            6 => {
                const r = try std.fmt.parseInt(u8, slice[0..2], 16);
                const g = try std.fmt.parseInt(u8, slice[2..4], 16);
                const b = try std.fmt.parseInt(u8, slice[4..6], 16);
                return .{ .r = r, .g = g, .b = b, .a = 255 };
            },
            8 => {
                const r = try std.fmt.parseInt(u8, slice[0..2], 16);
                const g = try std.fmt.parseInt(u8, slice[2..4], 16);
                const b = try std.fmt.parseInt(u8, slice[4..6], 16);
                const a = try std.fmt.parseInt(u8, slice[6..8], 16);
                return .{ .r = r, .g = g, .b = b, .a = a };
            },
            else => return error.Invalid,
        }
    }

    /// By default, browsers prefer lowercase formatting.
    const format_upper = false;

    /// Formats the `Color` according to web expectations.
    /// If color is opaque, HEX is preferred; RGBA otherwise.
    pub fn format(self: *const RGBA, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.isOpaque()) {
            // Convert RGB to HEX.
            // https://gristle.tripod.com/hexconv.html
            // Hexadecimal characters up to 15.
            const char: []const u8 = "0123456789" ++ if (format_upper) "ABCDEF" else "abcdef";
            // This variant always prefers 6 digit format, +1 is for hash char.
            const buffer = [7]u8{
                '#',
                char[self.r >> 4],
                char[self.r & 15],
                char[self.g >> 4],
                char[self.g & 15],
                char[self.b >> 4],
                char[self.b & 15],
            };

            return writer.writeAll(&buffer);
        }

        // CSSOM exposes the shortest decimal that maps back to this alpha
        // byte, rather than simply rounding a/255 to a fixed precision.
        try writer.print("rgba({d}, {d}, {d}, ", .{ self.r, self.g, self.b });
        const alpha: u32 = self.a;
        for ([_]u32{ 1, 10, 100, 1000 }) |scale| {
            const numerator = (alpha * scale + 127) / 255;
            if ((numerator * 255 + scale / 2) / scale != alpha) continue;
            if (scale == 1) {
                try writer.print("{d})", .{numerator});
            } else {
                const places: usize = if (scale == 10) 1 else if (scale == 100) 2 else 3;
                var digits: [3]u8 = undefined;
                var remaining = numerator;
                var i: usize = places;
                while (i > 0) {
                    i -= 1;
                    digits[i] = @as(u8, @intCast(remaining % 10)) + '0';
                    remaining /= 10;
                }
                try writer.writeAll("0.");
                try writer.writeAll(digits[0..places]);
                try writer.writeAll(")");
            }
            return;
        }
        unreachable;
    }

    /// Returns true if `Color` is opaque.
    inline fn isOpaque(self: *const RGBA) bool {
        return self.a == std.math.maxInt(u8);
    }
};

fn parseFunctional(value: []const u8) ?RGBA {
    const rgba = std.ascii.startsWithIgnoreCase(value, "rgba(");
    const rgb = std.ascii.startsWithIgnoreCase(value, "rgb(");
    if (!rgba and !rgb) return null;
    if (value.len == 0 or value[value.len - 1] != ')') return null;
    const inner = std.mem.trim(u8, value[if (rgba) 5 else 4 .. value.len - 1], " \t\n\r");
    var parts: [4][]const u8 = undefined;
    var count: usize = 0;
    if (std.mem.indexOfScalar(u8, inner, ',')) |_| {
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            if (count == parts.len) return null;
            parts[count] = std.mem.trim(u8, part, " \t\n\r");
            count += 1;
        }
        if (count != (if (rgba) @as(usize, 4) else 3)) return null;
    } else {
        var it = std.mem.tokenizeAny(u8, inner, " \t\n\r/");
        while (it.next()) |part| {
            if (count == parts.len) return null;
            parts[count] = part;
            count += 1;
        }
        if (count != 3 and count != 4) return null;
        // A four-component modern form requires the alpha slash.
        if (count == 4 and std.mem.indexOfScalar(u8, inner, '/') == null) return null;
    }
    return .{
        .r = parseChannel(parts[0]) orelse return null,
        .g = parseChannel(parts[1]) orelse return null,
        .b = parseChannel(parts[2]) orelse return null,
        .a = if (count == 4) parseAlpha(parts[3]) orelse return null else 255,
    };
}

fn parseChannel(input: []const u8) ?u8 {
    const percent = std.mem.endsWith(u8, input, "%");
    const number = std.fmt.parseFloat(f64, if (percent) input[0 .. input.len - 1] else input) catch return null;
    if (!std.math.isFinite(number)) return null;
    return @intFromFloat(@round(std.math.clamp(if (percent) number * 255.0 / 100.0 else number, 0.0, 255.0)));
}

fn parseAlpha(input: []const u8) ?u8 {
    const percent = std.mem.endsWith(u8, input, "%");
    const number = std.fmt.parseFloat(f64, if (percent) input[0 .. input.len - 1] else input) catch return null;
    if (!std.math.isFinite(number)) return null;
    return @intFromFloat(@round(std.math.clamp(if (percent) number / 100.0 else number, 0.0, 1.0) * 255.0));
}

test "RGBA: Chrome canvas functional colors and alpha serialization" {
    const testing = std.testing;
    const inputs = [_]struct { input: []const u8, expected: []const u8, alpha: u8 }{
        .{ .input = "rgb(127,64,32)", .expected = "#7f4020", .alpha = 255 },
        .{ .input = "rgba(127,64,32,0.5)", .expected = "rgba(127, 64, 32, 0.5)", .alpha = 128 },
        .{ .input = "rgba(127,64,32,0.267)", .expected = "rgba(127, 64, 32, 0.267)", .alpha = 68 },
        .{ .input = "rgba(127,64,32,0.1)", .expected = "rgba(127, 64, 32, 0.1)", .alpha = 26 },
        .{ .input = "rgb(50%,25%,12.5%)", .expected = "#804020", .alpha = 255 },
        .{ .input = "rgb(127 64 32 / 50%)", .expected = "rgba(127, 64, 32, 0.5)", .alpha = 128 },
        .{ .input = "#11223344", .expected = "rgba(17, 34, 51, 0.267)", .alpha = 68 },
        .{ .input = "#1234", .expected = "rgba(17, 34, 51, 0.267)", .alpha = 68 },
    };
    for (inputs) |case| {
        const value = try RGBA.parse(case.input);
        try testing.expectEqual(case.alpha, value.a);
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try value.format(&output.writer);
        try testing.expectEqualStrings(case.expected, output.written());
    }

    // Headed Chrome 151: concatenate the exposed fillStyle for every alpha
    // byte of #000000AA, with ';' separators, and hash the ASCII bytes.
    var hash: u32 = 2166136261;
    var length: usize = 0;
    for (0..256) |alpha| {
        const value: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = @intCast(alpha) };
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try value.format(&output.writer);
        for (output.written()) |byte| {
            hash = (hash ^ byte) *% 16777619;
        }
        hash = (hash ^ ';') *% 16777619;
        length += output.written().len + 1;
    }
    try testing.expectEqual(@as(usize, 5251), length);
    try testing.expectEqual(@as(u32, 0x1704d708), hash);
}
