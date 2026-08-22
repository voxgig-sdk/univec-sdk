// Idempotency keys for mutating operations (mirrors go
// feature/idempotency_feature.go / rust feature/idempotency.rs). Adds an
// `Idempotency-Key` header (name configurable via `header`) to unsafe
// requests so a server can de-duplicate retried writes. The key is set once,
// at PreRequest, before the request is built — so it is stable across
// transport-level retries of the same call. A caller-supplied header is never
// overwritten (case-insensitive). The key generator is injectable (`keygen`).

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;

pub const IdempotencyFeature = struct {
    name: []const u8 = "idempotency",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },

    // Activity tracking (mirrors the ts client._idempotency record).
    issued: i64 = 0,
    last: []const u8 = "",

    pub fn make() Feature {
        const self = h.A().create(IdempotencyFeature) catch unreachable;
        self.* = .{};
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *IdempotencyFeature {
        return @ptrCast(@alignCast(p));
    }

    fn mutating(self: *IdempotencyFeature, ctx: *Context) bool {
        const methods: []const []const u8 = sup.fopt_str_list(self.options, "methods") orelse &[_][]const u8{ "POST", "PUT", "PATCH", "DELETE" };
        const method: []const u8 = if (ctx.spec) |sp| sp.method else "";
        if (method.len != 0) {
            for (methods) |m| {
                if (std.ascii.eqlIgnoreCase(m, method)) return true;
            }
        }

        const opname = ctx.op.name;
        const ops: []const []const u8 = sup.fopt_str_list(self.options, "ops") orelse &[_][]const u8{ "create", "update", "remove" };
        for (ops) |o| {
            if (std.mem.eql(u8, o, opname)) return true;
        }
        return false;
    }

    fn genkey(self: *IdempotencyFeature) []const u8 {
        const kg = h.getp(self.options, "keygen");
        if (kg == .function) {
            const r = h.call_vfn(kg, h.vnull());
            if (r == .string) return r.string;
        }
        const key = std.fmt.allocPrint(h.A(), "{x:0>6}{x:0>6}{x:0>6}{x:0>6}", .{
            @as(u32, @intCast(h.rand_int(0x1000000))),
            @as(u32, @intCast(h.rand_int(0x1000000))),
            @as(u32, @intCast(h.rand_int(0x1000000))),
            @as(u32, @intCast(h.rand_int(0x1000000))),
        }) catch "";
        return if (key.len >= 24) key[0..24] else key;
    }

    fn pre_request(self: *IdempotencyFeature, ctx: *Context) void {
        if (!self.active) return;

        const sp = ctx.spec orelse return;

        if (!self.mutating(ctx)) return;

        const header = sup.fopt_str(self.options, "header", "Idempotency-Key");

        const headers: Value = if (sp.headers == .object) sp.headers else blk: {
            const m = h.omap();
            sp.headers = m;
            break :blk m;
        };

        // Respect a key the caller already provided.
        if (sup.fheader_get(headers, header) != null) return;

        const key = self.genkey();
        h.setp(headers, header, h.vstr(key));

        self.issued += 1;
        self.last = key;
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
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        if (std.mem.eql(u8, name, "PreRequest")) self_of(p).pre_request(ctx);
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};
