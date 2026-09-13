// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/env.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Environment overrides (§9.5) — level 7 of the ladder.
//!
//! One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
//!
//!   VOXGIG_PLUGIN_PROFILE            the profile name
//!   VOXGIG_PLUGIN_<REF>_<PATH>       one option
//!   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
//!
//! THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
//! OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` ->
//! `_`. But `_` is legal in a name and in a tag, and the mapping folds
//! case, so `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
//!
//! Rather than restrict a grammar the rest of the stack already uses,
//! the host DETECTS THE COLLISION: it encodes every ref it holds, and a
//! key two refs claim is `plugin_env_ambiguous`, naming both.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const ref = @import("ref.zig");

const PREFIX = "VOXGIG_PLUGIN_";

pub fn encoderef(r: []const u8) []const u8 {
    var out = v.List(u8).init(v.arena());
    for (r) |c| {
        if (c == '$') {
            out.appendSlice("__") catch @panic("oom");
        } else if (c == '.') {
            out.append('_') catch @panic("oom");
        } else if (c >= 'a' and c <= 'z') {
            out.append(c - 'a' + 'A') catch @panic("oom");
        } else {
            out.append(c) catch @panic("oom");
        }
    }
    return out.items;
}

fn lower(s: []const u8) []const u8 {
    const out = v.arena().alloc(u8, s.len) catch @panic("oom");
    for (s, 0..) |c, i| out[i] = if (c >= 'A' and c <= 'Z') c - 'A' + 'a' else c;
    return out;
}

fn checkreserved(r: []const u8, reserved: ?*v.Value) t.Err!void {
    if (!v.isList(reserved) or v.len(reserved) == 0) return;
    const name = ref.refname(r);
    for (v.items(reserved)) |x| {
        if (v.isStr(x) and std.mem.eql(u8, v.asStr(x), name)) {
            return t.fail("plugin_ref_reserved", v.print("ref is reserved by the host: {s}", .{r}), t.details1("ref", v.vstr(r)));
        }
    }
}

/// Values parse as JSON, FALLING BACK TO STRING — so `8080` is a number,
/// `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
/// looks like rather than a parse error.
fn parsevalue(s: []const u8) *v.Value {
    var err: []const u8 = "";
    return v.parse(s, &err) orelse v.vstr(s);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn lessByLenDesc(_: void, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len > b.len;
    return std.mem.order(u8, a, b) == .lt;
}

pub fn applyenv(input: ?*v.Value) t.Err!*v.Value {
    var env = v.get(input, "env");
    if (!v.isMap(env)) env = v.vmap();
    const refsin = v.get(input, "refs");
    const reserved = v.get(input, "reserved");

    const out = v.vmap();
    const options = v.vmap();
    const active = v.vlist();
    const inactive = v.vlist();
    v.set(out, "options", options);
    v.set(out, "active", active);
    v.set(out, "inactive", inactive);

    // Encode every ref the host holds, and refuse a key that two of them
    // claim. Done UP FRONT so the collision is reported even when no
    // environment variable exercises it — a latent ambiguity is still an
    // ambiguity, and finding it at deploy time is the failure this
    // exists to prevent.
    const byencoded = v.vmap();
    if (v.isList(refsin)) {
        for (v.items(refsin)) |rv| {
            const r = try ref.canonref(rv);
            const e = encoderef(r);
            var list = v.get(byencoded, e);
            if (v.isNull(list)) {
                list = v.vlist();
                v.set(byencoded, e, list);
            }
            v.push(list, v.vstr(r));
        }
    }

    const encs = v.sortedKeys(byencoded);
    for (encs) |e| {
        const claims = v.get(byencoded, e);
        if (v.len(claims) > 1) {
            const a = v.asStr(v.at(claims, 0));
            const b = v.asStr(v.at(claims, 1));
            const lo = if (std.mem.order(u8, a, b) != .gt) a else b;
            const hi = if (std.mem.order(u8, a, b) != .gt) b else a;
            const pair = v.vlist();
            v.push(pair, v.vstr(lo));
            v.push(pair, v.vstr(hi));
            const d = v.vmap();
            v.set(d, "encoded", v.vstr(e));
            v.set(d, "refs", pair);
            return t.fail("plugin_env_ambiguous", v.print("refs collide in the environment encoding as {s}: {s}, {s}", .{ e, lo, hi }), d);
        }
    }

    // LONGEST encoded ref first, so `retry$fast` wins over `retry` on
    // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    const order = v.arena().alloc([]const u8, encs.len) catch @panic("oom");
    @memcpy(order, encs);
    std.mem.sort([]const u8, order, {}, lessByLenDesc);

    for (v.sortedKeys(env)) |key| {
        if (key.len < PREFIX.len or !std.mem.eql(u8, key[0..PREFIX.len], PREFIX)) continue;
        const rest = key[PREFIX.len..];
        const raw = v.get(env, key);
        const val = if (v.isStr(raw)) v.asStr(raw) else "";

        if (std.mem.eql(u8, rest, "PROFILE")) {
            v.set(out, "profile", v.vstr(val));
            continue;
        }

        if (std.mem.eql(u8, rest, "ACTIVE") or std.mem.eql(u8, rest, "INACTIVE")) {
            const isactive = std.mem.eql(u8, rest, "ACTIVE");
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |piece| {
                const p = trim(piece);
                if (p.len == 0) continue;
                const c = try ref.canonrefs(p);
                // The reservation covers EVERY input layer (§9.1).
                // VOXGIG_PLUGIN_INACTIVE=station is easier to set than
                // editing a config file, and INACTIVE has the final word
                // — so guarding documents alone would leave the one
                // lever this mechanism exists to deny wide open.
                try checkreserved(c, reserved);
                v.push(if (isactive) active else inactive, v.vstr(c));
            }
            continue;
        }

        var enc: ?[]const u8 = null;
        for (order) |cand| {
            if (std.mem.eql(u8, rest, cand) or
                (rest.len > cand.len and std.mem.eql(u8, rest[0..cand.len], cand) and rest[cand.len] == '_'))
            {
                enc = cand;
                break;
            }
        }
        const e = enc orelse continue; // not for any ref this host holds

        const r = v.asStr(v.at(v.get(byencoded, e), 0));
        try checkreserved(r, reserved);

        if (std.mem.eql(u8, rest, e)) continue; // a ref with no path sets nothing

        const pathtext = rest[e.len + 1 ..];
        var node = v.get(options, r);
        if (v.isNull(node)) {
            node = v.vmap();
            v.set(options, r, node);
        }

        var segs = std.mem.splitScalar(u8, pathtext, '_');
        var seg = segs.next().?;
        while (segs.peek() != null) : (seg = segs.next().?) {
            const piece = lower(seg);
            var next = v.get(node, piece);
            if (!v.isMap(next)) {
                next = v.vmap();
                v.set(node, piece, next);
            }
            node = next;
        }
        v.set(node, lower(seg), parsevalue(val));
    }

    return out;
}
