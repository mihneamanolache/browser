//! Rewrites curl's ngtcp2 client settings so the QUIC transport parameters
//! match Chrome on macOS instead of advertising curl's server-sized defaults.
//!
//! The values below come from Chrome's own stripped NetLog
//! QUIC_SESSION_TRANSPORT_PARAMETERS_SENT event. They are visible to the
//! server before HTTP/3 request headers or page JavaScript, so they are part
//! of the browser's network fingerprint.
//!
//! Usage: curl_quic_patch <src-vquic-dir> <out-dir>

const std = @import("std");

const find =
    \\  s->max_window = H3_CONN_WINDOW_SIZE_MAX;
    \\  s->max_stream_window = 0; /* disable ngtcp2 auto-tuning of window */
    \\  s->no_pmtud = FALSE;
    \\#ifdef NGTCP2_SETTINGS_V3
    \\  /* try ten times the ngtcp2 defaults here for problems with Caddy */
    \\  s->glitch_ratelim_burst = 1000 * 10;
    \\  s->glitch_ratelim_rate = 33 * 10;
    \\#endif
    \\  t->initial_max_data = s->max_window;
    \\  t->initial_max_stream_data_bidi_local = H3_STREAM_WINDOW_SIZE_INITIAL;
    \\  t->initial_max_stream_data_bidi_remote = H3_STREAM_WINDOW_SIZE_INITIAL;
    \\  t->initial_max_stream_data_uni = t->initial_max_data;
    \\  t->initial_max_streams_bidi = QUIC_MAX_STREAMS;
    \\  t->initial_max_streams_uni = QUIC_MAX_STREAMS;
    \\  t->max_idle_timeout = 0; /* no idle timeout from our side */
;

const replace =
    \\  /* lightpanda: Chrome 151 macOS client transport parameters. */
    \\  s->max_window = 15 * 1024 * 1024;
    \\  s->max_stream_window = 0; /* disable ngtcp2 auto-tuning of window */
    \\  s->no_pmtud = FALSE;
    \\#ifdef NGTCP2_SETTINGS_V3
    \\  /* try ten times the ngtcp2 defaults here for problems with Caddy */
    \\  s->glitch_ratelim_burst = 1000 * 10;
    \\  s->glitch_ratelim_rate = 33 * 10;
    \\#endif
    \\  t->max_idle_timeout = 30 * NGTCP2_SECONDS;
    \\  t->max_udp_payload_size = 1472;
    \\  t->initial_max_data = 15 * 1024 * 1024;
    \\  t->initial_max_stream_data_bidi_local = 6 * 1024 * 1024;
    \\  t->initial_max_stream_data_bidi_remote = 6 * 1024 * 1024;
    \\  t->initial_max_stream_data_uni = 6 * 1024 * 1024;
    \\  t->initial_max_streams_bidi = 100;
    \\  t->initial_max_streams_uni = 103;
    \\  t->max_datagram_frame_size = 65536;
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

    const file_name = "cf-ngtcp2-cmn.c";
    const current = try src_dir.readFileAlloc(io, file_name, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(current);

    const count = std.mem.count(u8, current, find);
    if (count != 1) {
        std.debug.print(
            "curl_quic_patch: anchor matched {d} times, expected 1.\n" ++
                "The vendored curl has moved; re-read the diff before bumping.\n",
            .{count},
        );
        return error.PatchAnchorNotFound;
    }

    const patched = try std.mem.replaceOwned(u8, gpa, current, find, replace);
    defer gpa.free(patched);
    try out_dir.writeFile(io, .{ .sub_path = file_name, .data = patched });
}
