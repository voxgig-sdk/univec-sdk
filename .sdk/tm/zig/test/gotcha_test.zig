// Cross-language gotcha verification (entity-agnostic). Each test targets a
// specific trap called out in the porting playbook.

const std = @import("std");
const sdk = @import("sdk");
const h = sdk.h;
const Value = sdk.Value;
const testing = std.testing;

fn vnull() Value {
    return Value{ .null = {} };
}

// ---- test-only callables ------------------------------------------------

var probe_calls: i64 = 0;
var probe_dummy: u8 = 0;
fn probeCall(_: *anyopaque, _: std.mem.Allocator, arg: Value) anyerror!Value {
    probe_calls += 1;
    return arg;
}

fn makeAlwaysOk() Value {
    const Ok = struct {
        var dummy: u8 = 0;
        fn call(_: *anyopaque, _: std.mem.Allocator, _: Value) anyerror!Value {
            return h.jo(&.{
                .{ "status", h.vnum(200) },
                .{ "statusText", h.vstr("OK") },
                .{ "headers", h.omap() },
                .{ "json", h.json_thunk(h.jo(&.{.{ "ok", h.vbool(true) }})) },
                .{ "body", h.vstr("x") },
            });
        }
    };
    return h.callable(@ptrCast(&Ok.dummy), Ok.call);
}

// A deterministic sleep recorder: appends each requested ms to `sleep_log`.
var sleep_log: std.ArrayList(i64) = undefined;
var sleep_log_init = false;
var sleep_dummy: u8 = 0;
fn sleepRecCall(_: *anyopaque, _: std.mem.Allocator, arg: Value) anyerror!Value {
    if (!sleep_log_init) {
        sleep_log = std.ArrayList(i64).init(h.A());
        sleep_log_init = true;
    }
    sleep_log.append(h.to_int(arg)) catch {};
    return vnull();
}
fn sleepRec() Value {
    return h.callable(@ptrCast(&sleep_dummy), sleepRecCall);
}

// A custom feature with configurable name + add_opts (for featureAdd order).
const OrderFeat = struct {
    nm: []const u8,
    opts: Value,
    fn make(nm: []const u8, opts: Value) sdk.Feature {
        const s = h.A().create(OrderFeat) catch unreachable;
        s.* = .{ .nm = nm, .opts = opts };
        return .{ .ptr = @ptrCast(s), .vtable = &vt };
    }
    fn s_of(p: *anyopaque) *OrderFeat {
        return @ptrCast(@alignCast(p));
    }
    fn vname(p: *anyopaque) []const u8 {
        return s_of(p).nm;
    }
    fn vactive(_: *anyopaque) bool {
        return true;
    }
    fn vaddopts(p: *anyopaque) Value {
        return s_of(p).opts;
    }
    fn vinit(_: *anyopaque, _: *sdk.Context, _: Value) void {}
    fn vdispatch(_: *anyopaque, _: []const u8, _: *sdk.Context) void {}
    const vt = sdk.Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};

// ---- gotcha #8: value semantics — set-at-path keeps the ROOT ------------

test "gotcha8: setpath keeps root" {
    const root = h.jo(&.{ .{ "a", h.vnum(1) }, .{ "b", h.omap() } });
    h.setpath(root, &.{ "b", "c" }, h.vnum(2));
    try testing.expect(h.to_int(h.getp(root, "a")) == 1);
    try testing.expect(h.to_int(h.getpath(&.{ "b", "c" }, root)) == 2);
}

// ---- gotcha #8: custom-utility callable survives options merge ----------

test "gotcha8: custom utility callable survives" {
    probe_calls = 0;
    const fn_val = h.callable(@ptrCast(&probe_dummy), probeCall);
    const opts = h.jo(&.{.{ "utility", h.jo(&.{.{ "probe", fn_val }}) }});
    const client = sdk.SDK.new(opts);
    const stored = h.getp(client.sdkUtility.custom, "probe");
    try testing.expect(stored == .function);
    const r = h.call_vfn(stored, h.vstr("x"));
    try testing.expect(r == .string and std.mem.eql(u8, r.string, "x"));
    try testing.expect(probe_calls == 1);
}

// ---- gotcha #8 (test_sdk): set_path must keep other sdkopts keys --------

test "gotcha8: test_sdk keeps root sdkopts" {
    const sdkopts = h.jo(&.{.{ "base", h.vstr("http://example.test") }});
    const client = sdk.test_sdk(vnull(), sdkopts);
    const opts = client.options_map();
    try testing.expect(std.mem.eql(u8, h.get_str(opts, "base") orelse "", "http://example.test"));
    try testing.expect(h.veq(h.getpath(&.{ "feature", "test", "active" }, opts), h.vbool(true)));
    try testing.expect(std.mem.eql(u8, client.mode, "test"));
}

// ---- gotcha #3: config is N-feature-safe (0 and N features) -------------

test "gotcha3: zero features" {
    const client = sdk.new();
    try testing.expect(std.mem.eql(u8, client.mode, "live"));
}

test "gotcha3: many features" {
    const opts = h.jo(&.{.{ "feature", h.jo(&.{
        .{ "retry", h.jo(&.{.{ "active", h.vbool(true) }}) },
        .{ "cache", h.jo(&.{.{ "active", h.vbool(true) }}) },
        .{ "timeout", h.jo(&.{.{ "active", h.vbool(true) }}) },
    }) }});
    const client = sdk.SDK.new(opts);
    try testing.expect(client.features.items.len >= 3);
}

// ---- gotcha #2: make_point surfaces a PrePoint (rbac) error ------------

test "gotcha2: make_point surfaces out.point error" {
    const client = sdk.new();
    const ctx = client.sdkUtility.make_context(.{ .opname = "list" }, client.get_root_ctx());
    const e = ctx.make_error("rbac_denied", "denied");
    ctx.out_set("point", sdk.OutVal{ .err = e });
    try testing.expectError(error.Sdk, client.sdkUtility.make_point(ctx));
    try testing.expect(ctx.pending_err != null);
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "rbac_denied"));
}

// ---- gotcha #4: featureAdd __before__ ordering -------------------------

test "gotcha4: featureAdd before ordering" {
    const client = sdk.new();
    const ctx = client.get_root_ctx();
    client.sdkUtility.feature_add(ctx, OrderFeat.make("aaa", vnull()));
    client.sdkUtility.feature_add(ctx, OrderFeat.make("bbb", h.jo(&.{.{ "__before__", h.vstr("aaa") }})));
    var ai: usize = 999;
    var bi: usize = 999;
    for (client.features.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name(), "aaa")) ai = i;
        if (std.mem.eql(u8, f.name(), "bbb")) bi = i;
    }
    try testing.expect(bi < ai and ai != 999);
}

// ---- gotcha #6: netsim exact error codes + seeded determinism ----------

test "gotcha6: netsim offline error code" {
    const opts = h.jo(&.{
        .{ "feature", h.jo(&.{.{ "netsim", h.jo(&.{
            .{ "active", h.vbool(true) },
            .{ "offline", h.vbool(true) },
            .{ "seed", h.vnum(1) },
        }) }}) },
        .{ "system", h.jo(&.{.{ "fetch", makeAlwaysOk() }}) },
    });
    const client = sdk.SDK.new(opts);
    const ctx = client.get_root_ctx();
    const r = client.sdkUtility.fetch(ctx, "http://x", h.jo(&.{.{ "url", h.vstr("http://x") }}));
    try testing.expectError(error.Sdk, r);
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "netsim_offline"));
}

test "gotcha6: netsim conn error code" {
    const opts = h.jo(&.{
        .{ "feature", h.jo(&.{.{ "netsim", h.jo(&.{
            .{ "active", h.vbool(true) },
            .{ "errorTimes", h.vnum(1) },
            .{ "seed", h.vnum(1) },
        }) }}) },
        .{ "system", h.jo(&.{.{ "fetch", makeAlwaysOk() }}) },
    });
    const client = sdk.SDK.new(opts);
    const ctx = client.get_root_ctx();
    const r = client.sdkUtility.fetch(ctx, "http://x", h.jo(&.{.{ "url", h.vstr("http://x") }}));
    try testing.expectError(error.Sdk, r);
    try testing.expect(std.mem.eql(u8, ctx.pending_err.?.code, "netsim_conn"));
}

test "gotcha6: netsim seeded latency is deterministic" {
    const mk = struct {
        fn build() []const i64 {
            sleep_log = std.ArrayList(i64).init(h.A());
            sleep_log_init = true;
            const opts = h.jo(&.{
                .{ "feature", h.jo(&.{.{ "netsim", h.jo(&.{
                    .{ "active", h.vbool(true) },
                    .{ "seed", h.vnum(42) },
                    .{ "latency", h.jo(&.{ .{ "min", h.vnum(100) }, .{ "max", h.vnum(200) } }) },
                    .{ "sleep", sleepRec() },
                }) }}) },
                .{ "system", h.jo(&.{.{ "fetch", makeAlwaysOk() }}) },
            });
            const client = sdk.SDK.new(opts);
            const ctx = client.get_root_ctx();
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                _ = client.sdkUtility.fetch(ctx, "http://x", h.jo(&.{.{ "url", h.vstr("http://x") }})) catch {};
            }
            return sleep_log.toOwnedSlice() catch &.{};
        }
    };
    const run1 = mk.build();
    const run2 = mk.build();
    try testing.expect(run1.len == 4 and run2.len == 4);
    for (run1, run2) |a, b| {
        try testing.expect(a == b); // same seed -> identical LCG sequence
        try testing.expect(a >= 100 and a <= 200);
    }
}
