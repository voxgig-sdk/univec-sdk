// Network behaviour simulation (mirrors go feature/netsim_feature.go / rust
// feature/netsim.rs). Wraps the active transport and injects realistic
// network conditions so offline unit tests can exercise slowness, transient
// failures, rate limiting and outages deterministically. Every mode is
// counter-driven per client; `failRate` uses a seeded LCG (gotcha #6):
//   seed = (seed*1103515245 + 12345) & 0x7fffffff.
// Error codes are exactly `netsim_offline` / `netsim_conn`.

const std = @import("std");
const h = @import("../core/helpers.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;

pub const NetsimTrack = struct {
    seed: i64 = 0,
    calls: i64 = 0,
    applied: std.ArrayList(Value),
};

pub const NetsimFeature = struct {
    name: []const u8 = "netsim",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    track: *NetsimTrack,

    pub fn make() Feature {
        const self = h.A().create(NetsimFeature) catch unreachable;
        const track = h.A().create(NetsimTrack) catch unreachable;
        track.* = .{ .applied = std.ArrayList(Value).init(h.A()) };
        self.* = .{ .track = track };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *NetsimFeature {
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

        self.track.seed = sup.fopt_int(options, "seed", 0);
        if (self.track.seed == 0) self.track.seed = 1;

        if (!self.active) return;

        const util = ctx.util();
        const w = h.A().create(WrapCtx) catch unreachable;
        w.* = .{ .inner = util.fetcher, .options = options, .track = self.track };
        util.fetcher = .{ .ctx = @ptrCast(w), .call = wrapCall };
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        _ = p;
        _ = name;
        _ = ctx;
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
    track: *NetsimTrack,
};

fn wrapCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *WrapCtx = @ptrCast(@alignCast(p));
    return simulate(w.track, w.options, ctx, url, fetchdef, w.inner);
}

fn lcg_rand(track: *NetsimTrack) f64 {
    track.seed = (track.seed *% 1103515245 +% 12345) & 0x7fffffff;
    return @as(f64, @floatFromInt(track.seed)) / @as(f64, @floatFromInt(@as(i64, 0x7fffffff)));
}

fn pick_latency(track: *NetsimTrack, options: Value) i64 {
    const l = h.getp(options, "latency");
    if (h.is_noval(l)) return 0;
    if (l == .object) {
        const min = sup.fopt_int(l, "min", 0);
        const max = sup.fopt_int(l, "max", min);
        if (max <= min) return min;
        return min + @as(i64, @intFromFloat(lcg_rand(track) * @as(f64, @floatFromInt(max - min))));
    }
    return @max(sup.fopt_int(options, "latency", 0), 0);
}

fn track_applied(track: *NetsimTrack, ctx: *Context, applied: Value) void {
    track.applied.append(applied) catch {};
    const calls = track.calls;
    const applied_list = h.olist();
    for (track.applied.items) |a| applied_list.array.append(a) catch {};

    const c = ctx.ctrl;
    if (c.has_explain()) {
        h.setp(c.explain, "netsim", h.jo(&.{
            .{ "calls", h.vnum(calls) },
            .{ "applied", applied_list },
        }));
    }
}

fn respond(status: i64, data: Value, extra: []const h.Pair) Value {
    const out = h.jo(&.{
        .{ "status", h.vnum(status) },
        .{ "statusText", h.vstr("OK") },
        .{ "json", h.json_thunk(data) },
        .{ "body", h.vstr("not-used") },
        .{ "headers", h.omap() },
    });
    for (extra) |kv| h.setp(out, kv[0], kv[1]);
    return out;
}

fn simulate(track: *NetsimTrack, opts: Value, ctx: *Context, url: []const u8, fetchdef: Value, inner: Fetcher) err.E!Value {
    track.calls += 1;
    const call = track.calls;

    // Total outage: every call fails at the transport level.
    if (sup.fopt_bool(opts, "offline", false)) {
        sup.fopt_sleep(opts, pick_latency(track, opts));
        track_applied(track, ctx, h.jo(&.{.{ "offline", h.vbool(true) }}));
        return ctx.fail("netsim_offline", std.fmt.allocPrint(h.A(), "Simulated network offline (URL was: \"{s}\")", .{url}) catch "offline");
    }

    // Connection-level errors for the first N calls.
    if (call <= sup.fopt_int(opts, "errorTimes", 0)) {
        sup.fopt_sleep(opts, pick_latency(track, opts));
        track_applied(track, ctx, h.jo(&.{.{ "error", h.vbool(true) }}));
        return ctx.fail("netsim_conn", std.fmt.allocPrint(h.A(), "Simulated connection error (call {d})", .{call}) catch "conn");
    }

    // Rate-limit responses (429 + Retry-After) for the first N calls.
    if (call <= sup.fopt_int(opts, "rateLimitTimes", 0)) {
        sup.fopt_sleep(opts, pick_latency(track, opts));
        track_applied(track, ctx, h.jo(&.{.{ "rateLimited", h.vbool(true) }}));
        const headers = h.jo(&.{.{ "retry-after", h.vstr(std.fmt.allocPrint(h.A(), "{d}", .{sup.fopt_int(opts, "retryAfter", 0)}) catch "0") }});
        return respond(429, h.vnull(), &.{
            .{ "statusText", h.vstr("Too Many Requests") },
            .{ "headers", headers },
        });
    }

    // Retryable failure status: first N calls, every Nth, or at failRate.
    const fail_status = sup.fopt_int(opts, "failStatus", 503);
    const fail_every = sup.fopt_int(opts, "failEvery", 0);
    const fail_by_count = call <= sup.fopt_int(opts, "failTimes", 0);
    const fail_by_every = fail_every > 0 and @mod(call, fail_every) == 0;
    const fail_rate = sup.fopt_num(opts, "failRate", 0.0);
    const fail_by_rate = fail_rate > 0.0 and lcg_rand(track) < fail_rate;
    if (fail_by_count or fail_by_every or fail_by_rate) {
        sup.fopt_sleep(opts, pick_latency(track, opts));
        track_applied(track, ctx, h.jo(&.{.{ "failStatus", h.vnum(fail_status) }}));
        return respond(fail_status, h.vnull(), &.{.{ "statusText", h.vstr("Simulated Failure") }});
    }

    // Otherwise: apply latency then delegate to the real transport.
    const latency = pick_latency(track, opts);
    track_applied(track, ctx, h.jo(&.{.{ "latency", h.vnum(latency) }}));
    sup.fopt_sleep(opts, latency);
    return inner.invoke(ctx, url, fetchdef);
}
