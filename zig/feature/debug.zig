// Request/response capture for debugging (mirrors go feature/debug_feature.go
// / rust feature/debug.rs). Records a bounded ring buffer of per-operation
// traces — method, URL, redacted headers, response status and timing — on the
// feature's entries. Sensitive header values (matching `redact`, default
// authorization/cookie/api-key style names) are masked. An optional `onEntry`
// callback receives each finished entry. `max` caps the buffer (default 100).

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const OutVal = types.OutVal;

const DEBUG_ENTRY_KEY: []const u8 = "debug_entry";

const DEBUG_DEFAULT_REDACT = [_][]const u8{
    "authorization",
    "cookie",
    "set-cookie",
    "api-key",
    "apikey",
    "x-api-key",
    "idempotency-key",
};

pub const DebugFeature = struct {
    name: []const u8 = "debug",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },

    // Activity tracking (mirrors the ts client._debug record).
    entries: std.ArrayList(Value),

    pub fn make() Feature {
        const self = h.A().create(DebugFeature) catch unreachable;
        self.* = .{ .entries = std.ArrayList(Value).init(h.A()) };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *DebugFeature {
        return @ptrCast(@alignCast(p));
    }

    fn redact(self: *DebugFeature, headers: Value) Value {
        const out = h.omap();
        const patterns: [][]const u8 = sup.fopt_str_list(self.options, "redact") orelse blk: {
            var l = std.ArrayList([]const u8).init(h.A());
            for (DEBUG_DEFAULT_REDACT) |p| l.append(p) catch {};
            break :blk l.toOwnedSlice() catch &.{};
        };
        if (headers == .object) {
            var it = headers.object.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                const lower = std.ascii.allocLowerString(h.A(), key) catch key;
                var masked = false;
                for (patterns) |p| {
                    if (std.mem.eql(u8, lower, p)) {
                        masked = true;
                        break;
                    }
                }
                if (masked) {
                    h.setp(out, key, h.vstr("<redacted>"));
                } else {
                    h.setp(out, key, kv.value_ptr.*);
                }
            }
        }
        return out;
    }

    fn finish(self: *DebugFeature, ctx: *Context, ok: bool) void {
        // Finish once per operation: the marker in ctx.out is consumed here.
        const taken = ctx.out.fetchRemove(DEBUG_ENTRY_KEY) orelse return;
        const entry: Value = switch (taken.value) {
            .val => |v| if (v == .object) v else return,
            else => return,
        };

        const result_ok = if (ctx.result) |r| r.ok else true;
        h.setp(entry, "ok", h.vbool(ok and result_ok));
        const start = h.get_i64(entry, "start") orelse 0;
        const dur = @max(sup.fopt_now(self.options) - start, 0);
        h.setp(entry, "durationMs", h.vnum(dur));
        if (h.is_noval(h.getp(entry, "status"))) {
            if (ctx.result) |r| h.setp(entry, "status", h.vnum(r.status));
        }

        self.entries.append(entry) catch {};
        const max: usize = @intCast(@max(sup.fopt_int(self.options, "max", 100), 0));
        while (self.entries.items.len > max) {
            _ = self.entries.orderedRemove(0);
        }

        const on_entry = h.getp(self.options, "onEntry");
        if (on_entry == .function) {
            _ = h.call_vfn(on_entry, entry);
        }
    }

    fn pre_request(self: *DebugFeature, ctx: *Context) void {
        if (!self.active) return;

        const entity = ctx.op.entity;
        const opname = ctx.op.name;

        const entry = h.omap();
        h.setp(entry, "op", h.vstr(std.fmt.allocPrint(h.A(), "{s}.{s}", .{ entity, opname }) catch ""));
        h.setp(entry, "start", h.vnum(sup.fopt_now(self.options)));
        if (ctx.spec) |sp| {
            h.setp(entry, "method", h.vstr(sp.method));
            if (sp.url.len != 0) {
                h.setp(entry, "url", h.vstr(sp.url));
            } else {
                h.setp(entry, "url", h.vstr(sp.path));
            }
            h.setp(entry, "headers", self.redact(sp.headers));
        }
        ctx.out_set(DEBUG_ENTRY_KEY, OutVal{ .val = entry });
    }

    fn pre_response(self: *DebugFeature, ctx: *Context) void {
        if (!self.active) return;

        const entry = ctx.out_val(DEBUG_ENTRY_KEY);
        if (entry != .object) return;
        if (ctx.response) |resp| {
            h.setp(entry, "status", h.vnum(resp.status));
            const url = h.get_str(entry, "url") orelse "";
            if (url.len == 0) {
                if (ctx.spec) |sp| h.setp(entry, "url", h.vstr(sp.url));
            }
        }
    }

    fn pre_done(self: *DebugFeature, ctx: *Context) void {
        self.finish(ctx, true);
    }

    fn pre_unexpected(self: *DebugFeature, ctx: *Context) void {
        const entry = ctx.out_val(DEBUG_ENTRY_KEY);
        if (entry == .object) {
            if (ctx.ctrl.err) |e| {
                h.setp(entry, "error", h.vstr(e.msg));
            }
        }
        self.finish(ctx, false);
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
        const self = self_of(p);
        if (std.mem.eql(u8, name, "PreRequest")) {
            self.pre_request(ctx);
        } else if (std.mem.eql(u8, name, "PreResponse")) {
            self.pre_response(ctx);
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
