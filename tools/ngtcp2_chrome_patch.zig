//! Adds Chromium's client-only QUIC transport-parameter behavior to ngtcp2:
//! the ORIG Google connection option, a reserved GREASE parameter, and
//! per-connection parameter-order randomization.
//!
//! Chromium's QUICHE source does all three before serializing the TLS
//! quic_transport_parameters extension. They are server-visible before HTTP
//! headers and distinguish stock ngtcp2 even when its parameter values match.
//!
//! Usage: ngtcp2_chrome_patch <src-lib-dir> <out-dir>

const std = @import("std");

const Patch = struct {
    find: []const u8,
    replace: []const u8,
    why: []const u8,
};

const patches = [_]Patch{
    .{
        .why = "derive per-connection transport-parameter randomness",
        .find =
        \\  ngtcp2_transport_params paramsbuf;
        \\
        \\  params = ngtcp2_transport_params_convert_to_latest(
        \\    &paramsbuf, transport_params_version, params);
        ,
        .replace =
        \\  ngtcp2_transport_params paramsbuf;
        \\  uint64_t lp_rand = UINT64_C(0x9e3779b97f4a7c15);
        \\  uint64_t lp_grease_id;
        \\  size_t lp_grease_len;
        \\  size_t lp_i;
        \\
        \\  params = ngtcp2_transport_params_convert_to_latest(
        \\    &paramsbuf, transport_params_version, params);
        \\
        \\  /* Chrome randomizes these per connection. The source CID is
        \\   * already random, so use it to seed a deterministic xorshift
        \\   * without adding a second RNG dependency to ngtcp2. */
        \\  if (params->initial_scid_present) {
        \\    for (lp_i = 0; lp_i < params->initial_scid.datalen; ++lp_i) {
        \\      lp_rand ^= params->initial_scid.data[lp_i];
        \\      lp_rand *= UINT64_C(0x100000001b3);
        \\    }
        \\  }
        \\  lp_rand ^= lp_rand << 13;
        \\  lp_rand ^= lp_rand >> 7;
        \\  lp_rand ^= lp_rand << 17;
        \\  lp_grease_id = lp_rand & ((UINT64_C(1) << 62) - 1);
        \\  lp_grease_id = (lp_grease_id / 31) * 31 + 27;
        \\  if (lp_grease_id >= (UINT64_C(1) << 62)) {
        \\    lp_grease_id -= 31;
        \\  }
        \\  lp_rand ^= lp_rand << 13;
        \\  lp_rand ^= lp_rand >> 7;
        \\  lp_rand ^= lp_rand << 17;
        \\  lp_grease_len = (size_t)(lp_rand & 15);
        ,
    },
    .{
        .why = "reserve ORIG and GREASE transport parameters",
        .find =
        \\  if (params->version_info_present) {
        \\    version_infolen =
        \\      sizeof(uint32_t) + params->version_info.available_versionslen;
        \\    len += ngtcp2_put_uvarintlen(NGTCP2_TRANSPORT_PARAM_VERSION_INFORMATION) +
        \\           ngtcp2_put_uvarintlen(version_infolen) + version_infolen;
        \\  }
        ,
        .replace =
        \\  if (params->version_info_present) {
        \\    version_infolen =
        \\      sizeof(uint32_t) + params->version_info.available_versionslen;
        \\    len += ngtcp2_put_uvarintlen(NGTCP2_TRANSPORT_PARAM_VERSION_INFORMATION) +
        \\           ngtcp2_put_uvarintlen(version_infolen) + version_infolen;
        \\  }
        \\
        \\  /* Chrome advertises ORIG on every client QUIC connection and one
        \\   * random reserved transport parameter (RFC 9000 section 18.1). */
        \\  len += ngtcp2_put_uvarintlen(UINT64_C(0x3128)) + 1 + 4;
        \\  len += ngtcp2_put_uvarintlen(lp_grease_id) +
        \\         ngtcp2_put_uvarintlen(lp_grease_len) + lp_grease_len;
        ,
    },
    .{
        .why = "emit and randomize Chrome transport parameters",
        .find =
        \\  assert((size_t)(p - dest) == len);
        \\
        \\  return (ngtcp2_ssize)len;
        ,
        .replace =
        \\  /* Google connection option ORIG, encoded as a QUIC tag. */
        \\  p = ngtcp2_put_uvarint(p, UINT64_C(0x3128));
        \\  p = ngtcp2_put_uvarint(p, 4);
        \\  p = ngtcp2_cpymem(p, (const uint8_t *)"ORIG", 4);
        \\
        \\  /* Random reserved transport parameter with random-looking bytes. */
        \\  p = ngtcp2_put_uvarint(p, lp_grease_id);
        \\  p = ngtcp2_put_uvarint(p, lp_grease_len);
        \\  for (lp_i = 0; lp_i < lp_grease_len; ++lp_i) {
        \\    lp_rand ^= lp_rand << 13;
        \\    lp_rand ^= lp_rand >> 7;
        \\    lp_rand ^= lp_rand << 17;
        \\    *p++ = (uint8_t)lp_rand;
        \\  }
        \\
        \\  assert((size_t)(p - dest) == len);
        \\
        \\  /* QUICHE shuffles the complete TLV list. Re-parse ngtcp2's valid
        \\   * output into segments and perform the same Fisher-Yates shape.
        \\   * Chrome client parameters are far below both conservative caps. */
        \\  if (len <= 512) {
        \\    struct lp_tp_segment {
        \\      size_t off;
        \\      size_t len;
        \\    } lp_segments[32], lp_swap;
        \\    uint8_t lp_tmp[512];
        \\    const uint8_t *lp_scan = dest;
        \\    size_t lp_nsegments = 0;
        \\    int lp_complete = 1;
        \\
        \\    while (lp_scan < p) {
        \\      const uint8_t *lp_start = lp_scan;
        \\      uint64_t lp_type, lp_value_len;
        \\      if (lp_nsegments == 32) {
        \\        lp_complete = 0;
        \\        break;
        \\      }
        \\      lp_scan = ngtcp2_get_uvarint(&lp_type, lp_scan);
        \\      lp_scan = ngtcp2_get_uvarint(&lp_value_len, lp_scan);
        \\      (void)lp_type;
        \\      if (lp_value_len > (uint64_t)(p - lp_scan)) {
        \\        lp_complete = 0;
        \\        break;
        \\      }
        \\      lp_scan += (size_t)lp_value_len;
        \\      lp_segments[lp_nsegments].off = (size_t)(lp_start - dest);
        \\      lp_segments[lp_nsegments].len = (size_t)(lp_scan - lp_start);
        \\      ++lp_nsegments;
        \\    }
        \\
        \\    if (lp_complete && lp_scan == p) {
        \\      size_t lp_out = 0;
        \\      for (lp_i = lp_nsegments; lp_i > 1; --lp_i) {
        \\        size_t lp_j;
        \\        lp_rand ^= lp_rand << 13;
        \\        lp_rand ^= lp_rand >> 7;
        \\        lp_rand ^= lp_rand << 17;
        \\        lp_j = (size_t)(lp_rand % lp_i);
        \\        lp_swap = lp_segments[lp_i - 1];
        \\        lp_segments[lp_i - 1] = lp_segments[lp_j];
        \\        lp_segments[lp_j] = lp_swap;
        \\      }
        \\      for (lp_i = 0; lp_i < lp_nsegments; ++lp_i) {
        \\        memcpy(lp_tmp + lp_out, dest + lp_segments[lp_i].off,
        \\               lp_segments[lp_i].len);
        \\        lp_out += lp_segments[lp_i].len;
        \\      }
        \\      assert(lp_out == len);
        \\      memcpy(dest, lp_tmp, len);
        \\    }
        \\  }
        \\
        \\  return (ngtcp2_ssize)len;
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
    _ = args.next();
    const src_dir_path = args.next() orelse return error.MissingSourceDir;
    const out_dir_path = args.next() orelse return error.MissingOutputDir;

    const cwd = std.Io.Dir.cwd();
    var src_dir = try cwd.openDir(io, src_dir_path, .{});
    defer src_dir.close(io);
    var out_dir = try cwd.openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    const file_name = "ngtcp2_transport_params.c";
    var current = try src_dir.readFileAlloc(io, file_name, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(current);

    for (patches) |patch| {
        const count = std.mem.count(u8, current, patch.find);
        if (count != 1) {
            std.debug.print(
                "ngtcp2_chrome_patch: anchor for \"{s}\" matched {d} times, expected 1.\n" ++
                    "The vendored ngtcp2 has moved; re-read the diff before bumping.\n",
                .{ patch.why, count },
            );
            return error.PatchAnchorNotFound;
        }
        const patched = try std.mem.replaceOwned(u8, gpa, current, patch.find, patch.replace);
        gpa.free(current);
        current = patched;
    }

    try out_dir.writeFile(io, .{ .sub_path = file_name, .data = current });
}
