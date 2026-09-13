// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/point.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Extension points (§6). Three kinds, chosen because they are what the
//! two existing systems actually needed, and no more.
//!
//! A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
//! deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
//! undoable, but "this instance holds slot 3 of the request chain" is
//! undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
//! paper called *Listeners Considered Harmful*, and for exactly this
//! reason.
//!
//! A CLOSURE IN ZIG IS A FUNCTION POINTER PLUS A CONTEXT, exactly as in
//! `c`. Zig has no closures: a function literal that captures is not a
//! value you can store. So `chain` gets an explicit `Chain *` to call
//! back into, and a binding's `ctx` is its instance — the same shape the
//! `c` port has, for the same reason, in a language forty years newer.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");

/// The remaining composition, as seen by one chain binding. A binding
/// may CALL it and must not store it — a plugin that stashes `next` and
/// calls it after deactivation is a bug the host cannot prevent, and
/// saying so is better than pretending otherwise (§6.2).
pub const Chain = struct {
    bindings: []Bound,
    i: usize,
    base: ?*const fn (?*v.Value, ?*anyopaque) t.Err!?*v.Value,
    basectx: ?*anyopaque,
};

/// A binding answers with an optional: null DECLINES, a value answers.
pub const HookFn = *const fn (?*v.Value, ?*anyopaque) t.Err!?*v.Value;
pub const ChainFn = *const fn (*Chain, ?*v.Value, ?*anyopaque) t.Err!?*v.Value;

pub const Bound = struct {
    ref: []const u8,
    point: []const u8,
    /// `provider` ranks by HIGHEST band, unlike hook and chain which run
    /// lowest first. Kept as declared so the two rules stay visibly
    /// different rather than one being derived from the other by a
    /// reader who then gets it backwards.
    band: f64 = 0,
    hook: ?HookFn = null,
    chain: ?ChainFn = null,
    ctx: ?*anyopaque = null,
};

/// Call the rest of the composition.
pub fn chainNext(c: *Chain, arg: ?*v.Value) t.Err!?*v.Value {
    if (c.i >= c.bindings.len) {
        if (c.base) |b| return b(arg, c.basectx);
        return arg;
    }
    const b = c.bindings[c.i];
    var rest = Chain{ .bindings = c.bindings, .i = c.i + 1, .base = c.base, .basectx = c.basectx };
    return b.chain.?(&rest, arg, b.ctx);
}

/// Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2).
pub fn pointcall(
    bindings: []Bound,
    base: ?*const fn (?*v.Value, ?*anyopaque) t.Err!?*v.Value,
    basectx: ?*anyopaque,
    arg: ?*v.Value,
) t.Err!?*v.Value {
    var c = Chain{ .bindings = bindings, .i = 0, .base = base, .basectx = basectx };
    return chainNext(&c, arg);
}

pub const EmitResult = struct { value: ?*v.Value, errors: *v.Value };

/// Fan-out. Return values are ignored except in `bail`.
///
/// §6.1: "fan-out" is not one answer but four. In a language with
/// asynchrony, "call every binding" hides a decision — start them all
/// and wait, await each in turn, or do not wait — and a design that
/// leaves it unsaid gets four different answers from four ports, in the
/// concurrency behaviour of production code no corpus entry happens to
/// cover. Zig has no asynchrony here, so all four modes are sequential
/// and only the ERROR and RETURN handling distinguishes them.
pub fn pointemit(bindings: []Bound, mode: []const u8, arg: ?*v.Value) t.Err!EmitResult {
    const errors = v.vlist();

    if (std.mem.eql(u8, mode, "bail")) {
        // Stops at the first binding that RETURNS A VALUE — the
        // "handled, stop" case. A null, AND A JSON NULL, BOTH DECLINE.
        //
        // JavaScript can tell null from undefined and almost nothing
        // else in the target set can — Go, Python, Ruby, PHP, Lua, Java
        // and C# each have exactly one way to say nothing, and zig has
        // one too. Making the distinction load-bearing would cost every
        // one of them a wrapper type carried through the whole dispatch
        // path, to express a difference their plugin authors cannot
        // write. §18's budget settles it (§6.1).
        for (bindings) |b| {
            const x = try b.hook.?(arg, b.ctx);
            if (!v.isNull(x)) return .{ .value = x, .errors = errors };
        }
        return .{ .value = null, .errors = errors };
    }

    const raising = std.mem.eql(u8, mode, "emit");
    for (bindings) |b| {
        if (raising) {
            // `emit` raises synchronously; the collecting modes gather.
            _ = try b.hook.?(arg, b.ctx);
            continue;
        }
        _ = b.hook.?(arg, b.ctx) catch {
            const e = t.take();
            const rec = v.vmap();
            v.set(rec, "code", v.vstr(e.code));
            v.set(rec, "message", v.vstr(e.message));
            v.push(errors, rec);
        };
    }
    return .{ .value = null, .errors = errors };
}

fn lessProv(_: void, a: Bound, b: Bound) bool {
    // HIGHEST band wins, unlike hook and chain; ties break by ref sort,
    // which is a TOTAL order.
    if (a.band != b.band) return a.band > b.band;
    return std.mem.order(u8, a.ref, b.ref) == .lt;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub const ProviderResult = struct { winner: ?Bound, shadowed: *v.Value };

/// At most one live implementation (§6.3). The winner is the highest
/// band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
/// silently ignored.
pub fn pointprovider(bindings: []Bound, exclusive: bool) t.Err!ProviderResult {
    const shadowed = v.vlist();
    if (bindings.len == 0) return .{ .winner = null, .shadowed = shadowed };

    if (exclusive and bindings.len > 1) {
        const refs = v.arena().alloc([]const u8, bindings.len) catch @panic("oom");
        for (bindings, 0..) |b, i| refs[i] = b.ref;
        // Sorted, so the message names the same pair whatever order the
        // bindings arrived in.
        std.mem.sort([]const u8, refs, {}, lessStr);
        const list = v.vlist();
        var names = v.List(u8).init(v.arena());
        for (refs, 0..) |r, i| {
            if (i > 0) names.appendSlice(", ") catch @panic("oom");
            names.appendSlice(r) catch @panic("oom");
            v.push(list, v.vstr(r));
        }
        return t.fail("plugin_point_exclusive", v.print("point is exclusive and has {d} bindings: {s}", .{ bindings.len, names.items }), t.details1("refs", list));
    }

    const ranked = v.arena().alloc(Bound, bindings.len) catch @panic("oom");
    @memcpy(ranked, bindings);
    std.mem.sort(Bound, ranked, {}, lessProv);

    for (ranked[1..]) |b| v.push(shadowed, v.vstr(b.ref));
    return .{ .winner = ranked[0], .shadowed = shadowed };
}
