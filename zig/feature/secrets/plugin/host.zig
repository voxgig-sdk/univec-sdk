// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/host.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The host: the lifecycle state machine (§5), extension points (§6),
//! and resource capture (§8).
//!
//! TWO RULES SHAPE EVERY FUNCTION HERE.
//!
//! Transitions are SEQUENTIAL (§5.2). One at a time, in call order,
//! never interleaved; a transition triggered from inside a lifecycle
//! callback is `plugin_reentrant`. A hard rule, because it is the only
//! way the semantics can be identical in Go, in Ruby and in
//! single-threaded JavaScript — and in zig, which has no event loop to
//! hide behind.
//!
//! Reconciliation is EAGER (§18's portability budget). A transition
//! settles by running the state machine to a fixed point, not by
//! suspending on a promise.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const cap = @import("capability.zig");
const catalog = @import("catalog.zig");
const cfg = @import("config.zig");
const dep = @import("depend.zig");
const exp = @import("export.zig");
const ord = @import("order.zig");
const point = @import("point.zig");
const ref = @import("ref.zig");
const model = @import("inst.zig");

pub const Inst = model.Inst;
pub const Host = model.Host;
pub const HostOptions = model.HostOptions;
pub const DeclareSpec = model.DeclareSpec;
pub const ScopeEntry = model.ScopeEntry;
pub const BaseFn = model.BaseFn;
pub const Definition = catalog.Definition;

// ---------------------------------------------------------------------
// construction and registry helpers
// ---------------------------------------------------------------------

pub fn makehost(o: HostOptions) *Host {
    const h = v.arena().create(Host) catch @panic("oom");
    h.* = .{
        .catalog = o.catalog orelse catalog.makecatalog(),
        .reserved = o.reserved,
        .keys = o.keys,
        .defaults = o.defaults,
        .profile = o.profile,
        .points = if (v.isMap(o.points)) o.points.? else v.vmap(),
        .bases = o.bases,
        .dependency = if (o.dependency.len == 0) "restart" else o.dependency,
        .instances = v.List(*Inst).init(v.arena()),
        .log = v.vlist(),
        .events = v.vlist(),
    };
    return h;
}

pub fn define(h: *Host, d: *Definition) t.Err!void {
    return h.catalog.add(d);
}

fn find(h: *Host, r: []const u8) ?*Inst {
    for (h.instances.items) |e| {
        if (std.mem.eql(u8, e.ref, r)) return e;
    }
    return null;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Every instance ref, SORTED — the deterministic walk §4 rule 4
/// requires in a language whose containers have no inherent order.
fn sortedrefs(h: *Host) [][]const u8 {
    const out = v.arena().alloc([]const u8, h.instances.items.len) catch @panic("oom");
    for (h.instances.items, 0..) |e, i| out[i] = e.ref;
    std.mem.sort([]const u8, out, {}, lessStr);
    return out;
}

// ---------------------------------------------------------------------
// observation
// ---------------------------------------------------------------------

pub fn list(h: *Host) *v.Value {
    const out = v.vmap();
    for (sortedrefs(h)) |r| {
        if (find(h, r)) |e| v.set(out, r, v.vstr(e.status));
    }
    return out;
}

/// The VALIDATING canonicalizer, not the forgiving one: a lookup with a
/// malformed ref is `plugin_bad_name`, not a miss
/// (`declare/lookup#malformed`). Rust and swift both wrote this with
/// `canon` and failed that entry.
pub fn instance(h: *Host, r: []const u8) t.Err!?*Inst {
    return find(h, try ref.canonrefs(r));
}

pub fn observable(h: *Host, result: ?*v.Value, hasresult: bool) *v.Value {
    const out = v.vmap();
    v.set(out, "status", list(h));
    v.set(out, "open", v.vnum(h.open));
    const lg = v.vlist();
    for (v.items(h.log)) |x| v.push(lg, x);
    v.set(out, "log", lg);
    v.set(out, "result", if (!hasresult or result == null) v.vnull() else result);
    return out;
}

/// A COPY, not the live list: the canonical is `trace: () => events.slice()`, and `observable` already copies the log. Returning the live list lets a caller append to or delete from the host's own event record — application observation code fabricating or erasing lifecycle history.
pub fn trace(h: *Host) *v.Value {
    const out = v.vlist();
    for (v.items(h.events)) |x| v.push(out, x);
    return out;
}

pub fn instname(e: *Inst) []const u8 {
    return ref.refname(e.ref);
}

pub fn insttag(e: *Inst) []const u8 {
    const cut = std.mem.indexOfScalar(u8, e.ref, '$') orelse return "";
    return e.ref[cut + 1 ..];
}

// ---------------------------------------------------------------------
// guards
// ---------------------------------------------------------------------

fn guard(h: *Host) t.Err!void {
    if (h.intransition) {
        return t.fail("plugin_reentrant", "transition attempted from inside a lifecycle callback", null);
    }
}

fn need(h: *Host, r0: []const u8) t.Err!*Inst {
    const r = try ref.canonrefs(r0);
    return find(h, r) orelse
        t.fail("plugin_not_loaded", v.print("no such instance: {s}", .{r}), t.details1("ref", v.vstr(r)));
}

fn checkreserved(h: *Host, r: []const u8) t.Err!void {
    if (!v.isList(h.reserved) or v.len(h.reserved) == 0) return;
    const name = ref.refname(r);
    for (v.items(h.reserved)) |x| {
        if (v.isStr(x) and std.mem.eql(u8, v.asStr(x), name)) {
            return t.fail("plugin_ref_reserved", v.print("ref is reserved by the host: {s}", .{r}), t.details1("ref", v.vstr(r)));
        }
    }
}

// ---------------------------------------------------------------------
// scope
// ---------------------------------------------------------------------

fn pushscope(e: *Inst, f: ?model.ReleaseFn, ctx: ?*anyopaque, counts: bool) *ScopeEntry {
    const s = v.arena().create(ScopeEntry) catch @panic("oom");
    s.* = .{ .fn_ = f, .ctx = ctx, .done = false, .counts = counts };
    e.scope.append(s) catch @panic("oom");
    return s;
}

/// A selection belongs to ONE activation (§11.4). Leaving `live` by any
/// door drops it, so the next activation ranks afresh — keeping it would
/// make a consumer prefer a provider it never actually ran against.
///
/// Answers the errors the scope raised. §8.3: "A failing release does
/// not stop the rest. Every entry runs, in reverse order, whatever any
/// of them does; the errors are collected and raised as one
/// `plugin_release_failed`."
///
/// A RELEASE CANNOT FAIL IN ZIG'S TYPE SYSTEM: `ReleaseFn` returns void,
/// because a release that could return an error would make every unwind
/// site fallible for a failure the contract says must not stop the rest.
/// The probe that must raise does so through the host's own error slot,
/// which `releasefailed` reads.
fn unwind(h: *Host, e: *Inst) *v.Value {
    e.selected = v.vmap();
    const errors = v.vlist();
    var k = e.scope.items.len;
    while (k > 0) {
        k -= 1;
        const s = e.scope.items[k];
        if (s.done) continue;
        s.done = true;
        if (s.counts) h.open -= 1;
        if (s.fn_) |f| {
            release_error = null;
            f(s.ctx);
            if (release_error) |msg| v.push(errors, v.vstr(msg));
            release_error = null;
        }
    }
    e.scope.clearRetainingCapacity();
    return errors;
}

/// The one channel a release has to report a failure, since it cannot
/// return one. Set by a release callback, read by `unwind`.
pub var release_error: ?[]const u8 = null;

/// §8.3: "A failed release ends the instance in `failed`, exactly as a
/// failed callback does (§5.2) — a release that raised may have leaked,
/// and an instance that may be holding resources it cannot account for
/// must not be reactivated."
fn releasecheck(e: *Inst, errors: *v.Value) t.Err!void {
    if (v.len(errors) == 0) return;
    e.status = "failed";
    var why = v.List(u8).init(v.arena());
    for (v.items(errors), 0..) |x, i| {
        if (i > 0) why.appendSlice("; ") catch @panic("oom");
        why.appendSlice(v.asStr(x)) catch @panic("oom");
    }
    const d = v.vmap();
    v.set(d, "ref", v.vstr(e.ref));
    v.set(d, "cause", errors);
    return t.fail("plugin_release_failed", v.print("release failed for {s}: {s}", .{ e.ref, why.items }), d);
}

// ---------------------------------------------------------------------
// the instance api
// ---------------------------------------------------------------------

pub fn acquire(e: *Inst) t.Err!*ScopeEntry {
    // §8.1: resources are "acquired during `activate` — the scope's
    // actual job".
    if (!std.mem.eql(u8, e.owner.phase, "activate")) {
        return t.fail("plugin_release_scope", "acquire called outside activate", null);
    }
    const s = pushscope(e, null, null, true);
    e.owner.open += 1;
    return s;
}

/// Hand a resource back before teardown. Idempotent, and the scope keeps
/// the entry: unwinding it again must be a no-op, or releasing early
/// would make teardown wrong.
pub fn giveback(e: *Inst, s: *ScopeEntry) void {
    if (s.done) return;
    s.done = true;
    if (s.counts) e.owner.open -= 1;
}

pub fn release(e: *Inst, f: ?model.ReleaseFn, ctx: ?*anyopaque) t.Err!void {
    // §8.3: "`inst.release` outside `activate` is
    // `plugin_release_scope`". Being in a transition is true in `define`
    // too, and a scope entry registered there is never unwound —
    // `unload` on a merely `loaded` instance does not unwind, because a
    // loaded instance is not supposed to hold anything.
    if (!std.mem.eql(u8, e.owner.phase, "activate")) {
        return t.fail("plugin_release_scope", "release called outside activate", null);
    }
    // SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
    // resources CURRENTLY HELD, so an entry that is registered and then
    // unwound must leave the count where it found it. Incrementing on
    // registration and never decrementing made every `release` a
    // permanent leak in the counter.
    _ = pushscope(e, f, ctx, true);
    e.owner.open += 1;
}

pub fn bind(
    e: *Inst,
    pt: []const u8,
    hook: ?point.HookFn,
    chain: ?point.ChainFn,
    ctx: ?*anyopaque,
    band: ?*v.Value,
) t.Err!void {
    const h = e.owner;
    // §12's `plugin_bind_scope`: "binding declared outside `define`".
    // §8.1 puts binding declaration in `define` and insertion at a
    // SUCCESSFUL activate, and the guard was the half that never got
    // written — so a binding added from `activate` went live without
    // being part of the loaded definition, and a deactivate/activate
    // cycle appended it again. The code was in the table before anything
    // raised it.
    if (!std.mem.eql(u8, h.phase, "define")) {
        const d = v.vmap();
        v.set(d, "ref", v.vstr(e.ref));
        v.set(d, "point", v.vstr(pt));
        return t.fail("plugin_bind_scope", v.print("bind called outside define: {s}", .{pt}), d);
    }
    if (!v.has(h.points, pt)) {
        return t.fail("plugin_point_unknown", v.print("no such point: {s}", .{pt}), t.details1("point", v.vstr(pt)));
    }
    e.bindings.append(.{
        .ref = e.ref,
        .point = v.dupe(pt),
        .band = if (v.isNum(band)) v.asNum(band) else 0,
        .hook = hook,
        .chain = chain,
        .ctx = ctx,
    }) catch @panic("oom");
}

pub fn exportvalue(e: *Inst, key: []const u8, value: ?*v.Value) void {
    v.set(e.exports, key, value);
}

pub fn provides(e: *Inst, p: ?*v.Value) void {
    v.push(e.provides, p);
}

// ---------------------------------------------------------------------
// running a callback
// ---------------------------------------------------------------------

fn run(h: *Host, e: *Inst, at: []const u8) t.Err!void {
    const f = catalog.callbackFor(e.def, at);

    v.push(h.log, v.vstr(v.print("{s}:{s}", .{ e.ref, at })));
    const ev = v.vmap();
    v.set(ev, "ref", v.vstr(e.ref));
    v.set(ev, "event", v.vstr(at));
    v.set(ev, "seq", v.vnum(e.seq));
    v.set(ev, "status", v.vstr(e.status));
    v.push(h.events, ev);

    const cb = f orelse return;

    h.intransition = true;
    h.phase = at;
    cb(e) catch {
        h.intransition = false;
        h.phase = "";
        // TAKE FIRST. `pending` holds one error, and everything below
        // this line can raise.
        const err = t.take();
        // §12: `plugin_define_failed` and its three siblings are "a
        // callback raised; wraps the cause". AN ERROR THAT ALREADY
        // CARRIES A CODE KEEPS IT — the code is the error's identity,
        // and a plugin that raised `store_unreachable` must not have it
        // rewritten. Only a code-less error is wrapped, which is the
        // ordinary case for a callback that let a library error escape.
        if (err.code.len > 0 and !std.mem.eql(u8, err.code, "plugin_bare")) {
            return t.reraise(err);
        }
        const d = v.vmap();
        v.set(d, "ref", v.vstr(e.ref));
        v.set(d, "cause", v.vstr(err.text));
        return t.fail(v.print("plugin_{s}_failed", .{at}), v.print("{s} raised in {s}: {s}", .{ e.ref, at, err.text }), d);
    };
    h.intransition = false;
    h.phase = "";
}

// ---------------------------------------------------------------------
// requirements and providers
// ---------------------------------------------------------------------

fn providersof(h: *Host, req: ?*v.Value) *v.Value {
    const cands = v.vlist();
    // ASK WHETHER THE NAME IS A REF, do not assume it. A requirement
    // name is a CAPABILITY name first (§11.1) and capability names are
    // free-form, so `2fa` and `my cap` are legal ones that no ref could
    // be called — and `canonref` FAILS on those, which made a perfectly
    // legal document kill the host right here.
    const rname = v.get(req, "name");
    const asref = if (v.isStr(rname)) ref.tryref(v.asStr(rname)) else null;

    for (sortedrefs(h)) |r| {
        const tinst = find(h, r) orelse continue;
        if (!std.mem.eql(u8, tinst.status, "live")) continue;
        // A ref satisfies directly.
        if (asref != null and std.mem.eql(u8, r, asref.?)) {
            const prov = v.vmap();
            v.set(prov, "name", rname);
            const c = v.vmap();
            v.set(c, "ref", v.vstr(r));
            v.set(c, "pos", v.vnum(tinst.pos));
            v.set(c, "provides", prov);
            v.push(cands, c);
            continue;
        }
        for (v.items(tinst.provides)) |p| {
            if (v.same(v.get(p, "name"), rname)) {
                const c = v.vmap();
                v.set(c, "ref", v.vstr(r));
                v.set(c, "pos", v.vnum(tinst.pos));
                v.set(c, "provides", p);
                v.push(cands, c);
            }
        }
    }
    return cap.resolvecapability(req, cands);
}

fn unmetof(h: *Host, e: *Inst) *v.Value {
    const out = v.vlist();
    for (v.items(dep.requirements(e.options))) |r| {
        if (!dep.gatesactivation(r)) continue;
        if (v.len(providersof(h, r)) == 0) v.push(out, v.get(r, "name"));
    }
    return out;
}

/// §11.4's always-reluctant selection, and the ONE place a provider is
/// chosen for a live instance. "A satisfied requirement is not re-bound
/// while it stays satisfied" is a statement about a REMEMBERED choice.
///
/// `remember` is false for the questions asked ABOUT an instance rather
/// than BY it — introspection must not create a binding.
fn chosen(h: *Host, e: *Inst, req: ?*v.Value, remember: bool) ?[]const u8 {
    const cands = providersof(h, req);
    if (v.len(cands) == 0) return null;
    const name = v.asStr(v.get(req, "name"));
    const heldv = v.get(e.selected, name);
    if (v.isStr(heldv)) {
        for (v.items(cands)) |c| {
            if (std.mem.eql(u8, v.asStr(v.get(c, "ref")), v.asStr(heldv))) return v.asStr(heldv);
        }
    }
    const first = v.asStr(v.get(v.at(cands, 0), "ref"));
    if (remember) v.set(e.selected, name, v.vstr(first));
    return first;
}

/// The instance currently SELECTED for each of this one's
/// restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
/// capability (§11.1): the selected one going away restarts a `static`
/// consumer even though a survivor is available.
fn boundproviders(h: *Host, e: *Inst) [][]const u8 {
    var out = v.List([]const u8).init(v.arena());
    for (v.items(dep.requirements(e.options))) |r| {
        if (!dep.restartsonloss(r)) continue;
        const p = chosen(h, e, r, false) orelse continue;
        var dup = false;
        for (out.items) |x| {
            if (std.mem.eql(u8, x, p)) {
                dup = true;
                break;
            }
        }
        if (!dup) out.append(p) catch @panic("oom");
    }
    return out.items;
}

fn consumersof(h: *Host, r: []const u8) [][]const u8 {
    var out = v.List([]const u8).init(v.arena());
    for (sortedrefs(h)) |c| {
        if (std.mem.eql(u8, c, r)) continue;
        const ci = find(h, c) orelse continue;
        if (!std.mem.eql(u8, ci.status, "live")) continue;
        for (boundproviders(h, ci)) |p| {
            if (std.mem.eql(u8, p, r)) {
                out.append(c) catch @panic("oom");
                break;
            }
        }
    }
    return out.items;
}

/// §11.3's `hold` asks a DIFFERENT question from the cascade.
///
/// The cascade wants the edges that RESTART — mandatory-static and
/// optional-static. `hold` says "deactivating a REQUIRED instance is
/// `plugin_dependency_held`", and `required` is CARDINALITY:
/// `gatesactivation`, not `restartsonloss`. The two sets differ in both
/// directions and each difference was a real bug.
fn holdersof(h: *Host, r: []const u8) [][]const u8 {
    var out = v.List([]const u8).init(v.arena());
    for (sortedrefs(h)) |c| {
        if (std.mem.eql(u8, c, r)) continue;
        const ci = find(h, c) orelse continue;
        if (!std.mem.eql(u8, ci.status, "live")) continue;
        for (v.items(dep.requirements(ci.options))) |req| {
            if (!dep.gatesactivation(req)) continue;
            const sel = chosen(h, ci, req, false) orelse continue;
            if (std.mem.eql(u8, sel, r)) {
                out.append(c) catch @panic("oom");
                break;
            }
        }
    }
    return out.items;
}

/// The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
/// TEARDOWN. In a bulk operation that is removing the holders too, it is
/// suspended — otherwise `close()` under `hold` would raise on the first
/// provider it reached whenever a document happened to list a consumer
/// after it, which is the policy refusing the one teardown it has no
/// reason to object to.
fn held(h: *Host, e: *Inst) t.Err!void {
    if (!std.mem.eql(u8, h.dependency, "hold")) return;
    if (h.coordinated) return;
    const holders = holdersof(h, e.ref);
    if (holders.len == 0) return;
    const list_ = v.vlist();
    for (holders) |x| v.push(list_, v.vstr(x));
    const d = v.vmap();
    v.set(d, "ref", v.vstr(e.ref));
    v.set(d, "holders", list_);
    return t.fail("plugin_dependency_held", v.print("instance is required by live consumers: {s}", .{e.ref}), d);
}

/// The requirement graph as plain data, for the pure detector.
fn graphnodes(h: *Host) *v.Value {
    const out = v.vlist();
    for (sortedrefs(h)) |r| {
        const e = find(h, r) orelse continue;
        const provs = v.vlist();
        for (v.items(e.provides)) |p| v.push(provs, v.get(p, "name"));
        const node = v.vmap();
        v.set(node, "ref", v.vstr(r));
        v.set(node, "provides", provs);
        v.set(node, "requires", dep.requirements(e.options));
        v.push(out, node);
    }
    return out;
}

// ---------------------------------------------------------------------
// ordering and points
// ---------------------------------------------------------------------

fn lessSeq(_: void, a: *Inst, b: *Inst) bool {
    return a.seq < b.seq;
}

pub fn order(h: *Host, pt: []const u8) t.Err!*v.Value {
    // Sorted by declaration SEQUENCE, which is what makes the §7 sort's
    // fall-through deterministic in a language whose containers have no
    // insertion order. §7 breaks ties by `pos`; two instances CAN share
    // one — `declare` defaults `pos` to the registry size, so an unload
    // followed by a fresh declare reuses a surviving instance's — and
    // past that the canonical was falling through to map order. `seq` is
    // that order, made explicit. Found by review of the go port.
    var live = v.List(*Inst).init(v.arena());
    for (h.instances.items) |e| {
        if (std.mem.eql(u8, e.status, "live")) live.append(e) catch @panic("oom");
    }
    std.mem.sort(*Inst, live.items, {}, lessSeq);

    const bindings = v.vlist();
    for (live.items) |e| {
        const b = v.vmap();
        v.set(b, "ref", v.vstr(e.ref));
        v.set(b, "pos", v.vnum(e.pos));
        if (!v.isNull(e.order)) v.set(b, "order", e.order);
        v.push(bindings, b);
    }

    const spec = if (pt.len == 0) v.vnull() else v.get(h.points, pt);
    return ord.resolveorder(bindings, if (v.isMap(spec)) v.get(spec, "pin") else null);
}

pub fn positionof(h: *Host, r0: []const u8, pt: []const u8) t.Err!*v.Value {
    const ranked = try order(h, pt);
    const r = try ref.canonrefs(r0);
    var index: f64 = -1;
    for (v.items(ranked), 0..) |x, i| {
        if (std.mem.eql(u8, v.asStr(x), r)) {
            index = @floatFromInt(i);
            break;
        }
    }
    const out = v.vmap();
    v.set(out, "index", v.vnum(index));
    v.set(out, "count", v.vnum(@floatFromInt(v.len(ranked))));
    // §6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST,
    // so these are not index 0 and count-1 the other way round. Getting
    // this backwards is the exact error the positional pin vocabulary
    // exists to prevent.
    v.set(out, "outermost", v.vbool(index == 0));
    v.set(out, "innermost", v.vbool(index == @as(f64, @floatFromInt(v.len(ranked))) - 1));
    return out;
}

pub fn position(e: *Inst, pt: []const u8) t.Err!*v.Value {
    return positionof(e.owner, e.ref, pt);
}

/// Live bindings on a point, in resolved order. Recomputed on any change
/// to the live set (§7) rather than cached at startup — the bug a host
/// discovers only when something deactivates in production.
fn boundon(h: *Host, pt: []const u8) t.Err![]point.Bound {
    const ranked = try order(h, pt);
    var out = v.List(point.Bound).init(v.arena());
    for (v.items(ranked)) |rv| {
        const e = find(h, v.asStr(rv)) orelse continue;
        // The band is the INSTANCE's ordering block (§7), stamped by the
        // host. A plugin passing its own would be ranking itself above
        // the order its document declared.
        const band = v.get(e.order, "band");
        const bandv: f64 = if (v.isNum(band)) v.asNum(band) else 0;
        for (e.bindings.items) |b| {
            if (!std.mem.eql(u8, b.point, pt)) continue;
            var copy = b;
            copy.band = bandv;
            out.append(copy) catch @panic("oom");
        }
    }
    return out.items;
}

fn pointspec(h: *Host, pt: []const u8) t.Err!*v.Value {
    if (!v.has(h.points, pt)) {
        return t.fail("plugin_point_unknown", v.print("no such point: {s}", .{pt}), t.details1("point", v.vstr(pt)));
    }
    const spec = v.get(h.points, pt);
    return if (v.isMap(spec)) spec else v.vmap();
}

fn checkkind(spec: ?*v.Value, pt: []const u8, want: []const u8) t.Err!void {
    const kind = v.get(spec, "kind");
    const given = v.isStr(kind);
    const ok = if (given) std.mem.eql(u8, v.asStr(kind), want) else std.mem.eql(u8, want, "hook");
    if (ok) return;
    const d = v.vmap();
    v.set(d, "point", v.vstr(pt));
    v.set(d, "kind", if (given) kind else v.vnull());
    return t.fail("plugin_point_kind", v.print("point is not a {s}: {s}", .{ want, pt }), d);
}

pub fn emit(h: *Host, pt: []const u8, arg: ?*v.Value) t.Err!?*v.Value {
    const spec = try pointspec(h, pt);
    try checkkind(spec, pt, "hook");
    const bindings = try boundon(h, pt);
    const mode = v.get(spec, "mode");
    const m = if (v.isStr(mode)) v.asStr(mode) else "emit";
    const res = try point.pointemit(bindings, m, arg);
    if (std.mem.eql(u8, m, "emit")) return null;
    if (std.mem.eql(u8, m, "bail")) return res.value;
    return res.errors;
}

pub fn call(h: *Host, pt: []const u8, arg: ?*v.Value) t.Err!?*v.Value {
    const spec = try pointspec(h, pt);
    try checkkind(spec, pt, "chain");
    const bindings = try boundon(h, pt);
    // The host owns the base and a plugin cannot replace it (§6.2). One
    // that wants to SUBSTITUTE rather than wrap binds innermost and
    // simply does not call `next`.
    for (h.bases) |b| {
        if (std.mem.eql(u8, b.point, pt)) return point.pointcall(bindings, b.func, null, arg);
    }
    return point.pointcall(bindings, null, null, arg);
}

pub fn provider(h: *Host, pt: []const u8, arg: ?*v.Value) t.Err!?*v.Value {
    const spec = try pointspec(h, pt);
    try checkkind(spec, pt, "provider");
    const bindings = try boundon(h, pt);
    const res = try point.pointprovider(bindings, v.truthy(v.get(spec, "exclusive")));
    const w = res.winner orelse return v.get(spec, "default");
    return w.hook.?(arg, w.ctx);
}

pub fn shadowed(h: *Host, pt: []const u8) t.Err!*v.Value {
    if (!v.has(h.points, pt)) return v.vlist();
    const spec = v.get(h.points, pt);
    const bindings = try boundon(h, pt);
    const res = try point.pointprovider(bindings, v.isMap(spec) and v.truthy(v.get(spec, "exclusive")));
    return res.shadowed;
}

pub fn exports(h: *Host, spec: []const u8) t.Err!?*v.Value {
    const all = v.vlist();
    for (sortedrefs(h)) |r| {
        const e = find(h, r) orelse continue;
        // Exports of a `loaded` (not live) instance are VISIBLE (§11).
        if (std.mem.eql(u8, e.status, "declared") or std.mem.eql(u8, e.status, "failed")) continue;
        for (v.keys(e.exports)) |k| {
            const ex = v.vmap();
            v.set(ex, "ref", v.vstr(r));
            v.set(ex, "key", v.vstr(k));
            v.set(ex, "value", v.get(e.exports, k));
            v.push(all, ex);
        }
    }
    return exp.resolveexport(v.vstr(spec), all);
}

pub fn capability(h: *Host, name: []const u8) *v.Value {
    const cands = v.vlist();
    for (sortedrefs(h)) |r| {
        const e = find(h, r) orelse continue;
        if (!std.mem.eql(u8, e.status, "live")) continue;
        for (v.items(e.provides)) |p| {
            if (v.isStr(v.get(p, "name")) and std.mem.eql(u8, v.asStr(v.get(p, "name")), name)) {
                const c = v.vmap();
                v.set(c, "ref", v.vstr(r));
                v.set(c, "pos", v.vnum(e.pos));
                v.set(c, "provides", p);
                v.push(cands, c);
            }
        }
    }
    const req = v.vmap();
    v.set(req, "name", v.vstr(name));
    const ranked = cap.resolvecapability(req, cands);
    const out = v.vlist();
    for (v.items(ranked)) |c| v.push(out, v.get(c, "ref"));
    return out;
}

// ---------------------------------------------------------------------
// the state machine
// ---------------------------------------------------------------------

/// AUTO-TAGGING IS EXPLICIT (§4 rule 3): the LOWEST UNUSED POSITIVE
/// INTEGER tag. It needs a host because it must know what is already
/// declared, which is why it cannot live in the pure `ref` section.
pub fn autotag(h: *Host, name: []const u8) t.Err![]const u8 {
    var n: i32 = 1;
    while (true) : (n += 1) {
        const cand = try ref.formatref(v.vstr(name), v.vstr(v.print("{d}", .{n})));
        if (find(h, cand) == null) return cand;
    }
}

pub fn declare(h: *Host, r0: []const u8, spec: DeclareSpec) t.Err!*Inst {
    const r = if (std.mem.eql(u8, spec.tag, "?"))
        try autotag(h, ref.refname(try ref.canonrefs(r0)))
    else
        try ref.canonrefs(r0);

    if (!spec.hostowned) try checkreserved(h, r);

    const defname = if (spec.definition.len == 0) ref.refname(r) else spec.definition;
    const def = h.catalog.get(defname) orelse
        return t.fail("plugin_unknown_definition", v.print("not in catalog: {s}", .{defname}), t.details1("name", v.vstr(defname)));

    if (find(h, r)) |existing| {
        // §4 rule 1: a pair addresses at most one instance. Re-declaring
        // the SAME definition is the idempotent case; a different one is
        // a duplicate, not a silent overwrite (seneca) and not an
        // impossibility (sdkgen).
        if (!std.mem.eql(u8, existing.def.name, def.name)) {
            return t.fail("plugin_ref_duplicate", v.print("instance already declared: {s}", .{r}), t.details1("ref", v.vstr(r)));
        }
        return existing;
    }

    const e = v.arena().create(Inst) catch @panic("oom");
    e.* = .{
        .ref = v.dupe(r),
        .def = def,
        .status = "declared",
        .pos = spec.pos orelse @floatFromInt(h.instances.items.len),
        .seq = h.seqn,
        // NO OPTIONS ADOPTED HERE. `apply` resolves options and hands
        // the map over; adopting the caller's map made target and source
        // THE SAME MAP in the refill that follows, which cleared its own
        // source and left a first-time instance with no options at all.
        .options = if (v.isMap(spec.options)) spec.options.? else v.vmap(),
        .state = v.vmap(),
        .order = spec.order,
        .selected = v.vmap(),
        .unmet = v.vlist(),
        .scope = v.List(*ScopeEntry).init(v.arena()),
        .bindings = v.List(point.Bound).init(v.arena()),
        .exports = v.vmap(),
        .provides = v.vlist(),
        .owner = h,
    };
    h.seqn += 1;
    h.instances.append(e) catch @panic("oom");
    return e;
}

pub fn load(h: *Host, r: []const u8, spec: DeclareSpec) t.Err!*Inst {
    try guard(h);
    const e = try declare(h, r, spec);
    if (!std.mem.eql(u8, e.status, "declared")) return e; // idempotent
    // PRESENT AND NOT NULL, not merely present. Every driver builds its
    // command spec with all four keys and a null for each absent one, so
    // a presence test reads an omitted `options` as an authored empty
    // and wipes the real ones.
    if (v.isMap(spec.options)) e.options = spec.options.?;

    run(h, e, "define") catch {
        e.status = "failed";
        return error.Plugin;
    };
    e.status = "loaded";

    // AT LOAD, and before anything runs: a cycle through restart-causing
    // requirements does not settle, and the only safe time to report a
    // non-terminating reconcile is before it starts (§11.3). `provides`
    // is populated by `define`, which has just run, so this is the first
    // moment the graph is complete.
    dep.checkcycle(graphnodes(h)) catch {
        e.status = "failed";
        return error.Plugin;
    };
    return e;
}

/// CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
///
/// The cascade is part of the provider's own deactivation and runs
/// BEFORE the provider's `deactivate` callback and scope unwind, so a
/// consumer's teardown can still call the thing it depends on — flushing
/// a buffer to the store it is about to lose is exactly what a
/// `deactivate` callback is for.
fn cascade(h: *Host, prov: *Inst, seen: *v.Value) void {
    if (v.has(seen, prov.ref)) return;
    v.set(seen, prov.ref, v.vbool(true));

    for (consumersof(h, prov.ref)) |cref| {
        const c = find(h, cref) orelse continue;
        if (!std.mem.eql(u8, c.status, "live")) continue;
        cascade(h, c, seen); // deepest-first
        var bad = false;
        run(h, c, "deactivate") catch {
            _ = t.take();
            bad = true;
        };
        const errors = unwind(h, c);
        if (bad or v.len(errors) > 0) {
            // §5.2: ANY failure during a transition lands the instance
            // in `failed`, and a cascaded consumer is not an exception.
            // Marking it `pending` instead handed it straight back to
            // `reconcile`, which would activate it again the moment the
            // provider returned — the one thing `failed` exists to stop.
            c.status = "failed";
            continue;
        }
        c.status = "pending";
        c.unmet = unmetof(h, c);
    }
}

pub fn activate(h: *Host, r: []const u8) t.Err!*Inst {
    try guard(h);
    const e = try need(h, r);
    if (std.mem.eql(u8, e.status, "live")) return e; // no-op returning success
    if (std.mem.eql(u8, e.status, "failed")) {
        return t.fail("plugin_bad_state", v.print("instance has failed: {s}", .{e.ref}), t.details1("ref", v.vstr(e.ref)));
    }
    // §9.6: `active: false` bars the instance from running, and the bar
    // is on the INSTANCE rather than on the apply that set it. `ready`
    // reaches this through `activate`, which is why one guard covers
    // both verbs the design names.
    if (e.barred) {
        return t.fail("plugin_inactive", v.print("instance is barred by active: false: {s}", .{e.ref}), t.details1("ref", v.vstr(e.ref)));
    }
    if (std.mem.eql(u8, e.status, "declared")) _ = try load(h, e.ref, .{});

    // A declared requirement that is not live means `pending`:
    // activation is a STANDING REQUEST, not a one-shot event.
    const unmet = unmetof(h, e);
    if (v.len(unmet) > 0) {
        e.unmet = unmet;
        e.status = "pending";
        return e;
    }

    run(h, e, "activate") catch {
        // Unwind whatever the partial activation captured, in reverse.
        const err = t.take();
        _ = unwind(h, e);
        e.status = "failed";
        return t.reraise(err);
    };

    // §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
    // later question — the cascade, `hold`, `unmet` — reads it back
    // rather than re-ranking, which is what "always-reluctant" means.
    for (v.items(dep.requirements(e.options))) |req| _ = chosen(h, e, req, true);
    e.status = "live";
    reconcile(h);
    return e;
}

pub fn deactivate(h: *Host, r: []const u8) t.Err!*Inst {
    try guard(h);
    const e = try need(h, r);
    if (std.mem.eql(u8, e.status, "loaded") or std.mem.eql(u8, e.status, "declared")) return e;

    // §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`. Falling
    // through here ran the definition's `deactivate` on an instance that
    // never completed activation and, if that callback happened to
    // succeed, returned it to `loaded` — from where it could be
    // activated again, which is precisely what `failed` exists to
    // prevent.
    if (std.mem.eql(u8, e.status, "failed")) {
        return t.fail("plugin_bad_state", v.print("instance has failed: {s}", .{e.ref}), t.details1("ref", v.vstr(e.ref)));
    }

    if (std.mem.eql(u8, e.status, "pending")) {
        // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It
        // never reached activate, so it holds no scope and no live
        // bindings; running the definition's deactivate there would be
        // teardown without matching setup. It cannot fail.
        e.status = "loaded";
        e.unmet = v.vlist();
        return e;
    }

    try held(h, e);
    cascade(h, e, v.vmap());

    run(h, e, "deactivate") catch {
        const err = t.take();
        _ = unwind(h, e);
        e.status = "failed";
        return t.reraise(err);
    };
    try releasecheck(e, unwind(h, e));
    e.status = "loaded";
    reconcile(h);
    return e;
}

fn removeinst(h: *Host, e: *Inst) void {
    for (h.instances.items, 0..) |x, i| {
        if (x == e) {
            _ = h.instances.orderedRemove(i);
            return;
        }
    }
}

pub fn unload(h: *Host, r: []const u8) t.Err!void {
    try guard(h);
    const e = try need(h, r);
    if (std.mem.eql(u8, e.status, "live") or std.mem.eql(u8, e.status, "pending")) {
        if (std.mem.eql(u8, e.status, "live")) {
            try held(h, e);
            cascade(h, e, v.vmap());
            run(h, e, "deactivate") catch {
                // §5.2: ANY failure during a transition lands the
                // instance in `failed`, with the scope STILL FULLY
                // UNWOUND. An earlier draft let the raise propagate
                // straight out of `unload`, which left the instance
                // `live` and its scope untouched — reporting a failure
                // while leaking exactly the resources the failure was
                // about.
                const err = t.take();
                _ = unwind(h, e);
                e.status = "failed";
                return t.reraise(err);
            };
            try releasecheck(e, unwind(h, e));
        }
        e.status = "loaded";
    }
    if (std.mem.eql(u8, e.status, "loaded") or std.mem.eql(u8, e.status, "failed")) {
        run(h, e, "close") catch {
            const err = t.take();
            removeinst(h, e);
            return t.reraise(err);
        };
    }
    removeinst(h, e);
}

pub fn ready(h: *Host, r0: []const u8) t.Err!*Inst {
    // Runs the whole forward path in one call (§5.1). §15.2's verb list
    // omits this; §5.1 defines it and §15.3's `declare` row requires the
    // corpus to pin it, so the list was incomplete rather than excluding
    // it (DOCS.md §4.2).
    try guard(h);
    const r = try ref.canonrefs(r0);
    if (find(h, r) == null) _ = try declare(h, r, .{});
    if (find(h, r)) |e| {
        if (std.mem.eql(u8, e.status, "declared")) _ = try load(h, r, .{});
    }
    return activate(h, r);
}

/// EAGER reconciliation: run to a fixed point rather than scheduling.
///
/// Two directions, and both are the reason `pending` exists. Activation
/// is a STANDING REQUEST, not a one-shot event: a pending instance whose
/// requirement arrives activates without being asked again, and a LIVE
/// instance whose requirement is lost goes back to pending —
/// recursively, through its own consumers.
fn reconcile(h: *Host) void {
    var moved = true;
    var rounds: i32 = 0;
    while (moved) {
        moved = false;
        rounds += 1;
        if (rounds > 1000) break;

        // Losses first, so a cascade settles in one pass rather than
        // alternating with re-activations.
        for (sortedrefs(h)) |r| {
            const e = find(h, r) orelse continue;
            if (!std.mem.eql(u8, e.status, "live")) continue;
            const lost = v.vlist();
            for (v.items(dep.requirements(e.options))) |q| {
                if (!dep.gatesactivation(q)) continue;
                if (v.len(providersof(h, q)) == 0) v.push(lost, q);
            }
            if (v.len(lost) == 0) continue;
            // POLICY IS PER REQUIREMENT, not per instance (§11.3): only
            // the definition that has the requirement knows what it can
            // cope with, and one instance may hold both a `static` and a
            // `dynamic` one. A `dynamic` requirement whose provider is
            // gone leaves the consumer LIVE and notified.
            var anyrestart = false;
            for (v.items(lost)) |q| {
                if (dep.restartsonloss(q)) {
                    anyrestart = true;
                    break;
                }
            }
            if (!anyrestart) continue;

            var bad = false;
            run(h, e, "deactivate") catch {
                _ = t.take();
                bad = true;
            };
            const errors = unwind(h, e);
            if (bad or v.len(errors) > 0) {
                e.status = "failed";
            } else {
                e.status = "pending";
                e.unmet = unmetof(h, e);
            }
            moved = true;
        }

        for (sortedrefs(h)) |r| {
            const e = find(h, r) orelse continue;
            if (!std.mem.eql(u8, e.status, "pending")) continue;
            if (v.len(unmetof(h, e)) > 0) continue;
            run(h, e, "activate") catch {
                _ = t.take();
                _ = unwind(h, e);
                e.status = "failed";
                moved = true;
                continue;
            };
            for (v.items(dep.requirements(e.options))) |req| _ = chosen(h, e, req, true);
            e.status = "live";
            e.unmet = v.vlist();
            moved = true;
        }
    }
}

fn lessDropOrder(h: *Host, a: []const u8, b: []const u8) bool {
    const x = find(h, a) orelse return false;
    const y = find(h, b) orelse return false;
    // Reverse load order: highest `pos` first, ref-descending for a tie,
    // so a consumer declared after its provider goes down first.
    if (x.pos != y.pos) return x.pos > y.pos;
    return std.mem.order(u8, a, b) == .gt;
}

const DropCtx = struct { h: *Host };

fn lessDrop(ctx: DropCtx, a: []const u8, b: []const u8) bool {
    return lessDropOrder(ctx.h, a, b);
}

pub fn close(h: *Host) t.Err!void {
    // A bulk teardown removing the holders too, so `hold` is suspended
    // for exactly those holders (§11.3) — while the consumers-first
    // cascade still runs, which is the half that matters.
    // A COORDINATED FLAG THAT SURVIVES A RAISE IS A DISABLED GUARD. The
    // canonical wraps the teardown in try/finally; an unload that raises
    // would skip the reset and leave the host permanently `coordinated`,
    // so a caller that catches the error and carries on under
    // `dependency: "hold"` gets ad-hoc deactivation with the holder
    // check silently off.
    //
    // `defer` rather than a catch: the flag is cleared on every exit
    // from this function, so the raising path is not written twice.
    h.coordinated = true;
    defer h.coordinated = false;
    const refs = v.arena().alloc([]const u8, h.instances.items.len) catch @panic("oom");
    for (h.instances.items, 0..) |e, i| refs[i] = e.ref;
    std.mem.sort([]const u8, refs, DropCtx{ .h = h }, lessDrop);
    for (refs) |r| {
        if (find(h, r) != null) try unload(h, r);
    }
}

/// The scope entry carries the inner host as its context — zig's
/// stand-in for the closure every other port with closures writes here.
fn closeinner(ctx: ?*anyopaque) void {
    const inner: *Host = @ptrCast(@alignCast(ctx.?));
    close(inner) catch {
        release_error = t.take().message;
    };
}

/// AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
/// INNER ONE'S LIFETIME. Registering the teardown in the instance scope
/// is what makes that true rather than aspirational: the inner host
/// closes when the outer instance deactivates, in the same reverse
/// unwind as every other resource.
///
/// It does NOT count toward `open` — a teardown is not an acquisition
/// (`nest/open`).
pub fn nest(e: *Inst, o: HostOptions) t.Err!*Host {
    if (!e.owner.intransition) {
        return t.fail("plugin_release_scope", "nest called outside a lifecycle callback", null);
    }
    const inner = makehost(o);
    _ = pushscope(e, closeinner, inner, false);
    e.inner = inner;
    return inner;
}

// ---------------------------------------------------------------------
// documents
// ---------------------------------------------------------------------

/// Empty the target and refill it, so callers holding the reference see
/// the new values. A definition's callbacks close over the options map
/// they were handed at `define`; replacing the reference would leave
/// every binding reading the values the first apply gave it.
fn refill(target: *v.Value, source: ?*v.Value) void {
    for (v.keys(target)) |k| v.del(target, k);
    for (v.keys(source)) |k| v.set(target, k, v.get(source, k));
}

fn shapeof(h: *Host, r: []const u8) ?*v.Value {
    const d = h.catalog.get(ref.refname(r)) orelse return null;
    return d.shape;
}

fn wantlive(ent: ?*v.Value) bool {
    return v.isMap(ent) and v.truthy(v.get(ent, "active")) and
        std.mem.eql(u8, v.asStr(v.get(ent, "start")), "eager");
}

pub fn apply(h: *Host, doc: ?*v.Value, profile: ?*v.Value) t.Err!void {
    try guard(h);
    const in = v.vmap();
    v.set(in, "doc", doc);
    v.set(in, "profile", if (v.isNull(profile)) h.profile else profile);
    v.set(in, "keys", h.keys);
    v.set(in, "reserved", h.reserved);
    const norm = try cfg.normalizeconfig(in);

    const want = v.get(norm, "order");
    const optionsof = v.vmap();
    for (v.items(want)) |rv| {
        const r = v.asStr(rv);
        const oin = v.vmap();
        v.set(oin, "ref", v.vstr(r));
        v.set(oin, "doc", doc);
        v.set(oin, "profile", if (v.isNull(profile)) h.profile else profile);
        v.set(oin, "shape", shapeof(h, r));
        if (v.isMap(h.defaults)) v.set(oin, "hostdefaults", v.get(h.defaults, ref.refname(r)));
        v.set(optionsof, r, try cfg.resolveoptions(oin));
    }

    // --- phase 1: deactivations and unloads, in REVERSE load order ---
    const instancespec = v.get(norm, "instance");
    var drop = v.List([]const u8).init(v.arena());
    for (h.instances.items) |e| {
        if (std.mem.eql(u8, e.status, "declared")) continue;
        if (!wantlive(v.get(instancespec, e.ref))) drop.append(e.ref) catch @panic("oom");
    }
    std.mem.sort([]const u8, drop.items, DropCtx{ .h = h }, lessDrop);
    for (drop.items) |r| try unload(h, r);

    // --- phase 2: declare and patch EVERYTHING, in load order --------
    for (v.items(want)) |rv| {
        const r = v.asStr(rv);
        const ent = v.get(instancespec, r);
        const e = try declare(h, r, .{
            .order = v.get(ent, "order"),
            .pos = v.asNum(v.get(ent, "pos")),
        });
        // The bar is REASSERTED ON EVERY APPLY, in both directions — a
        // document that turns the instance back on clears it, which is
        // the whole point of a config switch.
        e.barred = !v.truthy(v.get(ent, "active"));
        refill(e.options, v.get(optionsof, r));
        e.order = v.get(ent, "order");
        e.pos = v.asNum(v.get(ent, "pos"));
    }

    // --- phase 3: loads, then phase 4: activations, in load order ----
    for (v.items(want)) |rv| {
        if (wantlive(v.get(instancespec, v.asStr(rv)))) _ = try load(h, v.asStr(rv), .{});
    }
    for (v.items(want)) |rv| {
        if (wantlive(v.get(instancespec, v.asStr(rv)))) _ = try activate(h, v.asStr(rv));
    }
}

pub fn setoptions(h: *Host, r: []const u8, patch: ?*v.Value) t.Err!void {
    try guard(h);
    const e = try need(h, r);
    const previous = v.clone(e.options);
    const in = v.vmap();
    v.set(in, "ref", v.vstr(e.ref));
    v.set(in, "shape", shapeof(h, e.ref));
    v.set(in, "doc", v.vmap());
    v.set(in, "patch", t.mergeValue(previous, patch));
    refill(e.options, try cfg.resolveoptions(in));

    if (!std.mem.eql(u8, e.status, "live")) return;
    if (e.def.reconfigure) |f| {
        h.intransition = true;
        h.phase = "reconfigure";
        f(e, e.options, previous) catch {
            h.intransition = false;
            h.phase = "";
            return error.Plugin;
        };
        h.intransition = false;
        h.phase = "";
        return;
    }
    // Always correct and sometimes expensive; `reconfigure` exists to
    // make the common case cheap (§9.4).
    _ = try deactivate(h, e.ref);
    _ = try activate(h, e.ref);
}
