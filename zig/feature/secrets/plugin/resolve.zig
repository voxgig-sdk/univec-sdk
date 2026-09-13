// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/resolve.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Dynamic resolution (§10.2) — name to candidate module ids.
//!
//! PURE. It returns the ids a host WOULD try, in order; it does not load
//! anything. That separation is what lets the corpus pin resolution in
//! every language including those with no dynamic loading at all — zig
//! among them — and it is why §15.4 puts real module loading in per-port
//! integration tests rather than here.

const std = @import("std");
const v = @import("value.zig");

fn pushuniq(out: *v.Value, id: []const u8) void {
    for (v.items(out)) |x| {
        if (std.mem.eql(u8, v.asStr(x), id)) return;
    }
    v.push(out, v.vstr(id));
}

const DEFAULT_PREFIX = [_][]const u8{ "@voxgig/plugin-", "voxgig-plugin-", "plugin-", "" };

pub fn resolvecandidates(name: ?*v.Value, sources: ?*v.Value) *v.Value {
    const out = v.vlist();
    const n = if (v.isStr(name)) v.asStr(name) else "";

    // A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
    // already a package id; prefixing it produces
    // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    if (n.len > 0 and n[0] == '@') {
        v.push(out, v.vstr(n));
        return out;
    }

    if (!(v.isList(sources) and v.len(sources) > 0)) {
        for (DEFAULT_PREFIX) |p| pushuniq(out, v.print("{s}{s}", .{ p, n }));
        return out;
    }

    for (v.items(sources)) |src| {
        const kind = v.asStr(v.get(src, "kind"));
        if (std.mem.eql(u8, kind, "module")) {
            const prefix = v.get(src, "prefix");
            if (v.isList(prefix) and v.len(prefix) > 0) {
                for (v.items(prefix)) |p| pushuniq(out, v.print("{s}{s}", .{ v.asStr(p), n }));
            } else {
                pushuniq(out, n);
            }
        } else if (std.mem.eql(u8, kind, "path")) {
            var dir = v.asStr(v.get(src, "dir"));
            // Trailing slashes are trimmed, so `lib/` and `lib` give one
            // id rather than two spellings of it.
            while (dir.len > 0 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
            pushuniq(out, v.print("{s}/{s}", .{ dir, n }));
        }
    }

    return out;
}

/// A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name
/// with a letter or `@`, so `./local/thing` is not a ref and never
/// reaches candidate generation — seneca allows a path where a plugin
/// name goes, and this design deliberately does not, because a ref is an
/// ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
///
/// Loading from an explicit location bypasses candidate generation
/// entirely: `from` is passed to the resolver verbatim.
pub fn resolvefrom(from: ?*v.Value) *v.Value {
    const out = v.vlist();
    v.push(out, if (v.isNull(from)) v.vnull() else from);
    return out;
}
