// BaseFeature: the no-op feature every hook defaults to (mirrors go
// feature/base_feature.go / rust feature/base.rs).

const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;

pub const BaseFeature = struct {
    version: []const u8 = "0.0.1",
    name: []const u8 = "base",
    active: bool = true,
    add_opts: Value = .{ .null = {} },

    pub fn make() Feature {
        const self = h.A().create(BaseFeature) catch unreachable;
        self.* = .{};
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn vname(p: *anyopaque) []const u8 {
        const s: *BaseFeature = @ptrCast(@alignCast(p));
        return s.name;
    }
    fn vactive(p: *anyopaque) bool {
        const s: *BaseFeature = @ptrCast(@alignCast(p));
        return s.active;
    }
    fn vaddopts(p: *anyopaque) Value {
        const s: *BaseFeature = @ptrCast(@alignCast(p));
        return s.add_opts;
    }
    fn vinit(p: *anyopaque, ctx: *Context, options: Value) void {
        _ = p;
        _ = ctx;
        _ = options;
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        _ = p;
        _ = name;
        _ = ctx;
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};
