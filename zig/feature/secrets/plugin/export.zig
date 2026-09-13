// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/export.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Exports (§11).
//!
//! THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client`
//! resolves to the UNTAGGED instance if one exists; if not, and exactly
//! one tagged instance exports that key, it resolves to that one; if two
//! do, it is `plugin_export_ambiguous` — deliberately diverging from
//! seneca's silent last-wins, because with multi-instance as a headline
//! feature an ambiguous alias is a defect waiting for production.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const ref = @import("ref.zig");

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Answers null for "no such export", which is not an error —
/// `export/missing` pins that, and is why the answer is an optional
/// rather than a null Value.
pub fn resolveexport(spec: ?*v.Value, exported: ?*v.Value) t.Err!?*v.Value {
    const s = if (v.isStr(spec)) v.asStr(spec) else "";
    const cut = std.mem.indexOfScalar(u8, s, '/') orelse
        return t.fail("plugin_export_ambiguous", v.print("export spec needs a key: {s}", .{s}), t.details1("spec", v.vstr(s)));
    const head = s[0..cut];
    const key = s[cut + 1 ..];

    // A fully qualified ref: exactly one answer or none.
    //
    // VALIDATING, not tolerant. The canonical calls `canonref(head)`,
    // which RAISES — so `retry$bad!/client` is `plugin_bad_tag` and
    // `2fa/client` is `plugin_bad_name`. Reading it with `tryref`
    // turned a configuration typo into an ordinary missing export,
    // which is the error the caller most needs to see, silently
    // swallowed.
    const want = try ref.canonrefs(head);
    for (v.items(exported)) |e| {
        if (std.mem.eql(u8, v.asStr(v.get(e, "ref")), want) and
            std.mem.eql(u8, v.asStr(v.get(e, "key")), key))
        {
            return v.get(e, "value");
        }
    }

    // An alias: the NAME, not a ref. Look at every instance of it.
    var byname = v.List(*v.Value).init(v.arena());
    for (v.items(exported)) |e| {
        const eref = v.asStr(v.get(e, "ref"));
        if (std.mem.eql(u8, ref.refname(eref), head) and
            std.mem.eql(u8, v.asStr(v.get(e, "key")), key))
        {
            byname.append(e) catch @panic("oom");
        }
    }
    if (byname.items.len == 0) return null;

    // The untagged instance wins outright when there is one.
    for (byname.items) |e| {
        if (std.mem.indexOfScalar(u8, v.asStr(v.get(e, "ref")), '$') == null) return v.get(e, "value");
    }

    if (byname.items.len == 1) return v.get(byname.items[0], "value");

    const refs = v.arena().alloc([]const u8, byname.items.len) catch @panic("oom");
    for (byname.items, 0..) |e, i| refs[i] = v.asStr(v.get(e, "ref"));
    std.mem.sort([]const u8, refs, {}, lessStr);

    const list = v.vlist();
    var names = v.List(u8).init(v.arena());
    for (refs, 0..) |r, i| {
        if (i > 0) names.appendSlice(", ") catch @panic("oom");
        names.appendSlice(r) catch @panic("oom");
        v.push(list, v.vstr(r));
    }
    const d = v.vmap();
    v.set(d, "spec", v.vstr(s));
    v.set(d, "refs", list);
    return t.fail("plugin_export_ambiguous", v.print("alias {s} matches {d} instances: {s}", .{ s, byname.items.len, names.items }), d);
}
