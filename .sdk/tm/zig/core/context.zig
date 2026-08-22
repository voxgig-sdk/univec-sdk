// Operation context (mirrors go core/context.go / rust core/context.rs).
// Contexts are heap-allocated (*Context) and mutated in place through the
// pointer — Zig needs no RefCell, and the Value fields are already
// reference-stable via *MapRef / *ListRef.

const std = @import("std");
const h = @import("helpers.zig");
const err = @import("error.zig");
const control_mod = @import("control.zig");
const operation_mod = @import("operation.zig");
const spec_mod = @import("spec.zig");
const response_mod = @import("response.zig");
const result_mod = @import("result.zig");
const types = @import("types.zig");
const utility_mod = @import("utility.zig");
const sdk = @import("sdk.zig");

const Value = h.Value;
const Control = control_mod.Control;
const Operation = operation_mod.Operation;
const Spec = spec_mod.Spec;
const Response = response_mod.Response;
const SdkResult = result_mod.SdkResult;
const Entity = types.Entity;
const OutVal = types.OutVal;
const Utility = utility_mod.Utility;
const SdkError = err.UnivecError;

pub const OpMap = std.StringHashMap(*Operation);

// Construction spec for a Context.
pub const CtxSpec = struct {
    opname: ?[]const u8 = null,
    client: ?*sdk.UnivecSDK = null,
    utility: ?*Utility = null,
    ctrl: ?Value = null,
    ctrl_obj: ?*Control = null,
    meta: ?Value = null,
    config: ?Value = null,
    entopts: ?Value = null,
    options: ?Value = null,
    entity: ?Entity = null,
    shared: ?Value = null,
    opmap: ?*OpMap = null,
    data: ?Value = null,
    reqdata: ?Value = null,
    mtch: ?Value = null,
    reqmatch: ?Value = null,
    point: ?Value = null,
    spec: ?*Spec = null,
    result: ?*SdkResult = null,
    response: ?*Response = null,
};

pub const Context = struct {
    id: []const u8,
    out: std.StringHashMap(OutVal),
    ctrl: *Control,
    meta: Value,
    client: ?*sdk.UnivecSDK,
    utility: ?*Utility,
    op: *Operation,
    point: Value,
    config: Value,
    entopts: Value,
    options: Value,
    opmap: *OpMap,
    response: ?*Response,
    result: ?*SdkResult,
    spec: ?*Spec,
    data: Value,
    reqdata: Value,
    mtch: Value,
    reqmatch: Value,
    entity: ?Entity,
    shared: Value,
    pending_err: ?*SdkError = null,

    fn mapOrEmpty(v: ?Value) Value {
        if (v) |val| {
            if (h.to_map(val) == .object) return val;
        }
        return h.omap();
    }

    pub fn new(ctxspec: CtxSpec, basectx: ?*Context) *Context {
        const id = std.fmt.allocPrint(h.A(), "C{d}", .{h.rand_int(90000000) + 10000000}) catch "C0";

        const client = ctxspec.client orelse (if (basectx) |b| b.client else null);
        const utility = ctxspec.utility orelse (if (basectx) |b| b.utility else null);

        // Ctrl
        var ctrl: *Control = undefined;
        if (ctxspec.ctrl) |cm| {
            const c = Control.make();
            if (h.get_bool(cm, "throw")) |t| c.throw = t;
            if (h.getp(cm, "explain") == .object) c.explain = h.getp(cm, "explain");
            if (h.get_str(cm, "actor")) |a| c.actor = a;
            if (h.getp(cm, "paging") == .object) c.paging = h.getp(cm, "paging");
            ctrl = c;
        } else if (ctxspec.ctrl_obj) |co| {
            ctrl = co;
        } else if (basectx) |b| {
            ctrl = b.ctrl;
        } else {
            ctrl = Control.make();
        }

        // Meta
        const meta: Value = ctxspec.meta orelse blk: {
            if (basectx) |b| {
                if (b.meta == .object) break :blk b.meta;
            }
            break :blk h.omap();
        };

        // Config / Entopts / Options / Entity / Shared: fall back to base.
        const config: Value = ctxspec.config orelse (if (basectx) |b| b.config else h.vnull());
        const entopts: Value = ctxspec.entopts orelse (if (basectx) |b| b.entopts else h.vnull());
        const options: Value = ctxspec.options orelse (if (basectx) |b| b.options else h.vnull());
        const entity: ?Entity = ctxspec.entity orelse (if (basectx) |b| b.entity else null);
        const shared: Value = ctxspec.shared orelse blk: {
            if (basectx) |b| {
                if (b.shared == .object) break :blk b.shared;
            }
            break :blk h.vnull();
        };

        // Opmap (shared with the base context).
        const opmap: *OpMap = ctxspec.opmap orelse (if (basectx) |b| b.opmap else blk: {
            const m = h.A().create(OpMap) catch unreachable;
            m.* = OpMap.init(h.A());
            break :blk m;
        });

        // Data maps (never inherited).
        const data = mapOrEmpty(ctxspec.data);
        const reqdata = mapOrEmpty(ctxspec.reqdata);
        const mtch = mapOrEmpty(ctxspec.mtch);
        const reqmatch = mapOrEmpty(ctxspec.reqmatch);

        // Point / Spec / Result / Response: fall back to base.
        const point: Value = ctxspec.point orelse blk: {
            if (basectx) |b| {
                if (b.point == .object) break :blk b.point;
            }
            break :blk h.vnull();
        };
        const spec: ?*Spec = ctxspec.spec orelse (if (basectx) |b| b.spec else null);
        const result: ?*SdkResult = ctxspec.result orelse (if (basectx) |b| b.result else null);
        const response: ?*Response = ctxspec.response orelse (if (basectx) |b| b.response else null);

        const ctx = h.A().create(Context) catch unreachable;
        ctx.* = .{
            .id = id,
            .out = std.StringHashMap(OutVal).init(h.A()),
            .ctrl = ctrl,
            .meta = meta,
            .client = client,
            .utility = utility,
            .op = Operation.make(h.omap()),
            .point = point,
            .config = config,
            .entopts = entopts,
            .options = options,
            .opmap = opmap,
            .response = response,
            .result = result,
            .spec = spec,
            .data = data,
            .reqdata = reqdata,
            .mtch = mtch,
            .reqmatch = reqmatch,
            .entity = entity,
            .shared = shared,
            .pending_err = null,
        };

        const opname = ctxspec.opname orelse "";
        ctx.op = ctx.resolve_op(opname);

        return ctx;
    }

    fn resolve_op(self: *Context, opname: []const u8) *Operation {
        const entname: []const u8 = if (self.entity) |e| e.get_name() else "";
        const cache_key = std.fmt.allocPrint(h.A(), "{s}:{s}", .{ entname, opname }) catch opname;

        if (self.opmap.get(cache_key)) |op| return op;

        if (opname.len == 0) {
            return Operation.make(h.omap());
        }

        const opcfg = h.getpath(&.{ "entity", entname, "op", opname }, self.config);

        const input: []const u8 = if (std.mem.eql(u8, opname, "update") or std.mem.eql(u8, opname, "create")) "data" else "match";

        const targets: Value = switch (h.getp(opcfg, "points")) {
            .array => h.getp(opcfg, "points"),
            else => h.olist(),
        };

        const op = Operation.make(h.jo(&.{
            .{ "entity", h.vstr(entname) },
            .{ "name", h.vstr(opname) },
            .{ "input", h.vstr(input) },
            .{ "points", targets },
        }));

        self.opmap.put(cache_key, op) catch {};
        return op;
    }

    pub fn make_error(self: *Context, code: []const u8, msg: []const u8) *SdkError {
        _ = self;
        return SdkError.make(code, msg);
    }

    // Stash a pending error and return the pipeline error sentinel.
    pub fn fail(self: *Context, code: []const u8, msg: []const u8) err.E {
        self.pending_err = SdkError.make(code, msg);
        return error.Sdk;
    }

    pub fn fail_err(self: *Context, e: *SdkError) err.E {
        self.pending_err = e;
        return error.Sdk;
    }

    pub fn take_err(self: *Context) ?*SdkError {
        const e = self.pending_err;
        self.pending_err = null;
        return e;
    }

    pub fn util(self: *Context) *Utility {
        return self.utility orelse unreachable;
    }

    // --- ctx.out staging helpers ---

    pub fn out_get(self: *Context, key: []const u8) ?OutVal {
        return self.out.get(key);
    }
    pub fn out_set(self: *Context, key: []const u8, val: OutVal) void {
        self.out.put(key, val) catch {};
    }
    pub fn out_val(self: *Context, key: []const u8) Value {
        if (self.out.get(key)) |ov| {
            switch (ov) {
                .val => |v| return v,
                else => {},
            }
        }
        return h.vnull();
    }
};
