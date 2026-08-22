// Direct unit tests for the operation-pipeline utilities (mirrors
// tm/rust/tests/pipeline_test.rs and tm/go/test/pipeline_test.go). The
// generated entity tests exercise the happy path; these drive the error and
// edge branches (missing spec/response/result, 4xx handling, transport
// failures, feature-add semantics, auth header shaping) that a normal
// success-path op never reaches.

const std = @import("std");
const sdk = @import("sdk");
const fh = @import("fh.zig");
const h = sdk.h;
const Value = sdk.Value;
const testing = std.testing;

fn vnull() Value {
    return Value{ .null = {} };
}

// plCtx: a load context on the given client/utility (mirrors rust pl_ctx).
fn plCtx(client: *sdk.SDK, utility: *sdk.Utility, ctrl: ?Value) *sdk.Context {
    return utility.make_context(sdk.CtxSpec{
        .opname = "load",
        .client = client,
        .utility = utility,
        .ctrl = ctrl,
    }, client.get_root_ctx());
}

fn reqSpec() *sdk.Spec {
    return sdk.Spec.make(h.jo(&.{
        .{ "base", h.vstr("http://h") },
        .{ "path", h.vstr("a") },
        .{ "method", h.vstr("GET") },
        .{ "headers", h.omap() },
        .{ "step", h.vstr("s") },
    }));
}

fn authSpec(headers: Value) *sdk.Spec {
    const hv: Value = if (headers == .object) headers else h.omap();
    return sdk.Spec.make(h.jo(&.{
        .{ "headers", hv },
        .{ "step", h.vstr("s") },
    }));
}

// A minimal fake entity for the list-wrap test: data() records each call and
// echoes the argument back.
const FakeEntity = struct {
    made: *i64,
    fn getName(_: *anyopaque) []const u8 {
        return "x";
    }
    fn makeFn(p: *anyopaque) sdk.Entity {
        const self: *FakeEntity = @ptrCast(@alignCast(p));
        return newEnt(self.made);
    }
    fn dataFn(p: *anyopaque, args: ?Value) Value {
        const self: *FakeEntity = @ptrCast(@alignCast(p));
        if (args) |a| {
            if (!h.is_noval(a)) {
                self.made.* += 1;
                return a;
            }
        }
        return vnull();
    }
    fn matchvFn(_: *anyopaque, _: ?Value) Value {
        return vnull();
    }
    const vt = sdk.Entity.VTable{ .get_name = getName, .make = makeFn, .data = dataFn, .matchv = matchvFn };
    fn newEnt(made: *i64) sdk.Entity {
        const s = h.A().create(FakeEntity) catch unreachable;
        s.* = .{ .made = made };
        return .{ .ptr = @ptrCast(s), .vtable = &vt };
    }
};

// Named base feature + ordering options, for the feature-add ordering test.
fn named(name: []const u8, opts: ?Value) sdk.Feature {
    const f = sdk.BaseFeature.make();
    const bf: *sdk.BaseFeature = @ptrCast(@alignCast(f.ptr));
    bf.name = name;
    if (opts) |o| bf.add_opts = o;
    return f;
}
fn names(client: *sdk.SDK) []const u8 {
    var buf = std.ArrayList(u8).init(h.A());
    for (client.features.items, 0..) |f, i| {
        if (i != 0) buf.append(',') catch {};
        buf.appendSlice(f.name()) catch {};
    }
    return buf.toOwnedSlice() catch "";
}

// =====================================================================
// make_response
// =====================================================================

test "pipeline make_response: guards missing spec/response/result" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();

    var ctx = plCtx(client, utility, null);
    ctx.spec = null;
    ctx.response = sdk.Response.make(h.omap());
    ctx.result = sdk.SdkResult.make(h.omap());
    _ = utility.make_response(ctx) catch {};
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "response_no_spec"));

    ctx = plCtx(client, utility, null);
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("s") }}));
    ctx.response = null;
    ctx.result = sdk.SdkResult.make(h.omap());
    _ = utility.make_response(ctx) catch {};
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "response_no_response"));

    ctx = plCtx(client, utility, null);
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("s") }}));
    ctx.response = sdk.Response.make(h.omap());
    ctx.result = null;
    _ = utility.make_response(ctx) catch {};
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "response_no_result"));
}

test "pipeline make_response: 4xx sets result err and copies headers" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("s") }}));
    ctx.response = sdk.Response.make(fh.fh_response(404, vnull(), h.jo(&.{.{ "x-a", h.vstr("1") }})));
    ctx.result = sdk.SdkResult.make(h.omap());
    _ = utility.make_response(ctx) catch {};
    const r = ctx.result.?;
    try testing.expect(r.err != null);
    try testing.expect(r.status == 404);
    try testing.expect(h.veq(h.getp(r.headers, "x-a"), h.vstr("1")));
}

test "pipeline make_response: 2xx parses body and marks ok" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("s") }}));
    ctx.response = sdk.Response.make(fh.fh_response(200, h.jo(&.{.{ "v", h.vnum(1) }}), vnull()));
    ctx.result = sdk.SdkResult.make(h.omap());
    _ = utility.make_response(ctx) catch {};
    const r = ctx.result.?;
    try testing.expect(r.ok);
    try testing.expect(h.veq(h.getp(r.body, "v"), h.vnum(1)));
}

test "pipeline make_response: records to ctrl explain" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, h.jo(&.{.{ "explain", h.omap() }}));
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("s") }}));
    ctx.response = sdk.Response.make(fh.fh_response(200, h.jo(&.{.{ "v", h.vnum(2) }}), vnull()));
    ctx.result = sdk.SdkResult.make(h.omap());
    _ = utility.make_response(ctx) catch {};
    try testing.expect(!h.is_noval(h.getp(ctx.ctrl.explain, "result")));
}

// =====================================================================
// make_result
// =====================================================================

test "pipeline make_result: guards missing spec/result" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();

    var ctx = plCtx(client, utility, null);
    ctx.spec = null;
    ctx.result = sdk.SdkResult.make(h.omap());
    _ = utility.make_result(ctx) catch {};
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "result_no_spec"));

    ctx = plCtx(client, utility, null);
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("s") }}));
    ctx.result = null;
    _ = utility.make_result(ctx) catch {};
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "result_no_result"));
}

test "pipeline make_result: list op wraps resdata into entities" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    var made: i64 = 0;

    const ctx = plCtx(client, utility, null);
    ctx.op = sdk.Operation.make(h.jo(&.{ .{ "entity", h.vstr("x") }, .{ "name", h.vstr("list") } }));
    ctx.entity = FakeEntity.newEnt(&made);
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("s") }}));
    ctx.result = sdk.SdkResult.make(h.jo(&.{.{ "resdata", h.ja(&.{
        h.jo(&.{.{ "a", h.vnum(1) }}),
        h.jo(&.{.{ "a", h.vnum(2) }}),
    }) }}));

    _ = utility.make_result(ctx) catch {};
    try testing.expect(h.sizeOf(ctx.result.?.resdata) == 2);
    try testing.expect(made == 2);
}

test "pipeline make_result: empty list yields empty resdata" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    var made: i64 = 0;

    const ctx = plCtx(client, utility, null);
    ctx.op = sdk.Operation.make(h.jo(&.{ .{ "entity", h.vstr("x") }, .{ "name", h.vstr("list") } }));
    ctx.entity = FakeEntity.newEnt(&made);
    ctx.spec = sdk.Spec.make(h.jo(&.{.{ "step", h.vstr("s") }}));
    ctx.result = sdk.SdkResult.make(h.jo(&.{.{ "resdata", h.olist() }}));

    _ = utility.make_result(ctx) catch {};
    try testing.expect(ctx.result.?.resdata == .array);
    try testing.expect(h.sizeOf(ctx.result.?.resdata) == 0);
}

// =====================================================================
// make_request
// =====================================================================

test "pipeline make_request: guards missing spec" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    utility.fetcher = fh.Recorder.new(null).fetcher();
    const ctx = plCtx(client, utility, null);
    ctx.spec = null;
    _ = utility.make_request(ctx) catch {};
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "request_no_spec"));
}

test "pipeline make_request: transport error carried on response" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const srv = fh.ErrServer.new();
    utility.fetcher = srv.fetcher();
    const ctx = plCtx(client, utility, null);
    ctx.spec = reqSpec();
    _ = utility.make_request(ctx) catch {};
    const resp = ctx.response.?;
    try testing.expect(resp.err != null);
    try testing.expect(std.mem.eql(u8, resp.err.?.code, "boom"));
}

test "pipeline make_request: nil transport result becomes response error" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const srv = fh.NilThenOkServer.new(100);
    utility.fetcher = srv.fetcher();
    const ctx = plCtx(client, utility, null);
    ctx.spec = reqSpec();
    _ = utility.make_request(ctx) catch {};
    try testing.expect(ctx.response.?.err != null);
}

test "pipeline make_request: normal transport response wrapped" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    utility.fetcher = fh.Recorder.new(null).fetcher();
    const ctx = plCtx(client, utility, null);
    ctx.spec = reqSpec();
    _ = utility.make_request(ctx) catch {};
    try testing.expect(ctx.response.?.status == 200);
}

test "pipeline make_request: records fetchdef to ctrl explain" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    utility.fetcher = fh.Recorder.new(null).fetcher();
    const ctx = plCtx(client, utility, h.jo(&.{.{ "explain", h.omap() }}));
    ctx.spec = reqSpec();
    _ = utility.make_request(ctx) catch {};
    try testing.expect(!h.is_noval(h.getp(ctx.ctrl.explain, "fetchdef")));
}

// =====================================================================
// done / make_error
// =====================================================================

test "pipeline done: returns resdata on success" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    ctx.result = sdk.SdkResult.make(h.jo(&.{
        .{ "ok", h.vbool(true) },
        .{ "resdata", h.jo(&.{.{ "id", h.vstr("i1") }}) },
    }));
    const out = utility.done(ctx) catch unreachable;
    try testing.expect(h.veq(h.getp(out, "id"), h.vstr("i1")));
}

test "pipeline done: errors when not ok" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, h.omap());
    ctx.result = sdk.SdkResult.make(h.jo(&.{.{ "ok", h.vbool(false) }}));
    try testing.expectError(error.Sdk, utility.done(ctx));
}

test "pipeline make_error: returns resdata when throw false" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, h.omap());
    ctx.ctrl.throw = false;
    ctx.result = sdk.SdkResult.make(h.jo(&.{
        .{ "ok", h.vbool(false) },
        .{ "resdata", h.vstr("fallback") },
    }));
    ctx.pending_err = ctx.make_error("test_code", "test message");
    const out = utility.make_error(ctx) catch unreachable;
    try testing.expect(h.veq(out, h.vstr("fallback")));
}

test "pipeline make_error: records to ctrl explain" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, h.jo(&.{.{ "explain", h.omap() }}));
    ctx.ctrl.throw = false;
    ctx.result = sdk.SdkResult.make(h.jo(&.{.{ "ok", h.vbool(false) }}));
    ctx.pending_err = ctx.make_error("x", "x");
    _ = utility.make_error(ctx) catch {};
    try testing.expect(!h.is_noval(h.getp(ctx.ctrl.explain, "err")));
}

// =====================================================================
// feature add
// =====================================================================

test "pipeline feature_add: appends by default" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    const start = client.features.items.len;
    utility.feature_add(ctx, sdk.BaseFeature.make());
    try testing.expect(client.features.items.len == start + 1);
    const last = client.features.items[client.features.items.len - 1];
    try testing.expect(std.mem.eql(u8, last.name(), "base"));
}

test "pipeline feature_add: ordering before after replace" {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    client.features.clearRetainingCapacity();

    utility.feature_add(ctx, named("a", null));
    utility.feature_add(ctx, named("b", null));
    try testing.expect(std.mem.eql(u8, names(client), "a,b"));

    utility.feature_add(ctx, named("z1", h.jo(&.{.{ "__before__", h.vstr("b") }})));
    try testing.expect(std.mem.eql(u8, names(client), "a,z1,b"));

    utility.feature_add(ctx, named("z2", h.jo(&.{.{ "__after__", h.vstr("a") }})));
    try testing.expect(std.mem.eql(u8, names(client), "a,z2,z1,b"));

    utility.feature_add(ctx, named("z3", h.jo(&.{.{ "__replace__", h.vstr("z1") }})));
    try testing.expect(std.mem.eql(u8, names(client), "a,z2,z3,b"));

    // An ordering option naming no existing feature falls back to append.
    utility.feature_add(ctx, named("z4", h.jo(&.{.{ "__before__", h.vstr("missing") }})));
    try testing.expect(std.mem.eql(u8, names(client), "a,z2,z3,b,z4"));
}

// =====================================================================
// prepare_auth
// =====================================================================

test "pipeline prepare_auth: guards missing spec" {
    const client = sdk.test_sdk(vnull(), h.jo(&.{.{ "apikey", h.vstr("K") }}));
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    ctx.spec = null;
    _ = utility.prepare_auth(ctx) catch {};
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "auth_no_spec"));
}

test "pipeline prepare_auth: apikey with prefix space joined" {
    const client = sdk.test_sdk(vnull(), h.jo(&.{
        .{ "apikey", h.vstr("K") },
        .{ "auth", h.jo(&.{.{ "prefix", h.vstr("Bearer") }}) },
    }));
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    ctx.spec = authSpec(vnull());
    _ = utility.prepare_auth(ctx) catch {};
    try testing.expect(h.veq(h.getp(ctx.spec.?.headers, "authorization"), h.vstr("Bearer K")));
}

test "pipeline prepare_auth: raw apikey empty prefix as is" {
    const client = sdk.test_sdk(vnull(), h.jo(&.{
        .{ "apikey", h.vstr("K") },
        .{ "auth", h.jo(&.{.{ "prefix", h.vstr("") }}) },
    }));
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    ctx.spec = authSpec(vnull());
    _ = utility.prepare_auth(ctx) catch {};
    try testing.expect(h.veq(h.getp(ctx.spec.?.headers, "authorization"), h.vstr("K")));
}

test "pipeline prepare_auth: empty apikey drops header" {
    const client = sdk.test_sdk(vnull(), h.jo(&.{
        .{ "apikey", h.vstr("") },
        .{ "auth", h.jo(&.{.{ "prefix", h.vstr("Bearer") }}) },
    }));
    const utility = client.get_utility();
    const ctx = plCtx(client, utility, null);
    ctx.spec = authSpec(h.jo(&.{.{ "authorization", h.vstr("stale") }}));
    _ = utility.prepare_auth(ctx) catch {};
    try testing.expect(h.is_noval(h.getp(ctx.spec.?.headers, "authorization")));
}

test "pipeline prepare_auth: missing apikey drops header" {
    const client = sdk.test_sdk(vnull(), h.jo(&.{
        .{ "auth", h.jo(&.{.{ "prefix", h.vstr("Bearer") }}) },
    }));
    const utility = client.get_utility();
    const options = client.options_map();
    // Skip if this SDK's options happen to carry a configured apikey.
    if (h.get_str(options, "apikey")) |k| {
        if (k.len != 0) return;
    }
    const ctx = plCtx(client, utility, null);
    ctx.spec = authSpec(h.jo(&.{.{ "authorization", h.vstr("stale") }}));
    _ = utility.prepare_auth(ctx) catch {};
    try testing.expect(h.is_noval(h.getp(ctx.spec.?.headers, "authorization")));
}

test "pipeline prepare_auth: public api no auth block drops header" {
    const client = sdk.test_sdk(vnull(), h.jo(&.{.{ "apikey", h.vstr("K") }}));
    const utility = client.get_utility();
    // Option validation supplies an auth shape for this SDK, so a truly
    // auth-less client cannot be constructed here — mirror the rust skip.
    if (!h.is_noval(h.getp(client.options_map(), "auth"))) return;
    const ctx = plCtx(client, utility, null);
    ctx.spec = authSpec(h.jo(&.{.{ "authorization", h.vstr("stale") }}));
    _ = utility.prepare_auth(ctx) catch {};
    try testing.expect(h.is_noval(h.getp(ctx.spec.?.headers, "authorization")));
}

// --- feature order (array form + test-first default) ------------------------

fn makeOptsFeature(feature: Value) Value {
    const client = sdk.test_sdk(vnull(), vnull());
    const utility = client.get_utility();
    const ctx = utility.make_context(sdk.CtxSpec{
        .utility = utility,
        .options = h.jo(&.{.{ "feature", feature }}),
        .config = h.jo(&.{.{ "options", h.omap() }}),
    }, null);
    return utility.make_options(ctx);
}

fn orderJoin(opts: Value) []const u8 {
    const order = h.getpath(&.{ "__derived__", "featureorder" }, opts);
    var out = std.ArrayList(u8).init(h.A());
    if (order == .array) {
        for (order.array.data.items, 0..) |v, i| {
            if (i > 0) out.appendSlice(",") catch {};
            if (v == .string) out.appendSlice(v.string) catch {};
        }
    }
    return out.toOwnedSlice() catch "";
}

test "pipeline feature order: map is test-first" {
    const opts = makeOptsFeature(h.jo(&.{
        .{ "metrics", h.jo(&.{.{ "active", h.vbool(true) }}) },
        .{ "test", h.jo(&.{.{ "active", h.vbool(true) }}) },
    }));
    try testing.expect(std.mem.eql(u8, orderJoin(opts), "test,metrics"));
}

test "pipeline feature order: array is explicit" {
    const opts = makeOptsFeature(h.ja(&.{
        h.jo(&.{ .{ "name", h.vstr("metrics") }, .{ "active", h.vbool(true) } }),
        h.jo(&.{ .{ "name", h.vstr("test") }, .{ "active", h.vbool(true) } }),
    }));
    try testing.expect(std.mem.eql(u8, orderJoin(opts), "metrics,test"));
    // the list is normalized to a map for merge/init, opts preserved.
    try testing.expect(h.veq(h.getpath(&.{ "feature", "metrics", "active" }, opts), h.vbool(true)));
    try testing.expect(h.veq(h.getpath(&.{ "feature", "test", "active" }, opts), h.vbool(true)));
}

test "pipeline feature order: map without test is sorted" {
    const opts = makeOptsFeature(h.jo(&.{
        .{ "retry", h.jo(&.{.{ "active", h.vbool(true) }}) },
        .{ "cache", h.jo(&.{.{ "active", h.vbool(true) }}) },
    }));
    try testing.expect(std.mem.eql(u8, orderJoin(opts), "cache,retry"));
}
