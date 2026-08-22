// Primary utility tests — direct-assertion coverage of the SDK pipeline
// utility surface (mirrors tm/rust/tests/primary_utility_test.rs and
// tm/go/test/primary_utility_test.go). The donors also drive the shared
// test.json `primary` subtree through a data runner; here the same utilities
// are exercised with explicit inputs and assertions, which keeps the zig
// suite hermetic (no external fixture parsing) while covering every primary
// utility method.

const std = @import("std");
const sdk = @import("sdk");
const fh = @import("fh.zig");
const h = sdk.h;
const util = sdk.utilmod;
const Value = sdk.Value;
const testing = std.testing;

fn vnull() Value {
    return Value{ .null = {} };
}

fn baseClient() *sdk.SDK {
    return sdk.test_sdk(vnull(), vnull());
}

fn makeTestCtx(client: *sdk.SDK, utility: *sdk.Utility) *sdk.Context {
    return utility.make_context(sdk.CtxSpec{
        .opname = "load",
        .client = client,
        .utility = utility,
    }, client.get_root_ctx());
}

fn makeTestFullCtx(client: *sdk.SDK, utility: *sdk.Utility) *sdk.Context {
    const ctx = makeTestCtx(client, utility);
    ctx.point = h.jo(&.{
        .{ "parts", h.ja(&.{ h.vstr("items"), h.vstr("{id}") }) },
        .{ "args", h.jo(&.{.{ "params", h.ja(&.{h.jo(&.{
            .{ "name", h.vstr("id") },
            .{ "reqd", h.vbool(true) },
        })}) }}) },
        .{ "params", h.ja(&.{h.vstr("id")}) },
        .{ "alias", h.omap() },
        .{ "select", h.omap() },
        .{ "active", h.vbool(true) },
        .{ "transform", h.omap() },
    });
    ctx.mtch = h.jo(&.{.{ "id", h.vstr("item01") }});
    ctx.reqmatch = h.jo(&.{.{ "id", h.vstr("item01") }});
    return ctx;
}

// A probe feature that records init + a named hook dispatch.
const ProbeFeature = struct {
    nm: []const u8,
    active_: bool,
    hooked: *bool,
    inited: *bool,

    fn make(nm: []const u8, active_: bool, hooked: *bool, inited: *bool) sdk.Feature {
        const s = h.A().create(ProbeFeature) catch unreachable;
        s.* = .{ .nm = nm, .active_ = active_, .hooked = hooked, .inited = inited };
        return .{ .ptr = @ptrCast(s), .vtable = &vt };
    }
    fn s_of(p: *anyopaque) *ProbeFeature {
        return @ptrCast(@alignCast(p));
    }
    fn vname(p: *anyopaque) []const u8 {
        return s_of(p).nm;
    }
    fn vactive(p: *anyopaque) bool {
        return s_of(p).active_;
    }
    fn vaddopts(_: *anyopaque) Value {
        return vnull();
    }
    fn vinit(p: *anyopaque, _: *sdk.Context, _: Value) void {
        s_of(p).inited.* = true;
    }
    fn vdispatch(p: *anyopaque, name: []const u8, _: *sdk.Context) void {
        if (std.mem.eql(u8, name, "TestHook")) s_of(p).hooked.* = true;
    }
    const vt = sdk.Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};

// A system.fetch mock that records each call and replies 200.
const FetchRec = struct {
    calls: std.ArrayList(Value),
    fn call(p: *anyopaque, _: std.mem.Allocator, arg: Value) anyerror!Value {
        const self: *FetchRec = @ptrCast(@alignCast(p));
        self.calls.append(arg) catch {};
        return h.jo(&.{ .{ "status", h.vnum(200) }, .{ "statusText", h.vstr("OK") } });
    }
    fn new() *FetchRec {
        const s = h.A().create(FetchRec) catch unreachable;
        s.* = .{ .calls = std.ArrayList(Value).init(h.A()) };
        return s;
    }
    fn fn_val(self: *FetchRec) Value {
        return h.callable(@ptrCast(self), call);
    }
};

// =====================================================================

test "primary utility exists" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestCtx(client, utility);
    try testing.expect(std.mem.eql(u8, util.prepare_method_util(ctx), "GET"));
    try testing.expect(utility.prepare_headers(ctx) == .object);
    try testing.expect(util.prepare_query_util(ctx) == .object);
    try testing.expect(util.prepare_params_util(ctx) == .object);
    try testing.expect(utility.make_options(ctx) == .object);
    _ = utility.clean(ctx, h.vstr("x"));
}

test "primary clean basic" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestCtx(client, utility);
    const val = h.jo(&.{ .{ "key", h.vstr("secret123") }, .{ "name", h.vstr("test") } });
    try testing.expect(!h.is_noval(utility.clean(ctx, val)));
}

test "primary prepare_method by op" {
    const client = baseClient();
    const utility = client.get_utility();
    const load = utility.make_context(sdk.CtxSpec{ .opname = "load", .client = client, .utility = utility }, client.get_root_ctx());
    const create = utility.make_context(sdk.CtxSpec{ .opname = "create", .client = client, .utility = utility }, client.get_root_ctx());
    const remove = utility.make_context(sdk.CtxSpec{ .opname = "remove", .client = client, .utility = utility }, client.get_root_ctx());
    try testing.expect(std.mem.eql(u8, util.prepare_method_util(load), "GET"));
    try testing.expect(std.mem.eql(u8, util.prepare_method_util(create), "POST"));
    try testing.expect(std.mem.eql(u8, util.prepare_method_util(remove), "DELETE"));
}

test "primary make_options basic" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestCtx(client, utility);
    const opts = utility.make_options(ctx);
    try testing.expect(opts == .object);
    try testing.expect(!h.is_noval(h.getp(opts, "base")));
}

test "primary make_fetch_def basic" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestFullCtx(client, utility);
    ctx.spec = sdk.Spec.make(h.jo(&.{
        .{ "base", h.vstr("http://localhost:8080") },
        .{ "prefix", h.vstr("/api") },
        .{ "path", h.vstr("items/item01") },
        .{ "suffix", h.vstr("") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("item01") }}) },
        .{ "query", h.omap() },
        .{ "headers", h.jo(&.{.{ "content-type", h.vstr("application/json") }}) },
        .{ "method", h.vstr("GET") },
        .{ "step", h.vstr("start") },
    }));
    ctx.result = sdk.SdkResult.make(h.omap());

    const fetchdef = utility.make_fetch_def(ctx) catch unreachable;
    try testing.expect(h.veq(h.getp(fetchdef, "method"), h.vstr("GET")));
    const url = h.get_str(fetchdef, "url") orelse "";
    try testing.expect(std.mem.indexOf(u8, url, "/api/items/item01") != null);
    try testing.expect(h.veq(h.getp(h.getp(fetchdef, "headers"), "content-type"), h.vstr("application/json")));
    try testing.expect(h.is_noval(h.getp(fetchdef, "body")));
}

test "primary make_fetch_def with body" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestFullCtx(client, utility);
    ctx.spec = sdk.Spec.make(h.jo(&.{
        .{ "base", h.vstr("http://localhost:8080") },
        .{ "prefix", h.vstr("") },
        .{ "path", h.vstr("items") },
        .{ "suffix", h.vstr("") },
        .{ "params", h.omap() },
        .{ "query", h.omap() },
        .{ "headers", h.omap() },
        .{ "method", h.vstr("POST") },
        .{ "step", h.vstr("start") },
        .{ "body", h.jo(&.{.{ "name", h.vstr("test") }}) },
    }));
    ctx.result = sdk.SdkResult.make(h.omap());

    const fetchdef = utility.make_fetch_def(ctx) catch unreachable;
    try testing.expect(h.veq(h.getp(fetchdef, "method"), h.vstr("POST")));
    const body = h.get_str(fetchdef, "body") orelse "";
    try testing.expect(std.mem.indexOf(u8, body, "\"name\"") != null);
}

test "primary make_result basic" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestFullCtx(client, utility);
    ctx.spec = sdk.Spec.make(h.jo(&.{ .{ "method", h.vstr("GET") }, .{ "step", h.vstr("start") } }));
    ctx.result = sdk.SdkResult.make(h.jo(&.{
        .{ "ok", h.vbool(true) },
        .{ "status", h.vnum(200) },
        .{ "statusText", h.vstr("OK") },
        .{ "headers", h.omap() },
        .{ "resdata", h.jo(&.{ .{ "id", h.vstr("item01") }, .{ "name", h.vstr("Test") } }) },
    }));
    const result = utility.make_result(ctx) catch unreachable;
    try testing.expect(result.status == 200);
}

test "primary make_result no spec" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestFullCtx(client, utility);
    ctx.spec = null;
    ctx.result = sdk.SdkResult.make(h.jo(&.{ .{ "ok", h.vbool(true) }, .{ "status", h.vnum(200) } }));
    try testing.expectError(error.Sdk, utility.make_result(ctx));
}

test "primary make_result no result" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestFullCtx(client, utility);
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("start") }}));
    ctx.result = null;
    try testing.expectError(error.Sdk, utility.make_result(ctx));
}

test "primary make_point basic" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestCtx(client, utility);
    const point = h.jo(&.{
        .{ "parts", h.ja(&.{ h.vstr("items"), h.vstr("{id}") }) },
        .{ "args", h.jo(&.{.{ "params", h.olist() }}) },
        .{ "params", h.olist() },
        .{ "alias", h.omap() },
        .{ "select", h.omap() },
        .{ "active", h.vbool(true) },
        .{ "transform", h.omap() },
    });
    ctx.op = sdk.Operation.make(h.jo(&.{
        .{ "entity", h.vstr("x") },
        .{ "name", h.vstr("load") },
        .{ "points", h.ja(&.{point}) },
    }));
    _ = utility.make_point(ctx) catch unreachable;
    try testing.expect(!h.is_noval(ctx.point));
}

test "primary prepare_path basic" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestFullCtx(client, utility);
    ctx.point = h.jo(&.{
        .{ "parts", h.ja(&.{ h.vstr("api"), h.vstr("planet"), h.vstr("{id}") }) },
        .{ "args", h.jo(&.{.{ "params", h.olist() }}) },
    });
    try testing.expect(std.mem.eql(u8, util.prepare_path_util(ctx), "api/planet/{id}"));
}

test "primary prepare_path single" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestFullCtx(client, utility);
    ctx.point = h.jo(&.{
        .{ "parts", h.ja(&.{h.vstr("items")}) },
        .{ "args", h.jo(&.{.{ "params", h.olist() }}) },
    });
    try testing.expect(std.mem.eql(u8, util.prepare_path_util(ctx), "items"));
}

test "primary feature_hook basic" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestCtx(client, utility);

    var hooked = false;
    var inited = false;
    client.features.clearRetainingCapacity();
    client.features.append(ProbeFeature.make("probe", true, &hooked, &inited)) catch unreachable;

    utility.feature_hook(ctx, "TestHook");
    try testing.expect(hooked);
}

test "primary feature_init basic" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestCtx(client, utility);
    const fmap = h.to_map(h.getp(ctx.options, "feature"));
    h.setp(fmap, "initfeat", h.jo(&.{.{ "active", h.vbool(true) }}));

    var hooked = false;
    var inited = false;
    const feat = ProbeFeature.make("initfeat", true, &hooked, &inited);
    utility.feature_init(ctx, feat);
    try testing.expect(inited);
}

test "primary feature_init inactive" {
    const client = baseClient();
    const utility = client.get_utility();
    const ctx = makeTestCtx(client, utility);
    const fmap = h.to_map(h.getp(ctx.options, "feature"));
    h.setp(fmap, "nofeat", h.jo(&.{.{ "active", h.vbool(false) }}));

    var hooked = false;
    var inited = false;
    const feat = ProbeFeature.make("nofeat", false, &hooked, &inited);
    utility.feature_init(ctx, feat);
    try testing.expect(!inited);
}

test "primary fetcher live" {
    const rec = FetchRec.new();
    const client = sdk.SDK.new(h.jo(&.{.{ "system", h.jo(&.{.{ "fetch", rec.fn_val() }}) }}));
    const utility = client.get_utility();
    const ctx = utility.make_context(sdk.CtxSpec{ .opname = "load", .client = client, .utility = utility }, client.get_root_ctx());
    const fetchdef = h.jo(&.{ .{ "method", h.vstr("GET") }, .{ "headers", h.omap() } });
    _ = utility.fetch(ctx, "http://example.com/test", fetchdef) catch unreachable;
    try testing.expect(rec.calls.items.len == 1);
    const url = h.get_elem(rec.calls.items[0], h.vnum(0), vnull());
    try testing.expect(h.veq(url, h.vstr("http://example.com/test")));
}

test "primary fetcher blocked test mode" {
    const rec = FetchRec.new();
    const client = sdk.SDK.new(h.jo(&.{.{ "system", h.jo(&.{.{ "fetch", rec.fn_val() }}) }}));
    client.mode = "test";
    const utility = client.get_utility();
    const ctx = utility.make_context(sdk.CtxSpec{ .opname = "load", .client = client, .utility = utility }, client.get_root_ctx());
    const fetchdef = h.jo(&.{ .{ "method", h.vstr("GET") }, .{ "headers", h.omap() } });
    try testing.expectError(error.Sdk, utility.fetch(ctx, "http://example.com/test", fetchdef));
    try testing.expect(std.ascii.indexOfIgnoreCase(ctx.pending_err.?.msg, "blocked") != null);
}

test "primary new sdk smoke" {
    const client = sdk.new();
    try testing.expect(std.mem.eql(u8, client.mode, "live"));
}
