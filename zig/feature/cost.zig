// Cost tracking and spend budget (mirrors go feature/cost_feature.go / rust
// feature/cost.rs). Uses BOTH seams, which is the point of the feature: money
// is spent per HTTP ATTEMPT (a retried call is charged again, because the
// upstream API charges it again), but it is owed by an OPERATION. So the
// transport wrap prices each attempt, and PreDone attributes the running
// total to `<entity>.<op>` and to the caller (`ctrl.actor`, the same actor
// the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// '<entity>.<op>' / '<op>' / '*'), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. "usage.total_tokens") is read at PreDone instead,
// from the already-parsed result. A body figure describes the whole call, so
// it REPLACES the per-attempt estimate rather than adding to it.
//
// `budget` caps total spend. With `onBudget` = "deny" a further operation is
// refused at PrePoint, before an endpoint is resolved and before anything
// reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent.
//
// The per-operation accumulator lives on ctx.out as a Value map (like rust),
// not as a native pointer: OutVal carries Values, and the transport wrapper
// and the hooks are different objects that both have to reach it.

const std = @import("std");
const h = @import("../core/helpers.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;
const OutVal = types.OutVal;

const COST_PENDING_KEY: []const u8 = "cost_pending";

pub const CostBucket = struct {
    calls: i64 = 0,
    amount: f64 = 0,
};

pub const CostTotal = struct {
    calls: i64 = 0,
    attempts: i64 = 0,
    amount: f64 = 0,
    reported: f64 = 0,
    estimated: f64 = 0,
};

pub const CostBudget = struct {
    limit: f64 = 0,
    spent: f64 = 0,
    remaining: f64 = 0,
    exceeded: bool = false,
};

// Shared between the feature (hooks) and the transport wrapper, which are
// separate objects reached through different pointers.
pub const CostTrack = struct {
    currency: []const u8 = "USD",
    total: CostTotal = .{},
    ops: std.StringHashMap(CostBucket),
    actors: std.StringHashMap(CostBucket),
    budget: CostBudget = .{},
    last: Value,
    seq: i64 = 0,
};

pub const CostFeature = struct {
    name: []const u8 = "cost",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    track: *CostTrack,

    pub fn make() Feature {
        const self = h.A().create(CostFeature) catch unreachable;
        const track = h.A().create(CostTrack) catch unreachable;
        track.* = .{
            .ops = std.StringHashMap(CostBucket).init(h.A()),
            .actors = std.StringHashMap(CostBucket).init(h.A()),
            .last = h.vnull(),
        };
        self.* = .{ .track = track };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *CostFeature {
        return @ptrCast(@alignCast(p));
    }

    fn vname(p: *anyopaque) []const u8 {
        return self_of(p).name;
    }
    fn vactive(p: *anyopaque) bool {
        return self_of(p).active;
    }
    fn vaddopts(p: *anyopaque) Value {
        return self_of(p).add_opts;
    }
    fn vinit(p: *anyopaque, ctx: *Context, options: Value) void {
        const self = self_of(p);
        self.options = options;
        self.active = sup.fopt_bool(options, "active", false);

        const lim = sup.fopt_num(options, "budget", 0);
        self.track.* = .{
            .currency = sup.fopt_str(options, "currency", "USD"),
            .ops = std.StringHashMap(CostBucket).init(h.A()),
            .actors = std.StringHashMap(CostBucket).init(h.A()),
            .budget = .{ .limit = lim, .remaining = lim },
            .last = h.vnull(),
        };

        if (!self.active) return;

        const util = ctx.util();
        const w = h.A().create(WrapCtx) catch unreachable;
        w.* = .{ .inner = util.fetcher, .options = options, .track = self.track };
        util.fetcher = .{ .ctx = @ptrCast(w), .call = wrapCall };
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        const self = self_of(p);
        if (std.mem.eql(u8, name, "PrePoint")) {
            self.pre_point(ctx);
        } else if (std.mem.eql(u8, name, "PreDone")) {
            self.finish(ctx, true);
        } else if (std.mem.eql(u8, name, "PreUnexpected")) {
            self.finish(ctx, false);
        }
    }

    // Budget gate. Runs before endpoint resolution, so a refused call costs
    // nothing at all.
    fn pre_point(self: *CostFeature, ctx: *Context) void {
        if (!self.active) return;

        // Mark the context as running through the pipeline, so charge knows a
        // PreDone is coming and does not commit the spend itself.
        const pending = pending_for(ctx);
        h.setp(pending, "piped", h.vbool(true));

        const lim = self.track.budget.limit;
        if (lim <= 0) return;
        if (self.track.total.amount < lim) return;

        self.track.budget.exceeded = true;

        if (!std.mem.eql(u8, sup.fopt_str(self.options, "onBudget", "warn"), "deny")) return;

        const msg = std.fmt.allocPrint(
            h.A(),
            "Cost budget of {d} {s} is spent ({d} {s} used)",
            .{ lim, self.track.currency, self.track.total.amount, self.track.currency },
        ) catch "cost budget spent";
        const e = ctx.make_error("cost_budget", msg);
        // Short-circuit endpoint resolution; make_point surfaces this error.
        ctx.out_set("point", OutVal{ .err = e });
    }

    fn finish(self: *CostFeature, ctx: *Context, done: bool) void {
        if (!self.active) return;

        const taken = ctx.out.fetchRemove(COST_PENDING_KEY) orelse return;
        var pending: Value = h.vnull();
        switch (taken.value) {
            .val => |v| if (v == .object) {
                pending = v;
            },
            else => {},
        }
        if (pending != .object) {
            // Put back anything unexpected (should not happen).
            ctx.out_set(COST_PENDING_KEY, taken.value);
            return;
        }

        // A FAILED operation that made no attempt never reached the network:
        // PrePoint creates the pending entry to mark the context as piped, and
        // then the budget gate refuses the call (rbac, or an unresolvable
        // endpoint, short-circuits just as early). Committing it would count a
        // call that never happened and file a zero-amount record as `last`.
        //
        // A SUCCEEDED operation that made no attempt is the opposite case: it
        // was served from the cache. That is a real call, and the fact that it
        // cost nothing is the whole point of ordering cost inside the cache.
        const tried = h.get_f64(pending, "attempts") orelse 0;
        if (!done and tried == 0) return;

        const entity0 = ctx.op.entity;
        const opname0 = ctx.op.name;
        const entity = if (entity0.len == 0) "_" else entity0;
        const opname = if (opname0.len == 0) "_" else opname0;

        commit(self.track, self.options, ctx, pending, entity, opname);
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};

const WrapCtx = struct {
    inner: Fetcher,
    options: Value,
    track: *CostTrack,
};

fn wrapCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *WrapCtx = @ptrCast(@alignCast(p));
    return charge(w.track, w.options, ctx, url, fetchdef, w.inner);
}

fn new_pending() Value {
    const m = h.omap();
    h.setp(m, "attempts", h.vfloat(0));
    h.setp(m, "amount", h.vfloat(0));
    h.setp(m, "reported", h.vfloat(0));
    h.setp(m, "estimated", h.vfloat(0));
    h.setp(m, "source", h.vstr("none"));
    h.setp(m, "piped", h.vbool(false));
    return m;
}

fn pending_for(ctx: *Context) Value {
    if (ctx.out_get(COST_PENDING_KEY)) |ov| {
        switch (ov) {
            .val => |v| if (v == .object) return v,
            else => {},
        }
    }
    const m = new_pending();
    ctx.out_set(COST_PENDING_KEY, OutVal{ .val = m });
    return m;
}

fn charge(track: *CostTrack, options: Value, ctx: *Context, url: []const u8, fetchdef: Value, inner: Fetcher) err.E!Value {
    // A failing transport still costs an attempt. Without this, a run of
    // connection-level failures under `retry` (which retries on an error)
    // would be charged nothing at all, and an onBudget = "deny" ceiling could
    // never stop it.
    var res: Value = h.vnull();
    var failed = false;
    var fail_err: err.E = error.Sdk;
    if (inner.invoke(ctx, url, fetchdef)) |ok| {
        res = ok;
    } else |e| {
        failed = true;
        fail_err = e;
    }

    const priced = price(options, ctx, if (failed) h.vnull() else res);

    const pending = pending_for(ctx);

    // Accumulated here, committed once at PreDone. Adding each attempt to the
    // running total and then subtracting it again when a body figure
    // supersedes it loses precision to catastrophic cancellation
    // (5 + (0.01 - 5) is not 0.01 in binary floating point).
    //
    // Reported and estimated are kept apart per ATTEMPT, not per operation: a
    // 503 priced from the rate table followed by a 200 carrying the cost
    // header is part estimate, part reported, and collapsing both into the
    // final attempt's category would corrupt the split.
    const attempts = (h.get_f64(pending, "attempts") orelse 0) + 1;
    h.setp(pending, "attempts", h.vfloat(attempts));
    h.setp(pending, "amount", h.vfloat((h.get_f64(pending, "amount") orelse 0) + priced.amount));

    const bucket: []const u8 = if (std.mem.eql(u8, priced.source, "header") or
        std.mem.eql(u8, priced.source, "body")) "reported" else "estimated";
    h.setp(pending, bucket, h.vfloat((h.get_f64(pending, bucket) orelse 0) + priced.amount));
    h.setp(pending, "source", h.vstr(priced.source));

    track.total.attempts += 1;

    // direct() and graphql() reach the transport without dispatching any
    // pipeline hooks - no PrePoint to gate on, and no PreDone to commit.
    // Their spend is committed here instead, or it would never be counted and
    // could run past an onBudget = "deny" ceiling indefinitely. `piped` is set
    // by PrePoint, so its absence is the signal.
    if (!(h.get_bool(pending, "piped") orelse false)) {
        commit(track, options, ctx, pending, "_", "direct");
        _ = ctx.out.fetchRemove(COST_PENDING_KEY);
    }

    if (failed) return fail_err;
    return res;
}

const Priced = struct {
    amount: f64,
    source: []const u8,
};

// Price one attempt: a reported header figure, else the rate table, else the
// flat unit.
fn price(options: Value, ctx: *Context, res: Value) Priced {
    const header = sup.fopt_str(options, "header", "");
    if (header.len != 0) {
        if (header_num(res, header)) |v| {
            return .{ .amount = v * per_unit(options), .source = "header" };
        }
    }

    if (rate(options, ctx)) |r| {
        return .{ .amount = r, .source = "table" };
    }

    const unit = sup.fopt_num(options, "unit", 0);
    if (unit != 0) {
        return .{ .amount = unit, .source = "unit" };
    }

    return .{ .amount = 0, .source = "none" };
}

// The rate table uses the same lookup grammar as rbac's rules:
// '<entity>.<op>', then '<op>', then '*'.
fn rate(options: Value, ctx: *Context) ?f64 {
    const rates = sup.fopt_map(options, "rates");
    if (rates != .object) return null;

    const entity: []const u8 = if (ctx.entity) |e| e.get_name() else ctx.op.entity;
    const opname = ctx.op.name;

    const k0 = std.fmt.allocPrint(h.A(), "{s}.{s}", .{ entity, opname }) catch opname;
    const keys = [_][]const u8{ k0, opname, "*" };
    for (keys) |key| {
        if (h.get_f64(rates, key)) |n| return n;
    }
    return null;
}

// A usage figure from the parsed result body, priced by perUnit. Read here,
// not at the transport seam, because the body is consumed once.
fn body_amount(options: Value, ctx: *Context) ?f64 {
    const path = sup.fopt_str(options, "path", "");
    if (path.len == 0) return null;

    const result = ctx.result orelse return null;
    if (result.body != .object) return null;

    // Size the segment array from the separator count: a fixed array would
    // silently stop splitting and look up a truncated path, which reads as
    // "no usage figure" rather than as the bug it is. splitScalar yields
    // slices into `path`, so there is nothing to copy.
    var nseg: usize = 1;
    for (path) |c| {
        if (c == '.') nseg += 1;
    }
    const segs = h.A().alloc([]const u8, nseg) catch return null;

    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        segs[n] = seg;
        n += 1;
    }

    const v = h.getpath(segs[0..n], result.body);
    return switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)) * per_unit(options),
        .float => |f| f * per_unit(options),
        else => null,
    };
}

// Commit one operation's spend: totals, budget, per-op and per-actor
// attribution, and the record. Shared by finish and the raw-request path in
// charge, which has no PreDone to reach.
fn commit(track: *CostTrack, options: Value, ctx: *Context, pending: Value, entity: []const u8, opname: []const u8) void {
    var amount = h.get_f64(pending, "amount") orelse 0;
    var reported = h.get_f64(pending, "reported") orelse 0;
    var estimated = h.get_f64(pending, "estimated") orelse 0;
    var source = h.get_str(pending, "source") orelse "none";

    // A body figure prices the whole call, so it replaces the per-attempt
    // estimate rather than adding to it - and, being server-stated, the whole
    // amount counts as reported.
    if (body_amount(options, ctx)) |b| {
        amount = b;
        reported = b;
        estimated = 0;
        source = "body";
    }

    spend(track, amount, reported, estimated);

    var actor: []const u8 = "anonymous";
    const opt_actor = sup.fopt_str(options, "actor", "");
    if (opt_actor.len != 0) actor = opt_actor;
    if (ctx.ctrl.actor.len != 0) actor = ctx.ctrl.actor;

    track.total.calls += 1;

    const opkey = std.fmt.allocPrint(h.A(), "{s}.{s}", .{ entity, opname }) catch opname;
    bump(&track.ops, opkey, amount);
    bump(&track.actors, actor, amount);

    track.seq += 1;
    const record = h.omap();
    h.setp(record, "seq", h.vnum(track.seq));
    h.setp(record, "entity", h.vstr(entity));
    h.setp(record, "op", h.vstr(opname));
    h.setp(record, "actor", h.vstr(actor));
    h.setp(record, "amount", h.vfloat(amount));
    h.setp(record, "currency", h.vstr(track.currency));
    h.setp(record, "source", h.vstr(source));
    h.setp(record, "attempts", h.vfloat(h.get_f64(pending, "attempts") orelse 0));
    track.last = record;

    const sink = h.getp(options, "sink");
    if (sink == .function) {
        _ = h.call_vfn(sink, record);
    }
}

fn spend(track: *CostTrack, amount: f64, reported: f64, estimated: f64) void {
    track.total.amount += amount;
    track.total.reported += reported;
    track.total.estimated += estimated;

    track.budget.spent = track.total.amount;
    if (track.budget.limit > 0) {
        track.budget.remaining = @max(@as(f64, 0), track.budget.limit - track.total.amount);
        if (track.total.amount >= track.budget.limit) track.budget.exceeded = true;
    } else {
        track.budget.remaining = 0;
    }
}

fn bump(bucket: *std.StringHashMap(CostBucket), key: []const u8, amount: f64) void {
    const gop = bucket.getOrPut(key) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.calls += 1;
    gop.value_ptr.amount += amount;
}

// HTTP header names are case-insensitive and a custom transport keeps
// conventional casing ("X-Request-Cost"), so fres_header scans rather than
// indexes.
fn header_num(res: Value, name: []const u8) ?f64 {
    const s = sup.fres_header(res, name) orelse return null;
    return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch null;
}

fn per_unit(options: Value) f64 {
    return sup.fopt_num(options, "perUnit", 0);
}
