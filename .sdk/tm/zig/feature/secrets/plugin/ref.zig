// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/ref.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Identity: name+tag, written `name$tag` (§4).
//!
//! The four pure functions, and the whole of what `ref` pins. They are
//! the first thing a new port implements and the first corpus section
//! it passes.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");

const MAX_REF = 1024;

fn isNameHead(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '@';
}

fn isNameBody(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '~' or c == '_' or c == '-' or c == '/';
}

fn isTagChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '~' or c == '_' or c == '-';
}

fn namely(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_REF) return false;
    if (!isNameHead(name[0])) return false;
    for (name[1..]) |c| {
        if (!isNameBody(c)) return false;
    }
    return true;
}

fn tagly(tag: []const u8) bool {
    // The empty tag is an ordinary tag (§4 rule 2). The single-instance
    // case writes no tag and never learns tags exist.
    if (tag.len == 0) return true;
    if (tag.len > MAX_REF) return false;
    for (tag) |c| {
        if (!isTagChar(c)) return false;
    }
    return true;
}

/// A non-string is not a name. Every port has to answer this the same
/// way, and `ref/name` pins it for numbers, nulls and maps alike.
pub fn checkname(name: ?*const v.Value) bool {
    return v.isStr(name) and namely(v.asStr(name));
}

/// The asymmetry with a name is deliberate: a tag MAY start with a digit
/// because auto-tagging assigns integer tags (`stripe$1`), and a tag
/// admits neither `@` nor `/` because a name is a package specifier and
/// a tag is not.
pub fn checktag(tag: ?*const v.Value) bool {
    return v.isStr(tag) and tagly(v.asStr(tag));
}

const Split = struct { name: []const u8, tag: []const u8 };

/// Split on the FIRST `$`. Nothing in the grammar decides this — `$` is
/// in neither character class — so the corpus is the arbiter (§4 rule
/// 5), and it picks the split that blames the part actually at fault:
/// `a$b$c` is a good name with a bad tag, not the reverse.
fn split(s: []const u8) Split {
    const cut = std.mem.indexOfScalar(u8, s, '$') orelse return .{ .name = s, .tag = "" };
    return .{ .name = s[0..cut], .tag = s[cut + 1 ..] };
}

pub fn parseref(str: ?*const v.Value) t.Err!*v.Value {
    if (!v.isStr(str)) return t.fail("plugin_bad_name", "ref must be a string", null);
    const sp = split(v.asStr(str));
    if (!namely(sp.name)) {
        return t.fail("plugin_bad_name", v.print("invalid plugin name: {s}", .{sp.name}), t.details1("name", v.vstr(sp.name)));
    }
    if (!tagly(sp.tag)) {
        return t.fail("plugin_bad_tag", v.print("invalid plugin tag: {s}", .{sp.tag}), t.details2("name", v.vstr(sp.name), "tag", v.vstr(sp.tag)));
    }
    const out = v.vmap();
    v.set(out, "name", v.vstr(sp.name));
    v.set(out, "tag", v.vstr(sp.tag));
    return out;
}

/// An empty tag NEVER writes the separator, which is the half of
/// canonicalization formatref owns: parse tolerates `stripe$`, format
/// never produces it, so a round trip is idempotent.
pub fn formatref(name: ?*v.Value, tag: ?*v.Value) t.Err![]const u8 {
    const tagok = v.isNull(tag) or v.isStr(tag);
    const tg = if (v.isStr(tag)) v.asStr(tag) else "";

    if (!checkname(name)) {
        const shown = if (v.isStr(name)) v.asStr(name) else "";
        return t.fail("plugin_bad_name", v.print("invalid plugin name: {s}", .{shown}), t.details1("name", if (v.isNull(name)) v.vnull() else name));
    }
    if (!tagok or !tagly(tg)) {
        return t.fail("plugin_bad_tag", v.print("invalid plugin tag: {s}", .{tg}), t.details2("name", name, "tag", if (v.isNull(tag)) v.vstr("") else tag));
    }

    if (tg.len == 0) return v.asStr(name);
    return v.print("{s}${s}", .{ v.asStr(name), tg });
}

/// The canonical spelling. §4 rule 5: canonicalize before comparison.
pub fn canonref(str: ?*const v.Value) t.Err![]const u8 {
    const r = try parseref(str);
    return formatref(v.get(r, "name"), v.get(r, "tag"));
}

pub fn canonrefs(str: []const u8) t.Err![]const u8 {
    return canonref(v.vstr(str));
}

/// The canonical ref this string denotes, or null if it denotes none —
/// the TOLERANT half of `canonref`, and the one a requirement name needs
/// (§11.1). Capability names are free-form, so `2fa` is a good one and
/// no ref could be called that; `canonref` FAILS on those, and asking it
/// "is this a ref?" made a legal document kill the host.
///
/// An optional, so a caller cannot mistake "not a ref" for "the empty
/// ref" — and infallible, because it answers rather than raises.
pub fn tryref(str: []const u8) ?[]const u8 {
    const sp = split(str);
    if (!namely(sp.name) or !tagly(sp.tag)) return null;
    if (sp.tag.len == 0) return sp.name;
    return v.print("{s}${s}", .{ sp.name, sp.tag });
}

/// `canonref` for internal callers that want the input back unchanged
/// when it is not well formed. NEVER use where a bad ref must be
/// reported — the corpus pins plugin_bad_name at every public entry.
pub fn canon(str: []const u8) []const u8 {
    return tryref(str) orelse str;
}

/// The name half, for internal callers that only compare.
pub fn refname(str: []const u8) []const u8 {
    const sp = split(str);
    return if (namely(sp.name)) sp.name else str;
}
