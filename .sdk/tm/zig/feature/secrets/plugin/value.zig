// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/value.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The dynamic value, and the JSON reader that fills it (§16).
//!
//! HAND-WRITTEN, THOUGH `std.json` EXISTS. That is a choice, not a
//! constraint: zig's `std.json` is the standard library, so §16 would
//! permit it, and its `ObjectMap` even preserves insertion order. The
//! reason to write the reader here is symmetry — `c`, `cpp`, `ocaml`
//! and `haskell` all carry the same 200-line reader, the corpus is the
//! only thing it ever reads, and a port whose value type is its own is
//! a port whose ordering rules are visible in one place.
//!
//! ARENA ALLOCATION, for the reason `c` gives: every Value lives in one
//! arena and the whole arena is freed at once. Nothing frees an
//! individual value, so nothing can double-free one. Zig hands the
//! arena over in the standard library rather than making the port build
//! it.

const std = @import("std");
const builtin = @import("builtin");

/// TWO TOOLCHAINS, ONE SOURCE. This port's own CI builds it on zig 0.13,
/// and its first consumer (voxgig/sekreto) builds it on zig 0.16, and
/// the two standard libraries disagree in exactly three places: the
/// managed list, file I/O, and the environment. `modern` is the one
/// switch, and every difference is a comptime branch on it, so the
/// untaken branch is never analysed against a standard library that
/// lacks it.
pub const modern = builtin.zig_version.major > 0 or builtin.zig_version.minor >= 15;

/// The list whose allocator travels with it. Zig 0.15 made
/// `std.ArrayList` unmanaged and moved the managed one to
/// `std.array_list.Managed`; the API is the same on both sides of the
/// move, so this alias is the whole of the difference.
pub fn List(comptime T: type) type {
    return if (modern) std.array_list.Managed(T) else std.ArrayList(T);
}

pub const Kind = enum { nul, boolean, num, str, list, map };

pub const Entry = struct {
    key: []const u8,
    val: *Value,
};

pub const Value = struct {
    kind: Kind = .nul,
    boolean: bool = false,
    num: f64 = 0,
    str: []const u8 = "",
    /// A list preserves order because it IS the order.
    items: List(*Value) = undefined,
    /// A MAP PRESERVES INSERTION ORDER AND SORTS ON DEMAND. §4 rule 4
    /// makes order observable in several places (`keys` is sorted, `pos`
    /// is the sorted-ref index), so both orders have to be available and
    /// the code has to say which it means at each use. An ArrayList of
    /// entries rather than a hash map: these maps hold a handful of keys.
    entries: List(Entry) = undefined,
};

// --- the arena --------------------------------------------------------

var arena_state: ?std.heap.ArenaAllocator = null;

pub fn arena() std.mem.Allocator {
    if (arena_state == null) {
        arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return arena_state.?.allocator();
}

/// Free EVERYTHING. Call between corpus entries, never inside one.
pub fn arenaReset() void {
    if (arena_state) |*a| {
        _ = a.reset(.free_all);
    }
}

/// Allocation failure is fatal: a library that limps on after it cannot
/// be reasoned about and the corpus cannot express it.
fn alloc(comptime T: type, n: usize) []T {
    return arena().alloc(T, n) catch @panic("plugin: out of memory");
}

pub fn dupe(s: []const u8) []const u8 {
    const out = alloc(u8, s.len);
    @memcpy(out, s);
    return out;
}

pub fn print(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena(), fmt, args) catch @panic("plugin: out of memory");
}

// --- construction -----------------------------------------------------

fn make() *Value {
    const v = arena().create(Value) catch @panic("plugin: out of memory");
    v.* = .{};
    return v;
}

pub fn vnull() *Value {
    return make();
}

pub fn vbool(b: bool) *Value {
    const v = make();
    v.kind = .boolean;
    v.boolean = b;
    return v;
}

pub fn vnum(n: f64) *Value {
    const v = make();
    v.kind = .num;
    v.num = n;
    return v;
}

pub fn vstr(s: []const u8) *Value {
    const v = make();
    v.kind = .str;
    v.str = s;
    return v;
}

pub fn vlist() *Value {
    const v = make();
    v.kind = .list;
    v.items = List(*Value).init(arena());
    return v;
}

pub fn vmap() *Value {
    const v = make();
    v.kind = .map;
    v.entries = List(Entry).init(arena());
    return v;
}

// --- kinds ------------------------------------------------------------

/// A NULL POINTER MEANS "NOTHING"; a `.nul` Value means "JSON null".
/// They are different answers and several places need both: a `bail`
/// binding declining is not one answering null, and a missing export is
/// not an export of null. Every accessor tolerates a null pointer.
pub fn isNull(v: ?*const Value) bool {
    return v == null or v.?.kind == .nul;
}
pub fn isBool(v: ?*const Value) bool {
    return v != null and v.?.kind == .boolean;
}
pub fn isNum(v: ?*const Value) bool {
    return v != null and v.?.kind == .num;
}
pub fn isStr(v: ?*const Value) bool {
    return v != null and v.?.kind == .str;
}
pub fn isList(v: ?*const Value) bool {
    return v != null and v.?.kind == .list;
}
pub fn isMap(v: ?*const Value) bool {
    return v != null and v.?.kind == .map;
}

// --- access -----------------------------------------------------------

/// `get` answers a null Value for a missing key AND for a key holding
/// JSON null; `has` distinguishes them, which is what §9.1's "an
/// authored null is not an absent key" needs.
pub fn get(m: ?*const Value, key: []const u8) *Value {
    if (!isMap(m)) return vnull();
    for (m.?.entries.items) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.val;
    }
    return vnull();
}

pub fn has(m: ?*const Value, key: []const u8) bool {
    if (!isMap(m)) return false;
    for (m.?.entries.items) |e| {
        if (std.mem.eql(u8, e.key, key)) return true;
    }
    return false;
}

pub fn set(m: ?*Value, key: []const u8, val: ?*Value) void {
    if (!isMap(m)) return;
    const v = val orelse vnull();
    for (m.?.entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) {
            e.val = v;
            return;
        }
    }
    m.?.entries.append(.{ .key = dupe(key), .val = v }) catch @panic("plugin: out of memory");
}

pub fn del(m: ?*Value, key: []const u8) void {
    if (!isMap(m)) return;
    var i: usize = 0;
    while (i < m.?.entries.items.len) : (i += 1) {
        if (std.mem.eql(u8, m.?.entries.items[i].key, key)) {
            _ = m.?.entries.orderedRemove(i);
            return;
        }
    }
}

pub fn at(l: ?*const Value, i: usize) *Value {
    if (!isList(l) or i >= l.?.items.items.len) return vnull();
    return l.?.items.items[i];
}

pub fn push(l: ?*Value, item: ?*Value) void {
    if (!isList(l)) return;
    l.?.items.append(item orelse vnull()) catch @panic("plugin: out of memory");
}

pub fn len(v: ?*const Value) usize {
    if (v == null) return 0;
    return switch (v.?.kind) {
        .list => v.?.items.items.len,
        .map => v.?.entries.items.len,
        else => 0,
    };
}

pub fn items(v: ?*const Value) []*Value {
    if (!isList(v)) return &[_]*Value{};
    return v.?.items.items;
}

pub fn asStr(v: ?*const Value) []const u8 {
    return if (isStr(v)) v.?.str else "";
}
pub fn asNum(v: ?*const Value) f64 {
    return if (isNum(v)) v.?.num else 0;
}
pub fn asBool(v: ?*const Value) bool {
    return isBool(v) and v.?.boolean;
}

/// Keys in INSERTION order.
pub fn keys(m: ?*const Value) [][]const u8 {
    if (!isMap(m)) return &[_][]const u8{};
    const out = alloc([]const u8, m.?.entries.items.len);
    for (m.?.entries.items, 0..) |e, i| out[i] = e.key;
    return out;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Keys SORTED by byte order — §4 rule 4's deterministic walk.
pub fn sortedKeys(m: ?*const Value) [][]const u8 {
    const out = keys(m);
    std.mem.sort([]const u8, out, {}, lessStr);
    return out;
}

/// §4 rule 4: truthiness is JSON's, not zig's.
pub fn truthy(v: ?*const Value) bool {
    if (v == null) return false;
    return switch (v.?.kind) {
        .nul => false,
        .boolean => v.?.boolean,
        .num => v.?.num != 0,
        .str => v.?.str.len != 0,
        else => true,
    };
}

/// Deep equality INCLUDING JSON type, which is the half that matters:
/// half the ports are written in languages whose `==` says `true == 1`,
/// and `capability/match` exists to catch exactly that.
pub fn same(a: ?*const Value, b: ?*const Value) bool {
    const anull = isNull(a);
    const bnull = isNull(b);
    if (anull or bnull) return anull and bnull;
    if (a.?.kind != b.?.kind) return false;
    return switch (a.?.kind) {
        .boolean => a.?.boolean == b.?.boolean,
        .num => a.?.num == b.?.num,
        .str => std.mem.eql(u8, a.?.str, b.?.str),
        .list => blk: {
            if (len(a) != len(b)) break :blk false;
            for (a.?.items.items, 0..) |x, i| {
                if (!same(x, at(b, i))) break :blk false;
            }
            break :blk true;
        },
        .map => blk: {
            if (len(a) != len(b)) break :blk false;
            for (a.?.entries.items) |e| {
                if (!has(b, e.key)) break :blk false;
                if (!same(e.val, get(b, e.key))) break :blk false;
            }
            break :blk true;
        },
        else => true,
    };
}

pub fn clone(v: ?*const Value) ?*Value {
    if (v == null) return null;
    return switch (v.?.kind) {
        .list => blk: {
            const out = vlist();
            for (v.?.items.items) |x| push(out, clone(x));
            break :blk out;
        },
        .map => blk: {
            const out = vmap();
            for (v.?.entries.items) |e| set(out, e.key, clone(e.val));
            break :blk out;
        },
        .boolean => vbool(v.?.boolean),
        .num => vnum(v.?.num),
        .str => vstr(v.?.str),
        else => vnull(),
    };
}

// --- json -------------------------------------------------------------

/// An integral float renders as an integer: the corpus's expected values
/// are written `1`, not `1.0`, and a port that emits the latter fails
/// every comparison for a reason that has nothing to do with the
/// behaviour under test.
pub fn numStr(n: f64) []const u8 {
    if (std.math.isFinite(n) and n == @trunc(n) and @abs(n) < 1e18) {
        return print("{d}", .{@as(i64, @intFromFloat(n))});
    }
    return print("{d}", .{n});
}

fn escape(s: []const u8, buf: *List(u8)) void {
    buf.append('"') catch @panic("oom");
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice("\\\"") catch @panic("oom"),
            '\\' => buf.appendSlice("\\\\") catch @panic("oom"),
            '\n' => buf.appendSlice("\\n") catch @panic("oom"),
            '\r' => buf.appendSlice("\\r") catch @panic("oom"),
            '\t' => buf.appendSlice("\\t") catch @panic("oom"),
            0x08 => buf.appendSlice("\\b") catch @panic("oom"),
            0x0C => buf.appendSlice("\\f") catch @panic("oom"),
            else => {
                if (c < 0x20) {
                    buf.appendSlice(print("\\u{x:0>4}", .{c})) catch @panic("oom");
                } else {
                    buf.append(c) catch @panic("oom");
                }
            },
        }
    }
    buf.append('"') catch @panic("oom");
}

fn render(v: ?*const Value, buf: *List(u8)) void {
    if (isNull(v)) {
        buf.appendSlice("null") catch @panic("oom");
        return;
    }
    switch (v.?.kind) {
        .boolean => buf.appendSlice(if (v.?.boolean) "true" else "false") catch @panic("oom"),
        .num => buf.appendSlice(numStr(v.?.num)) catch @panic("oom"),
        .str => escape(v.?.str, buf),
        .list => {
            buf.append('[') catch @panic("oom");
            for (v.?.items.items, 0..) |x, i| {
                if (i > 0) buf.append(',') catch @panic("oom");
                render(x, buf);
            }
            buf.append(']') catch @panic("oom");
        },
        .map => {
            // SORTED, so two values that are `same` render identically.
            buf.append('{') catch @panic("oom");
            for (sortedKeys(v), 0..) |k, i| {
                if (i > 0) buf.append(',') catch @panic("oom");
                escape(k, buf);
                buf.append(':') catch @panic("oom");
                render(get(v, k), buf);
            }
            buf.append('}') catch @panic("oom");
        },
        else => buf.appendSlice("null") catch @panic("oom"),
    }
}

pub fn json(v: ?*const Value) []const u8 {
    var buf = List(u8).init(arena());
    render(v, &buf);
    return buf.items;
}

pub const ParseError = error{BadJson};

const Parser = struct {
    text: []const u8,
    i: usize = 0,
    err: []const u8 = "",

    fn digit(p: *Parser) bool {
        return p.i < p.text.len and p.text[p.i] >= '0' and p.text[p.i] <= '9';
    }

    fn skip(p: *Parser) void {
        while (p.i < p.text.len) {
            const c = p.text[p.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') p.i += 1 else break;
        }
    }

    fn lit(p: *Parser, word: []const u8) bool {
        if (p.i + word.len > p.text.len) return false;
        if (!std.mem.eql(u8, p.text[p.i .. p.i + word.len], word)) return false;
        p.i += word.len;
        return true;
    }

    fn hex4(p: *Parser) ?u21 {
        if (p.i + 4 > p.text.len) return null;
        var acc: u21 = 0;
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const d = std.fmt.charToDigit(p.text[p.i + k], 16) catch return null;
            acc = acc * 16 + d;
        }
        p.i += 4;
        return acc;
    }

    fn string(p: *Parser, buf: *List(u8)) bool {
        if (p.i >= p.text.len or p.text[p.i] != '"') {
            p.err = "expected a string";
            return false;
        }
        p.i += 1;
        while (p.i < p.text.len and p.text[p.i] != '"') {
            const c = p.text[p.i];
            if (c != '\\') {
                buf.append(c) catch @panic("oom");
                p.i += 1;
                continue;
            }
            p.i += 1;
            if (p.i >= p.text.len) {
                p.err = "unterminated escape";
                return false;
            }
            const e = p.text[p.i];
            p.i += 1;
            switch (e) {
                '"' => buf.append('"') catch @panic("oom"),
                '\\' => buf.append('\\') catch @panic("oom"),
                '/' => buf.append('/') catch @panic("oom"),
                'n' => buf.append('\n') catch @panic("oom"),
                'r' => buf.append('\r') catch @panic("oom"),
                't' => buf.append('\t') catch @panic("oom"),
                'b' => buf.append(0x08) catch @panic("oom"),
                'f' => buf.append(0x0C) catch @panic("oom"),
                'u' => {
                    const hi = p.hex4() orelse {
                        p.err = "bad \\u escape";
                        return false;
                    };
                    var cp: u21 = hi;
                    if (hi >= 0xD800 and hi <= 0xDBFF and p.i + 1 < p.text.len and
                        p.text[p.i] == '\\' and p.text[p.i + 1] == 'u')
                    {
                        p.i += 2;
                        const lo = p.hex4() orelse {
                            p.err = "bad \\u escape";
                            return false;
                        };
                        cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &tmp) catch {
                        p.err = "bad code point";
                        return false;
                    };
                    buf.appendSlice(tmp[0..n]) catch @panic("oom");
                },
                else => {
                    p.err = "bad escape";
                    return false;
                },
            }
        }
        if (p.i >= p.text.len) {
            p.err = "unterminated string";
            return false;
        }
        p.i += 1;
        return true;
    }

    fn value(p: *Parser) ?*Value {
        p.skip();
        if (p.i >= p.text.len) {
            p.err = "unexpected end of input";
            return null;
        }
        const c = p.text[p.i];

        if (c == 'n') {
            if (!p.lit("null")) {
                p.err = "bad literal";
                return null;
            }
            return vnull();
        }
        if (c == 't') {
            if (!p.lit("true")) {
                p.err = "bad literal";
                return null;
            }
            return vbool(true);
        }
        if (c == 'f') {
            if (!p.lit("false")) {
                p.err = "bad literal";
                return null;
            }
            return vbool(false);
        }
        if (c == '"') {
            var buf = List(u8).init(arena());
            if (!p.string(&buf)) return null;
            return vstr(buf.items);
        }
        if (c == '[') {
            p.i += 1;
            const out = vlist();
            p.skip();
            if (p.i < p.text.len and p.text[p.i] == ']') {
                p.i += 1;
                return out;
            }
            while (true) {
                const item = p.value() orelse return null;
                push(out, item);
                p.skip();
                if (p.i < p.text.len and p.text[p.i] == ',') {
                    p.i += 1;
                    continue;
                }
                if (p.i < p.text.len and p.text[p.i] == ']') {
                    p.i += 1;
                    return out;
                }
                p.err = "expected , or ] in array";
                return null;
            }
        }
        if (c == '{') {
            p.i += 1;
            const out = vmap();
            p.skip();
            if (p.i < p.text.len and p.text[p.i] == '}') {
                p.i += 1;
                return out;
            }
            while (true) {
                p.skip();
                var kbuf = List(u8).init(arena());
                if (!p.string(&kbuf)) return null;
                p.skip();
                if (p.i >= p.text.len or p.text[p.i] != ':') {
                    p.err = "expected : in object";
                    return null;
                }
                p.i += 1;
                const val = p.value() orelse return null;
                set(out, kbuf.items, val);
                p.skip();
                if (p.i < p.text.len and p.text[p.i] == ',') {
                    p.i += 1;
                    continue;
                }
                if (p.i < p.text.len and p.text[p.i] == '}') {
                    p.i += 1;
                    return out;
                }
                p.err = "expected , or } in object";
                return null;
            }
        }

        // JSON's number grammar is STRICT, and §9.5 makes that
        // observable: env values "parse as JSON, falling back to
        // string", so anything this reader accepts loosely silently
        // becomes a number where the canonical keeps the authored
        // string. `1e`, `1.`, `01`, `.5` and a bare `-` are all errors
        // to JSON.parse; only `-0` and `1e5` are not.
        //
        //   number = [ '-' ] int [ frac ] [ exp ]
        //   int    = '0' | digit1-9 *digit
        //   frac   = '.' 1*digit
        //   exp    = ('e'|'E') [ '+' | '-' ] 1*digit
        const start = p.i;
        if (p.i < p.text.len and p.text[p.i] == '-') p.i += 1;
        if (!p.digit()) {
            p.err = "bad number";
            return null;
        }
        if (p.text[p.i] == '0') p.i += 1 else while (p.digit()) p.i += 1;
        if (p.i < p.text.len and p.text[p.i] == '.') {
            p.i += 1;
            if (!p.digit()) {
                p.err = "bad number";
                return null;
            }
            while (p.digit()) p.i += 1;
        }
        if (p.i < p.text.len and (p.text[p.i] == 'e' or p.text[p.i] == 'E')) {
            p.i += 1;
            if (p.i < p.text.len and (p.text[p.i] == '+' or p.text[p.i] == '-')) p.i += 1;
            if (!p.digit()) {
                p.err = "bad number";
                return null;
            }
            while (p.digit()) p.i += 1;
        }
        if (start == p.i) {
            p.err = "unexpected character";
            return null;
        }
        // A REPORTED failure, not a crash: a bare `-` or a truncated
        // `1e` reaches here from `env`'s parse-or-string fallback (§9.5),
        // and a reader that panics on a bad number rather than reporting
        // one turns "this env value is a string" into a crash. The ocaml
        // port hit this first.
        const n = std.fmt.parseFloat(f64, p.text[start..p.i]) catch {
            p.err = "bad number";
            return null;
        };
        return vnum(n);
    }
};

/// Parse, or null with `err` set to a message.
pub fn parse(text: []const u8, err: *[]const u8) ?*Value {
    var p = Parser{ .text = text };
    const out = p.value() orelse {
        err.* = p.err;
        return null;
    };
    p.skip();
    if (p.i != p.text.len) {
        err.* = "trailing content";
        return null;
    }
    return out;
}
