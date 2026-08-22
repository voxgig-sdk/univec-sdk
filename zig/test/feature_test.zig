// Behavioural tests for the enterprise features shipped with this SDK
// (mirrors tm/rust/tests/feature_test.rs and tm/go/test/feature_test.go).
// Each feature is driven through a faithful miniature of the real operation
// pipeline (test/fh.zig) against a configurable mock transport — the same
// hook order and short-circuit rules as the generated entity op code, but
// with no live server and no API-specific fixtures. Injected deterministic
// clocks/idgens/keygens keep timing and id assertions exact. Every block runs
// only when its feature is present in this SDK (fh.fh_present).

const std = @import("std");
const sdk = @import("sdk");
const fh = @import("fh.zig");
const h = sdk.h;
const Value = sdk.Value;
const testing = std.testing;

fn vnull() Value {
    return Value{ .null = {} };
}

// ---- reply hooks (used by recorder-backed transports) -------------------

fn reply404(_: i64, _: *sdk.Context, _: Value) fh.E!Value {
    return fh.fh_response(404, vnull(), vnull());
}
fn reply500(_: i64, _: *sdk.Context, _: Value) fh.E!Value {
    return fh.fh_response(500, vnull(), vnull());
}
fn reply503(_: i64, _: *sdk.Context, _: Value) fh.E!Value {
    return fh.fh_response(503, vnull(), vnull());
}
fn replyPaging(_: i64, _: *sdk.Context, _: Value) fh.E!Value {
    return fh.fh_response(
        200,
        h.jo(&.{.{ "items", h.ja(&.{ h.vnum(1), h.vnum(2) }) }}),
        h.jo(&.{
            .{ "x-next-page", h.vstr("2") },
            .{ "x-total-count", h.vstr("5") },
            .{ "link", h.vstr("</w?page=2>; rel=\"next\"") },
        }),
    );
}
fn replyCursor(_: i64, _: *sdk.Context, _: Value) fh.E!Value {
    return fh.fh_response(
        200,
        h.jo(&.{ .{ "nextCursor", h.vstr("abc") }, .{ "hasMore", h.vbool(true) } }),
        vnull(),
    );
}
fn replyStreamItems(_: i64, _: *sdk.Context, _: Value) fh.E!Value {
    return fh.fh_response(200, h.ja(&.{ h.vstr("a"), h.vstr("b"), h.vstr("c") }), vnull());
}
fn replyStreamNums(_: i64, _: *sdk.Context, _: Value) fh.E!Value {
    return fh.fh_response(200, h.ja(&.{ h.vnum(1), h.vnum(2), h.vnum(3), h.vnum(4), h.vnum(5) }), vnull());
}

// small casting helpers keep each test terse.
fn asNetsim(f: sdk.Feature) *sdk.NetsimFeature {
    return @ptrCast(@alignCast(f.ptr));
}

// =====================================================================
// netsim
// =====================================================================

test "feature netsim: fixed latency then delegate" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.NetsimFeature.make();
    const nf: *sdk.NetsimFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "latency", h.vnum(250) },
        .{ "sleep", clock.sleep_fn() },
    }) }});
    const res = hh.op(.{ .op = "load", .ctrl = h.jo(&.{.{ "explain", h.omap() }}) });
    try testing.expect(res.ok);
    try testing.expect(clock.now() == 250);
    try testing.expect(nf.track.calls == 1);
}

test "feature netsim: ranged latency in min max" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "latency", h.jo(&.{ .{ "min", h.vnum(100) }, .{ "max", h.vnum(300) } }) },
        .{ "seed", h.vnum(7) },
        .{ "sleep", clock.sleep_fn() },
    }) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(clock.now() >= 100 and clock.now() < 300);
}

test "feature netsim: equal min max latency exact" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "latency", h.jo(&.{ .{ "min", h.vnum(50) }, .{ "max", h.vnum(50) } }) },
        .{ "sleep", clock.sleep_fn() },
    }) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(clock.now() == 50);
}

test "feature netsim: fail times returns retryable status" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const f = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "failTimes", h.vnum(2) },
        .{ "failStatus", h.vnum(503) },
    }) }});
    try testing.expect(hh.op(.{ .op = "load" }).result.?.status == 503);
    try testing.expect(hh.op(.{ .op = "load" }).result.?.status == 503);
    try testing.expect(hh.op(.{ .op = "load" }).ok);
}

test "feature netsim: fail every fails every nth" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const f = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "failEvery", h.vnum(2) }}) }});
    try testing.expect(hh.op(.{ .op = "load" }).ok);
    try testing.expect(!hh.op(.{ .op = "load" }).ok);
    try testing.expect(hh.op(.{ .op = "load" }).ok);
}

test "feature netsim: fail rate with seed deterministic" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const f = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "failRate", h.vfloat(1.0) },
        .{ "seed", h.vnum(5) },
    }) }});
    try testing.expect(!hh.op(.{ .op = "load" }).ok);
}

test "feature netsim: error times connection error" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const f = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "errorTimes", h.vnum(1) }}) }});
    const res = hh.op(.{ .op = "load" });
    try testing.expect(std.mem.eql(u8, fh.fh_err_code(res.err), "netsim_conn"));
}

test "feature netsim: offline fails every call" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const f = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "offline", h.vbool(true) }}) }});
    const res = hh.op(.{ .op = "load" });
    try testing.expect(std.mem.eql(u8, fh.fh_err_code(res.err), "netsim_offline"));
}

test "feature netsim: rate limit times 429 retry-after" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const f = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "rateLimitTimes", h.vnum(1) },
        .{ "retryAfter", h.vnum(3) },
    }) }});
    const res = hh.op(.{ .op = "load" });
    try testing.expect(res.result.?.status == 429);
    try testing.expect(h.veq(h.getp(res.result.?.headers, "retry-after"), h.vstr("3")));
}

test "feature netsim: inactive does not wrap" {
    if (!fh.fh_present(&.{"netsim"})) return;
    const f = sdk.NetsimFeature.make();
    const nf = asNetsim(f);
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "active", h.vbool(false) },
        .{ "offline", h.vbool(true) },
    }) }});
    try testing.expect(hh.op(.{ .op = "load" }).ok);
    try testing.expect(nf.track.calls == 0);
}

// =====================================================================
// retry
// =====================================================================

test "feature retry: retries transient then succeeds" {
    if (!fh.fh_present(&.{ "retry", "netsim" })) return;
    const clock = fh.FhClock.new();
    const rf_feat = sdk.RetryFeature.make();
    const rf: *sdk.RetryFeature = @ptrCast(@alignCast(rf_feat.ptr));
    const nf_feat = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{
        .{ .feat = nf_feat, .options = h.jo(&.{ .{ "failTimes", h.vnum(2) }, .{ "failStatus", h.vnum(503) } }) },
        .{ .feat = rf_feat, .options = h.jo(&.{
            .{ "retries", h.vnum(3) },
            .{ "minDelay", h.vnum(10) },
            .{ "jitter", h.vbool(false) },
            .{ "sleep", clock.sleep_fn() },
        }) },
    });
    const res = hh.op(.{ .op = "load" });
    try testing.expect(res.ok);
    try testing.expect(rf.track.attempts == 2);
}

test "feature retry: gives up after budget" {
    if (!fh.fh_present(&.{ "retry", "netsim" })) return;
    const clock = fh.FhClock.new();
    const nf_feat = sdk.NetsimFeature.make();
    const rf_feat = sdk.RetryFeature.make();
    const hh = fh.fh_make(null, &.{
        .{ .feat = nf_feat, .options = h.jo(&.{ .{ "failTimes", h.vnum(9) }, .{ "failStatus", h.vnum(500) } }) },
        .{ .feat = rf_feat, .options = h.jo(&.{
            .{ "retries", h.vnum(2) },
            .{ "minDelay", h.vnum(1) },
            .{ "jitter", h.vbool(false) },
            .{ "sleep", clock.sleep_fn() },
        }) },
    });
    const res = hh.op(.{ .op = "load" });
    try testing.expect(res.result.?.status == 500);
}

test "feature retry: does not retry non-retryable status" {
    if (!fh.fh_present(&.{"retry"})) return;
    const rec = fh.Recorder.new(reply404);
    const rf = sdk.RetryFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = rf, .options = h.jo(&.{
        .{ "retries", h.vnum(3) },
        .{ "minDelay", h.vnum(0) },
    }) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(rec.count() == 1);
}

test "feature retry: retries transport error then returns it" {
    if (!fh.fh_present(&.{"retry"})) return;
    const clock = fh.FhClock.new();
    const srv = fh.ErrServer.new();
    const rf = sdk.RetryFeature.make();
    const hh = fh.fh_make(srv.fetcher(), &.{.{ .feat = rf, .options = h.jo(&.{
        .{ "retries", h.vnum(2) },
        .{ "minDelay", h.vnum(1) },
        .{ "jitter", h.vbool(false) },
        .{ "sleep", clock.sleep_fn() },
    }) }});
    const res = hh.op(.{ .op = "load" });
    try testing.expect(!res.ok);
    try testing.expect(srv.n == 3);
}

test "feature retry: retries nil transport result" {
    if (!fh.fh_present(&.{"retry"})) return;
    const srv = fh.NilThenOkServer.new(2);
    const rf = sdk.RetryFeature.make();
    const hh = fh.fh_make(srv.fetcher(), &.{.{ .feat = rf, .options = h.jo(&.{
        .{ "retries", h.vnum(3) },
        .{ "minDelay", h.vnum(0) },
    }) }});
    const res = hh.op(.{ .op = "load" });
    try testing.expect(res.ok);
    try testing.expect(srv.n == 2);
}

test "feature retry: honours server retry-after" {
    if (!fh.fh_present(&.{ "retry", "netsim" })) return;
    const clock = fh.FhClock.new();
    const nf_feat = sdk.NetsimFeature.make();
    const rf_feat = sdk.RetryFeature.make();
    const hh = fh.fh_make(null, &.{
        .{ .feat = nf_feat, .options = h.jo(&.{ .{ "rateLimitTimes", h.vnum(1) }, .{ "retryAfter", h.vnum(2) } }) },
        .{ .feat = rf_feat, .options = h.jo(&.{
            .{ "retries", h.vnum(2) },
            .{ "minDelay", h.vnum(10) },
            .{ "maxDelay", h.vnum(60000) },
            .{ "jitter", h.vbool(false) },
            .{ "sleep", clock.sleep_fn() },
        }) },
    });
    const res = hh.op(.{ .op = "load" });
    try testing.expect(res.ok);
    try testing.expect(clock.now() == 2000);
}

test "feature retry: inactive does not wrap" {
    if (!fh.fh_present(&.{"retry"})) return;
    const rec = fh.Recorder.new(reply503);
    const rf = sdk.RetryFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = rf, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(rec.count() == 1);
}

// =====================================================================
// timeout
// =====================================================================

test "feature timeout: slow request times out" {
    if (!fh.fh_present(&.{"timeout"})) return;
    const clock = fh.FhSeqClock.new(&.{ 0, 200 });
    const f = sdk.TimeoutFeature.make();
    const tf: *sdk.TimeoutFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "ms", h.vnum(10) },
        .{ "now", clock.now_fn() },
    }) }});
    const res = hh.op(.{ .op = "load" });
    try testing.expect(std.mem.eql(u8, fh.fh_err_code(res.err), "timeout"));
    try testing.expect(tf.track.count == 1);
}

test "feature timeout: fast request passes" {
    if (!fh.fh_present(&.{"timeout"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.TimeoutFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "ms", h.vnum(1000) },
        .{ "now", clock.now_fn() },
    }) }});
    try testing.expect(hh.op(.{ .op = "load" }).ok);
}

test "feature timeout: ms zero disables" {
    if (!fh.fh_present(&.{"timeout"})) return;
    const f = sdk.TimeoutFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "ms", h.vnum(0) }}) }});
    try testing.expect(hh.op(.{ .op = "load" }).ok);
}

test "feature timeout: inactive does not wrap" {
    if (!fh.fh_present(&.{"timeout"})) return;
    const f = sdk.TimeoutFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    try testing.expect(hh.op(.{ .op = "load" }).ok);
}

// =====================================================================
// ratelimit
// =====================================================================

test "feature ratelimit: throttles once burst spent" {
    if (!fh.fh_present(&.{"ratelimit"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.RatelimitFeature.make();
    const rf: *sdk.RatelimitFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "rate", h.vnum(1) },
        .{ "burst", h.vnum(2) },
        .{ "now", clock.now_fn() },
        .{ "sleep", clock.sleep_fn() },
    }) }});
    _ = hh.op(.{ .op = "load" });
    _ = hh.op(.{ .op = "load" });
    _ = hh.op(.{ .op = "load" });
    try testing.expect(rf.track.throttled == 1);
    try testing.expect(clock.now() > 0);
}

test "feature ratelimit: burst defaults to rate and refills" {
    if (!fh.fh_present(&.{"ratelimit"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.RatelimitFeature.make();
    const rf: *sdk.RatelimitFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "rate", h.vnum(2) },
        .{ "now", clock.now_fn() },
        .{ "sleep", clock.sleep_fn() },
    }) }});
    _ = hh.op(.{ .op = "load" });
    _ = hh.op(.{ .op = "load" });
    clock.advance(1000); // refill
    _ = hh.op(.{ .op = "load" });
    try testing.expect(rf.track.throttled == 0);
}

test "feature ratelimit: inactive does not wrap" {
    if (!fh.fh_present(&.{"ratelimit"})) return;
    const f = sdk.RatelimitFeature.make();
    const rf: *sdk.RatelimitFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    try testing.expect(hh.op(.{ .op = "load" }).ok);
    try testing.expect(rf.track.throttled == 0);
}

// =====================================================================
// cache
// =====================================================================

test "feature cache: serves repeated read from cache" {
    if (!fh.fh_present(&.{"cache"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.CacheFeature.make();
    const cf: *sdk.CacheFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "ttl", h.vnum(10000) }}) }});
    const a = hh.op(.{ .op = "load", .path = "/w/1" });
    const b = hh.op(.{ .op = "load", .path = "/w/1" });
    try testing.expect(rec.count() == 1);
    try testing.expect(h.veq(a.data, b.data));
    try testing.expect(cf.track.hit == 1);
}

test "feature cache: does not cache non-get" {
    if (!fh.fh_present(&.{"cache"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.CacheFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "create", .path = "/w" });
    _ = hh.op(.{ .op = "create", .path = "/w" });
    try testing.expect(rec.count() == 2);
}

test "feature cache: does not cache non-2xx" {
    if (!fh.fh_present(&.{"cache"})) return;
    const rec = fh.Recorder.new(reply500);
    const f = sdk.CacheFeature.make();
    const cf: *sdk.CacheFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "load", .path = "/w" });
    _ = hh.op(.{ .op = "load", .path = "/w" });
    try testing.expect(rec.count() == 2);
    try testing.expect(cf.track.bypass == 2);
}

test "feature cache: refetches after ttl" {
    if (!fh.fh_present(&.{"cache"})) return;
    const clock = fh.FhClock.new();
    const rec = fh.Recorder.new(null);
    const f = sdk.CacheFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "ttl", h.vnum(1000) },
        .{ "now", clock.now_fn() },
    }) }});
    _ = hh.op(.{ .op = "load", .path = "/w" });
    clock.advance(1500);
    _ = hh.op(.{ .op = "load", .path = "/w" });
    try testing.expect(rec.count() == 2);
}

test "feature cache: evicts oldest past max" {
    if (!fh.fh_present(&.{"cache"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.CacheFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "ttl", h.vnum(10000) },
        .{ "max", h.vnum(1) },
    }) }});
    _ = hh.op(.{ .op = "load", .path = "/a" });
    _ = hh.op(.{ .op = "load", .path = "/b" }); // evicts /a
    _ = hh.op(.{ .op = "load", .path = "/a" }); // miss again
    try testing.expect(rec.count() == 3);
}

test "feature cache: inactive does not wrap" {
    if (!fh.fh_present(&.{"cache"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.CacheFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "load", .path = "/x" });
    _ = hh.op(.{ .op = "load", .path = "/x" });
    try testing.expect(rec.count() == 2);
}

// =====================================================================
// idempotency
// =====================================================================

test "feature idempotency: adds key to mutating ops" {
    if (!fh.fh_present(&.{"idempotency"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.IdempotencyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "create", .path = "/w" });
    try testing.expect(!h.is_noval(h.getp(fh.rec_headers(rec, 0), "Idempotency-Key")));
}

test "feature idempotency: adds key by http method" {
    if (!fh.fh_present(&.{"idempotency"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.IdempotencyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "act", .method = "PUT", .path = "/w" });
    try testing.expect(!h.is_noval(h.getp(fh.rec_headers(rec, 0), "Idempotency-Key")));
}

test "feature idempotency: leaves reads untouched" {
    if (!fh.fh_present(&.{"idempotency"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.IdempotencyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "load", .path = "/w/1" });
    try testing.expect(h.is_noval(h.getp(fh.rec_headers(rec, 0), "Idempotency-Key")));
}

test "feature idempotency: preserves caller key custom header" {
    if (!fh.fh_present(&.{"idempotency"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.IdempotencyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "header", h.vstr("X-Idem") }}) }});
    _ = hh.op(.{ .op = "create", .path = "/w", .headers = h.jo(&.{.{ "X-Idem", h.vstr("caller-1") }}) });
    try testing.expect(h.veq(h.getp(fh.rec_headers(rec, 0), "X-Idem"), h.vstr("caller-1")));
}

test "feature idempotency: injected keygen" {
    if (!fh.fh_present(&.{"idempotency"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.IdempotencyFeature.make();
    const idf: *sdk.IdempotencyFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "keygen", fh.constFn(h.vstr("K1")) }}) }});
    _ = hh.op(.{ .op = "create", .path = "/w" });
    try testing.expect(h.veq(h.getp(fh.rec_headers(rec, 0), "Idempotency-Key"), h.vstr("K1")));
    try testing.expect(std.mem.eql(u8, idf.last, "K1"));
    try testing.expect(idf.issued == 1);
}

test "feature idempotency: inactive is noop" {
    if (!fh.fh_present(&.{"idempotency"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.IdempotencyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "create", .path = "/w" });
    try testing.expect(h.is_noval(h.getp(fh.rec_headers(rec, 0), "Idempotency-Key")));
}

// =====================================================================
// rbac
// =====================================================================

test "feature rbac: denies before any call" {
    if (!fh.fh_present(&.{"rbac"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.RbacFeature.make();
    const rf: *sdk.RbacFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "rules", h.jo(&.{.{ "widget.remove", h.vstr("admin") }}) },
        .{ "permissions", h.olist() },
    }) }});
    const res = hh.op(.{ .op = "remove", .path = "/w/1" });
    try testing.expect(std.mem.eql(u8, fh.fh_err_code(res.err), "rbac_denied"));
    try testing.expect(rec.count() == 0);
    try testing.expect(rf.denied == 1);
}

test "feature rbac: allows held permission" {
    if (!fh.fh_present(&.{"rbac"})) return;
    const f = sdk.RbacFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "rules", h.jo(&.{.{ "widget.remove", h.vstr("admin") }}) },
        .{ "permissions", h.ja(&.{h.vstr("admin")}) },
    }) }});
    try testing.expect(hh.op(.{ .op = "remove", .path = "/w/1" }).ok);
}

test "feature rbac: op rule and wildcard grant" {
    if (!fh.fh_present(&.{"rbac"})) return;
    const f = sdk.RbacFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "rules", h.jo(&.{.{ "load", h.vstr("read") }}) },
        .{ "permissions", h.ja(&.{h.vstr("*")}) },
    }) }});
    try testing.expect(hh.op(.{ .op = "load" }).ok);
}

test "feature rbac: default allow and deny true" {
    if (!fh.fh_present(&.{"rbac"})) return;
    const fa = sdk.RbacFeature.make();
    const allow = fh.fh_make(null, &.{.{ .feat = fa, .options = h.jo(&.{.{ "permissions", h.olist() }}) }});
    try testing.expect(allow.op(.{ .op = "load" }).ok);

    const fd = sdk.RbacFeature.make();
    const deny = fh.fh_make(null, &.{.{ .feat = fd, .options = h.jo(&.{
        .{ "deny", h.vbool(true) },
        .{ "permissions", h.olist() },
    }) }});
    const res = deny.op(.{ .op = "load" });
    try testing.expect(std.mem.eql(u8, fh.fh_err_code(res.err), "rbac_denied"));
}

test "feature rbac: inactive is noop" {
    if (!fh.fh_present(&.{"rbac"})) return;
    const f = sdk.RbacFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "active", h.vbool(false) },
        .{ "deny", h.vbool(true) },
    }) }});
    try testing.expect(hh.op(.{ .op = "load" }).ok);
}

// =====================================================================
// metrics
// =====================================================================

test "feature metrics: counts ok and err per op" {
    if (!fh.fh_present(&.{ "metrics", "netsim" })) return;
    const mf_feat = sdk.MetricsFeature.make();
    const mf: *sdk.MetricsFeature = @ptrCast(@alignCast(mf_feat.ptr));
    const nf_feat = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{
        .{ .feat = nf_feat, .options = h.jo(&.{ .{ "failTimes", h.vnum(1) }, .{ "failStatus", h.vnum(500) } }) },
        .{ .feat = mf_feat, .options = vnull() },
    });
    _ = hh.op(.{ .op = "load" });
    _ = hh.op(.{ .op = "load" });
    _ = hh.op(.{ .op = "list" });
    try testing.expect(mf.total.count == 3 and mf.total.ok == 2 and mf.total.err == 1);
    const wl = mf.ops.get("widget.load") orelse unreachable;
    try testing.expect(wl.count == 2);
}

test "feature metrics: injected clock" {
    if (!fh.fh_present(&.{"metrics"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.MetricsFeature.make();
    const mf: *sdk.MetricsFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "now", clock.now_fn() }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(mf.total.count == 1);
    try testing.expect(mf.total.total_ms == 0);
}

test "feature metrics: inactive records nothing" {
    if (!fh.fh_present(&.{"metrics"})) return;
    const f = sdk.MetricsFeature.make();
    const mf: *sdk.MetricsFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(mf.total.count == 0);
}

// =====================================================================
// telemetry
// =====================================================================

test "feature telemetry: opens spans and propagates headers" {
    if (!fh.fh_present(&.{"telemetry"})) return;
    const rec = fh.Recorder.new(null);
    const exp = fh.Collector.new();
    const f = sdk.TelemetryFeature.make();
    const tf: *sdk.TelemetryFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "exporter", exp.fn_val() }}) }});
    const res = hh.op(.{ .op = "load" });
    try testing.expect(res.ok);
    try testing.expect(tf.spans.items.len == 1);
    try testing.expect(exp.len() == 1);
    const sent = fh.rec_headers(rec, 0);
    try testing.expect(h.veq(h.getp(sent, "X-Trace-Id"), h.getp(tf.spans.items[0], "traceId")));
    const tp = h.get_str(sent, "traceparent") orelse "";
    try testing.expect(std.mem.startsWith(u8, tp, "00-") and std.mem.endsWith(u8, tp, "-01"));
}

test "feature telemetry: records failed span" {
    if (!fh.fh_present(&.{ "telemetry", "netsim" })) return;
    const f = sdk.TelemetryFeature.make();
    const tf: *sdk.TelemetryFeature = @ptrCast(@alignCast(f.ptr));
    const nf_feat = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{
        .{ .feat = nf_feat, .options = h.jo(&.{ .{ "failTimes", h.vnum(1) }, .{ "failStatus", h.vnum(500) } }) },
        .{ .feat = f, .options = vnull() },
    });
    _ = hh.op(.{ .op = "load" });
    try testing.expect(tf.spans.items.len == 1);
    try testing.expect((h.get_bool(tf.spans.items[0], "ok") orelse true) == false);
}

test "feature telemetry: injected idgen and clock" {
    if (!fh.fh_present(&.{"telemetry"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.TelemetryFeature.make();
    const tf: *sdk.TelemetryFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "idgen", fh.suffixFn("-X") },
        .{ "now", clock.now_fn() },
    }) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.veq(h.getp(tf.spans.items[0], "traceId"), h.vstr("trace-X")));
    try testing.expect(h.veq(h.getp(tf.spans.items[0], "durationMs"), h.vnum(0)));
}

test "feature telemetry: inactive records nothing" {
    if (!fh.fh_present(&.{"telemetry"})) return;
    const f = sdk.TelemetryFeature.make();
    const tf: *sdk.TelemetryFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(tf.spans.items.len == 0);
}

// =====================================================================
// debug
// =====================================================================

test "feature debug: redacts and honours onentry max" {
    if (!fh.fh_present(&.{"debug"})) return;
    const seen = fh.Collector.new();
    const f = sdk.DebugFeature.make();
    const df: *sdk.DebugFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "max", h.vnum(1) },
        .{ "onEntry", seen.fn_val() },
    }) }});
    _ = hh.op(.{ .op = "load", .headers = h.jo(&.{.{ "authorization", h.vstr("Bearer secret") }}) });
    _ = hh.op(.{ .op = "list" });
    try testing.expect(df.entries.items.len == 1);
    try testing.expect(seen.len() == 2);
    const hdrs = h.getp(seen.at(0), "headers");
    try testing.expect(h.veq(h.getp(hdrs, "authorization"), h.vstr("<redacted>")));
}

test "feature debug: captures failures" {
    if (!fh.fh_present(&.{ "debug", "netsim" })) return;
    const f = sdk.DebugFeature.make();
    const df: *sdk.DebugFeature = @ptrCast(@alignCast(f.ptr));
    const nf_feat = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{
        .{ .feat = nf_feat, .options = h.jo(&.{ .{ "failTimes", h.vnum(1) }, .{ "failStatus", h.vnum(500) } }) },
        .{ .feat = f, .options = vnull() },
    });
    _ = hh.op(.{ .op = "load" });
    try testing.expect(df.entries.items.len == 1);
    try testing.expect((h.get_bool(df.entries.items[0], "ok") orelse true) == false);
}

test "feature debug: injected clock and custom redact" {
    if (!fh.fh_present(&.{"debug"})) return;
    const clock = fh.FhClock.new();
    const f = sdk.DebugFeature.make();
    const df: *sdk.DebugFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{
        .{ "now", clock.now_fn() },
        .{ "redact", h.ja(&.{h.vstr("x-secret")}) },
    }) }});
    _ = hh.op(.{ .op = "load", .headers = h.jo(&.{
        .{ "x-secret", h.vstr("hide") },
        .{ "x-ok", h.vstr("show") },
    }) });
    const hdrs = h.getp(df.entries.items[0], "headers");
    try testing.expect(h.veq(h.getp(hdrs, "x-secret"), h.vstr("<redacted>")));
    try testing.expect(h.veq(h.getp(hdrs, "x-ok"), h.vstr("show")));
}

test "feature debug: inactive records nothing" {
    if (!fh.fh_present(&.{"debug"})) return;
    const f = sdk.DebugFeature.make();
    const df: *sdk.DebugFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(df.entries.items.len == 0);
}

// =====================================================================
// audit
// =====================================================================

test "feature audit: one record per op sink actor" {
    if (!fh.fh_present(&.{ "audit", "netsim" })) return;
    const sunk = fh.Collector.new();
    const f = sdk.AuditFeature.make();
    const af: *sdk.AuditFeature = @ptrCast(@alignCast(f.ptr));
    const nf_feat = sdk.NetsimFeature.make();
    const hh = fh.fh_make(null, &.{
        .{ .feat = nf_feat, .options = h.jo(&.{ .{ "failTimes", h.vnum(1) }, .{ "failStatus", h.vnum(500) } }) },
        .{ .feat = f, .options = h.jo(&.{
            .{ "actor", h.vstr("svc") },
            .{ "max", h.vnum(5) },
            .{ "sink", sunk.fn_val() },
        }) },
    });
    _ = hh.op(.{ .op = "remove", .path = "/w/1" });
    _ = hh.op(.{ .op = "load", .ctrl = h.jo(&.{.{ "actor", h.vstr("per-call") }}) });
    try testing.expect(af.records.items.len == 2);
    try testing.expect(h.veq(h.getp(af.records.items[0], "outcome"), h.vstr("error")));
    try testing.expect(h.veq(h.getp(af.records.items[0], "actor"), h.vstr("svc")));
    try testing.expect(h.veq(h.getp(af.records.items[1], "actor"), h.vstr("per-call")));
    try testing.expect(sunk.len() == 2);
}

test "feature audit: default actor anonymous" {
    if (!fh.fh_present(&.{"audit"})) return;
    const f = sdk.AuditFeature.make();
    const af: *sdk.AuditFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.veq(h.getp(af.records.items[0], "actor"), h.vstr("anonymous")));
}

test "feature audit: injected clock" {
    if (!fh.fh_present(&.{"audit"})) return;
    const f = sdk.AuditFeature.make();
    const af: *sdk.AuditFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "now", fh.constFn(h.vnum(42)) }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.veq(h.getp(af.records.items[0], "ts"), h.vnum(42)));
}

test "feature audit: inactive records nothing" {
    if (!fh.fh_present(&.{"audit"})) return;
    const f = sdk.AuditFeature.make();
    const af: *sdk.AuditFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(af.records.items.len == 0);
}

// =====================================================================
// clienttrack
// =====================================================================

test "feature clienttrack: stable client id unique request ids ua" {
    if (!fh.fh_present(&.{"clienttrack"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.ClienttrackFeature.make();
    const cf: *sdk.ClienttrackFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "clientName", h.vstr("Acme") },
        .{ "clientVersion", h.vstr("2.0.0") },
    }) }});
    _ = hh.op(.{ .op = "load" });
    _ = hh.op(.{ .op = "load" });
    const h0 = fh.rec_headers(rec, 0);
    const h1 = fh.rec_headers(rec, 1);
    try testing.expect(h.veq(h.getp(h0, "User-Agent"), h.vstr("Acme/2.0.0")));
    try testing.expect(h.veq(h.getp(h0, "X-Client-Id"), h.getp(h1, "X-Client-Id")));
    try testing.expect(!h.veq(h.getp(h0, "X-Request-Id"), h.getp(h1, "X-Request-Id")));
    try testing.expect(cf.requests == 2);
}

test "feature clienttrack: does not clobber caller ua" {
    if (!fh.fh_present(&.{"clienttrack"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.ClienttrackFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "load", .headers = h.jo(&.{.{ "User-Agent", h.vstr("mine") }}) });
    try testing.expect(h.veq(h.getp(fh.rec_headers(rec, 0), "User-Agent"), h.vstr("mine")));
}

test "feature clienttrack: injected idgen fixed session" {
    if (!fh.fh_present(&.{"clienttrack"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.ClienttrackFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "sessionId", h.vstr("S1") },
        .{ "idgen", fh.suffixFn("-1") },
    }) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.veq(h.getp(fh.rec_headers(rec, 0), "X-Client-Id"), h.vstr("S1")));
    try testing.expect(h.veq(h.getp(fh.rec_headers(rec, 0), "X-Request-Id"), h.vstr("request-1")));
}

test "feature clienttrack: inactive stamps nothing" {
    if (!fh.fh_present(&.{"clienttrack"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.ClienttrackFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.is_noval(h.getp(fh.rec_headers(rec, 0), "X-Client-Id")));
}

// =====================================================================
// paging
// =====================================================================

test "feature paging: stamps page limit and reads headers" {
    if (!fh.fh_present(&.{"paging"})) return;
    const rec = fh.Recorder.new(replyPaging);
    const f = sdk.PagingFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "limit", h.vnum(2) }}) }});
    const res = hh.op(.{ .op = "list", .path = "/w" });
    const url = fh.rec_url(rec, 0);
    try testing.expect(std.mem.indexOf(u8, url, "page=1") != null);
    try testing.expect(std.mem.indexOf(u8, url, "limit=2") != null);
    const paging = res.result.?.paging;
    try testing.expect(h.veq(h.getp(paging, "nextPage"), h.vnum(2)));
    try testing.expect(h.veq(h.getp(paging, "totalCount"), h.vnum(5)));
    try testing.expect(h.veq(h.getp(paging, "next"), h.vstr("/w?page=2")));
}

test "feature paging: body cursor and explicit cursor" {
    if (!fh.fh_present(&.{"paging"})) return;
    const rec = fh.Recorder.new(replyCursor);
    const f = sdk.PagingFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    const res = hh.op(.{
        .op = "list",
        .path = "/w",
        .ctrl = h.jo(&.{.{ "paging", h.jo(&.{.{ "cursor", h.vstr("xyz") }}) }}),
    });
    try testing.expect(std.mem.indexOf(u8, fh.rec_url(rec, 0), "cursor=xyz") != null);
    const paging = res.result.?.paging;
    try testing.expect(h.veq(h.getp(paging, "cursor"), h.vstr("abc")));
    try testing.expect(h.veq(h.getp(paging, "hasMore"), h.vbool(true)));
}

test "feature paging: non-list not paged" {
    if (!fh.fh_present(&.{"paging"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.PagingFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "load", .path = "/w/1" });
    try testing.expect(std.mem.indexOf(u8, fh.rec_url(rec, 0), "page=") == null);
}

test "feature paging: inactive stamps nothing" {
    if (!fh.fh_present(&.{"paging"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.PagingFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    _ = hh.op(.{ .op = "list", .path = "/w" });
    try testing.expect(std.mem.indexOf(u8, fh.rec_url(rec, 0), "page=") == null);
}

// =====================================================================
// streaming
// =====================================================================

test "feature streaming: streams list items" {
    if (!fh.fh_present(&.{"streaming"})) return;
    const clock = fh.FhClock.new();
    const rec = fh.Recorder.new(replyStreamItems);
    const f = sdk.StreamingFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "chunkDelay", h.vnum(5) },
        .{ "sleep", clock.sleep_fn() },
    }) }});
    const res = hh.op(.{ .op = "list", .path = "/w" });
    try testing.expect(res.result.?.streaming);
    const sf = res.result.?.stream orelse unreachable;
    const seen = sf.call(sf.ctx);
    try testing.expect(h.veq(h.ja(seen), h.ja(&.{ h.vstr("a"), h.vstr("b"), h.vstr("c") })));
    try testing.expect(clock.now() == 15);
}

test "feature streaming: batches with chunksize" {
    if (!fh.fh_present(&.{"streaming"})) return;
    const rec = fh.Recorder.new(replyStreamNums);
    const f = sdk.StreamingFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "chunkSize", h.vnum(2) }}) }});
    const res = hh.op(.{ .op = "list", .path = "/w" });
    const sf = res.result.?.stream orelse unreachable;
    const batches = sf.call(sf.ctx);
    const want = h.ja(&.{
        h.ja(&.{ h.vnum(1), h.vnum(2) }),
        h.ja(&.{ h.vnum(3), h.vnum(4) }),
        h.ja(&.{h.vnum(5)}),
    });
    try testing.expect(h.veq(h.ja(batches), want));
}

test "feature streaming: non-list not streamed" {
    if (!fh.fh_present(&.{"streaming"})) return;
    const f = sdk.StreamingFeature.make();
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = vnull() }});
    const res = hh.op(.{ .op = "load" });
    try testing.expect(!res.result.?.streaming);
    try testing.expect(res.result.?.stream == null);
}

test "feature streaming: inactive is noop" {
    if (!fh.fh_present(&.{"streaming"})) return;
    const f = sdk.StreamingFeature.make();
    const sf: *sdk.StreamingFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(null, &.{.{ .feat = f, .options = h.jo(&.{.{ "active", h.vbool(false) }}) }});
    const res = hh.op(.{ .op = "list", .path = "/w" });
    try testing.expect(!res.result.?.streaming);
    try testing.expect(sf.opened == 0);
}

// =====================================================================
// proxy
// =====================================================================

test "feature proxy: routes through proxy" {
    if (!fh.fh_present(&.{"proxy"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.ProxyFeature.make();
    const pf: *sdk.ProxyFeature = @ptrCast(@alignCast(f.ptr));
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{.{ "url", h.vstr("http://proxy:8080") }}) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.veq(h.getp(fh.rec_fetchdef(rec, 0), "proxy"), h.vstr("http://proxy:8080")));
    try testing.expect(pf.track.routed == 1);
}

test "feature proxy: bypasses noproxy hosts" {
    if (!fh.fh_present(&.{"proxy"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.ProxyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "url", h.vstr("http://proxy:8080") },
        .{ "noProxy", h.ja(&.{h.vstr("api.test")}) },
    }) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.is_noval(h.getp(fh.rec_fetchdef(rec, 0), "proxy")));
}

test "feature proxy: fromenv respects explicit url" {
    if (!fh.fh_present(&.{"proxy"})) return;
    // fromEnv only consults the environment when no explicit url is given, so
    // an explicit url must win — a deterministic stand-in for the donor's
    // HTTPS_PROXY env test (zig's captured environ cannot be mutated at
    // runtime the way rust's std::env::set_var can).
    const rec = fh.Recorder.new(null);
    const f = sdk.ProxyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "fromEnv", h.vbool(true) },
        .{ "url", h.vstr("http://proxy:8080") },
    }) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.veq(h.getp(fh.rec_fetchdef(rec, 0), "proxy"), h.vstr("http://proxy:8080")));
}

test "feature proxy: no url is noop" {
    if (!fh.fh_present(&.{"proxy"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.ProxyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = vnull() }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.is_noval(h.getp(fh.rec_fetchdef(rec, 0), "proxy")));
}

test "feature proxy: inactive does not wrap" {
    if (!fh.fh_present(&.{"proxy"})) return;
    const rec = fh.Recorder.new(null);
    const f = sdk.ProxyFeature.make();
    const hh = fh.fh_make(rec.fetcher(), &.{.{ .feat = f, .options = h.jo(&.{
        .{ "active", h.vbool(false) },
        .{ "url", h.vstr("http://proxy:8080") },
    }) }});
    _ = hh.op(.{ .op = "load" });
    try testing.expect(h.is_noval(h.getp(fh.rec_fetchdef(rec, 0), "proxy")));
}

// =====================================================================
// composition + support
// =====================================================================

test "feature composition: cache hit skips simulated failure" {
    if (!fh.fh_present(&.{ "cache", "netsim" })) return;
    const nf_feat = sdk.NetsimFeature.make();
    const nf: *sdk.NetsimFeature = @ptrCast(@alignCast(nf_feat.ptr));
    const cf_feat = sdk.CacheFeature.make();
    const hh = fh.fh_make(null, &.{
        .{ .feat = nf_feat, .options = h.jo(&.{.{ "failEvery", h.vnum(2) }}) },
        .{ .feat = cf_feat, .options = h.jo(&.{.{ "ttl", h.vnum(10000) }}) },
    });
    try testing.expect(hh.op(.{ .op = "load", .path = "/w" }).ok);
    try testing.expect(hh.op(.{ .op = "load", .path = "/w" }).ok);
    try testing.expect(nf.track.calls == 1);
}

test "feature support smoke" {
    try testing.expect(std.mem.eql(u8, h.stringify(h.vstr("x")), "x"));
}
