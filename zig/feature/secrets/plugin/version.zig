// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/version.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Versions and ranges (§11.2).
//!
//! TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
//! concrete version. A requirement declares `range`. A requirement is
//! satisfied when the names match, the `match` passes, and the
//! provider's `version` falls inside the requirement's `range`. That is
//! the whole rule — there is no third field and no second comparison.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");

/// A COMPONENT IS BOUNDED, like a ref is (§4's 1024).
///
/// The grammar admits an unbounded digit sequence, and every language
/// then disagrees about what happens past its integer range: JavaScript
/// silently loses precision, Go's Atoi errors (and a port ignoring that
/// gets 0), C overflows, Python is exact, Haskell's Integer is
/// unbounded. `satisfies("0", "9223372036854775808")` was false in the
/// canonical and true in go, from the same corpus.
///
/// 2^31-1 because every port has a signed 32-bit integer, and no real
/// version has ever needed more. Stated rather than left to arithmetic
/// nobody agrees on. Found by review of the go port.
const COMPONENT_MAX: i64 = 2147483647;

const Parsed = struct { parts: [3]i64, overflow: bool };

/// `^(\d+)(?:\.(\d+))?(?:\.(\d+))?$`, by hand: three components, digits
/// only, no leading sign, no empty component. Written out rather than
/// handed to a regex because the bound above has to be checked per
/// component anyway.
fn parse3(s: []const u8) ?Parsed {
    if (s.len == 0) return null;
    var out = Parsed{ .parts = .{ 0, 0, 0 }, .overflow = false };
    var i: usize = 0;
    var part: usize = 0;
    while (part < 3) : (part += 1) {
        if (i >= s.len) return if (part > 0) out else null; // fewer than three is fine
        if (part > 0) {
            if (s[i] != '.') return null;
            i += 1;
        }
        const start = i;
        var acc: i64 = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            if (!out.overflow) {
                acc = acc * 10 + @as(i64, s[i] - '0');
                if (acc > COMPONENT_MAX) out.overflow = true;
            }
        }
        if (start == i) return null; // an empty component is not a number
        out.parts[part] = acc;
    }
    return if (i == s.len) out else null;
}

fn triple(n: [3]i64) *v.Value {
    const out = v.vlist();
    for (n) |x| v.push(out, v.vnum(@floatFromInt(x)));
    return out;
}

pub fn parserange(range: ?*v.Value) t.Err!*v.Value {
    if (!v.isStr(range) or v.asStr(range).len == 0) {
        const shown = if (v.isStr(range)) v.asStr(range) else "";
        return t.fail("plugin_bad_range", v.print("invalid range: {s}", .{shown}), t.details1("range", if (v.isNull(range)) v.vnull() else range));
    }
    const s = v.asStr(range);
    // Two forms and no more (§11.2):
    //   '2.1'   >= 2.1.0 and < 3.0.0
    //   '~2.1'  >= 2.1.0 and < 2.2.0
    const tilde = s[0] == '~';
    const body = if (tilde) s[1..] else s;

    const p = parse3(body) orelse
        return t.fail("plugin_bad_range", v.print("invalid range: {s}", .{s}), t.details1("range", range));
    if (p.overflow) {
        return t.fail("plugin_bad_range", v.print("version component out of range in {s}", .{s}), t.details1("range", range));
    }

    const lo = p.parts;
    const hi: [3]i64 = if (tilde)
        .{ p.parts[0], p.parts[1] + 1, 0 }
    else
        .{ p.parts[0] + 1, 0, 0 };

    const out = v.vmap();
    v.set(out, "lo", triple(lo));
    v.set(out, "hi", triple(hi));
    return out;
}

pub fn parseversion(version: ?*v.Value) t.Err!*v.Value {
    if (!v.isStr(version)) {
        return t.fail("plugin_bad_range", "invalid version", t.details1("version", if (v.isNull(version)) v.vnull() else version));
    }
    const s = v.asStr(version);
    // `plugin_bad_range` either way — the same code the rest of the
    // grammar's failures use, because "this is not a version I can
    // compare" is one fact however it went wrong.
    const p = parse3(s) orelse
        return t.fail("plugin_bad_range", v.print("invalid version: {s}", .{s}), t.details1("version", version));
    if (p.overflow) {
        return t.fail("plugin_bad_range", v.print("version component out of range in {s}", .{s}), t.details1("version", version));
    }
    return triple(p.parts);
}

pub fn vercmp(a: ?*v.Value, b: ?*v.Value) i32 {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const x = v.asNum(v.at(a, i));
        const y = v.asNum(v.at(b, i));
        if (x != y) return if (x < y) -1 else 1;
    }
    return 0;
}

pub fn satisfies(version: ?*v.Value, range: ?*v.Value) t.Err!bool {
    const ver = try parseversion(version);
    const r = try parserange(range);
    return vercmp(ver, v.get(r, "lo")) >= 0 and vercmp(ver, v.get(r, "hi")) < 0;
}

/// `satisfies` for the internal callers that treat an unparseable
/// version or range as "does not satisfy" — Capability and Graph, both
/// of which run over data the corpus has already admitted.
pub fn satisfiesq(version: ?*v.Value, range: ?*v.Value) bool {
    return satisfies(version, range) catch {
        // TAKE FIRST: the parked diagnostic is discarded deliberately
        // here, and leaving it parked would hand it to the next handler.
        _ = t.take();
        return false;
    };
}
