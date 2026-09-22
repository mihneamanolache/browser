//! Rewrites BoringSSL's extension table so the ClientHello offers the two
//! extensions Chrome 151 always sends and this BoringSSL never does.
//!
//! Measured 2026-09-22 by capturing raw ClientHello bytes from both clients
//! through the same loopback CONNECT proxy to www.google.com. Across 20
//! Chrome handshakes the non-GREASE extension set differed from ours by
//! exactly two entries, both carrying a two-byte empty list:
//!
//!   0xca34  trust_anchors            0000   20/20 Chrome handshakes
//!   0x12e0  (unregistered)           0000   20/20 Chrome handshakes
//!
//! Nothing else differed: same 16 ciphers, same remaining 16 extensions,
//! same groups, same ALPS codepoint, same signature_algorithms (the ML-DSA
//! entries from boringssl_sigalg_patch.zig are already on the wire). The
//! visible effect is JA4's third field, the extension count: `t13d1516h2`
//! where Chrome is `t13d1518h2`. JA4 sorts extensions, so this is a genuine
//! difference in the set and not the per-connection order permutation that
//! both clients already do.
//!
//! WHY THIS IS SAFE
//!
//! Both extensions are emitted with an empty body, byte-for-byte what Chrome
//! sends, so no server sees a value it would not already see from Chrome.
//! TLS requires unknown ClientHello extensions to be ignored, and a server
//! that does understand these gets the same empty list Chrome offers. The
//! ServerHello side is handled by `forbid_parse_serverhello`, matching every
//! other client-only extension in the table: a server that echoes one back
//! unsolicited gets a clean unsupported_extension alert rather than being
//! silently accepted.
//!
//! trust_anchors (draft-ietf-tls-trust-anchor-ids) is implemented here
//! already; it is simply gated behind a configured list that libcurl gives us
//! no way to set. Patch 1 makes the empty list the default rather than an
//! omission. 0x12e0 is not in this BoringSSL under any name -- it is a
//! Chromium codepoint newer than the vendored commit -- so patch 2 adds a
//! minimal client-only entry for it. Its semantics are unknown to us beyond
//! the empty payload; we deliberately send exactly Chrome's bytes and nothing
//! more.
//!
//! The table's `sent` bitmask is a uint32_t and BoringSSL static_asserts
//! kNumExtensions against it. The table has 28 entries; this adds a 29th.
//! Another three and that assert fires -- which is the correct failure mode.
//!
//! Patching rather than vendoring: extensions.cc is ~4000 lines and copying
//! it wholesale would bury a small change and freeze the rest at today's
//! upstream. Every replacement is anchored on an exact string and
//! `error.PatchAnchorNotFound` fails the build if BoringSSL moves, which is
//! the intended behaviour -- a bump should stop and make someone re-read the
//! diff, not quietly emit the wrong JA4 again.
//!
//! Usage: boringssl_clienthello_ext_patch <boringssl-ssl-dir> <out-dir>

const std = @import("std");

const Patch = struct {
    /// Exact text to find. Must be unique in the file.
    find: []const u8,
    replace: []const u8,
    why: []const u8,
};

const file_name = "extensions.cc";

const patches = [_]Patch{
    // 1. trust_anchors: send the empty list instead of omitting the
    //    extension. A configured list still wins, so the upstream behaviour
    //    is preserved for any caller that sets one.
    .{
        .why = "trust_anchors offered with an empty list by default",
        .find =
        \\  if (!hs->config->requested_trust_anchors.has_value()) {
        \\    return true;
        \\  }
        \\  // TODO(crbug.com/398275713): What should this send in ClientHelloOuter?
        \\  CBB contents, list;
        \\  if (!CBB_add_u16(out_compressible, TLSEXT_TYPE_trust_anchors) ||  //
        \\      !CBB_add_u16_length_prefixed(out_compressible, &contents) ||  //
        \\      !CBB_add_u16_length_prefixed(&contents, &list) ||             //
        \\      !CBB_add_bytes(&list, hs->config->requested_trust_anchors->data(),
        \\                     hs->config->requested_trust_anchors->size()) ||
        \\      !CBB_flush(out_compressible)) {
        \\    return false;
        \\  }
        \\  return true;
        ,
        .replace =
        \\  // lightpanda: Chrome 151 offers this on every ClientHello with an
        \\  // empty TrustAnchorIdList (payload 0000). Omitting it when no list
        \\  // is configured costs one extension in the JA4 count. A configured
        \\  // list still takes precedence.
        \\  // TODO(crbug.com/398275713): What should this send in ClientHelloOuter?
        \\  CBB contents, list;
        \\  if (!CBB_add_u16(out_compressible, TLSEXT_TYPE_trust_anchors) ||  //
        \\      !CBB_add_u16_length_prefixed(out_compressible, &contents) ||  //
        \\      !CBB_add_u16_length_prefixed(&contents, &list)) {
        \\    return false;
        \\  }
        \\  if (hs->config->requested_trust_anchors.has_value() &&
        \\      !hs->config->requested_trust_anchors->empty() &&
        \\      !CBB_add_bytes(&list, hs->config->requested_trust_anchors->data(),
        \\                     hs->config->requested_trust_anchors->size())) {
        \\    return false;
        \\  }
        \\  if (!CBB_flush(out_compressible)) {
        \\    return false;
        \\  }
        \\  return true;
        ,
    },

    // 2. The unregistered 0x12e0 extension. Defined immediately above the
    //    table so the function is in scope, and added as the last entry.
    .{
        .why = "0x12e0 client-only extension definition and table entry",
        .find =
        \\    {
        \\        TLSEXT_TYPE_trust_anchors,
        \\        ext_trust_anchors_add_clienthello,
        \\        ext_trust_anchors_parse_serverhello,
        \\        ext_trust_anchors_parse_clienthello,
        \\        ext_trust_anchors_add_serverhello,
        \\    },
        \\};
        ,
        .replace =
        \\    {
        \\        TLSEXT_TYPE_trust_anchors,
        \\        ext_trust_anchors_add_clienthello,
        \\        ext_trust_anchors_parse_serverhello,
        \\        ext_trust_anchors_parse_clienthello,
        \\        ext_trust_anchors_add_serverhello,
        \\    },
        \\    {
        \\        // lightpanda: unregistered codepoint Chrome 151 sends on every
        \\        // ClientHello with an empty two-byte list. Not present in this
        \\        // BoringSSL under any name. Client-only: a server echoing it
        \\        // back unsolicited is an error, as for every other such
        \\        // extension here. See tools/boringssl_clienthello_ext_patch.zig.
        \\        TLSEXT_TYPE_lp_chrome_unregistered_12e0,
        \\        ext_lp_12e0_add_clienthello,
        \\        ext_lp_12e0_parse_serverhello,
        \\        ignore_parse_clienthello,
        \\        dont_add_serverhello,
        \\    },
        \\};
        ,
    },

    // The definition itself, anchored on the trust_anchors ClientHello
    // emitter that precedes the table.
    .{
        .why = "0x12e0 emitter function",
        .find = "static bool ext_trust_anchors_add_clienthello(const SSL_HANDSHAKE *hs, CBB *out,",
        .replace =
        \\// lightpanda: see tools/boringssl_clienthello_ext_patch.zig.
        \\#define TLSEXT_TYPE_lp_chrome_unregistered_12e0 0x12e0
        \\
        \\static bool ext_lp_12e0_add_clienthello(const SSL_HANDSHAKE *hs, CBB *out,
        \\                                        CBB *out_compressible,
        \\                                        ssl_client_hello_type_t type) {
        \\  CBB contents, list;
        \\  if (!CBB_add_u16(out_compressible,
        \\                   TLSEXT_TYPE_lp_chrome_unregistered_12e0) ||     //
        \\      !CBB_add_u16_length_prefixed(out_compressible, &contents) || //
        \\      !CBB_add_u16_length_prefixed(&contents, &list) ||            //
        \\      !CBB_flush(out_compressible)) {
        \\    return false;
        \\  }
        \\  return true;
        \\}
        \\
        \\static bool ext_lp_12e0_parse_serverhello(SSL_HANDSHAKE *hs, uint8_t *out_alert,
        \\                                          CBS *contents) {
        \\  // lightpanda: Google echoes this one back in EncryptedExtensions --
        \\  // it is a Google draft and google.com answers it, which is how the
        \\  // handshake broke when this was forbid_parse_serverhello: every
        \\  // other host completed, google.com alone failed with
        \\  // SslConnectError. We send Chrome's empty body and do not pretend
        \\  // to understand the reply, so the only honest handling is to
        \\  // accept and ignore it.
        \\  return true;
        \\}
        \\
        \\static bool ext_trust_anchors_add_clienthello(const SSL_HANDSHAKE *hs, CBB *out,
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

    var current = try src_dir.readFileAlloc(io, file_name, gpa, .limited(8 * 1024 * 1024));
    defer gpa.free(current);

    for (patches) |patch| {
        const count = std.mem.count(u8, current, patch.find);
        if (count != 1) {
            std.debug.print(
                "boringssl_clienthello_ext_patch: {s}: anchor for \"{s}\" matched {d} times, expected 1.\n" ++
                    "The vendored BoringSSL has moved; re-read the diff before bumping.\n",
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
