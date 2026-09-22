//! Rewrites two libcurl sources so the HTTP/2 connection preface matches
//! Chrome's instead of nghttp2's defaults.
//!
//! This exists because the H2 layer is fingerprinted as aggressively as TLS
//! is. The "Akamai fingerprint" is the SETTINGS frame, the initial
//! WINDOW_UPDATE and the pseudo-header order, concatenated. Stock libcurl
//! produces a shape no browser produces:
//!
//!   chrome  1:65536;2:0;4:6291456;6:262144 | 15663105 | 0 | m,a,s,p
//!   curl    3:100;4:65536;2:0              |  1048510465 | 0 | m,s,a,p
//!
//! That fingerprint is necessary but not sufficient: it says nothing about
//! the PRIORITY flag on the request HEADERS frame, which Chrome sets and
//! curl does not. That one cannot be fixed here -- curl does build a
//! priority spec, but this nghttp2 discards it ((void)pri_spec) -- so it
//! lives in tools/nghttp2_chrome_patch.zig instead.
//!
//! None of it is reachable through libcurl's API: the SETTINGS list is built
//! in C, the window size is a #define, and the pseudo-header order is the
//! literal statement order of four function calls. So the sources are
//! patched at build time.
//!
//! Patching rather than vendoring: these two files are ~7500 lines together
//! and copying them wholesale would bury a 30-line change and silently
//! freeze the rest at today's upstream. Every replacement below is anchored
//! on an exact string and `error.PatchAnchorNotFound` fails the build if
//! upstream moves, which is the intended behaviour — a curl bump should stop
//! and make someone re-read the diff, not quietly emit curl's fingerprint
//! again.
//!
//! Usage: curl_h2_patch <src-lib-dir> <out-dir>

const std = @import("std");

const Patch = struct {
    file: []const u8,
    /// Exact text to find. Must be unique in the file.
    find: []const u8,
    replace: []const u8,
    why: []const u8,
};

const patches = [_]Patch{
    // 1. SETTINGS frame.
    //
    // Chrome sends HEADER_TABLE_SIZE, ENABLE_PUSH, INITIAL_WINDOW_SIZE and
    // MAX_HEADER_LIST_SIZE, in that order, and does not send
    // MAX_CONCURRENT_STREAMS at all. curl sends MAX_CONCURRENT_STREAMS first
    // and never sends the other two, so both the identifiers and their order
    // differ.
    .{
        .file = "http2.c",
        .why = "SETTINGS frame contents and order",
        .find =
        \\  iv[0].settings_id = NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
        \\  iv[0].value = Curl_multi_max_concurrent_streams(data->multi);
        \\
        \\  iv[1].settings_id = NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE;
        \\  iv[1].value = cf_h2_initial_win_size(data);
        \\  if(ctx)
        \\    ctx->initial_win_size = iv[1].value;
        \\  iv[2].settings_id = NGHTTP2_SETTINGS_ENABLE_PUSH;
        \\  iv[2].value = !!data->multi->push_cb;
        \\
        \\  return 3;
        ,
        .replace =
        \\  /* lightpanda: Chrome's SETTINGS, in Chrome's order. See
        \\   * tools/curl_h2_patch.zig. MAX_CONCURRENT_STREAMS is deliberately
        \\   * absent: Chrome does not send it, and its presence alone is a
        \\   * non-browser signal. */
        \\  (void)Curl_multi_max_concurrent_streams;
        \\  iv[0].settings_id = NGHTTP2_SETTINGS_HEADER_TABLE_SIZE;
        \\  iv[0].value = 65536;
        \\
        \\  iv[1].settings_id = NGHTTP2_SETTINGS_ENABLE_PUSH;
        \\  iv[1].value = !!data->multi->push_cb;
        \\
        \\  iv[2].settings_id = NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE;
        \\  iv[2].value = 6291456;
        \\  if(ctx)
        \\    ctx->initial_win_size = iv[2].value;
        \\
        \\  iv[3].settings_id = NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE;
        \\  iv[3].value = 262144;
        \\
        \\  (void)cf_h2_initial_win_size;
        \\  return 4;
        ,
    },

    // The iv[] arrays are sized by this constant, and we now write four
    // entries. Raised rather than replaced so every declaration site follows.
    .{
        .file = "http2.c",
        .why = "SETTINGS array must hold four entries",
        .find = "#define H2_SETTINGS_IV_LEN 3",
        .replace = "#define H2_SETTINGS_IV_LEN 4 /* lightpanda: Chrome sends four */",
    },

    // curl re-evaluates the per-transfer receive window immediately before
    // submitting the first request. Its default (65536) differs from the
    // Chrome-sized value installed above, so stock curl emits a second
    // SETTINGS_INITIAL_WINDOW_SIZE frame after the Chrome-shaped preface.
    // Keep the connection value stable: Chrome sends this setting once.
    .{
        .file = "http2.c",
        .why = "suppress curl's post-preface window-size SETTINGS drift",
        .find =
        \\  initial_win_size = cf_h2_initial_win_size(data);
        \\  if(initial_win_size != ctx->initial_win_size) {
        \\    result = cf_h2_update_settings(ctx, initial_win_size);
        \\    if(result)
        \\      goto out;
        \\  }
        ,
        .replace =
        \\  /* lightpanda: the initial SETTINGS already advertises Chrome's
        \\   * 6291456-byte stream window. Do not follow it with curl's
        \\   * 65536-byte correction on the first request. */
        \\  initial_win_size = ctx->initial_win_size;
        \\  (void)initial_win_size;
        ,
    },

    // 2. Initial connection WINDOW_UPDATE.
    //
    // curl asks for 100 * 10MB and the increment lands at 1048510465.
    // Chrome's connection window is 15728640 (15MB), which after the 65535
    // default leaves an increment of 15663105 — the number that appears in
    // the fingerprint.
    .{
        .file = "http2.c",
        .why = "connection WINDOW_UPDATE increment",
        .find = "#define HTTP2_HUGE_WINDOW_SIZE (100 * H2_STREAM_WINDOW_SIZE_MAX)",
        .replace =
        \\/* lightpanda: Chrome's 15MB connection window, so the initial
        \\ * WINDOW_UPDATE increment is 15663105 (15728640 - 65535). */
        \\#define HTTP2_HUGE_WINDOW_SIZE (15 * 1024 * 1024)
        ,
    },

    // 3. Pseudo-header order.
    //
    // RFC 9113 lets these appear in any order, so curl's m,s,a,p is legal —
    // but every Chromium build emits m,a,s,p, and the difference is one
    // field in the fingerprint. Swapping the two blocks is the whole fix.
    .{
        .file = "http.c",
        .why = "pseudo-header order (:authority before :scheme)",
        .find =
        \\  if(!result && scheme) {
        \\    result = Curl_dynhds_add(h2_headers, STRCONST(HTTP_PSEUDO_SCHEME),
        \\                             scheme, strlen(scheme));
        \\  }
        \\  if(!result && authority) {
        \\    result = Curl_dynhds_add(h2_headers, STRCONST(HTTP_PSEUDO_AUTHORITY),
        \\                             authority, strlen(authority));
        \\  }
        ,
        .replace =
        \\  /* lightpanda: Chrome orders these :method, :authority, :scheme,
        \\   * :path. Any order is legal per RFC 9113, but only this one is
        \\   * what a browser sends. */
        \\  if(!result && authority) {
        \\    result = Curl_dynhds_add(h2_headers, STRCONST(HTTP_PSEUDO_AUTHORITY),
        \\                             authority, strlen(authority));
        \\  }
        \\  if(!result && scheme) {
        \\    result = Curl_dynhds_add(h2_headers, STRCONST(HTTP_PSEUDO_SCHEME),
        \\                             scheme, strlen(scheme));
        \\  }
        ,
    },
};

var io_threaded: std.Io.Threaded = .init_single_threaded;
const io: std.Io = io_threaded.io();

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]

    const src_dir_path = args.next() orelse return error.MissingSourceDir;
    const out_dir_path = args.next() orelse return error.MissingOutputDir;

    const cwd = std.Io.Dir.cwd();
    var src_dir = try cwd.openDir(io, src_dir_path, .{});
    defer src_dir.close(io);
    // The build system creates the output directory (addOutputDirectoryArg).
    var out_dir = try cwd.openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    // Each file is read once, then every patch for it is applied in turn.
    for ([_][]const u8{ "http2.c", "http.c" }) |file_name| {
        var current = try src_dir.readFileAlloc(io, file_name, gpa, .limited(8 * 1024 * 1024));
        defer gpa.free(current);

        for (patches) |patch| {
            if (!std.mem.eql(u8, patch.file, file_name)) continue;

            const count = std.mem.count(u8, current, patch.find);
            if (count != 1) {
                std.debug.print(
                    "curl_h2_patch: {s}: anchor for \"{s}\" matched {d} times, expected 1.\n" ++
                        "The vendored curl has moved; re-read the diff before bumping.\n",
                    .{ file_name, patch.why, count },
                );
                return error.PatchAnchorNotFound;
            }

            const patched = try std.mem.replaceOwned(u8, gpa, current, patch.find, patch.replace);
            gpa.free(current);
            current = patched;
        }

        try out_dir.writeFile(io, .{ .sub_path = file_name, .data = current });
    }
}
