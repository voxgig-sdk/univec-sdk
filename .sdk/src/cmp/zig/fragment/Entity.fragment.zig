// EntityName entity client (generated — mirrors the go/rust Entity fragment).

const std = @import("std");
const vs = @import("voxgig-struct");
const h = @import("../core/helpers.zig");
const errmod = @import("../core/error.zig");
const types = @import("../core/types.zig");
const ctxmod = @import("../core/context.zig");
const utility_mod = @import("../core/utility.zig");
const sdk = @import("../core/sdk.zig");

const Value = h.Value;
const Context = ctxmod.Context;
const CtxSpec = ctxmod.CtxSpec;
const Utility = utility_mod.Utility;
const OpResult = types.OpResult;
const OutVal = types.OutVal;
const Entity = types.Entity;

// Every operation resolves to the ENTITY, not the raw data — `list` to a
// slice of them, one per record; the record is reached through `data()`.
// See AGENTS.md "Entity operations return ENTITIES".
//
// `Value` cannot carry an entity (it is a closed data union) and the shared
// `OpResult` cannot name a per-entity type, so each entity declares its own
// result unions and the CONTRACT lives in those signatures.
pub const EntResult = union(enum) {
    ok: *EntyClass,
    err: *errmod.ProjectNameError,
};

pub const EntListResult = union(enum) {
    ok: []*EntyClass,
    err: *errmod.ProjectNameError,
};

pub const EntyClass = struct {
    name: []const u8 = "entityname",
    client: *sdk.ProjectNameSDK,
    utility: *Utility,
    entopts: Value,
    data: Value,
    mtch: Value,
    entctx: ?*Context = null,
    // Set once a successful `remove` resolves on this instance.
    deleted: bool = false,

    pub fn new(client: *sdk.ProjectNameSDK, entopts_in: Value) *EntyClass {
        const entopts: Value = switch (entopts_in) {
            .object => entopts_in,
            else => h.omap(),
        };
        const act = h.get_bool(entopts, "active");
        if (act == null) {
            h.setp(entopts, "active", h.vbool(true));
        } else if (act.? != false) {
            h.setp(entopts, "active", h.vbool(true));
        }

        const e = h.A().create(EntyClass) catch unreachable;
        e.* = .{
            .name = "entityname",
            .client = client,
            .utility = client.get_utility(),
            .entopts = entopts,
            .data = h.omap(),
            .mtch = h.omap(),
            .entctx = null,
        };

        const entctx = e.utility.make_context(CtxSpec{
            .entity = e.asEntity(),
            .entopts = entopts,
        }, client.get_root_ctx());

        e.utility.feature_hook(entctx, "PostConstructEntity");
        e.entctx = entctx;
        return e;
    }

    fn ent_ctx(self: *EntyClass) *Context {
        return self.entctx orelse unreachable;
    }

    fn opError(self: *EntyClass, ctx: *Context) OpResult {
        const v = self.utility.make_error(ctx) catch return .{ .err = ctx.pending_err.? };
        return .{ .ok = v };
    }

    fn doneResult(self: *EntyClass, ctx: *Context) OpResult {
        const v = self.utility.done(ctx) catch return .{ .err = ctx.pending_err.? };
        return .{ .ok = v };
    }

    // Runs the pipeline and hands back THIS entity: run_op has just absorbed
    // the result into it. See AGENTS.md "Entity operations return ENTITIES".
    fn run_op_ent(self: *EntyClass, ctx: *Context, post_done: *const fn (*EntyClass, *Context) void) EntResult {
        return switch (self.run_op(ctx, post_done)) {
            .err => |e| EntResult{ .err = e },
            .ok => EntResult{ .ok = self },
        };
    }

    // `remove` resolves to the entity, marked. The instance KEEPS the data it
    // held — a caller can still read what was deleted — but it is no longer a
    // live record.
    pub fn mark_deleted(self: *EntyClass) void {
        self.deleted = true;
    }

    pub fn is_deleted(self: *EntyClass) bool {
        return self.deleted;
    }

    fn run_op(self: *EntyClass, ctx: *Context, post_done: *const fn (*EntyClass, *Context) void) OpResult {
        const utility = self.utility;

        // #PrePoint-Hook

        const point = utility.make_point(ctx) catch return self.opError(ctx);
        ctx.out_set("point", OutVal{ .val = point });

        // #PreSpec-Hook

        const spec = utility.make_spec(ctx) catch return self.opError(ctx);
        ctx.out_set("spec", OutVal{ .spec = spec });

        // #PreRequest-Hook

        const resp = utility.make_request(ctx) catch return self.opError(ctx);
        ctx.out_set("request", OutVal{ .response = resp });

        // #PreResponse-Hook

        const resp2 = utility.make_response(ctx) catch return self.opError(ctx);
        ctx.out_set("response", OutVal{ .response = resp2 });

        // #PreResult-Hook

        const result = utility.make_result(ctx) catch return self.opError(ctx);
        ctx.out_set("result", OutVal{ .result = result });

        // #PreDone-Hook

        post_done(self, ctx);

        return self.doneResult(ctx);
    }

    /// Streaming operation. Runs `action` through the full pipeline and
    /// returns a slice of the result items, so the `streaming` feature's
    /// incremental output is reachable from a generated entity (a normal op
    /// call materialises the whole result). This runtime is synchronous and
    /// zig has no built-in lazy iterators, so the returned slice is a
    /// materialised cursor the caller walks. `callopts` parameterises the
    /// call: inbound yields the streaming feature's items when active, else
    /// the materialised items; outbound attaches an iterable `body` to the
    /// request (reqdata `body$`); `ctrl` threads pipeline control.
    pub fn stream(self: *EntyClass, action: []const u8, args: Value, callopts: Value) []Value {
        const utility = self.utility;

        const stream_opts: Value = switch (callopts) {
            .object => callopts,
            else => h.omap(),
        };

        const ctrl: Value = switch (h.to_map(h.getp(stream_opts, "ctrl"))) {
            .object => h.to_map(h.getp(stream_opts, "ctrl")),
            else => h.omap(),
        };
        h.setp(ctrl, "stream", stream_opts);

        const reqmatch: Value = switch (args) {
            .object => args,
            else => h.omap(),
        };

        const ctx = utility.make_context(CtxSpec{
            .opname = action,
            .ctrl = ctrl,
            .mtch = self.mtch,
            .data = self.data,
            .reqmatch = reqmatch,
        }, self.ent_ctx());

        // Outbound: attach a caller `body` so the transport can stream a
        // request payload (reqdata `body$`).
        const body = h.getp(stream_opts, "body");
        if (!h.is_noval(body)) {
            const reqdata: Value = switch (ctx.reqdata) {
                .object => ctx.reqdata,
                else => h.omap(),
            };
            h.setp(reqdata, "body$", body);
            ctx.reqdata = reqdata;
        }

        // Run the same pipeline as run_op, firing the feature hooks (the
        // streaming feature attaches result.stream on PreResult).
        utility.feature_hook(ctx, "PrePoint");
        const point = utility.make_point(ctx) catch return &.{};
        ctx.out_set("point", OutVal{ .val = point });

        utility.feature_hook(ctx, "PreSpec");
        const spec = utility.make_spec(ctx) catch return &.{};
        ctx.out_set("spec", OutVal{ .spec = spec });

        utility.feature_hook(ctx, "PreRequest");
        const resp = utility.make_request(ctx) catch return &.{};
        ctx.out_set("request", OutVal{ .response = resp });

        utility.feature_hook(ctx, "PreResponse");
        const resp2 = utility.make_response(ctx) catch return &.{};
        ctx.out_set("response", OutVal{ .response = resp2 });

        utility.feature_hook(ctx, "PreResult");
        const result = utility.make_result(ctx) catch return &.{};
        ctx.out_set("result", OutVal{ .result = result });

        utility.feature_hook(ctx, "PreDone");

        // Inbound: prefer the streaming feature's incremental producer; else
        // fall back to the materialised items so stream always yields.
        if (ctx.result) |res| {
            if (res.stream) |sf| {
                return sf.call(sf.ctx);
            }
        }

        const data = utility.done(ctx) catch return &.{};
        if (data == .array) {
            return data.array.data.items;
        } else if (!h.is_noval(data)) {
            var out = std.ArrayList(Value).init(h.A());
            out.append(data) catch {};
            return out.toOwnedSlice() catch &.{};
        }
        return &.{};
    }

    // ---- Entity interface ----

    fn e_of(p: *anyopaque) *EntyClass {
        return @ptrCast(@alignCast(p));
    }
    fn v_get_name(p: *anyopaque) []const u8 {
        return e_of(p).name;
    }
    fn v_make(p: *anyopaque) Entity {
        const self = e_of(p);
        const opts = h.omap();
        if (self.entopts == .object) {
            var it = self.entopts.object.iterator();
            while (it.next()) |kv| h.setp(opts, kv.key_ptr.*, kv.value_ptr.*);
        }
        return EntyClass.new(self.client, opts).asEntity();
    }
    fn v_data(p: *anyopaque, args: ?Value) Value {
        return e_of(p).data_impl(args);
    }
    fn v_matchv(p: *anyopaque, args: ?Value) Value {
        return e_of(p).matchv_impl(args);
    }

    const entity_vtable = Entity.VTable{
        .get_name = v_get_name,
        .make = v_make,
        .data = v_data,
        .matchv = v_matchv,
    };

    pub fn asEntity(self: *EntyClass) Entity {
        return .{ .ptr = @ptrCast(self), .vtable = &entity_vtable };
    }

    fn data_impl(self: *EntyClass, args: ?Value) Value {
        if (args) |arg| {
            if (!h.is_noval(arg)) {
                const cloned = h.to_map(h.clone(arg));
                self.data = switch (cloned) {
                    .object => cloned,
                    else => h.omap(),
                };
                self.utility.feature_hook(self.ent_ctx(), "SetData");
            }
        }
        self.utility.feature_hook(self.ent_ctx(), "GetData");
        return h.clone(self.data);
    }

    fn matchv_impl(self: *EntyClass, args: ?Value) Value {
        if (args) |arg| {
            if (!h.is_noval(arg)) {
                const cloned = h.to_map(h.clone(arg));
                self.mtch = switch (cloned) {
                    .object => cloned,
                    else => h.omap(),
                };
                self.utility.feature_hook(self.ent_ctx(), "SetMatch");
            }
        }
        self.utility.feature_hook(self.ent_ctx(), "GetMatch");
        return h.clone(self.mtch);
    }

    // ---- CRUD operations ----

    // #LoadOp

    // #ListOp

    // #CreateOp

    // #UpdateOp

    // #RemoveOp
};
