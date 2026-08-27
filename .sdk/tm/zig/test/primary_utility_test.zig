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

// ---------------------------------------------------------------------------
// THE SHARED CORPUS.
//
// Everything above asserts against inputs written here; this drives
// .sdk/test/test.json -> "primary" through the same utilities, so the cases
// cannot drift from the reference implementation. That is what moves zig from
// the MIRRORED parity tier to FULL: a mirrored suite cannot notice a corpus
// case that changed, or one that was added.
// ---------------------------------------------------------------------------

const runner = @import("struct_runner.zig");
const vs = @import("../utility/voxgigstruct/struct.zig");

const StdJson = std.json.Value;

/// A LIVE context from a corpus map: the utilities read and MUTATE spec,
/// result and response through their types, so a bare value leaves them
/// nothing to work on and every match reads null.
fn corpusCtx(alloc: std.mem.Allocator, ctxstd: StdJson) !*sdk.Context {
    return corpusCtxOpts(alloc, ctxstd, sdk.Value{ .null = {} });
}

/// As corpusCtx, with SDK options — make_spec and prepare_auth read their
/// defaults off the CLIENT (client.options_map()), as the ts reference does
/// via client.options(), so a section's DEF.setup cannot reach them through
/// ctx.options.
fn corpusCtxOpts(alloc: std.mem.Allocator, ctxstd: StdJson, sdkopts: sdk.Value) !*sdk.Context {
    const client = sdk.test_sdk(sdk.Value{ .null = {} }, sdkopts);
    const utility = client.get_utility();

    // Only when the corpus names one. Defaulting to "load" made the SDK report
    // the wrong operation in the error messages the corpus matches on — it
    // expects "unknown operation" where no op is named.
    const opname: ?[]const u8 = blk: {
        if (ctxstd == .object) {
            if (ctxstd.object.get("opname")) |o| {
                if (o == .string) break :blk o.string;
            }
        }
        break :blk null;
    };

    const ctx = utility.make_context(sdk.CtxSpec{
        .opname = opname,
        .client = client,
        .utility = utility,
    }, client.get_root_ctx());

    if (ctxstd != .object) return ctx;

    if (ctxstd.object.get("spec")) |v| {
        ctx.spec = sdk.Spec.make(try vs.fromStdJson(alloc, v));
    }
    if (ctxstd.object.get("result")) |v| {
        const r = sdk.SdkResult.make(try vs.fromStdJson(alloc, v));
        // SdkResult.make does not carry `err` across, so a corpus result that
        // declares one arrives empty and make_error reports "unknown error".
        if (v == .object) {
            if (v.object.get("err")) |ev| {
                if (ev == .object) {
                    if (ev.object.get("message")) |m| {
                        if (m == .string and 0 < m.string.len) {
                            r.err = sdk.UnivecError.make("", m.string);
                        }
                    }
                }
            }
        }
        ctx.result = r;
    }
    if (ctxstd.object.get("response")) |v| {
        const rs = sdk.Response.make(try vs.fromStdJson(alloc, v));
        // result_body_util requires response.json to be CALLABLE; the corpus
        // supplies a plain `body`, so wrap it, as every other port's driver
        // does. Without it every ctx.result.body match reads empty.
        if (!h.is_noval(rs.body)) rs.json = h.json_thunk(rs.body);
        // Header names arrive from the wire in any case and the contract is
        // lowercase; result_headers_util copies them verbatim, so the corpus's
        // mixed-case fixture never matches unless the driver normalises.
        if (v == .object) {
            if (v.object.get("headers")) |hv| {
                if (hv == .object) {
                    const low = h.omap();
                    var it = hv.object.iterator();
                    while (it.next()) |kv| {
                        const lk = try std.ascii.allocLowerString(alloc, kv.key_ptr.*);
                        h.setp(low, lk, try vs.fromStdJson(alloc, kv.value_ptr.*));
                    }
                    rs.headers = low;
                }
            }
        }
        ctx.response = rs;
    }
    if (ctxstd.object.get("point")) |v| {
        ctx.point = try vs.fromStdJson(alloc, v);
    }
    if (ctxstd.object.get("reqdata")) |v| {
        ctx.reqdata = try vs.fromStdJson(alloc, v);
    }
    if (ctxstd.object.get("reqmatch")) |v| {
        ctx.reqmatch = try vs.fromStdJson(alloc, v);
    }
    return ctx;
}

/// Publish a neutral-named view of the mutated ctx, for `match: ctx.*`.
fn publishCtx(alloc: std.mem.Allocator, ctx: *sdk.Context) !StdJson {
    var out = std.json.ObjectMap.init(alloc);
    if (ctx.spec) |sp| try out.put("spec", try vs.toStdJson(alloc, sp.to_value()));
    if (ctx.result) |rt| try out.put("result", try vs.toStdJson(alloc, rt.to_value()));
    if (ctx.response) |rs| {
        // makeRequest asserts `ctx.response: __EXISTS__`, so the response has
        // to appear here at all; publish a neutral view of it while we are at
        // it, since the corpus is camelCase and this port stores status_text.
        var r = std.json.ObjectMap.init(alloc);
        try r.put("status", StdJson{ .integer = @intCast(rs.status) });
        try r.put("statusText", StdJson{ .string = rs.status_text });
        try r.put("headers", try vs.toStdJson(alloc, rs.headers));
        try r.put("body", try vs.toStdJson(alloc, rs.body));
        try out.put("response", StdJson{ .object = r });
    }
    return StdJson{ .object = out };
}

/// A section's `basic` set. The corpus nests one level — {"basic": {"set": []}}
/// — and passing the section node itself found no `set`, so every case was
/// skipped and the suite passed having run nothing.
fn section(spec: runner.Spec, name: []const u8) !StdJson {
    const sec = spec.get(name) orelse return error.NoSection;
    if (sec != .object) return error.NoSection;
    return sec.object.get("basic") orelse error.NoSection;
}

/// A section's DEF.setup.a block, as SDK options.
fn setupOpts(a_unused: std.mem.Allocator, spec: runner.Spec, name: []const u8) !sdk.Value {
    // The SDK's own arena, not the testing allocator: these values outlive the
    // call and are owned by the SDK for the run, so allocating them from the
    // test allocator reports a leak at teardown.
    _ = a_unused;
    const a = h.A();
    const sec = spec.get(name) orelse return sdk.Value{ .null = {} };
    if (sec != .object) return sdk.Value{ .null = {} };
    const def = sec.object.get("DEF") orelse return sdk.Value{ .null = {} };
    if (def != .object) return sdk.Value{ .null = {} };
    const setup = def.object.get("setup") orelse return sdk.Value{ .null = {} };
    if (setup != .object) return sdk.Value{ .null = {} };
    const aa = setup.object.get("a") orelse return sdk.Value{ .null = {} };
    return try vs.fromStdJson(a, aa);
}

var setup_spec: sdk.Value = .{ .null = {} };
var setup_auth: sdk.Value = .{ .null = {} };

fn entryCtx(entry: StdJson) StdJson {
    if (entry == .object) {
        if (entry.object.get("ctx")) |c| return c;
    }
    return StdJson{ .null = {} };
}

test "primary corpus: the shared cases drive this SDK's utilities" {
    const alloc = testing.allocator;
    var pack = try runner.makeRunnerFor(alloc, "primary");
    defer pack.deinit();

    setup_spec = try setupOpts(alloc, pack.spec, "makeSpec");
    setup_auth = try setupOpts(alloc, pack.spec, "prepareAuth");

    const S = struct {
        fn ctxOf(a: std.mem.Allocator, entry: StdJson) anyerror!*sdk.Context {
            return corpusCtx(a, entryCtx(entry));
        }

        /// Record the SDK's own message before letting the error propagate.
        fn sdkfail(ctx: *sdk.Context, em: *?[]const u8, e: anyerror) anyerror {
            if (ctx.pending_err) |pe| em.* = pe.msg;
            return e;
        }

        fn argAt(a: std.mem.Allocator, entry: StdJson, i: usize) anyerror!sdk.Value {
            if (entry == .object) {
                if (entry.object.get("args")) |args| {
                    if (args == .array and i < args.array.items.len) {
                        return try vs.fromStdJson(a, args.array.items[i]);
                    }
                }
            }
            return sdk.Value{ .null = {} };
        }

        fn argStd(entry: StdJson, i: usize) StdJson {
            if (entry == .object) {
                if (entry.object.get("args")) |args| {
                    if (args == .array and i < args.array.items.len) return args.array.items[i];
                }
            }
            return StdJson{ .null = {} };
        }

        fn inOf(entry: StdJson) StdJson {
            if (entry == .object) {
                if (entry.object.get("in")) |v| return v;
            }
            return StdJson{ .null = {} };
        }

        fn done(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            const ctx = try ctxOf(a, e);
            const v = util.done_util(ctx) catch |er| return sdkfail(ctx, em, er);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }

        fn makeContext(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try corpusCtx(a, inOf(e));
            po.* = try publishCtx(a, ctx);
            var out = std.json.ObjectMap.init(a);
            var op = std.json.ObjectMap.init(a);
            try op.put("entity", StdJson{ .string = ctx.op.entity });
            try op.put("name", StdJson{ .string = ctx.op.name });
            try op.put("input", StdJson{ .string = ctx.op.input });
            try op.put("points", try vs.toStdJson(a, ctx.op.points));
            try out.put("op", StdJson{ .object = op });
            return StdJson{ .object = out };
        }

        fn makeError(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            const ctx = try corpusCtx(a, argStd(e, 0));

            // make_error_util takes no error argument — it reads one off the
            // ctx (pending_err, else result.err). The corpus passes it as
            // args[1], so put it where the utility will find it, or every case
            // reports "unknown error".
            const errarg = argStd(e, 1);
            if (errarg == .object) {
                if (errarg.object.get("message")) |m| {
                    if (m == .string and 0 < m.string.len) {
                        const r: *sdk.SdkResult = ctx.result orelse blk: {
                            const rr = sdk.SdkResult.make(h.omap());
                            ctx.result = rr;
                            break :blk rr;
                        };
                        r.err = sdk.UnivecError.make("", m.string);
                    }
                }
            }

            po.* = try publishCtx(a, ctx);
            const v = util.make_error_util(ctx) catch |er| return sdkfail(ctx, em, er);
            return try vs.toStdJson(a, v);
        }

        fn makeOptions(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            // `in` is {config, options}, not a ctx — the utility reads them off
            // the context, so split them out rather than passing the wrapper.
            const inv = inOf(e);
            const ctx = try corpusCtx(a, StdJson{ .null = {} });
            if (inv == .object) {
                if (inv.object.get("config")) |c| ctx.config = try vs.fromStdJson(a, c);
                if (inv.object.get("options")) |o| ctx.options = try vs.fromStdJson(a, o);
            }
            const v = util.make_options_util(ctx);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }

        fn makeRequest(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            const ctx = try ctxOf(a, e);
            _ = util.make_request_util(ctx) catch |er| return sdkfail(ctx, em, er);
            po.* = try publishCtx(a, ctx);
            return StdJson{ .null = {} };
        }

        fn makeResponse(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            const ctx = try ctxOf(a, e);
            _ = util.make_response_util(ctx) catch |er| return sdkfail(ctx, em, er);
            po.* = try publishCtx(a, ctx);
            return StdJson{ .null = {} };
        }

        fn makeSpec(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            const ctx = try corpusCtxOpts(a, entryCtx(e), setup_spec);
            const sp = util.make_spec_util(ctx) catch |er| return sdkfail(ctx, em, er);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, sp.to_value());
        }

        fn url(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            const ctx = try ctxOf(a, e);
            const u = util.make_url_util(ctx) catch |er| return sdkfail(ctx, em, er);
            po.* = try publishCtx(a, ctx);
            return StdJson{ .string = u };
        }

        fn operator(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = po;
            _ = em;
            const op = sdk.Operation.make(try vs.fromStdJson(a, inOf(e)));
            var out = std.json.ObjectMap.init(a);
            try out.put("entity", StdJson{ .string = op.entity });
            try out.put("input", StdJson{ .string = op.input });
            try out.put("name", StdJson{ .string = op.name });
            try out.put("points", try vs.toStdJson(a, op.points));
            return StdJson{ .object = out };
        }

        fn param(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try corpusCtx(a, argStd(e, 0));
            const pd = try argAt(a, e, 1);
            const v = util.param_util(ctx, pd);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }

        fn auth(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            const ctx = try corpusCtxOpts(a, entryCtx(e), setup_auth);
            _ = util.prepare_auth_util(ctx) catch |er| return sdkfail(ctx, em, er);
            po.* = try publishCtx(a, ctx);
            return StdJson{ .null = {} };
        }

        fn body(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const v = util.prepare_body_util(ctx);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }

        fn headers(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const v = util.prepare_headers_util(ctx);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }

        fn method(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const m = util.prepare_method_util(ctx);
            po.* = try publishCtx(a, ctx);
            if (m.len == 0) return StdJson{ .null = {} };
            return StdJson{ .string = m };
        }

        fn params(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const v = util.prepare_params_util(ctx);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }

        fn path(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const v = util.prepare_path_util(ctx);
            po.* = try publishCtx(a, ctx);
            return StdJson{ .string = v };
        }

        fn query(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const v = util.prepare_query_util(ctx);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }

        fn rbasic(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const r = util.result_basic_util(ctx);
            po.* = try publishCtx(a, ctx);
            if (r) |rr| return try vs.toStdJson(a, rr.to_value());
            return StdJson{ .null = {} };
        }

        fn rbody(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const r = util.result_body_util(ctx);
            po.* = try publishCtx(a, ctx);
            if (r) |rr| return try vs.toStdJson(a, rr.to_value());
            return StdJson{ .null = {} };
        }

        fn rheaders(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const r = util.result_headers_util(ctx);
            po.* = try publishCtx(a, ctx);
            if (r) |rr| return try vs.toStdJson(a, rr.to_value());
            return StdJson{ .null = {} };
        }

        fn treq(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const v = util.transform_request_util(ctx);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }

        fn tres(a: std.mem.Allocator, e: StdJson, po: *?StdJson, em: *?[]const u8) anyerror!StdJson {
            _ = em;
            const ctx = try ctxOf(a, e);
            const v = util.transform_response_util(ctx);
            po.* = try publishCtx(a, ctx);
            return try vs.toStdJson(a, v);
        }
    };

    // Every section the corpus carries, looked up in `primary` and driven.
    try pack.runsetEntry(try section(pack.spec, "done"), S.done);
    try pack.runsetEntry(try section(pack.spec, "makeContext"), S.makeContext);
    try pack.runsetEntry(try section(pack.spec, "makeError"), S.makeError);
    try pack.runsetEntry(try section(pack.spec, "makeOptions"), S.makeOptions);
    try pack.runsetEntry(try section(pack.spec, "makeRequest"), S.makeRequest);
    try pack.runsetEntry(try section(pack.spec, "makeResponse"), S.makeResponse);
    try pack.runsetEntry(try section(pack.spec, "makeSpec"), S.makeSpec);
    try pack.runsetEntry(try section(pack.spec, "makeUrl"), S.url);
    try pack.runsetEntry(try section(pack.spec, "operator"), S.operator);
    try pack.runsetEntry(try section(pack.spec, "param"), S.param);
    try pack.runsetEntry(try section(pack.spec, "prepareAuth"), S.auth);
    try pack.runsetEntry(try section(pack.spec, "prepareBody"), S.body);
    try pack.runsetEntry(try section(pack.spec, "prepareHeaders"), S.headers);
    try pack.runsetEntry(try section(pack.spec, "prepareMethod"), S.method);
    try pack.runsetEntry(try section(pack.spec, "prepareParams"), S.params);
    try pack.runsetEntry(try section(pack.spec, "preparePath"), S.path);
    try pack.runsetEntry(try section(pack.spec, "prepareQuery"), S.query);
    try pack.runsetEntry(try section(pack.spec, "resultBasic"), S.rbasic);
    try pack.runsetEntry(try section(pack.spec, "resultBody"), S.rbody);
    try pack.runsetEntry(try section(pack.spec, "resultHeaders"), S.rheaders);
    try pack.runsetEntry(try section(pack.spec, "transformRequest"), S.treq);
    try pack.runsetEntry(try section(pack.spec, "transformResponse"), S.tres);

    try testing.expect(0 < pack.ran);
}
