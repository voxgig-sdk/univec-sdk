// Client-side rate limiting via a token bucket (mirrors go
// feature/ratelimit_feature.go / rust feature/ratelimit.rs). Each request
// consumes a token; when the bucket is empty the request waits until the
// bucket refills at `rate` tokens per second (with capacity `burst`, default:
// rate). The clock (`now`) and the wait (`sleep`) are injectable so the
// accounting can be tested deterministically.

const std = @import("std");
const h = @import("../core/helpers.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;

pub const RatelimitTrack = struct {
    tokens: f64 = 0,
    last: i64 = 0,

    // Activity tracking (mirrors the ts client._ratelimit record).
    throttled: i64 = 0,
    wait_ms: i64 = 0,
};

pub const RatelimitFeature = struct {
    name: []const u8 = "ratelimit",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    track: *RatelimitTrack,

    pub fn make() Feature {
        const self = h.A().create(RatelimitFeature) catch unreachable;
        const track = h.A().create(RatelimitTrack) catch unreachable;
        track.* = .{};
        self.* = .{ .track = track };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
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
        if (!self.active) return;

        const rate = sup.fopt_num(options, "rate", 5.0);
        const burst = sup.fopt_num(options, "burst", rate);
        self.track.tokens = burst;
        self.track.last = sup.fopt_now(options);

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

    fn self_of(p: *anyopaque) *RatelimitFeature {
        return @ptrCast(@alignCast(p));
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
    track: *RatelimitTrack,
};

fn wrapCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *WrapCtx = @ptrCast(@alignCast(p));
    acquire(w.track, w.options);
    return w.inner.invoke(ctx, url, fetchdef);
}

fn acquire(track: *RatelimitTrack, options: Value) void {
    const rate = sup.fopt_num(options, "rate", 5.0);
    const burst = sup.fopt_num(options, "burst", rate);

    // Refill according to elapsed time.
    const now = sup.fopt_now(options);
    const elapsed = now - track.last;
    track.last = now;
    track.tokens = @min(burst, track.tokens + (@as(f64, @floatFromInt(elapsed)) / 1000.0) * rate);

    if (track.tokens >= 1.0) {
        track.tokens -= 1.0;
        return;
    }

    // Not enough tokens: wait for one to accrue, then consume it.
    const needed = 1.0 - track.tokens;
    const wait_ms = @as(i64, @intFromFloat(std.math.ceil((needed / rate) * 1000.0)));
    track.throttled += 1;
    track.wait_ms += wait_ms;

    if (wait_ms > 0) sup.fopt_sleep(options, wait_ms);
    track.last = sup.fopt_now(options);
    track.tokens = 0.0;
}
