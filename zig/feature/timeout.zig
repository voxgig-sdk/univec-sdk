// Per-request timeout (mirrors go feature/timeout_feature.go / rust
// feature/timeout.rs, adapted to a synchronous single-threaded transport).
// The active transport is wrapped with a deadline of `ms` milliseconds
// (default 30000; <= 0 disables). The transport is synchronous, so the
// elapsed (injectable `now`) clock is checked around the inner call: when the
// call took longer than the deadline its result is discarded and a `timeout`
// error is returned instead.

const std = @import("std");
const h = @import("../core/helpers.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;

pub const TimeoutTrack = struct {
    // Activity tracking (mirrors the ts client._timeout record).
    count: i64 = 0,
    ms: i64 = 0,
};

pub const TimeoutFeature = struct {
    name: []const u8 = "timeout",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    track: *TimeoutTrack,

    pub fn make() Feature {
        const self = h.A().create(TimeoutFeature) catch unreachable;
        const track = h.A().create(TimeoutTrack) catch unreachable;
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

    fn self_of(p: *anyopaque) *TimeoutFeature {
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
    track: *TimeoutTrack,
};

fn wrapCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *WrapCtx = @ptrCast(@alignCast(p));
    return with_timeout(w.track, w.options, ctx, url, fetchdef, w.inner);
}

fn with_timeout(track: *TimeoutTrack, options: Value, ctx: *Context, url: []const u8, fetchdef: Value, inner: Fetcher) err.E!Value {
    const ms = sup.fopt_int(options, "ms", 30000);
    if (ms <= 0) return inner.invoke(ctx, url, fetchdef);

    const start = sup.fopt_now(options);
    const out = inner.invoke(ctx, url, fetchdef);

    if (sup.fopt_now(options) - start > ms) {
        track.count += 1;
        track.ms = ms;
        return ctx.fail("timeout", std.fmt.allocPrint(h.A(), "Request exceeded timeout of {d}ms", .{ms}) catch "Request exceeded timeout");
    }

    return out;
}
