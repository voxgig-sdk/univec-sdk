// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/src/addr.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The address check every network provider makes before it sends a
//! credential anywhere.
//!
//! In the CORE, not the plugins: it is a pure function over a string,
//! it opens no socket, and every plugin that speaks HTTP calls it. A
//! port of typescript/src/provider/addr.ts, which is canonical.

const std = @import("std");

const sekreto = @import("sekreto.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;

/// An address with any userinfo replaced by `[redacted]`, for messages.
///
/// Every refusal in `checkaddr` names the address it refused, and one of them
/// fires precisely because the address carries a credential - so printing it
/// verbatim wrote the password to stderr and into the logs. It cannot be
/// cleaned up afterwards either: that password was never resolved as a
/// secret, so `redact` has never seen it and never will. The host is what a
/// reader needs to identify which chain entry is at fault; the userinfo is
/// not.
///
/// The caller owns the returned slice.
pub fn safeaddr(alloc: Allocator, addr: []const u8) Allocator.Error![]const u8 {
    const mark = std.mem.indexOf(u8, addr, "://") orelse return alloc.dupe(u8, addr);

    const rest = addr[mark + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];

    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse
        return alloc.dupe(u8, addr);

    return std.fmt.allocPrint(alloc, "{s}[redacted]{s}", .{
        addr[0 .. mark + 3],
        addr[mark + 3 + at ..],
    });
}

/// Refuse to send a secret-bearing credential in the clear.
///
/// A vault API is HTTPS in any real deployment; plaintext is a dev-mode
/// convenience. Sending a token over http to anything but the local machine
/// puts both the token and the secret it fetches on the wire for anyone on
/// the path, so sekreto will not do it. Loopback stays allowed: that is
/// `vault server -dev`, `boru vault serve`, and this repo's own harness.
///
/// The address is read by hand, in the same handful of steps in every port,
/// rather than by each platform's URL parser. That is deliberate. Twelve
/// parsers disagree about malformed input - where userinfo ends, whether
/// `0177.0.0.1` is loopback, what an unclosed bracket means - and a check
/// that answers differently in different ports is not a check.
///
/// The rule this parse obeys, and the reason it can be trusted: it is never
/// more permissive than the HTTP client that will dial the address. It ends
/// the authority at `/`, `?` or `#` only, so a client that also breaks on
/// `\` (WHATWG does) can only ever see a SHORTER host than this does. It
/// refuses userinfo outright rather than locating its end. It compares the
/// host literally, so a numeric form no parser here agrees on is refused
/// rather than guessed at.
pub fn checkaddr(alloc: Allocator, addr: []const u8) Allocator.Error!Answer(void) {
    const scheme = if (std.mem.startsWith(u8, addr, "https://"))
        "https://"
    else if (std.mem.startsWith(u8, addr, "http://"))
        "http://"
    else {
        const bad = try safeaddr(alloc, addr);
        defer alloc.free(bad);
        return .{ .err = try sekreto.fail(
            alloc,
            "sekreto: not an http(s) address: {s}",
            .{bad},
        ) };
    };

    // Redacted once, and used by every message below: no refusal prints the
    // credential it is refusing.
    const shown = try safeaddr(alloc, addr);
    defer alloc.free(shown);

    const rest = addr[scheme.len..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];

    // Userinfo is refused outright rather than parsed around, and on https as
    // well as http. No store this library speaks authenticates by userinfo -
    // they take a token or a signature - so an address carrying one is a
    // mistake at best. At worst it is the attack this whole function exists
    // to stop: `http://localhost:8200@evil.example.com/` is a request to
    // evil.example.com that reads, to anything that splits the authority on
    // ':', as loopback.
    if (null != std.mem.indexOfScalar(u8, authority, '@')) {
        return .{ .err = try sekreto.fail(
            alloc,
            "sekreto: refusing an address with embedded credentials: {s}",
            .{shown},
        ) };
    }

    // An opening bracket with no closing one is not an address at all.
    if (0 != authority.len and '[' == authority[0] and
        null == std.mem.indexOfScalar(u8, authority, ']'))
    {
        return .{ .err = try sekreto.fail(
            alloc,
            "sekreto: not a valid http(s) address: {s}",
            .{shown},
        ) };
    }

    if (std.mem.eql(u8, "https://", scheme)) {
        return .{ .ok = {} };
    }

    // A bracketed IPv6 literal keeps its brackets. Splitting the authority on
    // the first colon yields `[`, so `http://[::1]:8200` could never match -
    // which made the `[::1]` entry below unreachable, and refused a
    // legitimate local vault.
    const raw = if (0 != authority.len and '[' == authority[0]) blk: {
        // The closing bracket is known to be there: the check above returned
        // for an authority that opens one without closing it.
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse authority.len - 1;
        break :blk authority[0 .. close + 1];
    } else blk: {
        const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
        break :blk authority[0..colon];
    };

    const host = try std.ascii.allocLowerString(alloc, raw);
    defer alloc.free(host);

    for ([_][]const u8{ "localhost", "127.0.0.1", "::1", "[::1]" }) |allowed| {
        if (std.mem.eql(u8, allowed, host)) {
            return .{ .ok = {} };
        }
    }

    return .{ .err = try sekreto.fail(
        alloc,
        "sekreto: refusing to send a token in plaintext to {s} (use https)",
        .{shown},
    ) };
}
