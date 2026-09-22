//! Rewrites curl's nghttp3 client settings to match Chrome's HTTP/3 SETTINGS.
//!
//! Usage: curl_h3_patch <src-vquic-dir> <out-dir>

const std = @import("std");

const find =
    \\  nghttp3_settings_default(&ctx->h3settings);
;

const replace =
    \\  nghttp3_settings_default(&ctx->h3settings);
    \\  /* lightpanda: Chrome 151 HTTP/3 SETTINGS from a stripped NetLog. */
    \\  ctx->h3settings.max_field_section_size = 256 * 1024;
    \\  ctx->h3settings.qpack_max_dtable_capacity = 64 * 1024;
    \\  ctx->h3settings.qpack_encoder_max_dtable_capacity = 64 * 1024;
    \\  ctx->h3settings.qpack_blocked_streams = 100;
    \\  ctx->h3settings.h3_datagram = 1;
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

    for ([_][]const u8{ "cf-ngtcp2.c", "cf-ngtcp2-proxy.c" }) |file_name| {
        const current = try src_dir.readFileAlloc(io, file_name, gpa, .limited(4 * 1024 * 1024));
        defer gpa.free(current);

        const count = std.mem.count(u8, current, find);
        if (count != 1) {
            std.debug.print(
                "curl_h3_patch: {s} anchor matched {d} times, expected 1.\n" ++
                    "The vendored curl has moved; re-read the diff before bumping.\n",
                .{ file_name, count },
            );
            return error.PatchAnchorNotFound;
        }

        const patched = try std.mem.replaceOwned(u8, gpa, current, find, replace);
        defer gpa.free(patched);
        try out_dir.writeFile(io, .{ .sub_path = file_name, .data = patched });
    }
}
