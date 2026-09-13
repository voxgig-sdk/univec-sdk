// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/types.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Errors, and the raise mechanism (§12).
//!
//! ZIG ERRORS ARE VALUES WITHOUT PAYLOADS, and that is this port's one
//! big decision. There is no `throw` carrying an object and no
//! `setjmp`; there is `error.Plugin` and an explicit `try` at every
//! call. So the DIAGNOSTIC TRAVELS BESIDE THE ERROR: `fail` parks a
//! `PluginError` in `pending` and returns `error.Plugin`, and every
//! handler reads it with `take()` as its first act.
//!
//! THAT DISCIPLINE IS LOAD-BEARING. `pending` holds one error; a
//! handler that calls something fallible before reading it gets the
//! second error's payload with the first error's control flow. Every
//! `catch` in this port takes first and works afterwards, and that is
//! the thing to check when adding one.
//!
//! The upside is what `c` pays `volatile` for and does not get: an
//! explicit `try` means the compiler will not let a fallible call be
//! ignored, so the "missed check continues silently past a failure"
//! failure mode `c`'s longjmp exists to prevent cannot happen here at
//! all.
//!
//! Ports compare by CODE and never by message: wording is a port's own
//! business. The FORMAT is pinned, because a parseable message is what
//! makes a log searchable across twenty languages.

const std = @import("std");
const v = @import("value.zig");

pub const Err = error{Plugin};

pub const PluginError = struct {
    code: []const u8,
    text: []const u8,
    details: *v.Value,
    message: []const u8,
};

var pending: ?PluginError = null;

/// §12's detail fields render in a FIXED ORDER — part of the contract,
/// not a formatting preference, because otherwise each port invents its
/// own and message parity is gone.
const detail_order = [_][]const u8{
    "host",  "ref",     "name",  "tag",        "point", "key",     "capability",
    "range", "version", "match", "candidates", "cycle", "holders", "refs",
    "path",  "cause",
};

pub fn formatError(code: []const u8, text: []const u8, details: ?*v.Value) []const u8 {
    // Values render as COMPACT JSON, so a value containing a space or a
    // bracket cannot break the parse and a list renders as an array. The
    // bracket is absent entirely when no field applies.
    var tail = v.List(u8).init(v.arena());
    for (detail_order) |k| {
        if (!v.has(details, k)) continue;
        if (tail.items.len > 0) tail.append(' ') catch @panic("oom");
        tail.appendSlice(k) catch @panic("oom");
        tail.append('=') catch @panic("oom");
        tail.appendSlice(v.json(v.get(details, k))) catch @panic("oom");
    }
    if (tail.items.len == 0) return v.print("plugin/{s}: {s}", .{ code, text });
    return v.print("plugin/{s}: {s} [{s}]", .{ code, text, tail.items });
}

/// Raise. Use as `return fail(...)` or `try` through it.
pub fn fail(code: []const u8, text: []const u8, details: ?*v.Value) Err {
    const d = details orelse v.vmap();
    pending = .{
        .code = v.dupe(code),
        .text = v.dupe(text),
        .details = d,
        .message = formatError(code, text, d),
    };
    return error.Plugin;
}

/// Read and clear the parked error. THE FIRST THING EVERY HANDLER DOES.
pub fn take() PluginError {
    const e = pending orelse PluginError{
        .code = "plugin_bad_state",
        .text = "error raised with no diagnostic",
        .details = v.vmap(),
        .message = "plugin/plugin_bad_state: error raised with no diagnostic",
    };
    pending = null;
    return e;
}

/// Re-park an error a handler has already taken, so it can be
/// propagated unchanged.
pub fn reraise(e: PluginError) Err {
    pending = e;
    return error.Plugin;
}

pub fn details1(k: []const u8, val: ?*v.Value) *v.Value {
    const d = v.vmap();
    v.set(d, k, val);
    return d;
}

pub fn details2(k1: []const u8, v1: ?*v.Value, k2: []const u8, v2: ?*v.Value) *v.Value {
    const d = v.vmap();
    v.set(d, k1, v1);
    v.set(d, k2, v2);
    return d;
}

/// Deep merge, struct's semantics: maps merge, everything else
/// replaces. §16 permits voxgig/struct for this and zig has no port of
/// it.
pub fn mergeValue(a: ?*v.Value, b: ?*v.Value) ?*v.Value {
    if (!v.isMap(a) or !v.isMap(b)) return b orelse a;
    const out = v.vmap();
    for (v.keys(a)) |k| v.set(out, k, v.get(a, k));
    for (v.keys(b)) |k| {
        const bv = v.get(b, k);
        const av = v.get(out, k);
        if (v.isMap(av) and v.isMap(bv)) v.set(out, k, mergeValue(av, bv)) else v.set(out, k, bv);
    }
    return out;
}

/// §11.1's partial match: every leaf in `want` must be present and
/// equal in `have`; keys not mentioned are not checked.
pub fn matchValue(want: ?*v.Value, have: ?*v.Value) bool {
    if (v.isNull(want)) return true;
    if (v.isMap(want)) {
        if (!v.isMap(have)) return false;
        for (v.keys(want)) |k| {
            if (!v.has(have, k)) return false;
            if (!matchValue(v.get(want, k), v.get(have, k))) return false;
        }
        return true;
    }
    return v.same(want, have);
}
