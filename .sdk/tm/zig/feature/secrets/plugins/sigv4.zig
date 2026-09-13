// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/sigv4.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! AWS Signature Version 4, hand-rolled.
//!
//! The AWS providers need exactly one thing from the AWS SDK - request
//! signing - and taking an SDK for it would break the no-dependency rule
//! that keeps ten ports honest. SigV4 is a stable, published algorithm
//! built from HMAC-SHA256, which std already has
//! (`std.crypto.auth.hmac.Hmac(Sha256)`).
//!
//! `sign` is pure: the caller passes the timestamp, so the same input
//! yields the same signature everywhere. That is what lets the shared spec
//! carry known-answer cases all ten ports must reproduce bit-for-bit, and
//! lets the integration mock recompute the signature server-side.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.Hmac(Sha256);

/// One header, or one output field. A list rather than a map: the order of
/// the signed headers is part of the signature, and the order of the output
/// is what a port's test compares.
pub const Pair = struct {
    name: []const u8,
    value: []const u8,
};

pub const Input = struct {
    method: []const u8,
    /// Full request URL; the host, path and query are signed.
    url: []const u8,
    /// Extra headers to sign, e.g. content-type and x-amz-target.
    headers: []const Pair = &.{},
    body: []const u8 = "",
    service: []const u8,
    region: []const u8,
    keyid: []const u8,
    secret: []const u8,
    /// STS session token; signed as x-amz-security-token when present.
    session: []const u8 = "",
    /// The signing moment, `YYYYMMDDTHHMMSSZ`. Passed in, never sampled, so
    /// the function stays pure.
    datetime: []const u8,
};

/// The URL as the signature sees it. Deliberately hand-split rather than
/// handed to `std.Uri`: what is signed must be exactly what the canonical
/// TypeScript's `new URL()` yields - a `host` that carries the port only
/// when it is not the scheme's default, and a `pathname` that is `/` when
/// the URL has no path at all.
const Url = struct {
    host: []const u8,
    path: []const u8,
    query: []const u8,
};

fn parseurl(alloc: Allocator, url: []const u8) Allocator.Error!Url {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse 0;
    const scheme = url[0..scheme_end];
    const rest = if (0 == scheme_end) url else url[scheme_end + 3 ..];

    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..authority_end];

    // Userinfo is not part of the host, and never signed.
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        authority = authority[at + 1 ..];
    }

    var host = try std.ascii.allocLowerString(alloc, authority);

    // A default port is not part of `host`, exactly as URL.host omits it.
    const defaultport: []const u8 = if (std.mem.eql(u8, "https", scheme)) ":443" else ":80";
    if (std.mem.endsWith(u8, host, defaultport)) {
        host = host[0 .. host.len - defaultport.len];
    }

    var tail = rest[authority_end..];
    if (std.mem.indexOfScalar(u8, tail, '#')) |hash| {
        tail = tail[0..hash];
    }

    const query_at = std.mem.indexOfScalar(u8, tail, '?');
    const path = if (query_at) |at| tail[0..at] else tail;
    const query = if (query_at) |at| tail[at + 1 ..] else "";

    return .{
        .host = host,
        .path = if (0 == path.len) "/" else path,
        .query = query,
    };
}

fn hex(alloc: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try alloc.alloc(u8, 2 * bytes.len);

    for (bytes, 0..) |byte, at| {
        out[2 * at] = digits[byte >> 4];
        out[2 * at + 1] = digits[byte & 0x0f];
    }

    return out;
}

fn sha256hex(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &digest, .{});
    return hex(alloc, &digest);
}

fn hmac(key: []const u8, text: []const u8) [Hmac.mac_length]u8 {
    var out: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&out, text, key);
    return out;
}

/// RFC 3986 escaping, which is stricter than a URL encoder: AWS wants `!`,
/// `'`, `(`, `)` and `*` escaped too, and every escape upper-case.
fn uriescape(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    for (text) |ch| {
        const unreserved = ('A' <= ch and 'Z' >= ch) or ('a' <= ch and 'z' >= ch) or
            ('0' <= ch and '9' >= ch) or '-' == ch or '_' == ch or '.' == ch or '~' == ch;

        if (unreserved) {
            try out.append(alloc, ch);
        } else {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "%{X:0>2}", .{ch}));
        }
    }

    return out.items;
}

fn hexdigit(ch: u8) ?u8 {
    if ('0' <= ch and '9' >= ch) return ch - '0';
    if ('a' <= ch and 'f' >= ch) return ch - 'a' + 10;
    if ('A' <= ch and 'F' >= ch) return ch - 'A' + 10;
    return null;
}

fn percentdecode(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var at: usize = 0;
    while (at < text.len) : (at += 1) {
        if ('%' == text[at] and at + 2 < text.len) {
            const high = hexdigit(text[at + 1]);
            const low = hexdigit(text[at + 2]);
            if (null != high and null != low) {
                try out.append(alloc, 16 * high.? + low.?);
                at += 2;
                continue;
            }
        }
        try out.append(alloc, text[at]);
    }

    return out.items;
}

fn lesspair(_: void, left: Pair, right: Pair) bool {
    const order = std.mem.order(u8, left.name, right.name);
    if (.eq != order) {
        return .lt == order;
    }
    return .lt == std.mem.order(u8, left.value, right.value);
}

fn lessname(_: void, left: Pair, right: Pair) bool {
    return .lt == std.mem.order(u8, left.name, right.name);
}

/// The canonical query string: each pair RFC 3986-escaped, sorted by
/// escaped key then escaped value.
fn canonicalquery(alloc: Allocator, query: []const u8) Allocator.Error![]const u8 {
    if (0 == query.len) {
        return "";
    }

    var pairs: std.ArrayList(Pair) = .empty;

    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const key = if (eq) |at| pair[0..at] else pair;
        const value = if (eq) |at| pair[at + 1 ..] else "";

        try pairs.append(alloc, .{
            .name = try uriescape(alloc, try percentdecode(alloc, key)),
            .value = try uriescape(alloc, try percentdecode(alloc, value)),
        });
    }

    std.mem.sort(Pair, pairs.items, {}, lesspair);

    var out: std.ArrayList(u8) = .empty;
    for (pairs.items, 0..) |pair, at| {
        if (0 < at) {
            try out.append(alloc, '&');
        }
        try out.appendSlice(alloc, pair.name);
        try out.append(alloc, '=');
        try out.appendSlice(alloc, pair.value);
    }

    return out.items;
}

fn isspace(ch: u8) bool {
    return ' ' == ch or '\t' == ch or '\n' == ch or '\r' == ch or 0x0b == ch or 0x0c == ch;
}

/// A canonical header value: trimmed, and internal whitespace runs folded to
/// one space. AWS folds before signing, so `a  b` must sign as `a b` or the
/// service refuses the request.
fn collapse(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var at: usize = 0;
    while (at < text.len and isspace(text[at])) : (at += 1) {}

    var end = text.len;
    while (end > at and isspace(text[end - 1])) : (end -= 1) {}

    var run = false;
    while (at < end) : (at += 1) {
        if (isspace(text[at])) {
            if (!run) {
                try out.append(alloc, ' ');
                run = true;
            }
        } else {
            try out.append(alloc, text[at]);
            run = false;
        }
    }

    return out.items;
}

/// Sign one request. Returns the headers to attach, in a fixed order:
/// authorization, x-amz-date, and x-amz-security-token when a session token
/// was given.
pub fn sign(alloc: Allocator, input: Input) Allocator.Error![]const Pair {
    const url = try parseurl(alloc, input.url);

    const date = if (8 <= input.datetime.len) input.datetime[0..8] else input.datetime;

    // Every header that will be signed: the caller's extras, plus host and
    // x-amz-date (and the session token when present), lower-cased and
    // folded the way the canonical form requires.
    var headers: std.ArrayList(Pair) = .empty;

    for (input.headers) |header| {
        try headers.append(alloc, .{
            .name = try std.ascii.allocLowerString(alloc, header.name),
            .value = try collapse(alloc, header.value),
        });
    }
    try headers.append(alloc, .{ .name = "host", .value = url.host });
    try headers.append(alloc, .{ .name = "x-amz-date", .value = input.datetime });
    if (0 != input.session.len) {
        try headers.append(alloc, .{ .name = "x-amz-security-token", .value = input.session });
    }

    std.mem.sort(Pair, headers.items, {}, lessname);

    var canonicalheaders: std.ArrayList(u8) = .empty;
    var signedheaders: std.ArrayList(u8) = .empty;

    for (headers.items, 0..) |header, at| {
        try canonicalheaders.appendSlice(alloc, header.name);
        try canonicalheaders.append(alloc, ':');
        try canonicalheaders.appendSlice(alloc, header.value);
        try canonicalheaders.append(alloc, '\n');

        if (0 < at) {
            try signedheaders.append(alloc, ';');
        }
        try signedheaders.appendSlice(alloc, header.name);
    }

    const method = try std.ascii.allocUpperString(alloc, input.method);

    const canonicalrequest = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        method,
        url.path,
        try canonicalquery(alloc, url.query),
        canonicalheaders.items,
        signedheaders.items,
        try sha256hex(alloc, input.body),
    });

    const scope = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}/{s}/aws4_request",
        .{ date, input.region, input.service },
    );

    const stringtosign = try std.fmt.allocPrint(alloc, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{
        input.datetime,
        scope,
        try sha256hex(alloc, canonicalrequest),
    });

    const seed = try std.fmt.allocPrint(alloc, "AWS4{s}", .{input.secret});
    const kdate = hmac(seed, date);
    const kregion = hmac(&kdate, input.region);
    const kservice = hmac(&kregion, input.service);
    const ksigning = hmac(&kservice, "aws4_request");
    const signature = hmac(&ksigning, stringtosign);

    var out: std.ArrayList(Pair) = .empty;

    try out.append(alloc, .{
        .name = "authorization",
        .value = try std.fmt.allocPrint(
            alloc,
            "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
            .{ input.keyid, scope, signedheaders.items, try hex(alloc, &signature) },
        ),
    });
    try out.append(alloc, .{ .name = "x-amz-date", .value = input.datetime });

    if (0 != input.session.len) {
        try out.append(alloc, .{ .name = "x-amz-security-token", .value = input.session });
    }

    return out.items;
}
