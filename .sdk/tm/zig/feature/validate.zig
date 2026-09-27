// Payload validation against the model's own field types (mirrors rust
// feature/validate.rs and tm/ts/src/feature/validate/ValidateFeature.ts).
//
// The specs are NOT written here and not written in the model either: every
// entity field already carries a canonical type sentinel (`$STRING`,
// `$INTEGER`, the `$ONE` union for an OpenAPI multi-type), which is the same
// vocabulary vs.validate speaks. The generator maps them once
// (helpers/canonSpec) and emits `core/schema.zig`, so a field whose type
// changes in the API spec changes what this feature enforces with no edit
// anywhere.
//
// WHAT IS CHECKED
//   outbound (PreSpec)  the payload the caller asked to send, against
//                       spec.op[opname] — the operation's request shape.
//   inbound  (PreDone)  each record the operation returned, against
//                       spec.data — the entity's own field types.
//
// WHAT IS NOT. The model carries no array element types, no nested object
// schemas, no enums, formats or bounds, so this checks the shape the model
// knows and nothing more.

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const schema = @import("../core/schema.zig");
const sup = @import("support.zig");
const vs = @import("voxgig-struct");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const OutVal = types.OutVal;

// Built rather than written, so the backticks cannot be lost in an edit.
const OPEN = [_]u8{96} ++ "$OPEN" ++ [_]u8{96};

fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(h.A(), f, args) catch "validate";
}

// The spec tree with every `$OPEN` marker removed, so an undeclared key is an
// error rather than a pass. Rebuilt rather than mutated: shared_entityspec()
// hands out a process-lifetime singleton every client reads.
fn close_spec(node: Value) Value {
    switch (node) {
        .array => |l| {
            const out = h.olist();
            for (l.data.items) |item| out.array.append(close_spec(item)) catch {};
            return out;
        },
        .object => |m| {
            const out = h.omap();
            var it = m.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, OPEN)) continue;
                h.setp(out, e.key_ptr.*, close_spec(e.value_ptr.*));
            }
            return out;
        },
        else => return node,
    }
}

pub const ValidateFeature = struct {
    name: []const u8 = "validate",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    spec: Value = .{ .null = {} },

    request: bool = true,
    response: bool = false,
    mode: []const u8 = "throw",

    pub fn make() Feature {
        const self = h.A().create(ValidateFeature) catch unreachable;
        self.* = .{};
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *ValidateFeature {
        return @ptrCast(@alignCast(p));
    }

    fn entname(ctx: *Context) []const u8 {
        if (ctx.entity) |e| {
            const n = e.get_name();
            if (n.len != 0) return n;
        }
        return ctx.op.entity;
    }

    fn entity_spec(self: *ValidateFeature, ctx: *Context) Value {
        return h.getp(self.spec, entname(ctx));
    }

    // The payload an operation is about to send.
    //
    // TWO SLOTS, AND THE OP PICKS. A body op (create/update/patch) carries the
    // caller's argument in `reqdata` over the entity's `data`; a match op
    // (load/list/remove) carries it in `reqmatch` over `mtch`. That is what
    // the entity operations pass to the context and what make_point reads — so
    // reading `reqdata` for every op would check a `load({id})` against the
    // entity's STALE stored match and reject it for the id the caller had just
    // supplied.
    fn payload(ctx: *Context, opname: []const u8) Value {
        const body = std.mem.eql(u8, opname, "create") or
            std.mem.eql(u8, opname, "update") or
            std.mem.eql(u8, opname, "patch");

        const base = if (body) ctx.data else ctx.mtch;
        const req = if (body) ctx.reqdata else ctx.reqmatch;

        const out = h.omap();
        for ([_]Value{ base, req }) |src| {
            if (src != .object) continue;
            var it = src.object.iterator();
            while (it.next()) |e| h.setp(out, e.key_ptr.*, e.value_ptr.*);
        }

        // `$action` SELECTS A CUSTOM ENDPOINT; it is not a field of the
        // record. make_point reads it off this same argument and the request
        // transformer drops it before the body is built, so a spec built from
        // the API's own fields will never name it — and under `strict` every
        // custom-action call would be rejected for the one key that made it
        // reachable.
        _ = out.object.fetchOrderedRemove("$action");

        return out;
    }

    // One validate call. THE JOINED MESSAGE, not a list: this port's
    // vs.validate returns a single `err` string with the collected failures
    // already joined by " | ", rather than filling an errs array the way the
    // ts, go and JVM ports do. Nothing is lost — every failure is still in it
    // — so the feature reports the one string.
    fn check(self: *ValidateFeature, ctx: *Context, data: Value, spec: Value) ?[]const u8 {
        _ = self;
        _ = ctx;
        const res = vs.validate(h.A(), data, spec) catch |e| {
            // A spec this port cannot run at all (rather than a payload that
            // fails it) must not take the operation down with it: report it
            // like any other failure and let `mode` decide.
            return fmt("{s}", .{@errorName(e)});
        };
        return res.err;
    }

    // Outbound. make_spec surfaces an `.err` left in out["spec"] before the
    // request is built — the same seam rbac uses one stage earlier through
    // out["point"].
    fn pre_spec(self: *ValidateFeature, ctx: *Context) void {
        if (!self.active or !self.request) return;

        const opname = ctx.op.name;
        const opspec = h.getp(h.getp(self.entity_spec(ctx), "op"), opname);
        if (opspec == .null) return;

        const errs = self.check(ctx, payload(ctx, opname), opspec) orelse return;
        if (std.mem.eql(u8, self.mode, "report")) return;

        const e = ctx.make_error("validate_failed", fmt(
            "Invalid {s} request for entity \"{s}\": {s}",
            .{ opname, entname(ctx), errs },
        ));
        ctx.out_set("spec", OutVal{ .err = e });
    }

    // Inbound. PreDone rather than PreResult: the records are extracted from
    // the response body by make_result, which runs between the two, so at
    // PreResult there is nothing to check but the envelope.
    //
    // HOOK ORDER MATTERS HERE, and the default order is not the one you want.
    // PreDone hooks fire in feature ADD order, which defaults to `test` first
    // and then names sorted — and `validate` sorts last, after audit, cost,
    // debug, metrics and telemetry. Those observers therefore record the
    // operation as a success before this hook has looked at it. Activating
    // features as an ORDERED LIST fixes it.
    fn pre_done(self: *ValidateFeature, ctx: *Context) void {
        if (!self.active or !self.response) return;

        const dataspec = h.getp(self.entity_spec(ctx), "data");
        if (dataspec == .null) return;

        const result = ctx.result orelse return;
        const resdata = result.resdata;
        if (resdata == .null) return;

        // A list op returns many records and a load returns one; both are
        // checked against the same record spec, because they are the same
        // entity.
        //
        // NO UNWRAP STEP, unlike the ts and go ports: make_result already
        // stores a list entry as the item's own data Value rather than as the
        // entity object, so what arrives here is records either way.
        var msg: ?[]const u8 = null;
        if (resdata == .array) {
            for (resdata.array.data.items) |record| {
                if (record == .null) continue;

                // A NON-OBJECT IS A FAILURE, not something to skip. A load
                // that answered 42 where the entity's spec wants a record must
                // not pass this feature silently — struct rejects it with the
                // field it could not find.
                if (self.check(ctx, record, dataspec)) |e| {
                    msg = if (msg) |prev| fmt("{s}; {s}", .{ prev, e }) else e;
                }
            }
        } else if (self.check(ctx, resdata, dataspec)) |e| {
            msg = e;
        }

        const errs = msg orelse return;
        if (std.mem.eql(u8, self.mode, "report")) return;

        const e = ctx.make_error("validate_failed", fmt(
            "Invalid response for entity \"{s}\": {s}",
            .{ entname(ctx), errs },
        ));

        // BOTH, and `ok` is the load-bearing half: done returns resdata
        // whenever result.ok is true and never looks at err, so setting the
        // error alone would hand the caller the very records that failed the
        // spec.
        result.ok = false;
        result.err = e;

        // AND THE DATA GOES. The load/update paths copy result.resdata into
        // the entity's own state on any non-null value, BEFORE done raises —
        // so rejecting the operation while leaving the records in place would
        // leave the caller holding an entity populated from a payload this
        // feature had just declared invalid.
        result.resdata = .{ .null = {} };
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

        // DEFAULTS ARE APPLIED HERE, not by the option spec. The model's
        // `config.options` documents them and types them; it does not inject
        // them, because each feature entry in the spec is optional and struct
        // fills in nothing through an optional union. So every feature
        // resolves its own.
        self.request = sup.fopt_bool(options, "request", true);
        self.response = sup.fopt_bool(options, "response", false);

        // FAIL CLOSED. Only the exact string "report" selects report mode, so
        // a typo (`mode: "thow"`) still rejects rather than silently turning
        // enforcement off — the failure nobody would notice. The option spec
        // rejects the typo outright; this is what happens if it ever does not.
        self.mode = if (std.mem.eql(u8, sup.fopt_str(options, "mode", "throw"), "report"))
            "report"
        else
            "throw";

        // `strict` is applied ONCE, here, by rebuilding the spec tree without
        // the `$OPEN` markers — rather than per call, which would clone a spec
        // for every request an SDK ever makes.
        const entityspec = schema.shared_entityspec();
        self.spec = if (sup.fopt_bool(options, "strict", false))
            close_spec(entityspec)
        else
            entityspec;
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        const self = self_of(p);
        if (std.mem.eql(u8, name, "PreSpec")) {
            self.pre_spec(ctx);
        } else if (std.mem.eql(u8, name, "PreDone")) {
            self.pre_done(ctx);
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
