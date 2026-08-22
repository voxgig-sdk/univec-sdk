// Automatic retry of transient failures with exponential backoff and jitter
// (mirrors go feature/retry_feature.go / rust feature/retry.rs). Wraps the
// active transport so a single operation call may make several attempts. A
// failure is retryable when the transport errors, or responds with a status
// in `statuses` (default 408,425,429,500,502,503,504). A 429/503 with a
// Retry-After header overrides the computed backoff. `sleep` is injectable.

const std = @import("std");
const h = @import("../core/helpers.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;

pub const RetryTrack = struct {
    attempts: i64 = 0,
    retries: Value,
};

pub const RetryFeature = struct {
    name: []const u8 = "retry",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    track: *RetryTrack,

    pub fn make() Feature {
        const self = h.A().create(RetryFeature) catch unreachable;
        const track = h.A().create(RetryTrack) catch unreachable;
        track.* = .{ .retries = h.olist() };
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

    fn self_of(p: *anyopaque) *RetryFeature {
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
    track: *RetryTrack,
};

fn wrapCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *WrapCtx = @ptrCast(@alignCast(p));
    return with_retry(w.track, w.options, ctx, url, fetchdef, w.inner);
}

fn with_retry(track: *RetryTrack, options: Value, ctx: *Context, url: []const u8, fetchdef: Value, inner: Fetcher) err.E!Value {
    const max = sup.fopt_int(options, "retries", 2);
    const min_delay = sup.fopt_int(options, "minDelay", 50);
    const max_delay = sup.fopt_int(options, "maxDelay", 2000);
    const factor = sup.fopt_num(options, "factor", 2.0);

    var attempt: i64 = 0;
    while (true) {
        if (inner.invoke(ctx, url, fetchdef)) |res| {
            if (!retryable_ok(options, res) or attempt >= max) return res;
            const wait = backoff(options, res, attempt, min_delay, max_delay, factor);
            track_attempt_ok(track, attempt + 1, res, wait);
            if (wait > 0) sup.fopt_sleep(options, wait);
            attempt += 1;
        } else |e| {
            if (attempt >= max) return e;
            const wait = backoff(options, null, attempt, min_delay, max_delay, factor);
            track_attempt_err(track, attempt + 1, ctx.pending_err, wait);
            if (wait > 0) sup.fopt_sleep(options, wait);
            attempt += 1;
        }
    }
}

fn retryable_ok(options: Value, res: Value) bool {
    if (h.is_noval(res)) return true;
    const status = sup.fres_status(res) orelse return false;
    const statuses = sup.fopt_list(options, "statuses");
    if (statuses == .array) {
        for (statuses.array.data.items) |v| {
            switch (v) {
                .integer => |n| if (n == status) return true,
                .float => |f| if (@as(i64, @intFromFloat(f)) == status) return true,
                else => {},
            }
        }
        return false;
    }
    const defaults = [_]i64{ 408, 425, 429, 500, 502, 503, 504 };
    for (defaults) |d| {
        if (d == status) return true;
    }
    return false;
}

fn backoff(options: Value, res_opt: ?Value, attempt: i64, min_delay: i64, max_delay: i64, factor: f64) i64 {
    if (res_opt) |res| {
        if (retry_after(res)) |ra| return @min(ra, max_delay);
    }
    const base = @as(f64, @floatFromInt(min_delay)) * std.math.pow(f64, factor, @as(f64, @floatFromInt(attempt)));
    const jitter: i64 = if (sup.fopt_bool(options, "jitter", true) and min_delay > 0) h.rand_int(min_delay) else 0;
    const wait = @as(i64, @intFromFloat(base)) + jitter;
    return @min(wait, max_delay);
}

fn retry_after(res: Value) ?i64 {
    const v = sup.fres_header(res, "retry-after") orelse return null;
    const seconds = sup.fparse_int(v, -1);
    if (seconds < 0) return null;
    return seconds * 1000;
}

fn track_attempt_ok(track: *RetryTrack, attempt: i64, res: Value, wait: i64) void {
    track.attempts += 1;
    const entry = h.omap();
    h.setp(entry, "attempt", h.vnum(attempt));
    h.setp(entry, "wait", h.vnum(wait));
    if (sup.fres_status(res)) |status| h.setp(entry, "status", h.vnum(status));
    track.retries.array.append(entry) catch {};
}

fn track_attempt_err(track: *RetryTrack, attempt: i64, e: ?*err.UnivecError, wait: i64) void {
    track.attempts += 1;
    const entry = h.omap();
    h.setp(entry, "attempt", h.vnum(attempt));
    h.setp(entry, "wait", h.vnum(wait));
    if (e) |pe| h.setp(entry, "error", h.vstr(pe.msg));
    track.retries.array.append(entry) catch {};
}
