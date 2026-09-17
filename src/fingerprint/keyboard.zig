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

//! What `navigator.keyboard.getLayoutMap()` reports, per physical layout.
//!
//! The map answers "which character does this physical key produce", for the
//! writing-system keys only — the alphanumeric block plus the punctuation
//! around it. Chrome leaves out the function row, the modifiers and the
//! numpad, because those do not move with the layout.
//!
//! This is real entropy: it is the only surface that distinguishes a French
//! keyboard from an American one, and a fingerprinter that reads it next to
//! `navigator.language` gets a free consistency check. A browser claiming
//! fr-FR and Europe/Paris while its keyboard is ANSI QWERTY has contradicted
//! itself, which is why the layout travels with the region.
//!
//! ADDING A LAYOUT: take the unshifted character of every key from a real
//! keyboard of that layout, in the order below. The order is the same across
//! layouts so they can be read side by side, and it is the order Chrome
//! iterates in.

const std = @import("std");

const machines = @import("machines.zig");

pub const Entry = struct {
    /// A `KeyboardEvent.code`, i.e. the physical key.
    code: []const u8,
    /// The character it produces unshifted, which is the map's value.
    key: []const u8,
};

/// The layout for the active region's keyboard.
pub fn layout(which: machines.Keyboard) []const Entry {
    return switch (which) {
        .qwerty => &qwerty,
        .qwerty_uk => &qwerty_uk,
        .qwertz => &qwertz,
        .azerty => &azerty,
    };
}

/// US ANSI. No IntlBackslash: the key does not exist on an ANSI board, and
/// Chrome omits absent keys rather than reporting them empty.
const qwerty = [_]Entry{
    .{ .code = "Backquote", .key = "`" },
    .{ .code = "Digit1", .key = "1" },
    .{ .code = "Digit2", .key = "2" },
    .{ .code = "Digit3", .key = "3" },
    .{ .code = "Digit4", .key = "4" },
    .{ .code = "Digit5", .key = "5" },
    .{ .code = "Digit6", .key = "6" },
    .{ .code = "Digit7", .key = "7" },
    .{ .code = "Digit8", .key = "8" },
    .{ .code = "Digit9", .key = "9" },
    .{ .code = "Digit0", .key = "0" },
    .{ .code = "Minus", .key = "-" },
    .{ .code = "Equal", .key = "=" },
    .{ .code = "KeyQ", .key = "q" },
    .{ .code = "KeyW", .key = "w" },
    .{ .code = "KeyE", .key = "e" },
    .{ .code = "KeyR", .key = "r" },
    .{ .code = "KeyT", .key = "t" },
    .{ .code = "KeyY", .key = "y" },
    .{ .code = "KeyU", .key = "u" },
    .{ .code = "KeyI", .key = "i" },
    .{ .code = "KeyO", .key = "o" },
    .{ .code = "KeyP", .key = "p" },
    .{ .code = "BracketLeft", .key = "[" },
    .{ .code = "BracketRight", .key = "]" },
    .{ .code = "Backslash", .key = "\\" },
    .{ .code = "KeyA", .key = "a" },
    .{ .code = "KeyS", .key = "s" },
    .{ .code = "KeyD", .key = "d" },
    .{ .code = "KeyF", .key = "f" },
    .{ .code = "KeyG", .key = "g" },
    .{ .code = "KeyH", .key = "h" },
    .{ .code = "KeyJ", .key = "j" },
    .{ .code = "KeyK", .key = "k" },
    .{ .code = "KeyL", .key = "l" },
    .{ .code = "Semicolon", .key = ";" },
    .{ .code = "Quote", .key = "'" },
    .{ .code = "KeyZ", .key = "z" },
    .{ .code = "KeyX", .key = "x" },
    .{ .code = "KeyC", .key = "c" },
    .{ .code = "KeyV", .key = "v" },
    .{ .code = "KeyB", .key = "b" },
    .{ .code = "KeyN", .key = "n" },
    .{ .code = "KeyM", .key = "m" },
    .{ .code = "Comma", .key = "," },
    .{ .code = "Period", .key = "." },
    .{ .code = "Slash", .key = "/" },
};

/// UK ISO. Same letters as ANSI, but the extra ISO key exists: Backslash
/// carries `#` and IntlBackslash carries `\`.
const qwerty_uk = [_]Entry{
    .{ .code = "Backquote", .key = "`" },
    .{ .code = "Digit1", .key = "1" },
    .{ .code = "Digit2", .key = "2" },
    .{ .code = "Digit3", .key = "3" },
    .{ .code = "Digit4", .key = "4" },
    .{ .code = "Digit5", .key = "5" },
    .{ .code = "Digit6", .key = "6" },
    .{ .code = "Digit7", .key = "7" },
    .{ .code = "Digit8", .key = "8" },
    .{ .code = "Digit9", .key = "9" },
    .{ .code = "Digit0", .key = "0" },
    .{ .code = "Minus", .key = "-" },
    .{ .code = "Equal", .key = "=" },
    .{ .code = "KeyQ", .key = "q" },
    .{ .code = "KeyW", .key = "w" },
    .{ .code = "KeyE", .key = "e" },
    .{ .code = "KeyR", .key = "r" },
    .{ .code = "KeyT", .key = "t" },
    .{ .code = "KeyY", .key = "y" },
    .{ .code = "KeyU", .key = "u" },
    .{ .code = "KeyI", .key = "i" },
    .{ .code = "KeyO", .key = "o" },
    .{ .code = "KeyP", .key = "p" },
    .{ .code = "BracketLeft", .key = "[" },
    .{ .code = "BracketRight", .key = "]" },
    .{ .code = "Backslash", .key = "#" },
    .{ .code = "KeyA", .key = "a" },
    .{ .code = "KeyS", .key = "s" },
    .{ .code = "KeyD", .key = "d" },
    .{ .code = "KeyF", .key = "f" },
    .{ .code = "KeyG", .key = "g" },
    .{ .code = "KeyH", .key = "h" },
    .{ .code = "KeyJ", .key = "j" },
    .{ .code = "KeyK", .key = "k" },
    .{ .code = "KeyL", .key = "l" },
    .{ .code = "Semicolon", .key = ";" },
    .{ .code = "Quote", .key = "'" },
    .{ .code = "IntlBackslash", .key = "\\" },
    .{ .code = "KeyZ", .key = "z" },
    .{ .code = "KeyX", .key = "x" },
    .{ .code = "KeyC", .key = "c" },
    .{ .code = "KeyV", .key = "v" },
    .{ .code = "KeyB", .key = "b" },
    .{ .code = "KeyN", .key = "n" },
    .{ .code = "KeyM", .key = "m" },
    .{ .code = "Comma", .key = "," },
    .{ .code = "Period", .key = "." },
    .{ .code = "Slash", .key = "/" },
};

/// German ISO. Y and Z swap, the umlauts take the punctuation keys, and
/// Minus/Equal carry ß and ´.
const qwertz = [_]Entry{
    .{ .code = "Backquote", .key = "^" },
    .{ .code = "Digit1", .key = "1" },
    .{ .code = "Digit2", .key = "2" },
    .{ .code = "Digit3", .key = "3" },
    .{ .code = "Digit4", .key = "4" },
    .{ .code = "Digit5", .key = "5" },
    .{ .code = "Digit6", .key = "6" },
    .{ .code = "Digit7", .key = "7" },
    .{ .code = "Digit8", .key = "8" },
    .{ .code = "Digit9", .key = "9" },
    .{ .code = "Digit0", .key = "0" },
    .{ .code = "Minus", .key = "ß" },
    .{ .code = "Equal", .key = "´" },
    .{ .code = "KeyQ", .key = "q" },
    .{ .code = "KeyW", .key = "w" },
    .{ .code = "KeyE", .key = "e" },
    .{ .code = "KeyR", .key = "r" },
    .{ .code = "KeyT", .key = "t" },
    .{ .code = "KeyY", .key = "z" },
    .{ .code = "KeyU", .key = "u" },
    .{ .code = "KeyI", .key = "i" },
    .{ .code = "KeyO", .key = "o" },
    .{ .code = "KeyP", .key = "p" },
    .{ .code = "BracketLeft", .key = "ü" },
    .{ .code = "BracketRight", .key = "+" },
    .{ .code = "Backslash", .key = "#" },
    .{ .code = "KeyA", .key = "a" },
    .{ .code = "KeyS", .key = "s" },
    .{ .code = "KeyD", .key = "d" },
    .{ .code = "KeyF", .key = "f" },
    .{ .code = "KeyG", .key = "g" },
    .{ .code = "KeyH", .key = "h" },
    .{ .code = "KeyJ", .key = "j" },
    .{ .code = "KeyK", .key = "k" },
    .{ .code = "KeyL", .key = "l" },
    .{ .code = "Semicolon", .key = "ö" },
    .{ .code = "Quote", .key = "ä" },
    .{ .code = "IntlBackslash", .key = "<" },
    .{ .code = "KeyZ", .key = "y" },
    .{ .code = "KeyX", .key = "x" },
    .{ .code = "KeyC", .key = "c" },
    .{ .code = "KeyV", .key = "v" },
    .{ .code = "KeyB", .key = "b" },
    .{ .code = "KeyN", .key = "n" },
    .{ .code = "KeyM", .key = "m" },
    .{ .code = "Comma", .key = "," },
    .{ .code = "Period", .key = "." },
    .{ .code = "Slash", .key = "-" },
};

/// French ISO. The whole top row is punctuation, A/Q and Z/W swap, and M
/// moves off the bottom row onto Semicolon.
const azerty = [_]Entry{
    .{ .code = "Backquote", .key = "²" },
    .{ .code = "Digit1", .key = "&" },
    .{ .code = "Digit2", .key = "é" },
    .{ .code = "Digit3", .key = "\"" },
    .{ .code = "Digit4", .key = "'" },
    .{ .code = "Digit5", .key = "(" },
    .{ .code = "Digit6", .key = "-" },
    .{ .code = "Digit7", .key = "è" },
    .{ .code = "Digit8", .key = "_" },
    .{ .code = "Digit9", .key = "ç" },
    .{ .code = "Digit0", .key = "à" },
    .{ .code = "Minus", .key = ")" },
    .{ .code = "Equal", .key = "=" },
    .{ .code = "KeyQ", .key = "a" },
    .{ .code = "KeyW", .key = "z" },
    .{ .code = "KeyE", .key = "e" },
    .{ .code = "KeyR", .key = "r" },
    .{ .code = "KeyT", .key = "t" },
    .{ .code = "KeyY", .key = "y" },
    .{ .code = "KeyU", .key = "u" },
    .{ .code = "KeyI", .key = "i" },
    .{ .code = "KeyO", .key = "o" },
    .{ .code = "KeyP", .key = "p" },
    .{ .code = "BracketLeft", .key = "^" },
    .{ .code = "BracketRight", .key = "$" },
    .{ .code = "Backslash", .key = "*" },
    .{ .code = "KeyA", .key = "q" },
    .{ .code = "KeyS", .key = "s" },
    .{ .code = "KeyD", .key = "d" },
    .{ .code = "KeyF", .key = "f" },
    .{ .code = "KeyG", .key = "g" },
    .{ .code = "KeyH", .key = "h" },
    .{ .code = "KeyJ", .key = "j" },
    .{ .code = "KeyK", .key = "k" },
    .{ .code = "KeyL", .key = "l" },
    .{ .code = "Semicolon", .key = "m" },
    .{ .code = "Quote", .key = "ù" },
    .{ .code = "IntlBackslash", .key = "<" },
    .{ .code = "KeyZ", .key = "w" },
    .{ .code = "KeyX", .key = "x" },
    .{ .code = "KeyC", .key = "c" },
    .{ .code = "KeyV", .key = "v" },
    .{ .code = "KeyB", .key = "b" },
    .{ .code = "KeyN", .key = "n" },
    .{ .code = "KeyM", .key = "," },
    .{ .code = "Comma", .key = ";" },
    .{ .code = "Period", .key = ":" },
    .{ .code = "Slash", .key = "!" },
};

const testing = std.testing;

fn find(entries: []const Entry, code: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.code, code)) return e.key;
    }
    return null;
}

test "keyboard: every layout is a map, not a list with duplicates" {
    for (std.enums.values(machines.Keyboard)) |which| {
        const entries = layout(which);
        try testing.expect(entries.len >= 47);
        for (entries, 0..) |a, i| {
            try testing.expect(a.code.len > 0);
            try testing.expect(a.key.len > 0);
            for (entries[i + 1 ..]) |b| {
                try testing.expect(!std.mem.eql(u8, a.code, b.code));
            }
        }
        // The letter keys are always present, whatever they produce.
        try testing.expect(find(entries, "KeyQ") != null);
        try testing.expect(find(entries, "KeyM") != null);
    }
}

test "keyboard: the layouts differ where real keyboards differ" {
    // QWERTZ is named for the swap; QWERTY is not.
    try testing.expectEqualStrings("y", find(&qwerty, "KeyY").?);
    try testing.expectEqualStrings("z", find(&qwertz, "KeyY").?);
    try testing.expectEqualStrings("y", find(&qwertz, "KeyZ").?);

    // AZERTY moves A/Q, Z/W and M.
    try testing.expectEqualStrings("a", find(&azerty, "KeyQ").?);
    try testing.expectEqualStrings("q", find(&azerty, "KeyA").?);
    try testing.expectEqualStrings("m", find(&azerty, "Semicolon").?);

    // The ISO key exists on every European board and on none of the US ones.
    try testing.expectEqual(@as(?[]const u8, null), find(&qwerty, "IntlBackslash"));
    try testing.expectEqualStrings("\\", find(&qwerty_uk, "IntlBackslash").?);
    try testing.expectEqualStrings("#", find(&qwerty_uk, "Backslash").?);
}
