// Client-side role/permission enforcement (mirrors go feature/rbac_feature.go
// / rust feature/rbac.rs). Before an operation resolves its endpoint, the
// required permission for that entity+operation is checked against the held
// permissions; a disallowed call is short-circuited with an `rbac_denied`
// error stored on ctx.out["point"] (which make_point surfaces — gotcha #2) and
// never touches the network.

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const OutVal = types.OutVal;

pub const RbacFeature = struct {
    name: []const u8 = "rbac",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    granted: std.StringHashMap(bool),

    allowed: i64 = 0,
    denied: i64 = 0,
    last: Value = .{ .null = {} },

    pub fn make() Feature {
        const self = h.A().create(RbacFeature) catch unreachable;
        self.* = .{ .granted = std.StringHashMap(bool).init(h.A()) };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *RbacFeature {
        return @ptrCast(@alignCast(p));
    }

    fn required(self: *RbacFeature, ctx: *Context) ?[]const u8 {
        const rules = sup.fopt_map(self.options, "rules");
        if (rules != .object) return null;

        const entity: []const u8 = if (ctx.entity) |e| e.get_name() else ctx.op.entity;
        const opname = ctx.op.name;

        const k0 = std.fmt.allocPrint(h.A(), "{s}.{s}", .{ entity, opname }) catch opname;
        const keys = [_][]const u8{ k0, opname, "*" };
        for (keys) |key| {
            if (h.get_str(rules, key)) |r| return r;
        }
        return null;
    }

    fn track(self: *RbacFeature, ctx: *Context, req: []const u8, allowed: bool) void {
        if (allowed) {
            self.allowed += 1;
        } else {
            self.denied += 1;
        }
        const opname = ctx.op.name;
        const last = h.omap();
        h.setp(last, "required", h.vstr(req));
        h.setp(last, "allowed", h.vbool(allowed));
        h.setp(last, "op", h.vstr(opname));
        self.last = last;
    }

    fn reject(self: *RbacFeature, ctx: *Context, req: []const u8) void {
        self.track(ctx, req, false);
        const opname0 = ctx.op.name;
        const opname = if (opname0.len == 0) "?" else opname0;
        const msg = std.fmt.allocPrint(h.A(), "Permission \"{s}\" required for operation \"{s}\"", .{ req, opname }) catch "rbac denied";
        const e = ctx.make_error("rbac_denied", msg);
        // Short-circuit endpoint resolution; make_point surfaces this error.
        ctx.out_set("point", OutVal{ .err = e });
    }

    fn pre_point(self: *RbacFeature, ctx: *Context) void {
        if (!self.active) return;

        const req = self.required(ctx) orelse {
            // No rule: honour the default policy.
            if (sup.fopt_bool(self.options, "deny", false)) {
                self.reject(ctx, "<default-deny>");
            }
            return;
        };

        if ((self.granted.get("*") orelse false) or (self.granted.get(req) orelse false)) {
            self.track(ctx, req, true);
            return;
        }
        self.reject(ctx, req);
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
        self.granted = std.StringHashMap(bool).init(h.A());
        if (sup.fopt_str_list(options, "permissions")) |perms| {
            for (perms) |perm| self.granted.put(perm, true) catch {};
        }
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        if (std.mem.eql(u8, name, "PrePoint")) self_of(p).pre_point(ctx);
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};
