//! Rewrites one BoringSSL source so the signature_algorithms extension can
//! carry code points this BoringSSL does not implement.
//!
//! Chrome 151's ClientHello leads its signature_algorithms list with the
//! three ML-DSA entries, 0x0904-0x0906:
//!
//!   chrome  0904 0905 0906 0403 0804 0401 0503 0805 0501 0806 0601
//!
//! JA4's third component is a hash of that list, in order, so sending eight
//! of the eleven is a different JA4 from the Chrome we claim to be. Measured
//! against real Chrome through the same proxy exit, that one extension was
//! the *only* remaining difference: same ciphers, same extension set, same
//! groups, same ALPS, byte-identical HTTP/2 preface.
//!
//! `SSL_CTX_set_verify_algorithm_prefs` will not take them. `set_sigalg_prefs`
//! in ssl_privkey.cc runs every entry through `get_signature_algorithm` and
//! rejects the *whole list* if any one is unknown, which drops us back to
//! BoringSSL's default list -- worse than where we started, because that
//! default trails rsa_pkcs1_sha1 (0x0201) that Chrome has not offered in
//! years.
//!
//! WHY THIS IS SAFE
//!
//! The verify prefs are not a claim about what we can compute. They are two
//! things only: the bytes written into the ClientHello
//! (`tls12_add_verify_sigalgs`, which just copies u16s), and the set a
//! server's chosen algorithm is checked against (`tls12_check_peer_sigalg`).
//! That check calls `ssl_pkey_supports_algorithm`, whose first line is
//! `get_signature_algorithm(sigalg)` followed by `if (alg == NULL) return
//! false` -- so a server that somehow selected ML-DSA gets a clean
//! WRONG_SIGNATURE_TYPE alert, not a crash. No public CA issues ML-DSA
//! certificates today, and if one did, Chrome would be in the same position.
//!
//! The *signing* prefs keep validating, because those really are a claim
//! about what we can compute. Nothing here presents a client certificate, so
//! in practice they are unused either way.
//!
//! Patching rather than vendoring: ssl_privkey.cc is ~1000 lines and copying
//! it wholesale would bury a four-line change and freeze the rest at today's
//! upstream. Every replacement is anchored on an exact string and
//! `error.PatchAnchorNotFound` fails the build if BoringSSL moves, which is
//! the intended behaviour -- a bump should stop and make someone re-read the
//! diff, not quietly emit the wrong JA4 again.
//!
//! Usage: boringssl_sigalg_patch <boringssl-src-dir> <out-dir>

const std = @import("std");

const Patch = struct {
    /// Exact text to find. Must be unique in the file.
    find: []const u8,
    replace: []const u8,
    why: []const u8,
};

const file_name = "ssl_privkey.cc";

const patches = [_]Patch{
    // 1. An opt-in parameter, defaulted off so every existing caller keeps
    //    validating exactly as before.
    .{
        .why = "allow_unknown parameter",
        .find = "static bool set_sigalg_prefs(Array<uint16_t> *out, Span<const uint16_t> prefs) {",
        .replace =
        \\static bool set_sigalg_prefs(Array<uint16_t> *out, Span<const uint16_t> prefs,
        \\                             bool allow_unknown = false) {
        ,
    },

    // 2. The rejection itself. Note this sits after the
    //    SSL_SIGN_RSA_PKCS1_MD5_SHA1 filter, so that entry is still dropped:
    //    unknown code points pass through, a known-but-unwanted one does not.
    .{
        .why = "unknown code points are advertised rather than rejected",
        .find =
        \\    if (get_signature_algorithm(pref) == nullptr) {
        \\      OPENSSL_PUT_ERROR(SSL, SSL_R_INVALID_SIGNATURE_ALGORITHM);
        \\      return false;
        \\    }
        ,
        .replace =
        \\    if (get_signature_algorithm(pref) == nullptr && !allow_unknown) {
        \\      OPENSSL_PUT_ERROR(SSL, SSL_R_INVALID_SIGNATURE_ALGORITHM);
        \\      return false;
        \\    }
        ,
    },

    // 3 and 4. Only the two *verify* entry points opt in. The signing ones a
    //    few lines above are left alone on purpose.
    .{
        .why = "SSL_CTX_set_verify_algorithm_prefs opts in",
        .find = "  return set_sigalg_prefs(&ctx->verify_sigalgs, Span(prefs, num_prefs));",
        .replace = "  return set_sigalg_prefs(&ctx->verify_sigalgs, Span(prefs, num_prefs), true);",
    },
    .{
        .why = "SSL_set_verify_algorithm_prefs opts in",
        .find = "  return set_sigalg_prefs(&ssl->config->verify_sigalgs, Span(prefs, num_prefs));",
        .replace = "  return set_sigalg_prefs(&ssl->config->verify_sigalgs, Span(prefs, num_prefs), true);",
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
                "boringssl_sigalg_patch: {s}: anchor for \"{s}\" matched {d} times, expected 1.\n" ++
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
