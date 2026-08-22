// Structured hook logging (mirrors go feature/log_feature.go / rust
// feature/log.rs, using stderr lines instead of slog). Logs every pipeline
// hook with the operation and spec summary when active; `level` filters
// (debug < info < warn < error).

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;

fn level_num(level: []const u8) i64 {
    if (std.mem.eql(u8, level, "debug")) return 10;
    if (std.mem.eql(u8, level, "warn")) return 30;
    if (std.mem.eql(u8, level, "error")) return 40;
    return 20;
}

pub const LogFeature = struct {
    name: []const u8 = "log",
    active: bool = false,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    level: i64 = 20,

    pub fn make() Feature {
        const self = h.A().create(LogFeature) catch unreachable;
        self.* = .{ .level = level_num("info") };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *LogFeature {
        return @ptrCast(@alignCast(p));
    }

    fn loghook(self: *LogFeature, hook: []const u8, ctx: *Context) void {
        if (!self.active) return;
        if (level_num("info") < self.level) return;

        const opname = ctx.op.name;
        const specinfo: []const u8 = if (ctx.spec) |sp|
            std.fmt.allocPrint(h.A(), "{s} {s}", .{ sp.method, sp.path }) catch ""
        else
            "";

        std.debug.print("name=log hook={s} op={s} spec={s}\n", .{ hook, opname, specinfo });
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
        self.level = level_num(sup.fopt_str(options, "level", "info"));
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        const self = self_of(p);
        if (std.mem.eql(u8, name, "PostConstruct") or
            std.mem.eql(u8, name, "PostConstructEntity") or
            std.mem.eql(u8, name, "SetData") or
            std.mem.eql(u8, name, "GetData") or
            std.mem.eql(u8, name, "SetMatch") or
            std.mem.eql(u8, name, "GetMatch") or
            std.mem.eql(u8, name, "PrePoint") or
            std.mem.eql(u8, name, "PreSpec") or
            std.mem.eql(u8, name, "PreRequest") or
            std.mem.eql(u8, name, "PreResponse") or
            std.mem.eql(u8, name, "PreResult"))
        {
            self.loghook(name, ctx);
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
