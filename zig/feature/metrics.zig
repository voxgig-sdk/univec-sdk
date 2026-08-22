// Statistics capture (mirrors go feature/metrics_feature.go / rust
// feature/metrics.rs). Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
// endpoint resolution (PrePoint) and stops when the call returns (PreDone) or
// fails (PreUnexpected); each operation is recorded exactly once (the
// per-context start marker in ctx.out is consumed on record). The clock is
// injectable (`now`) for deterministic tests.

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const OutVal = types.OutVal;

const METRICS_START_KEY: []const u8 = "metrics_start";

pub const MetricsBucket = struct {
    count: i64 = 0,
    ok: i64 = 0,
    err: i64 = 0,
    total_ms: i64 = 0,
    max_ms: i64 = 0,
};

pub const MetricsFeature = struct {
    name: []const u8 = "metrics",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },

    // Aggregates (mirrors the ts client._metrics record).
    total: MetricsBucket = .{},
    ops: std.StringHashMap(MetricsBucket),

    pub fn make() Feature {
        const self = h.A().create(MetricsFeature) catch unreachable;
        self.* = .{ .ops = std.StringHashMap(MetricsBucket).init(h.A()) };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *MetricsFeature {
        return @ptrCast(@alignCast(p));
    }

    fn record(self: *MetricsFeature, ctx: *Context, ok: bool) void {
        // Record once per operation: the missing start marker makes a second
        // call (PreDone followed by PreUnexpected on failure) a no-op.
        const taken = ctx.out.fetchRemove(METRICS_START_KEY) orelse return;
        var start: i64 = 0;
        var is_num = false;
        switch (taken.value) {
            .val => |v| switch (v) {
                .integer, .float => {
                    is_num = true;
                    start = h.to_int(v);
                },
                else => {},
            },
            else => {},
        }
        if (!is_num) {
            // Put back anything unexpected (should not happen).
            ctx.out_set(METRICS_START_KEY, taken.value);
            return;
        }

        const dur = @max(sup.fopt_now(self.options) - start, 0);

        const entity = ctx.op.entity;
        const opname = ctx.op.name;
        const key = std.fmt.allocPrint(h.A(), "{s}.{s}", .{ entity, opname }) catch "";

        bump(&self.total, ok, dur);
        const gop = self.ops.getOrPut(key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        bump(gop.value_ptr, ok, dur);
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
        _ = ctx;
        const self = self_of(p);
        self.options = options;
        self.active = sup.fopt_bool(options, "active", false);
        self.total = .{};
        self.ops = std.StringHashMap(MetricsBucket).init(h.A());
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        const self = self_of(p);
        if (std.mem.eql(u8, name, "PrePoint")) {
            self.pre_point(ctx);
        } else if (std.mem.eql(u8, name, "PreDone")) {
            self.pre_done(ctx);
        } else if (std.mem.eql(u8, name, "PreUnexpected")) {
            self.pre_unexpected(ctx);
        }
    }

    fn pre_point(self: *MetricsFeature, ctx: *Context) void {
        if (!self.active) return;
        ctx.out_set(METRICS_START_KEY, OutVal{ .val = h.vnum(sup.fopt_now(self.options)) });
    }

    fn pre_done(self: *MetricsFeature, ctx: *Context) void {
        // Classify by the actual result: a 4xx/5xx that flows through still
        // reaches PreDone before the pipeline errors.
        const ok = if (ctx.result) |r| (r.ok and r.err == null) else false;
        self.record(ctx, ok);
    }

    fn pre_unexpected(self: *MetricsFeature, ctx: *Context) void {
        self.record(ctx, false);
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};

fn bump(bucket: *MetricsBucket, ok: bool, dur: i64) void {
    bucket.count += 1;
    if (ok) {
        bucket.ok += 1;
    } else {
        bucket.err += 1;
    }
    bucket.total_ms += dur;
    if (dur > bucket.max_ms) bucket.max_ms = dur;
}
