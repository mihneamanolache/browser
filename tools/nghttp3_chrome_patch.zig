//! Adds Chrome's randomized reserved HTTP/3 SETTINGS entry to nghttp3.
//!
//! RFC 9114 reserves settings identifiers of the form 0x1f * N + 0x21.
//! Chromium emits one such randomized identifier and value per connection.
//!
//! Usage: nghttp3_chrome_patch <src-lib-dir> <out-dir>

const std = @import("std");

const find =
    \\  if (local_settings->enable_connect_protocol) {
    \\    ents[fr.niv] = (nghttp3_settings_entry){
    \\      .id = NGHTTP3_SETTINGS_ID_ENABLE_CONNECT_PROTOCOL,
    \\      .value = 1,
    \\    };
    \\
    \\    ++fr.niv;
    \\  }
    \\
    \\  len = nghttp3_frame_write_settings_len(&payloadlen, &fr);
;

const replace =
    \\  if (local_settings->enable_connect_protocol) {
    \\    ents[fr.niv] = (nghttp3_settings_entry){
    \\      .id = NGHTTP3_SETTINGS_ID_ENABLE_CONNECT_PROTOCOL,
    \\      .value = 1,
    \\    };
    \\
    \\    ++fr.niv;
    \\  }
    \\
    \\  /* Chrome sends one per-connection reserved setting. The allocation
    \\   * address supplies connection-local entropy without changing nghttp3's
    \\   * public API; xorshift diffusion avoids exposing pointer structure. */
    \\  {
    \\    uint64_t lp_rand = (uint64_t)(uintptr_t)stream ^
    \\                       UINT64_C(0x9e3779b97f4a7c15);
    \\    lp_rand ^= lp_rand << 13;
    \\    lp_rand ^= lp_rand >> 7;
    \\    lp_rand ^= lp_rand << 17;
    \\    ents[fr.niv].id = UINT64_C(0x1f) *
    \\                      (UINT64_C(0x40000000) + (lp_rand & 0xffffffff)) +
    \\                      UINT64_C(0x21);
    \\    lp_rand ^= lp_rand << 13;
    \\    lp_rand ^= lp_rand >> 7;
    \\    lp_rand ^= lp_rand << 17;
    \\    ents[fr.niv].value = lp_rand & 0xffffffff;
    \\    ++fr.niv;
    \\  }
    \\
    \\  len = nghttp3_frame_write_settings_len(&payloadlen, &fr);
;

var io_threaded: std.Io.Threaded = .init_single_threaded;
const io: std.Io = io_threaded.io();

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const src_dir_path = args.next() orelse return error.MissingSourceDir;
    const out_dir_path = args.next() orelse return error.MissingOutputDir;

    const cwd = std.Io.Dir.cwd();
    var src_dir = try cwd.openDir(io, src_dir_path, .{});
    defer src_dir.close(io);
    var out_dir = try cwd.openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    const file_name = "nghttp3_stream.c";
    const current = try src_dir.readFileAlloc(io, file_name, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(current);

    const count = std.mem.count(u8, current, find);
    if (count != 1) {
        std.debug.print(
            "nghttp3_chrome_patch: anchor matched {d} times, expected 1.\n" ++
                "The vendored nghttp3 has moved; re-read the diff before bumping.\n",
            .{count},
        );
        return error.PatchAnchorNotFound;
    }

    const patched = try std.mem.replaceOwned(u8, gpa, current, find, replace);
    defer gpa.free(patched);
    try out_dir.writeFile(io, .{ .sub_path = file_name, .data = patched });
}
