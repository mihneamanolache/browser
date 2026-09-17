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

//! Where the exit IP is, so the profile's region can follow it.
//!
//! A browser whose clock says Europe/Bucharest while its packets arrive from
//! Ohio has contradicted itself, and that mismatch is one of the first things
//! a fingerprinter checks — it needs no per-user state and costs one
//! subtraction. Camoufox solves it the same way: resolve the proxy's exit
//! country once, then set the time zone and languages from it.
//!
//! This runs once, before the HTTP headers and the V8 platform are built from
//! the config, so it cannot use the browser's own client (which does not exist
//! yet) and talks to libcurl directly on a throwaway easy handle.
//!
//! FAILURE IS NOT FATAL. A dead endpoint, a proxy that blocks it or a country
//! the region table does not cover all mean "keep the region the seed drew".
//! Refusing to browse because a geo lookup timed out would be a far worse
//! trade than being in the wrong time zone.

const std = @import("std");

const crypto = @import("../sys/libcrypto.zig");
const libcurl = @import("../sys/libcurl.zig");
const tls_fingerprint = @import("../network/tls_fingerprint.zig");
const Certificates = @import("../network/Certificates.zig");

const log = @import("../log.zig");

/// Endpoints tried in order, first answer wins.
///
/// All HTTPS, verified against the same CA store the browser's own requests
/// use: over plaintext, anything on the path -- including the proxy itself --
/// could choose this browser's time zone for it.
///
/// Both formats are plain text on purpose: a JSON body would mean running a
/// real parser over an untrusted response at startup, for two characters. The
/// `cdn-cgi/trace` endpoints are Cloudflare's own and are reachable from
/// essentially anywhere a proxy exits; ipapi.co is an independent second
/// opinion in case a network blocks Cloudflare.
const endpoints = [_][:0]const u8{
    "https://www.cloudflare.com/cdn-cgi/trace",
    "https://one.one.one.one/cdn-cgi/trace",
    "https://ipapi.co/country/",
};

pub const Result = struct {
    /// ISO 3166-1 alpha-2, upper-cased.
    country: [2]u8,
    /// Which endpoint answered, for the log line.
    source: [:0]const u8,
};

/// Resolves the exit country, or null if nothing usable came back.
///
/// `proxy` is the same `--http-proxy` value the browser's own connections
/// use, credentials included: the point is to measure where *those* requests
/// come from, so a lookup that bypassed the proxy would answer the wrong
/// question.
pub fn lookup(certificates: Certificates, proxy: ?[:0]const u8, timeout_ms: u31) ?Result {
    for (endpoints) |endpoint| {
        if (fetchCountry(endpoint, certificates, proxy, timeout_ms)) |country| {
            return .{ .country = country, .source = endpoint };
        }
    }
    return null;
}

fn fetchCountry(url: [:0]const u8, certificates: Certificates, proxy: ?[:0]const u8, timeout_ms: u31) ?[2]u8 {
    var body: Body = .{};

    const easy = libcurl.curl_easy_init() orelse return null;
    defer libcurl.curl_easy_cleanup(easy);

    setup(easy, url, certificates, proxy, timeout_ms, &body) catch |err| {
        log.debug(.http, "geo lookup setup", .{ .url = url, .err = err });
        return null;
    };

    libcurl.curl_easy_perform(easy) catch |err| {
        log.debug(.http, "geo lookup failed", .{ .url = url, .err = err });
        return null;
    };

    var status: c_long = 0;
    libcurl.curl_easy_getinfo(easy, .response_code, &status) catch return null;
    if (status != 200) {
        log.debug(.http, "geo lookup status", .{ .url = url, .status = status });
        return null;
    }

    return parseCountry(body.slice());
}

fn setup(
    easy: *libcurl.Curl,
    url: [:0]const u8,
    certificates: Certificates,
    proxy: ?[:0]const u8,
    timeout_ms: u31,
    body: *Body,
) !void {
    try libcurl.curl_easy_setopt(easy, .url, url.ptr);
    try libcurl.curl_easy_setopt(easy, .timeout_ms, timeout_ms);
    try libcurl.curl_easy_setopt(easy, .connect_timeout_ms, timeout_ms);
    // Cloudflare redirects the apex to www; ip-api.com redirects nothing.
    try libcurl.curl_easy_setopt(easy, .follow_location, @as(c_long, 1));
    try libcurl.curl_easy_setopt(easy, .write_function, Body.write);
    try libcurl.curl_easy_setopt(easy, .write_data, body);

    // The URL carries its own credentials when it has any, which is how
    // --http-proxy is given everywhere else.
    if (proxy) |p| try libcurl.curl_easy_setopt(easy, .proxy, p.ptr);

    // The same store and the same ClientHello shaping the browser's own
    // requests get. libcurl here is linked against BoringSSL with no built-in
    // CA bundle, so without the store every HTTPS endpoint above fails
    // verification; and a handshake that did not match the profile would
    // announce a second, different client from the same IP.
    try libcurl.curl_easy_setopt(easy, .ssl_ctx_function, &(struct {
        fn wrap(
            _: *libcurl.Curl,
            raw_ssl_ctx: *anyopaque,
            raw_x509_store: *anyopaque,
        ) callconv(.c) libcurl.CurlCode {
            const ssl_ctx: *crypto.SSL_CTX = @ptrCast(raw_ssl_ctx);
            tls_fingerprint.apply(ssl_ctx);
            const store: *crypto.X509_STORE = @ptrCast(raw_x509_store);
            if (crypto.SSL_CTX_set1_verify_cert_store(ssl_ctx, store) != 1) {
                return libcurl.CURLE.ABORTED_BY_CALLBACK;
            }
            return libcurl.CURLE.OK;
        }
    }).wrap);
    try libcurl.curl_easy_setopt(easy, .ssl_ctx_data, certificates.store);
}

/// A small fixed buffer: the longest response any of these endpoints produces
/// is Cloudflare's ~400-byte trace, and a body that overflows it is a body
/// that is not what we asked for.
const Body = struct {
    len: usize = 0,
    buf: [2048]u8 = undefined,

    fn slice(self: *const Body) []const u8 {
        return self.buf[0..self.len];
    }

    fn write(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
        const self: *Body = @ptrCast(@alignCast(userdata));
        const chunk = ptr[0 .. size * nmemb];
        const room = self.buf.len - self.len;
        // Short-writing would make curl abort the transfer, which is the right
        // outcome for a response this much larger than expected.
        if (chunk.len > room) return 0;
        @memcpy(self.buf[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
        return chunk.len;
    }
};

/// Both response shapes, from an untrusted body.
///
///   loc=US            (one line of Cloudflare's key=value trace)
///   US                (ip-api.com/line, the whole body)
fn parseCountry(body: []const u8) ?[2]u8 {
    var lines = std.mem.splitAny(u8, body, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        const value = if (std.mem.startsWith(u8, line, "loc="))
            line["loc=".len..]
        else if (std.mem.indexOfScalar(u8, line, '=') != null)
            // Another key from the trace; not ours.
            continue
        else
            line;

        if (value.len != 2) continue;
        if (!std.ascii.isAlphabetic(value[0]) or !std.ascii.isAlphabetic(value[1])) continue;
        return .{ std.ascii.toUpper(value[0]), std.ascii.toUpper(value[1]) };
    }
    return null;
}

const testing = std.testing;

test "geo: reads loc= out of a cloudflare trace" {
    const trace =
        "fl=123abc\n" ++
        "h=www.cloudflare.com\n" ++
        "ip=203.0.113.7\n" ++
        "ts=1750000000.123\n" ++
        "visit_scheme=https\n" ++
        "uag=Mozilla/5.0\n" ++
        "colo=FRA\n" ++
        "sliver=none\n" ++
        "http=http/2\n" ++
        "loc=DE\n" ++
        "tls=TLSv1.3\n";
    try testing.expectEqualStrings("DE", &parseCountry(trace).?);
}

test "geo: reads a bare two-letter body, in either case" {
    try testing.expectEqualStrings("US", &parseCountry("US\n").?);
    try testing.expectEqualStrings("US", &parseCountry("us").?);
    try testing.expectEqualStrings("GB", &parseCountry("  gb  \r\n").?);
}

test "geo: refuses anything that is not a country code" {
    // An HTML error page, a rate-limit message, an empty body, a trace with no
    // loc line: all "we do not know", never a wrong two characters.
    try testing.expectEqual(@as(?[2]u8, null), parseCountry(""));
    try testing.expectEqual(@as(?[2]u8, null), parseCountry("<html><body>nope</body></html>"));
    try testing.expectEqual(@as(?[2]u8, null), parseCountry("colo=FRA\nhttp=http/2\n"));
    try testing.expectEqual(@as(?[2]u8, null), parseCountry("fail\nquota exceeded\n"));
    // "h=" lines carry a hostname, never a country, even a two-letter one.
    try testing.expectEqual(@as(?[2]u8, null), parseCountry("h=de\n"));
}

test "geo: a body larger than the buffer aborts the transfer" {
    var body: Body = .{};
    const chunk = "x" ** 1024;
    try testing.expectEqual(@as(usize, 1024), Body.write(chunk.ptr, 1, chunk.len, &body));
    try testing.expectEqual(@as(usize, 1024), Body.write(chunk.ptr, 1, chunk.len, &body));
    // Third chunk does not fit: a zero return is how libcurl is told to stop.
    try testing.expectEqual(@as(usize, 0), Body.write(chunk.ptr, 1, chunk.len, &body));
    try testing.expectEqual(@as(usize, 2048), body.len);
}
