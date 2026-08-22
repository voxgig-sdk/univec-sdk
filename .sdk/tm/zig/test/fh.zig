// Shared feature-test harness (mirrors the fh* helpers in tm/go/test/
// feature_test.go and tm/rust/tests/common/mod.rs). Feature behaviour is
// unit-tested by driving each feature through a faithful miniature of the
// real operation pipeline against a configurable mock transport — the same
// hook order and short-circuit rules as the generated entity op code, but
// with no live server and no API-specific fixtures.
//
// This file holds NO `test {}` blocks: it is `@import`ed by the behaviour
// suites (feature_test.zig, pipeline_test.zig, primary_utility_test.zig), so
// it must not add test cases of its own. Everything allocates from the
// process arena (h.A()) exactly like the rest of the SDK, so the zig test
// allocator's leak checks never see harness data.

const std = @import("std");
const sdk = @import("sdk");

pub const h = sdk.h;
pub const Value = sdk.Value;
pub const Fetcher = sdk.Fetcher;
pub const Context = sdk.Context;
pub const SdkError = sdk.h.SdkError;
pub const E = sdk.h.E;

fn vnull() Value {
    return Value{ .null = {} };
}

// ---- feature presence guard (mirrors rust fh_present) -------------------

pub fn fh_has_feature(name: []const u8) bool {
    const cfg = sdk.make_config();
    const fm = h.getp(cfg, "feature");
    return h.getp(fm, name) == .object;
}

pub fn fh_present(names: []const []const u8) bool {
    for (names) |name| {
        if (!fh_has_feature(name)) return false;
    }
    return true;
}

// ---- deterministic virtual clock (mirrors rust FhClock) -----------------

// now() advances only when sleep(ms) is called, so timing-based features can
// be asserted without real delays. Exposed as injectable function Values.
pub const FhClock = struct {
    t: i64 = 0,

    fn nowCall(p: *anyopaque, _: std.mem.Allocator, _: Value) anyerror!Value {
        const self: *FhClock = @ptrCast(@alignCast(p));
        return h.vnum(self.t);
    }
    fn sleepCall(p: *anyopaque, _: std.mem.Allocator, arg: Value) anyerror!Value {
        const self: *FhClock = @ptrCast(@alignCast(p));
        self.t += h.to_int(arg);
        return vnull();
    }

    pub fn new() *FhClock {
        const c = h.A().create(FhClock) catch unreachable;
        c.* = .{};
        return c;
    }
    pub fn now_fn(self: *FhClock) Value {
        return h.callable(@ptrCast(self), nowCall);
    }
    pub fn sleep_fn(self: *FhClock) Value {
        return h.callable(@ptrCast(self), sleepCall);
    }
    pub fn now(self: *FhClock) i64 {
        return self.t;
    }
    pub fn advance(self: *FhClock, ms: i64) void {
        self.t += ms;
    }
};

// A clock whose now() walks a fixed sequence (each read advances; the last
// value repeats). Used to drive timeout's elapsed check deterministically.
pub const FhSeqClock = struct {
    idx: usize = 0,
    seq: []const i64,

    fn nowCall(p: *anyopaque, _: std.mem.Allocator, _: Value) anyerror!Value {
        const self: *FhSeqClock = @ptrCast(@alignCast(p));
        const n = self.seq.len;
        const i = if (self.idx >= n) n - 1 else self.idx;
        self.idx += 1;
        return h.vnum(self.seq[i]);
    }

    pub fn new(seq: []const i64) *FhSeqClock {
        const c = h.A().create(FhSeqClock) catch unreachable;
        c.* = .{ .seq = h.A().dupe(i64, seq) catch seq };
        return c;
    }
    pub fn now_fn(self: *FhSeqClock) Value {
        return h.callable(@ptrCast(self), nowCall);
    }
};

// ---- injectable value functions -----------------------------------------

// A function value that ignores its argument and returns a fixed Value.
pub const ConstFn = struct {
    v: Value,
    fn call(p: *anyopaque, _: std.mem.Allocator, _: Value) anyerror!Value {
        const self: *ConstFn = @ptrCast(@alignCast(p));
        return self.v;
    }
    pub fn make(v: Value) Value {
        const s = h.A().create(ConstFn) catch unreachable;
        s.* = .{ .v = v };
        return h.callable(@ptrCast(s), call);
    }
};

pub fn constFn(v: Value) Value {
    return ConstFn.make(v);
}

// A function value that returns `<arg-as-string><suffix>` (arg defaults to
// "x" when not a string). Models the injectable idgen/keygen of the donors.
pub const SuffixFn = struct {
    suffix: []const u8,
    fn call(p: *anyopaque, _: std.mem.Allocator, arg: Value) anyerror!Value {
        const self: *SuffixFn = @ptrCast(@alignCast(p));
        const k: []const u8 = switch (arg) {
            .string => |s| s,
            else => "x",
        };
        return h.vstr(std.fmt.allocPrint(h.A(), "{s}{s}", .{ k, self.suffix }) catch k);
    }
    pub fn make(suffix: []const u8) Value {
        const s = h.A().create(SuffixFn) catch unreachable;
        s.* = .{ .suffix = suffix };
        return h.callable(@ptrCast(s), call);
    }
};

pub fn suffixFn(suffix: []const u8) Value {
    return SuffixFn.make(suffix);
}

// ---- collector (exporter / onEntry / sink callback recorder) ------------

pub const Collector = struct {
    items: std.ArrayList(Value),

    fn call(p: *anyopaque, _: std.mem.Allocator, arg: Value) anyerror!Value {
        const self: *Collector = @ptrCast(@alignCast(p));
        self.items.append(arg) catch {};
        return vnull();
    }
    pub fn new() *Collector {
        const s = h.A().create(Collector) catch unreachable;
        s.* = .{ .items = std.ArrayList(Value).init(h.A()) };
        return s;
    }
    pub fn fn_val(self: *Collector) Value {
        return h.callable(@ptrCast(self), call);
    }
    pub fn len(self: *Collector) usize {
        return self.items.items.len;
    }
    pub fn at(self: *Collector, i: usize) Value {
        return self.items.items[i];
    }
};

// ---- transport-shaped response (mirrors rust fh_response) ---------------

fn lowerAlloc(s: []const u8) []const u8 {
    const buf = h.A().alloc(u8, s.len) catch return s;
    return std.ascii.lowerString(buf, s);
}

pub fn fh_response(status: i64, data: Value, headers: Value) Value {
    const hh = h.omap();
    if (headers == .object) {
        var it = headers.object.iterator();
        while (it.next()) |kv| h.setp(hh, lowerAlloc(kv.key_ptr.*), kv.value_ptr.*);
    }
    const st: []const u8 = if (status >= 400) "ERR" else "OK";
    return h.jo(&.{
        .{ "status", h.vnum(status) },
        .{ "statusText", h.vstr(st) },
        .{ "body", h.vstr("not-used") },
        .{ "json", h.json_thunk(data) },
        .{ "headers", hh },
    });
}

// ---- mock transports -----------------------------------------------------

// Optional reply hook: (call-count, opctx, fetchdef) -> response|error.
pub const ReplyFn = *const fn (n: i64, opctx: *Context, fetchdef: Value) E!Value;

// A mock transport recording every call (url + fetchdef), replying via an
// optional hook (default: 200 with a call counter). Mirrors rust fh_recorder.
pub const Recorder = struct {
    calls: std.ArrayList(Value),
    reply: ?ReplyFn,

    fn call(p: *anyopaque, opctx: *Context, url: []const u8, fetchdef: Value) E!Value {
        const self: *Recorder = @ptrCast(@alignCast(p));
        self.calls.append(h.jo(&.{
            .{ "url", h.vstr(url) },
            .{ "fetchdef", fetchdef },
        })) catch {};
        const n: i64 = @intCast(self.calls.items.len);
        if (self.reply) |rf| return rf(n, opctx, fetchdef);
        return fh_response(200, h.jo(&.{
            .{ "ok", h.vbool(true) },
            .{ "n", h.vnum(n) },
        }), vnull());
    }
    pub fn new(reply: ?ReplyFn) *Recorder {
        const s = h.A().create(Recorder) catch unreachable;
        s.* = .{ .calls = std.ArrayList(Value).init(h.A()), .reply = reply };
        return s;
    }
    pub fn fetcher(self: *Recorder) Fetcher {
        return .{ .ctx = @ptrCast(self), .call = call };
    }
    pub fn count(self: *Recorder) usize {
        return self.calls.items.len;
    }
};

pub fn rec_call(rec: *Recorder, i: usize) Value {
    if (i >= rec.calls.items.len) return vnull();
    return rec.calls.items[i];
}
pub fn rec_fetchdef(rec: *Recorder, i: usize) Value {
    return h.getp(rec_call(rec, i), "fetchdef");
}
pub fn rec_headers(rec: *Recorder, i: usize) Value {
    return h.getp(rec_fetchdef(rec, i), "headers");
}
pub fn rec_url(rec: *Recorder, i: usize) []const u8 {
    return h.get_str(rec_call(rec, i), "url") orelse "";
}

// A transport that always errors at the connection level, counting calls.
pub const ErrServer = struct {
    n: i64 = 0,
    fn call(p: *anyopaque, opctx: *Context, _: []const u8, _: Value) E!Value {
        const self: *ErrServer = @ptrCast(@alignCast(p));
        self.n += 1;
        return opctx.fail("boom", "boom");
    }
    pub fn new() *ErrServer {
        const s = h.A().create(ErrServer) catch unreachable;
        s.* = .{};
        return s;
    }
    pub fn fetcher(self: *ErrServer) Fetcher {
        return .{ .ctx = @ptrCast(self), .call = call };
    }
};

// A transport returning nil (Noval) for the first (threshold-1) calls, then
// a 200. Exercises retry's nil-result handling.
pub const NilThenOkServer = struct {
    n: i64 = 0,
    threshold: i64 = 2,
    fn call(p: *anyopaque, _: *Context, _: []const u8, _: Value) E!Value {
        const self: *NilThenOkServer = @ptrCast(@alignCast(p));
        self.n += 1;
        if (self.n < self.threshold) return vnull();
        return fh_response(200, h.jo(&.{.{ "ok", h.vbool(true) }}), vnull());
    }
    pub fn new(threshold: i64) *NilThenOkServer {
        const s = h.A().create(NilThenOkServer) catch unreachable;
        s.* = .{ .threshold = threshold };
        return s;
    }
    pub fn fetcher(self: *NilThenOkServer) Fetcher {
        return .{ .ctx = @ptrCast(self), .call = call };
    }
};

// ---- the operation-pipeline harness (mirrors rust FhHarness) ------------

pub const FeatSpec = struct {
    feat: sdk.Feature,
    options: Value = .{ .null = {} },
};

pub const FhOpSpec = struct {
    entity: []const u8 = "",
    op: []const u8 = "",
    method: []const u8 = "",
    path: []const u8 = "",
    query: Value = .{ .null = {} },
    headers: Value = .{ .null = {} },
    body: Value = .{ .null = {} },
    ctrl: Value = .{ .null = {} },
};

pub const FhOpResult = struct {
    ok: bool,
    data: Value,
    err: ?*SdkError,
    result: ?*sdk.SdkResult,
    ctx: *Context,
};

pub fn fh_err_code(err: ?*SdkError) []const u8 {
    return if (err) |e| e.code else "";
}

fn fhDefaultMethod(op: []const u8) []const u8 {
    if (std.mem.eql(u8, op, "create")) return "POST";
    if (std.mem.eql(u8, op, "update")) return "PATCH";
    if (std.mem.eql(u8, op, "remove")) return "DELETE";
    return "GET";
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn fhBuildUrl(spec: *sdk.Spec) []const u8 {
    var url = std.fmt.allocPrint(h.A(), "{s}{s}", .{ spec.base, spec.path }) catch spec.path;
    if (spec.query == .object) {
        var keys = std.ArrayList([]const u8).init(h.A());
        var it = spec.query.object.iterator();
        while (it.next()) |kv| {
            if (!h.is_noval(kv.value_ptr.*)) keys.append(kv.key_ptr.*) catch {};
        }
        if (keys.items.len != 0) {
            std.mem.sort([]const u8, keys.items, {}, strLess);
            var qs = std.ArrayList(u8).init(h.A());
            for (keys.items) |k| {
                if (qs.items.len != 0) qs.append('&') catch {};
                const v = h.getp(spec.query, k);
                const part = std.fmt.allocPrint(h.A(), "{s}={s}", .{ h.esc_url(k), h.esc_url(h.scalar_str(v)) }) catch "";
                qs.appendSlice(part) catch {};
            }
            url = std.fmt.allocPrint(h.A(), "{s}?{s}", .{ url, qs.items }) catch url;
        }
    }
    return url;
}

pub const FhHarness = struct {
    client: *sdk.SDK,
    utility: *sdk.Utility,
    rootctx: *Context,
    base: []const u8,

    fn populate_result(self: *FhHarness, ctx: *Context, had_err: bool, fetch_err: ?*SdkError, fetched_val: Value) void {
        _ = self;
        const result = sdk.SdkResult.make(h.omap());
        ctx.result = result;

        if (had_err) {
            result.err = fetch_err;
            return;
        }
        if (fetched_val != .object) {
            result.err = ctx.make_error("request_no_response", "response: undefined");
            return;
        }

        const resp = sdk.Response.make(fetched_val);
        result.status = resp.status;
        result.status_text = resp.status_text;
        if (resp.headers == .object) result.headers = resp.headers;
        if (resp.json == .function) result.body = h.call_json(resp.json);
        result.resdata = result.body;

        if (result.status >= 400) {
            result.err = ctx.make_error("request_status", std.fmt.allocPrint(h.A(), "request: {d}: {s}", .{ result.status, result.status_text }) catch "request error");
        }
        if (result.err == null) result.ok = true;
    }

    fn fail(self: *FhHarness, ctx: *Context, e: *SdkError) FhOpResult {
        ctx.ctrl.err = e;
        self.utility.feature_hook(ctx, "PreUnexpected");
        return .{ .ok = false, .data = h.vnull(), .err = e, .result = ctx.result, .ctx = ctx };
    }

    // op: one operation through the mini pipeline (mirrors the generated
    // entity op code: hook, short-circuit, make*, hook, ...).
    pub fn op(self: *FhHarness, o: FhOpSpec) FhOpResult {
        const entity = if (o.entity.len == 0) "widget" else o.entity;
        const opname = if (o.op.len == 0) "load" else o.op;
        const method = if (o.method.len == 0) fhDefaultMethod(opname) else o.method;
        const ctrl: Value = if (o.ctrl == .object) o.ctrl else h.omap();

        const ctx = self.utility.make_context(sdk.CtxSpec{
            .opname = opname,
            .ctrl = ctrl,
        }, self.rootctx);
        ctx.op = sdk.Operation.make(h.jo(&.{
            .{ "entity", h.vstr(entity) },
            .{ "name", h.vstr(opname) },
        }));

        self.utility.feature_hook(ctx, "PostConstructEntity");

        self.utility.feature_hook(ctx, "PrePoint");
        if (ctx.out_get("point")) |ov| {
            switch (ov) {
                .err => |e| return self.fail(ctx, e),
                else => {},
            }
        }

        self.utility.feature_hook(ctx, "PreSpec");
        const path: []const u8 = if (o.path.len == 0)
            (std.fmt.allocPrint(h.A(), "/{s}", .{entity}) catch "/x")
        else
            o.path;

        const headers = h.omap();
        if (o.headers == .object) {
            var it = o.headers.object.iterator();
            while (it.next()) |kv| h.setp(headers, kv.key_ptr.*, kv.value_ptr.*);
        }
        const query = h.omap();
        if (o.query == .object) {
            var it = o.query.object.iterator();
            while (it.next()) |kv| h.setp(query, kv.key_ptr.*, kv.value_ptr.*);
        }

        const spec = sdk.Spec.make(h.jo(&.{
            .{ "method", h.vstr(method) },
            .{ "base", h.vstr(self.base) },
            .{ "path", h.vstr(path) },
            .{ "headers", headers },
            .{ "query", query },
            .{ "step", h.vstr("start") },
        }));
        if (!h.is_noval(o.body)) spec.body = o.body;
        ctx.spec = spec;

        self.utility.feature_hook(ctx, "PreRequest");
        const url = fhBuildUrl(spec);
        spec.url = url;

        const fetchdef = h.omap();
        h.setp(fetchdef, "url", h.vstr(url));
        h.setp(fetchdef, "method", h.vstr(spec.method));
        h.setp(fetchdef, "headers", spec.headers);
        if (!h.is_noval(spec.body)) h.setp(fetchdef, "body", spec.body);

        var fetched_val: Value = h.vnull();
        var had_err = false;
        var fetch_err: ?*SdkError = null;
        var used_short = false;
        if (ctx.out_get("request")) |ov| {
            switch (ov) {
                .val => |v| {
                    if (!h.is_noval(v)) {
                        fetched_val = v;
                        used_short = true;
                    }
                },
                else => {},
            }
        }
        if (!used_short) {
            if (self.utility.fetch(ctx, url, fetchdef)) |fv| {
                fetched_val = fv;
            } else |_| {
                had_err = true;
                fetch_err = ctx.take_err();
            }
        }

        if (!had_err and fetched_val == .object) {
            ctx.response = sdk.Response.make(fetched_val);
        }

        self.utility.feature_hook(ctx, "PreResponse");
        self.populate_result(ctx, had_err, fetch_err, fetched_val);
        self.utility.feature_hook(ctx, "PreResult");
        self.utility.feature_hook(ctx, "PreDone");

        if (ctx.result) |r| {
            if (r.ok) {
                return .{ .ok = true, .data = r.resdata, .err = null, .result = r, .ctx = ctx };
            }
        }
        const e: *SdkError = blk: {
            if (ctx.result) |r| {
                if (r.err) |re| break :blk re;
            }
            break :blk ctx.make_error("op_failed", "operation failed");
        };
        return self.fail(ctx, e);
    }
};

// fh_make: a real (test-mode) client, an isolated utility whose fetcher is
// the mock server, and the requested features initialised against it. Fires
// PostConstruct once wiring is complete. Mirrors rust fh_make.
pub fn fh_make(server: ?Fetcher, feats: []const FeatSpec) *FhHarness {
    const client = sdk.test_sdk(vnull(), vnull());
    client.features.clearRetainingCapacity();

    const utility = client.get_utility();
    utility.fetcher = server orelse Recorder.new(null).fetcher();

    const rootctx = utility.make_context(sdk.CtxSpec{
        .client = client,
        .utility = utility,
    }, client.get_root_ctx());

    for (feats) |fs| {
        const fopts = h.jo(&.{.{ "active", h.vbool(true) }});
        if (fs.options == .object) {
            var it = fs.options.object.iterator();
            while (it.next()) |kv| h.setp(fopts, kv.key_ptr.*, kv.value_ptr.*);
        }
        fs.feat.callInit(rootctx, fopts);
        client.features.append(fs.feat) catch {};
    }

    utility.feature_hook(rootctx, "PostConstruct");

    const hh = h.A().create(FhHarness) catch unreachable;
    hh.* = .{ .client = client, .utility = utility, .rootctx = rootctx, .base = "http://api.test" };
    return hh;
}
