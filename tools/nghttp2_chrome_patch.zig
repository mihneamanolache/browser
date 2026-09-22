//! Rewrites one nghttp2 source so request HEADERS frames carry Chrome's
//! priority block.
//!
//! Chrome opens every request stream with HEADERS flags 0x25 --
//! END_STREAM|END_HEADERS|PRIORITY -- followed by a five-byte block of
//! exclusive=1, stream dependency 0, weight 255 on the wire (256 in
//! nghttp2's 1..256 API). Stock nghttp2 sends flags 0x05 and no block:
//!
//!   chrome  flags=0x25  exclusive=1 dep=0 weight=255
//!   nghttp2 flags=0x05  (no priority block)
//!
//! WHY THIS IS NOT IN THE CURL PATCH
//!
//! curl does the right thing already: `h2_pri_spec()` builds a
//! `nghttp2_priority_spec` and hands it to `nghttp2_submit_request`. This
//! nghttp2 throws it away. RFC 7540 stream priorities were removed from the
//! submit API -- `nghttp2_submit_headers` opens with `(void)pri_spec;` and
//! `nghttp2_submit_priority` is a no-op `return 0;` -- so no argument curl
//! passes can reach the wire. Patching curl's spec is a silent no-op, which
//! is exactly how this was first mis-diagnosed.
//!
//! The *packer* is untouched, which is what makes this a three-line change:
//! `nghttp2_frame_pack_headers` still emits the block whenever
//! NGHTTP2_FLAG_PRIORITY is set, `nghttp2_frame_pack_priority_spec` still
//! writes the exclusive bit and `weight - 1`, and
//! `nghttp2_frame_headers_payload_nv_offset` still reserves the five bytes.
//! Only the submit path stopped setting the flag.
//!
//! WHY IT IS INVISIBLE TO THE AKAMAI FINGERPRINT
//!
//! That fingerprint's third field counts standalone PRIORITY *frames*, and
//! both Chrome and we send zero. The flag lives on the HEADERS frame, so a
//! matching Akamai hash says nothing about it. Measured by decoding raw
//! HEADERS frames from Chrome for Testing 151 and from us against a local
//! h2 server: SETTINGS matched, WINDOW_UPDATE matched, all 17 header names
//! and their order matched, and this differed.
//!
//! Restricted to NGHTTP2_HCAT_REQUEST so it only affects streams we open.
//! Trailers and pushed responses keep upstream behaviour, and no standalone
//! PRIORITY frame is introduced -- Chrome sends none either.
//!
//! Patching rather than vendoring: nghttp2_submit.c is ~800 lines and a
//! wholesale copy would freeze the rest at today's upstream. The anchor is
//! exact and `error.PatchAnchorNotFound` fails the build if nghttp2 moves,
//! which is the intended behaviour -- a bump should stop and make someone
//! re-read the diff rather than quietly drop the flag again.
//!
//! Usage: nghttp2_chrome_patch <nghttp2-lib-dir> <out-dir>

const std = @import("std");

const Patch = struct {
    /// Exact text to find. Must be unique in the file.
    find: []const u8,
    replace: []const u8,
    why: []const u8,
};

const file_name = "nghttp2_submit.c";

const patches = [_]Patch{
    .{
        .why = "request HEADERS carries Chrome's exclusive/weight-256 priority block",
        .find =
        \\  nghttp2_frame_headers_init(&frame->headers, flags_copy, stream_id, hcat, NULL,
        \\                             nva_copy, nvlen);
        ,
        .replace =
        \\  /* lightpanda: Chrome sets NGHTTP2_FLAG_PRIORITY on the HEADERS
        \\   * frame that opens a request stream, with an exclusive dependency
        \\   * on stream 0 at weight 256. nghttp2 dropped RFC 7540 priorities
        \\   * from its submit API but kept the packer, so setting the flag and
        \\   * supplying the spec here is enough to put it back on the wire.
        \\   * Request streams only. See tools/nghttp2_chrome_patch.zig. */
        \\  if (hcat == NGHTTP2_HCAT_REQUEST) {
        \\    nghttp2_priority_spec lp_chrome_pri;
        \\    nghttp2_priority_spec_init(&lp_chrome_pri, 0, 256, 1);
        \\    flags_copy = (uint8_t)(flags_copy | NGHTTP2_FLAG_PRIORITY);
        \\    nghttp2_frame_headers_init(&frame->headers, flags_copy, stream_id,
        \\                               hcat, &lp_chrome_pri, nva_copy, nvlen);
        \\  } else {
        \\    nghttp2_frame_headers_init(&frame->headers, flags_copy, stream_id,
        \\                               hcat, NULL, nva_copy, nvlen);
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

    var current = try src_dir.readFileAlloc(io, file_name, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(current);

    for (patches) |patch| {
        const count = std.mem.count(u8, current, patch.find);
        if (count != 1) {
            std.debug.print(
                "nghttp2_chrome_patch: {s}: anchor for \"{s}\" matched {d} times, expected 1.\n" ++
                    "The vendored nghttp2 has moved; re-read the diff before bumping.\n",
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
