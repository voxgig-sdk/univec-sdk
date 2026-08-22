// Distributed-tracing telemetry (mirrors go feature/telemetry_feature.go /
// rust feature/telemetry.rs). Opens a span per operation (PrePoint),
// propagates trace context to the server as W3C `traceparent` plus
// `X-Trace-Id` / `X-Span-Id` headers (PreRequest), and closes the span on
// completion (PreDone) or failure (PreUnexpected). Each span closes exactly
// once (the per-context marker in ctx.out is consumed on close). Finished
// spans accumulate on the feature; an `exporter` callback, when provided, is
// invoked with each finished span. Trace/span id generation (`idgen`) and the
// clock (`now`) are injectable for deterministic tests.

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const OutVal = types.OutVal;

const TELEMETRY_SPAN_KEY: []const u8 = "telemetry_span";

pub const TelemetryFeature = struct {
    name: []const u8 = "telemetry",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    seq: i64 = 0,

    // Activity tracking (mirrors the ts client._telemetry record).
    spans: std.ArrayList(Value),
    active_spans: i64 = 0,

    pub fn make() Feature {
        const self = h.A().create(TelemetryFeature) catch unreachable;
        self.* = .{ .spans = std.ArrayList(Value).init(h.A()) };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *TelemetryFeature {
        return @ptrCast(@alignCast(p));
    }

    fn id(self: *TelemetryFeature, kind: []const u8) []const u8 {
        const idgen = h.getp(self.options, "idgen");
        if (idgen == .function) {
            const r = h.call_vfn(idgen, h.vstr(kind));
            if (r == .string) return r.string;
        }
        // Deterministic-ish sequential id; unique within a client instance.
        self.seq += 1;
        var buf = std.ArrayList(u8).init(h.A());
        buf.writer().print("{x:0>4}", .{@as(u64, @intCast(self.seq))}) catch {};
        while (buf.items.len < 16) buf.append('0') catch {};
        const prefix: []const u8 = if (std.mem.eql(u8, kind, "trace")) "t" else "s";
        return std.fmt.allocPrint(h.A(), "{s}{s}", .{ prefix, buf.items }) catch "";
    }

    fn close(self: *TelemetryFeature, ctx: *Context, ok: bool) void {
        // Close once per operation; a PreDone followed by a pipeline failure
        // (non-2xx) fires PreUnexpected too, which then finds no open span.
        const taken = ctx.out.fetchRemove(TELEMETRY_SPAN_KEY) orelse return;
        const span: Value = switch (taken.value) {
            .val => |v| if (v == .object) v else return,
            else => return,
        };

        const end = sup.fopt_now(self.options);
        const start = h.get_i64(span, "start") orelse 0;
        const dur = @max(end - start, 0);
        h.setp(span, "end", h.vnum(end));
        h.setp(span, "durationMs", h.vnum(dur));
        h.setp(span, "ok", h.vbool(ok));

        self.active_spans -= 1;
        self.spans.append(span) catch {};

        const exporter = h.getp(self.options, "exporter");
        if (exporter == .function) {
            _ = h.call_vfn(exporter, span);
        }
    }

    fn pre_point(self: *TelemetryFeature, ctx: *Context) void {
        if (!self.active) return;

        const entity = ctx.op.entity;
        const opname = ctx.op.name;

        const span = h.omap();
        h.setp(span, "traceId", h.vstr(self.id("trace")));
        h.setp(span, "spanId", h.vstr(self.id("span")));
        h.setp(span, "name", h.vstr(std.fmt.allocPrint(h.A(), "{s}.{s}", .{ entity, opname }) catch ""));
        h.setp(span, "start", h.vnum(sup.fopt_now(self.options)));
        ctx.out_set(TELEMETRY_SPAN_KEY, OutVal{ .val = span });
        self.active_spans += 1;
    }

    fn pre_request(self: *TelemetryFeature, ctx: *Context) void {
        if (!self.active) return;

        const span = ctx.out_val(TELEMETRY_SPAN_KEY);
        if (span != .object) return;
        const sp = ctx.spec orelse return;

        const headers: Value = if (sp.headers == .object) sp.headers else blk: {
            const nh = h.omap();
            sp.headers = nh;
            break :blk nh;
        };

        const hmap = sup.fopt_map(self.options, "headers");
        const trace_id = h.get_str(span, "traceId") orelse "";
        const span_id = h.get_str(span, "spanId") orelse "";
        h.setp(headers, sup.fopt_str(hmap, "trace", "X-Trace-Id"), h.vstr(trace_id));
        h.setp(headers, sup.fopt_str(hmap, "span", "X-Span-Id"), h.vstr(span_id));
        h.setp(headers, sup.fopt_str(hmap, "parent", "traceparent"), h.vstr(std.fmt.allocPrint(h.A(), "00-{s}-{s}-01", .{ trace_id, span_id }) catch ""));
    }

    fn pre_done(self: *TelemetryFeature, ctx: *Context) void {
        const ok = if (ctx.result) |r| (r.ok and r.err == null) else false;
        self.close(ctx, ok);
    }

    fn pre_unexpected(self: *TelemetryFeature, ctx: *Context) void {
        self.close(ctx, false);
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
        self.seq = 0;
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        const self = self_of(p);
        if (std.mem.eql(u8, name, "PrePoint")) {
            self.pre_point(ctx);
        } else if (std.mem.eql(u8, name, "PreRequest")) {
            self.pre_request(ctx);
        } else if (std.mem.eql(u8, name, "PreDone")) {
            self.pre_done(ctx);
        } else if (std.mem.eql(u8, name, "PreUnexpected")) {
            self.pre_unexpected(ctx);
        }
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};
