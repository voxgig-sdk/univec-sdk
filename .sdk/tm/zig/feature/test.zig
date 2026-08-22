// The offline `test` feature (mirrors go feature/test_feature.go / rust
// feature/test.rs): an in-memory mock transport that serves entity CRUD from
// a fixture, so generated tests run with no live server. An optional `net`
// block wraps the mock with simulated network conditions.

const std = @import("std");
const vs = @import("voxgig-struct");
const h = @import("../core/helpers.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Allocator = std.mem.Allocator;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;

pub const TestFeature = struct {
    name: []const u8 = "test",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },

    pub fn make() Feature {
        const self = h.A().create(TestFeature) catch unreachable;
        self.* = .{};
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *TestFeature {
        return @ptrCast(@alignCast(p));
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
        const self = self_of(p);
        self.options = options;

        const entity: Value = switch (h.to_map(h.getp(options, "entity"))) {
            .object => h.to_map(h.getp(options, "entity")),
            else => h.omap(),
        };

        if (ctx.client) |client| client.mode = "test";

        // Ensure entity ids are correct.
        _ = vs.walk(h.A(), entity, fixIds, null, vs.MAXDEPTH) catch {};

        const tw = h.A().create(TestWrap) catch unreachable;
        tw.* = .{ .entity = entity };
        const test_fetcher = Fetcher{ .ctx = @ptrCast(tw), .call = testFetchCall };

        const net = h.to_map(h.getp(options, "net"));
        const util = ctx.util();
        if (h.is_noval(net)) {
            util.fetcher = test_fetcher;
        } else {
            const nw = h.A().create(NetWrap) catch unreachable;
            const counter = h.A().create(i64) catch unreachable;
            counter.* = 0;
            nw.* = .{ .net = net, .inner = test_fetcher, .calls = counter };
            util.fetcher = .{ .ctx = @ptrCast(nw), .call = netCall };
        }
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

fn fixIds(_: Allocator, key: ?[]const u8, val: Value, _: Value, path: []const []const u8) anyerror!Value {
    if (path.len == 2 and val == .object) {
        if (key) |k| h.setp(val, "id", h.vstr(k));
    }
    return val;
}

fn respond(status: i64, data: Value, extra: []const h.Pair) Value {
    const out = h.jo(&.{
        .{ "status", h.vnum(status) },
        .{ "statusText", h.vstr("OK") },
        .{ "json", h.json_thunk(data) },
        .{ "body", h.vstr("not-used") },
    });
    for (extra) |kv| h.setp(out, kv[0], kv[1]);
    return out;
}

fn resolve_match(ctx: *Context, explicit: Value) Value {
    if (h.sizeOf(explicit) > 0) return explicit;
    const srcs = [_]Value{ ctx.mtch, ctx.data };
    for (srcs) |src| {
        const v = h.getp(src, "id");
        if (!h.is_noval(v) and !h.veq(v, h.vstr("__UNDEFINED__"))) {
            return h.jo(&.{.{ "id", v }});
        }
    }
    return h.omap();
}

fn build_args(ctx: *Context, args: Value) Value {
    const op = ctx.op;
    const opname = op.name;
    const entname: []const u8 = if (ctx.entity) |e| e.get_name() else op.entity;

    const points = h.getpath(&.{ "entity", entname, "op", opname, "points" }, ctx.config);
    const point = h.get_elem(points, h.vnum(-1), h.vnull());

    const params_path = h.getpath(&.{ "args", "params" }, point);
    const reqd_params = vs.select(h.A(), params_path, h.jo(&.{.{ "reqd", h.vbool(true) }})) catch h.olist();
    const reqd = vs.transform(h.A(), reqd_params, h.ja(&.{
        h.vstr("`$EACH`"),
        h.vstr(""),
        h.vstr("`$KEY.name`"),
    })) catch h.olist();

    const qand = h.olist();
    const q = h.jo(&.{.{ "`$AND`", qand }});

    if (args == .object) {
        const keys = h.keysof_vec(args);
        for (keys) |key| {
            const is_id = std.mem.eql(u8, key, "id");
            const selected = vs.select(h.A(), reqd, h.vstr(key)) catch h.olist();
            const is_reqd = !h.is_empty(selected);

            if (is_id or is_reqd) {
                const v = ctx.util().param(ctx, h.vstr(key));
                const ka = h.getp(op.alias, key);

                const qor = h.ja(&.{h.jo(&.{.{ key, v }})});
                if (ka == .string) qor.array.append(h.jo(&.{.{ ka.string, v }})) catch {};

                qand.array.append(h.jo(&.{.{ "`$OR`", qor }})) catch {};
            }
        }
    }

    const c = ctx.ctrl;
    if (c.has_explain()) h.setp(c.explain, "test", h.jo(&.{.{ "query", q }}));

    return q;
}

const TestWrap = struct {
    entity: Value,
};

fn testFetchCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *TestWrap = @ptrCast(@alignCast(p));
    return test_fetch(w.entity, ctx, url, fetchdef);
}

fn test_fetch(entity: Value, ctx: *Context, _: []const u8, _: Value) err.E!Value {
    const op = ctx.op;
    const entmap: Value = switch (h.to_map(h.getp(entity, op.entity))) {
        .object => h.to_map(h.getp(entity, op.entity)),
        else => h.omap(),
    };

    if (std.mem.eql(u8, op.name, "load")) {
        const m = resolve_match(ctx, ctx.reqmatch);
        const args = build_args(ctx, m);
        const found = vs.select(h.A(), entmap, args) catch h.olist();
        const ent = h.get_elem(found, h.vnum(0), h.vnull());
        if (h.is_noval(ent)) {
            return respond(404, h.vnull(), &.{.{ "statusText", h.vstr("Not found") }});
        }
        h.del_prop(ent, h.vstr("$KEY"));
        return respond(200, h.clone(ent), &.{});
    } else if (std.mem.eql(u8, op.name, "list")) {
        const args = build_args(ctx, ctx.reqmatch);
        const found = vs.select(h.A(), entmap, args) catch h.olist();
        if (h.is_noval(found)) {
            return respond(404, h.vnull(), &.{.{ "statusText", h.vstr("Not found") }});
        }
        if (found == .array) {
            for (found.array.data.items) |item| h.del_prop(item, h.vstr("$KEY"));
        }
        return respond(200, h.clone(found), &.{});
    } else if (std.mem.eql(u8, op.name, "update")) {
        const reqdata = ctx.reqdata;
        var update_match = h.omap();
        if (reqdata == .object) {
            const idv = h.getp(reqdata, "id");
            if (!h.is_noval(idv)) h.setp(update_match, "id", idv);
            if (h.getp(op.alias, "id") == .string) {
                const alias_id = h.getp(op.alias, "id").string;
                const av = h.getp(reqdata, alias_id);
                if (!h.is_noval(av)) h.setp(update_match, alias_id, av);
            }
        }
        if (h.sizeOf(update_match) == 0) update_match = resolve_match(ctx, h.omap());
        const args = build_args(ctx, update_match);
        const found = vs.select(h.A(), entmap, args) catch h.olist();
        var ent = h.get_elem(found, h.vnum(0), h.vnull());
        if (h.is_noval(ent) and h.sizeOf(entmap) > 0) {
            for (h.items_vec(entmap)) |kv| {
                if (kv.v == .object) {
                    ent = kv.v;
                    break;
                }
            }
        }
        if (h.is_noval(ent)) {
            return respond(404, h.vnull(), &.{.{ "statusText", h.vstr("Not found") }});
        }
        if (ent == .object and reqdata == .object) {
            var it = reqdata.object.iterator();
            while (it.next()) |kv| h.setp(ent, kv.key_ptr.*, kv.value_ptr.*);
        }
        h.del_prop(ent, h.vstr("$KEY"));
        return respond(200, h.clone(ent), &.{});
    } else if (std.mem.eql(u8, op.name, "remove")) {
        const m = resolve_match(ctx, ctx.reqmatch);
        const args = build_args(ctx, m);
        const found = vs.select(h.A(), entmap, args) catch h.olist();
        const ent = h.get_elem(found, h.vnum(0), h.vnull());
        if (ent == .object) {
            const id = h.getp(ent, "id");
            h.del_prop(entmap, id);
        }
        return respond(200, h.vnull(), &.{});
    } else if (std.mem.eql(u8, op.name, "create")) {
        _ = build_args(ctx, ctx.reqdata);
        var id = ctx.util().param(ctx, h.vstr("id"));
        if (h.is_noval(id)) {
            id = h.vstr(std.fmt.allocPrint(h.A(), "{x:0>4}{x:0>4}{x:0>4}{x:0>4}", .{
                @as(u64, @intCast(h.rand_int(0x10000))),
                @as(u64, @intCast(h.rand_int(0x10000))),
                @as(u64, @intCast(h.rand_int(0x10000))),
                @as(u64, @intCast(h.rand_int(0x10000))),
            }) catch "id");
        }
        const ent = h.clone(ctx.reqdata);
        if (ent == .object) {
            h.setp(ent, "id", id);
            if (id == .string) h.setp(entmap, id.string, ent);
            h.del_prop(ent, h.vstr("$KEY"));
            return respond(200, h.clone(ent), &.{});
        }
        return respond(200, ent, &.{});
    }

    return respond(404, h.vnull(), &.{.{ "statusText", h.vstr("Unknown operation") }});
}

// make_netsim (test-local): counter-driven latency / first-N failures /
// connection errors / offline. pick_latency is deterministic ((min+max)/2).
const NetWrap = struct {
    net: Value,
    inner: Fetcher,
    calls: *i64,
};

fn netCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *NetWrap = @ptrCast(@alignCast(p));
    const net = w.net;
    w.calls.* += 1;
    const call = w.calls.*;

    const latency = pick_latency_net(net);

    if (sup.fopt_bool(net, "offline", false)) {
        sup.fopt_sleep(net, latency);
        return ctx.fail("netsim_offline", std.fmt.allocPrint(h.A(), "Simulated network offline (URL was: \"{s}\")", .{url}) catch "offline");
    }
    if (call <= sup.fopt_int(net, "errorTimes", 0)) {
        sup.fopt_sleep(net, latency);
        return ctx.fail("netsim_conn", std.fmt.allocPrint(h.A(), "Simulated connection error (call {d})", .{call}) catch "conn");
    }
    if (call <= sup.fopt_int(net, "failTimes", 0)) {
        sup.fopt_sleep(net, latency);
        const status = sup.fopt_int(net, "failStatus", 503);
        return h.jo(&.{
            .{ "status", h.vnum(status) },
            .{ "statusText", h.vstr("Simulated Failure") },
            .{ "body", h.vstr("not-used") },
            .{ "json", h.json_thunk(h.vnull()) },
            .{ "headers", h.omap() },
        });
    }
    sup.fopt_sleep(net, latency);
    return w.inner.invoke(ctx, url, fetchdef);
}

fn pick_latency_net(net: Value) i64 {
    const l = h.getp(net, "latency");
    if (h.is_noval(l)) return 0;
    if (l == .object) {
        const min = sup.fopt_int(l, "min", 0);
        const max = sup.fopt_int(l, "max", min);
        if (max <= min) return min;
        return min + ((max - min) >> 1);
    }
    return @max(sup.fopt_int(net, "latency", 0), 0);
}
