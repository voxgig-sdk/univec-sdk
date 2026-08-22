// Audit trail (mirrors go feature/audit_feature.go / rust feature/audit.rs).
// Emits a structured record for every operation — who (actor), what (entity +
// op), the outcome, and a correlation id — suitable for compliance logging.
// Records accumulate on the feature (bounded by `max`, default 1000) and, when
// a `sink` callback is supplied, are also pushed to it. The actor is the
// per-call ctrl actor, falling back to the options `actor`, then "anonymous".
// Each operation is audited exactly once (the per-context marker in ctx.out
// prevents a PreDone + PreUnexpected double-log). Timestamps use the injectable
// `now` clock so tests stay deterministic.

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const OutVal = types.OutVal;

const AUDIT_SEEN_KEY: []const u8 = "audit_seen";

pub const AuditFeature = struct {
    name: []const u8 = "audit",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    seq: i64 = 0,

    // Activity tracking (mirrors the ts client._audit record).
    records: std.ArrayList(Value),

    pub fn make() Feature {
        const self = h.A().create(AuditFeature) catch unreachable;
        self.* = .{ .records = std.ArrayList(Value).init(h.A()) };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *AuditFeature {
        return @ptrCast(@alignCast(p));
    }

    fn emit(self: *AuditFeature, ctx: *Context, outcome: []const u8) void {
        if (!self.active) return;

        // One record per operation (PreDone + a following PreUnexpected on a
        // failure must not double-log).
        if (ctx.out_get(AUDIT_SEEN_KEY)) |ov| {
            switch (ov) {
                .val => |v| if (v == .bool and v.bool) return,
                else => {},
            }
        }
        ctx.out_set(AUDIT_SEEN_KEY, OutVal{ .val = h.vbool(true) });

        self.seq += 1;

        var actor: []const u8 = "anonymous";
        const opt_actor = sup.fopt_str(self.options, "actor", "");
        if (opt_actor.len != 0) actor = opt_actor;
        if (ctx.ctrl.actor.len != 0) actor = ctx.ctrl.actor;

        const entity = ctx.op.entity;
        const opname = ctx.op.name;

        const record = h.omap();
        h.setp(record, "seq", h.vnum(self.seq));
        h.setp(record, "ts", h.vnum(sup.fopt_now(self.options)));
        h.setp(record, "actor", h.vstr(actor));
        h.setp(record, "entity", h.vstr(entity));
        h.setp(record, "op", h.vstr(opname));
        h.setp(record, "outcome", h.vstr(outcome));
        h.setp(record, "correlationId", h.vstr(ctx.id));
        if (ctx.result) |r| h.setp(record, "status", h.vnum(r.status));

        self.records.append(record) catch {};
        const max: usize = @intCast(@max(sup.fopt_int(self.options, "max", 1000), 0));
        while (self.records.items.len > max) {
            _ = self.records.orderedRemove(0);
        }

        const sink = h.getp(self.options, "sink");
        if (sink == .function) {
            _ = h.call_vfn(sink, record);
        }
    }

    fn pre_done(self: *AuditFeature, ctx: *Context) void {
        // Outcome reflects the actual result; a non-2xx reaches PreDone
        // before the pipeline errors.
        const ok = if (ctx.result) |r| (r.ok and r.err == null) else false;
        self.emit(ctx, if (ok) "ok" else "error");
    }

    fn pre_unexpected(self: *AuditFeature, ctx: *Context) void {
        self.emit(ctx, "error");
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
        if (std.mem.eql(u8, name, "PreDone")) {
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
