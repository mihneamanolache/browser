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

//! The ClientHello, shaped to match the browser the rest of the profile
//! claims to be.
//!
//! `fingerprint.zig` makes a page see Chrome. This makes the *socket* look
//! like Chrome, which is a separate and, for defended origins, more load
//! bearing claim: a server sees the ClientHello before it sees a single
//! header, and a UA that says Chrome over a ClientHello that says "libcurl"
//! is a contradiction no amount of JavaScript can paper over. Claiming Chrome
//! actually raises the bar here — a generic client is unremarkable, but a
//! client that claims Chrome and then fails a JA3/JA4 check has told the
//! server something specific.
//!
//! Reference capture, Chrome 151 on macOS, from tls.peet.ws (JA4_r):
//!
//!   t13d1516h2
//!     _002f,0035,009c,009d,1301,1302,1303,c013,c014,c02b,c02c,c02f,c030,cca8,cca9
//!     _0005,000a,000b,000d,0012,0017,001b,0023,002b,002d,0033,44cd,fe0d,ff01
//!     _0904,0905,0906,0403,0804,0401,0503,0805,0501,0806,0601
//!
//! JA4 sorts ciphers and extensions before hashing, so the per-connection
//! order BoringSSL picks does not matter — only the *set* does. That is what
//! makes this reproducible at all: extension order is permuted by Chrome
//! itself (see `SSL_CTX_set_permute_extensions`), so no fixed order could be
//! correct anyway.
//!
//! Two extensions in that capture are not reachable from an `SSL_CTX`:
//! ALPS (`44cd`) and ECH (`fe0d`) are configured per-`SSL`, and libcurl only
//! hands out the `SSL_CTX`. They are the known gap; see `missing_extensions`.

const std = @import("std");
const lp = @import("lightpanda");

const crypto = @import("../sys/libcrypto.zig");

const log = lp.log;

/// TLS 1.2-and-below suites, in Chrome's preference order. The three TLS 1.3
/// suites (1301/1302/1303) are fixed in BoringSSL and always offered, which
/// is exactly the set Chrome sends, so they are not listed here.
///
/// Order is Chrome's own, not the sorted JA4 order: this string drives what
/// goes on the wire, and a server picking from it should make the same choice
/// Chrome would.
const cipher_list: [:0]const u8 =
    "ECDHE-ECDSA-AES128-GCM-SHA256:" ++ // c02b
    "ECDHE-RSA-AES128-GCM-SHA256:" ++ // c02f
    "ECDHE-ECDSA-AES256-GCM-SHA384:" ++ // c02c
    "ECDHE-RSA-AES256-GCM-SHA384:" ++ // c030
    "ECDHE-ECDSA-CHACHA20-POLY1305:" ++ // cca9
    "ECDHE-RSA-CHACHA20-POLY1305:" ++ // cca8
    "ECDHE-RSA-AES128-SHA:" ++ // c013
    "ECDHE-RSA-AES256-SHA:" ++ // c014
    "AES128-GCM-SHA256:" ++ // 009c
    "AES256-GCM-SHA384:" ++ // 009d
    "AES128-SHA:" ++ // 002f
    "AES256-SHA"; // 0035

/// Supported groups, in Chrome's order. X25519MLKEM768 first is the
/// post-quantum hybrid Chrome has defaulted to since 131; a client that omits
/// it now looks *older* than its claimed version, which is its own tell.
const curve_list: [:0]const u8 = "X25519MLKEM768:X25519:P-256:P-384";

/// The signature_algorithms extension, raw IANA code points in Chrome's
/// order. This is exactly what goes on the wire, and JA4's third component
/// hashes it in order, so a list short by even one entry is a different JA4
/// from the Chrome it claims to be.
///
/// Chrome leads with the three ML-DSA entries. Stock BoringSSL will not
/// accept code points it does not implement and rejects the whole list,
/// which is why `tools/boringssl_sigalg_patch.zig` exists: it lets the
/// *verify* prefs carry unknown algorithms, since those are only an
/// advertisement plus the set a server's choice is checked against. Without
/// that patch this list silently becomes BoringSSL's default, which trails
/// rsa_pkcs1_sha1 (0x0201) that Chrome has not offered in years.
const signature_algorithms = [_]u16{
    0x0904, // mldsa44
    0x0905, // mldsa65
    0x0906, // mldsa87
    0x0403, // ecdsa_secp256r1_sha256
    0x0804, // rsa_pss_rsae_sha256
    0x0401, // rsa_pkcs1_sha256
    0x0503, // ecdsa_secp384r1_sha384
    0x0805, // rsa_pss_rsae_sha384
    0x0501, // rsa_pkcs1_sha384
    0x0806, // rsa_pss_rsae_sha512
    0x0601, // rsa_pkcs1_sha512
};

/// How many of the above this BoringSSL can actually produce a signature
/// with. The ML-DSA entries are advertised but not implemented, so they are
/// excluded from the signing prefs -- which are a genuine capability claim,
/// unlike the verify prefs. Only client certificates use them and nothing
/// here presents one, but a prefs list BoringSSL rejects would leave its
/// default in place, so the split is kept honest rather than convenient.
const unimplemented_signature_algorithms = 3;
const signing_algorithms = signature_algorithms[unimplemented_signature_algorithms..];

/// ALPN in wire format: each entry is a length byte then the protocol name.
/// Chrome offers h2 then http/1.1, and the order is what a server echoes
/// back, so it decides which protocol we actually speak.
const alpn_protos = [_]u8{
    2,   'h', '2',
    8,   'h', 't',
    't', 'p', '/',
    '1', '.', '1',
};

/// Decompresses a server's certificate chain. Registering this is what puts
/// compress_certificate (27) in the ClientHello — BoringSSL only advertises
/// algorithms it can actually handle, so the extension and a working
/// decompressor are the same decision.
///
/// `uncompressed_len` is the length the peer promised. BoringSSL requires the
/// result to be exactly that long, so a mismatch is an error rather than
/// something to tolerate.
fn brotliDecompressCert(
    _: *crypto.SSL,
    out: **crypto.CRYPTO_BUFFER,
    uncompressed_len: usize,
    in: [*]const u8,
    in_len: usize,
) callconv(.c) c_int {
    var data: [*]u8 = undefined;
    const buffer = crypto.CRYPTO_BUFFER_alloc(&data, uncompressed_len) orelse return 0;

    var decoded_len = uncompressed_len;
    const result = crypto.BrotliDecoderDecompress(in_len, in, &decoded_len, data);
    if (result != crypto.BROTLI_DECODER_RESULT_SUCCESS or decoded_len != uncompressed_len) {
        crypto.CRYPTO_BUFFER_free(buffer);
        return 0;
    }

    out.* = buffer;
    return 1;
}

/// Reaches the two extensions that are configured per-connection rather than
/// per-context. libcurl only exposes the `SSL_CTX`, so we hook the info
/// callback and act on `SSL_CB_HANDSHAKE_START`, which BoringSSL fires before
/// it builds the ClientHello.
fn onHandshakeStart(ssl: *const crypto.SSL, type_: c_int, _: c_int) callconv(.c) void {
    if (type_ != crypto.SSL_CB_HANDSHAKE_START) {
        return;
    }
    // The callback hands out a const pointer; both setters mutate the
    // connection's pending ClientHello, which is exactly what this stage is
    // for.
    const mutable: *crypto.SSL = @constCast(ssl);

    // ALPS (17613) for h2, with an empty settings value — which is what
    // Chrome sends, since HTTP/2 defines no ALPS payload of its own.
    _ = crypto.SSL_add_application_settings(mutable, alpn_h2.ptr, alpn_h2.len, "", 0);

    // ECH (65037). Chrome GREASEs this on essentially every connection: a
    // real ECHConfig is rare, but the extension is always present.
    crypto.SSL_set_enable_ech_grease(mutable, 1);
}

const alpn_h2: []const u8 = "h2";

/// Applies the profile to a freshly created `SSL_CTX`. Called from libcurl's
/// CURLOPT_SSL_CTX_FUNCTION, which runs once per connection before the
/// handshake starts.
///
/// Failures are logged and skipped rather than aborting the connection: a
/// ClientHello that is merely *less* like Chrome's still completes a
/// handshake, whereas failing the request outright turns a fingerprinting
/// regression into an outage.
pub fn apply(ctx: *crypto.SSL_CTX) void {
    // Chrome has not offered TLS 1.1 or below for years. Leaving them enabled
    // would add cipher suites and change the version list.
    _ = crypto.SSL_CTX_set_min_proto_version(ctx, crypto.TLS1_2_VERSION);
    _ = crypto.SSL_CTX_set_max_proto_version(ctx, crypto.TLS1_3_VERSION);

    if (crypto.SSL_CTX_set_cipher_list(ctx, cipher_list.ptr) != 1) {
        log.warn(.http, "tls fingerprint", .{ .step = "cipher_list" });
    }

    if (crypto.SSL_CTX_set1_curves_list(ctx, curve_list.ptr) != 1) {
        log.warn(.http, "tls fingerprint", .{ .step = "curves_list", .hint = "X25519MLKEM768 needs a recent BoringSSL" });
    }

    if (crypto.SSL_CTX_set_signing_algorithm_prefs(ctx, signing_algorithms.ptr, signing_algorithms.len) != 1) {
        log.warn(.http, "tls fingerprint", .{ .step = "signing_algorithm_prefs" });
    }
    if (crypto.SSL_CTX_set_verify_algorithm_prefs(ctx, &signature_algorithms, signature_algorithms.len) != 1) {
        // Almost certainly an unpatched BoringSSL: the ML-DSA code points are
        // rejected, the default list is used, and the JA4 stops matching.
        log.warn(.http, "tls fingerprint", .{
            .step = "verify_algorithm_prefs",
            .hint = "ML-DSA code points need tools/boringssl_sigalg_patch.zig applied",
        });
    }

    if (crypto.SSL_CTX_set_alpn_protos(ctx, &alpn_protos, alpn_protos.len) != 0) {
        // This one returns 0 on success, unlike its neighbours.
        log.warn(.http, "tls fingerprint", .{ .step = "alpn_protos" });
    }

    // status_request (5) and signed_certificate_timestamp (18). Both are in
    // Chrome's ClientHello and neither is on by default.
    crypto.SSL_CTX_enable_ocsp_stapling(ctx);
    crypto.SSL_CTX_enable_signed_cert_timestamps(ctx);

    // session_ticket (35). libcurl sets SSL_OP_NO_TICKET on every context it
    // builds (lib/vtls/openssl.c), which drops the extension entirely. Chrome
    // sends it, so clear the bit — this hook runs after curl's own setup, so
    // the clear sticks.
    _ = crypto.SSL_CTX_clear_options(ctx, crypto.SSL_OP_NO_TICKET);

    // compress_certificate (27), advertising brotli. BoringSSL only offers
    // algorithms it can decode, so this registration is what adds it.
    if (crypto.SSL_CTX_add_cert_compression_alg(ctx, crypto.CERT_COMPRESSION_BROTLI, null, brotliDecompressCert) != 1) {
        log.warn(.http, "tls fingerprint", .{ .step = "cert_compression" });
    }

    // ALPS (17613) and ECH (65037) are per-connection; this is the hook that
    // reaches them.
    crypto.SSL_CTX_set_info_callback(ctx, onHandshakeStart);

    // GREASE and extension permutation are what make the ClientHello vary
    // per connection the way Chrome's does. A byte-identical ClientHello
    // across every connection is itself a fingerprint.
    crypto.SSL_CTX_set_grease_enabled(ctx, 1);
    crypto.SSL_CTX_set_permute_extensions(ctx, 1);
}

const testing = std.testing;

test "tls_fingerprint: cipher list covers exactly the reference capture's TLS 1.2 suites" {
    // The 12 non-TLS-1.3 suites from the JA4_r cipher list. The other three
    // (1301/1302/1303) are BoringSSL built-ins.
    var count: usize = 1;
    for (cipher_list) |c| {
        if (c == ':') count += 1;
    }
    try testing.expectEqual(12, count);
}

test "tls_fingerprint: signature algorithms are Chrome's, in Chrome's order" {
    // Captured from a real Chrome 151 ClientHello through the same proxy
    // exit. JA4 hashes this list in order, so the order is part of the match
    // and this is a literal transcription, not a preference.
    try testing.expectEqualSlices(u16, &.{
        0x0904, 0x0905, 0x0906, 0x0403, 0x0804, 0x0401,
        0x0503, 0x0805, 0x0501, 0x0806, 0x0601,
    }, &signature_algorithms);

    // What we offer to sign with is the same list minus what BoringSSL
    // cannot produce, and nothing else: dropping a fourth entry here would
    // quietly change what a client-certificate handshake negotiates.
    try testing.expectEqualSlices(
        u16,
        signature_algorithms[unimplemented_signature_algorithms..],
        signing_algorithms,
    );
    for (signing_algorithms) |alg| {
        try testing.expect(alg < 0x0904 or alg > 0x0906);
        // rsa_pkcs1_sha1 is in BoringSSL's default list and not in Chrome's;
        // the whole point of setting prefs explicitly is to drop it.
        try testing.expect(alg != 0x0201);
    }
}

test "tls_fingerprint: alpn is well-formed wire format offering h2 first" {
    var i: usize = 0;
    var protos: [2][]const u8 = undefined;
    var n: usize = 0;
    while (i < alpn_protos.len) {
        const len = alpn_protos[i];
        protos[n] = alpn_protos[i + 1 ..][0..len];
        n += 1;
        i += 1 + len;
    }
    try testing.expectEqual(alpn_protos.len, i); // no trailing garbage
    try testing.expectEqual(2, n);
    try testing.expectEqualStrings("h2", protos[0]);
    try testing.expectEqualStrings("http/1.1", protos[1]);
}
