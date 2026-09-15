package JAVAPACKAGE.sdktest;

// Behavioural tests for the enterprise features shipped with this SDK
// (retry, cache, rbac, telemetry, ...), driven through the offline
// feature-test harness (FeatureHarness). Each block runs only when its
// feature is present in this SDK (see assumeFeatures). Mirrors
// tm/go/test/feature_test.go.

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import static JAVAPACKAGE.sdktest.FeatureHarness.FhClock;
import static JAVAPACKAGE.sdktest.FeatureHarness.FhFeature;
import static JAVAPACKAGE.sdktest.FeatureHarness.FhHarness;
import static JAVAPACKAGE.sdktest.FeatureHarness.FhOpResult;
import static JAVAPACKAGE.sdktest.FeatureHarness.FhRecorder;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhErrCode;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhF;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhHasFeature;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhMake;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhMap;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhOp;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhResponse;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import java.util.function.Function;
import java.util.function.IntConsumer;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.regex.Pattern;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.feature.AuditFeature;
import JAVAPACKAGE.feature.CacheFeature;
import JAVAPACKAGE.feature.ClienttrackFeature;
import JAVAPACKAGE.feature.DebugFeature;
import JAVAPACKAGE.feature.IdempotencyFeature;
import JAVAPACKAGE.feature.MetricsFeature;
import JAVAPACKAGE.feature.NetsimFeature;
import JAVAPACKAGE.feature.PagingFeature;
import JAVAPACKAGE.feature.ProxyFeature;
import JAVAPACKAGE.feature.RatelimitFeature;
import JAVAPACKAGE.feature.RbacFeature;
import JAVAPACKAGE.feature.RetryFeature;
import JAVAPACKAGE.feature.StreamingFeature;
import JAVAPACKAGE.feature.TelemetryFeature;
import JAVAPACKAGE.feature.TimeoutFeature;

@SuppressWarnings({"unchecked"})
public class FeatureTest {

  static void assumeFeatures(String... names) {
    for (String name : names) {
      Assumptions.assumeTrue(fhHasFeature(name),
          "feature not present in this SDK: " + name);
    }
  }

  // --- netsim -----------------------------------------------------------------

  @Test
  public void netsim_fixedLatencyThenDelegate() {
    assumeFeatures("netsim");
    FhClock clock = new FhClock();
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap(
        "latency", 250, "sleep", (IntConsumer) clock::sleep)));
    FhOpResult res = h.op(fhOp("load").ctrl(fhMap("explain", new LinkedHashMap<>())));
    assertTrue(res.ok, "expected ok, got err: " + res.err);
    assertEquals(250, clock.t, "expected 250ms latency");
    assertEquals(1, f.calls, "expected 1 call");
  }

  @Test
  public void netsim_rangedLatencyInMinMax() {
    assumeFeatures("netsim");
    FhClock clock = new FhClock();
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap(
        "latency", fhMap("min", 100, "max", 300),
        "seed", 7,
        "sleep", (IntConsumer) clock::sleep)));
    h.op(fhOp("load"));
    assertTrue(clock.t >= 100 && clock.t < 300,
        "expected latency in [100,300), got " + clock.t);
  }

  @Test
  public void netsim_equalMinMaxLatencyExact() {
    assumeFeatures("netsim");
    FhClock clock = new FhClock();
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap(
        "latency", fhMap("min", 50, "max", 50),
        "sleep", (IntConsumer) clock::sleep)));
    h.op(fhOp("load"));
    assertEquals(50, clock.t, "expected exactly 50ms");
  }

  @Test
  public void netsim_failTimesReturnsRetryableStatus() {
    assumeFeatures("netsim");
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("failTimes", 2, "failStatus", 503)));
    assertEquals(503, h.op(fhOp("load")).result.status);
    assertEquals(503, h.op(fhOp("load")).result.status);
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected third call to succeed, got err: " + res.err);
  }

  @Test
  public void netsim_failEveryFailsEveryNth() {
    assumeFeatures("netsim");
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("failEvery", 2)));
    assertTrue(h.op(fhOp("load")).ok, "call 1 should succeed");
    assertFalse(h.op(fhOp("load")).ok, "call 2 should fail");
    assertTrue(h.op(fhOp("load")).ok, "call 3 should succeed");
  }

  @Test
  public void netsim_failRateWithSeedDeterministic() {
    assumeFeatures("netsim");
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("failRate", 1, "seed", 5)));
    assertFalse(h.op(fhOp("load")).ok, "expected deterministic failure");
  }

  @Test
  public void netsim_errorTimesConnectionError() {
    assumeFeatures("netsim");
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("errorTimes", 1)));
    FhOpResult res = h.op(fhOp("load"));
    assertEquals("netsim_conn", fhErrCode(res.err));
  }

  @Test
  public void netsim_offlineFailsEveryCall() {
    assumeFeatures("netsim");
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("offline", true)));
    FhOpResult res = h.op(fhOp("load"));
    assertEquals("netsim_offline", fhErrCode(res.err));
  }

  @Test
  public void netsim_rateLimitTimes429RetryAfter() {
    assumeFeatures("netsim");
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("rateLimitTimes", 1, "retryAfter", 3)));
    FhOpResult res = h.op(fhOp("load"));
    assertEquals(429, res.result.status);
    assertEquals("3", res.result.headers.get("retry-after"));
  }

  @Test
  public void netsim_inactiveDoesNotWrap() {
    assumeFeatures("netsim");
    NetsimFeature f = new NetsimFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("active", false, "offline", true)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "inactive netsim must not simulate: " + res.err);
    assertEquals(0, f.calls, "expected 0 simulated calls");
  }

  // --- retry ------------------------------------------------------------------

  @Test
  public void retry_retriesTransientThenSucceeds() {
    assumeFeatures("retry", "netsim");
    FhClock clock = new FhClock();
    RetryFeature rf = new RetryFeature();
    FhHarness h = fhMake(null,
        fhF(new NetsimFeature(), fhMap("failTimes", 2, "failStatus", 503)),
        fhF(rf, fhMap("retries", 3, "minDelay", 10, "jitter", false,
            "sleep", (IntConsumer) clock::sleep)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected success after retries: " + res.err);
    assertEquals(2, rf.attempts, "expected 2 retries");
  }

  @Test
  public void retry_givesUpAfterBudget() {
    assumeFeatures("retry", "netsim");
    FhClock clock = new FhClock();
    RetryFeature rf = new RetryFeature();
    FhHarness h = fhMake(null,
        fhF(new NetsimFeature(), fhMap("failTimes", 9, "failStatus", 500)),
        fhF(rf, fhMap("retries", 2, "minDelay", 1, "jitter", false,
            "sleep", (IntConsumer) clock::sleep)));
    FhOpResult res = h.op(fhOp("load"));
    assertEquals(500, res.result.status, "expected final 500");
  }

  @Test
  public void retry_doesNotRetryNonRetryableStatus() {
    assumeFeatures("retry");
    FhRecorder rec = new FhRecorder();
    rec.reply = (n, fetchdef) -> fhResponse(404, null, null);
    FhHarness h = fhMake(rec::fetch,
        fhF(new RetryFeature(), fhMap("retries", 3, "minDelay", 0)));
    h.op(fhOp("load"));
    assertEquals(1, rec.calls.size(), "expected 1 call");
  }

  @Test
  public void retry_retriesTransportErrorThenReturnsIt() {
    assumeFeatures("retry");
    FhClock clock = new FhClock();
    final int[] n = { 0 };
    FhHarness h = fhMake(
        (ctx, url, fetchdef) -> {
          n[0]++;
          throw ctx.makeError("boom", "boom");
        },
        fhF(new RetryFeature(), fhMap("retries", 2, "minDelay", 1, "jitter", false,
            "sleep", (IntConsumer) clock::sleep)));
    FhOpResult res = h.op(fhOp("load"));
    assertFalse(res.ok, "expected failure");
    assertEquals(3, n[0], "expected 3 attempts");
  }

  @Test
  public void retry_retriesNilTransportResult() {
    assumeFeatures("retry");
    final int[] n = { 0 };
    FhHarness h = fhMake(
        (ctx, url, fetchdef) -> {
          n[0]++;
          if (n[0] < 2) {
            return null;
          }
          return fhResponse(200, fhMap("ok", true), null);
        },
        fhF(new RetryFeature(), fhMap("retries", 3, "minDelay", 0)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected success, got " + res.err);
    assertEquals(2, n[0], "expected 2 attempts");
  }

  @Test
  public void retry_honoursServerRetryAfter() {
    assumeFeatures("retry", "netsim");
    FhClock clock = new FhClock();
    FhHarness h = fhMake(null,
        fhF(new NetsimFeature(), fhMap("rateLimitTimes", 1, "retryAfter", 2)),
        fhF(new RetryFeature(), fhMap(
            "retries", 2, "minDelay", 10, "maxDelay", 60000,
            "jitter", false, "sleep", (IntConsumer) clock::sleep)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected success: " + res.err);
    assertEquals(2000, clock.t, "expected 2000ms Retry-After wait");
  }

  @Test
  public void retry_inactiveDoesNotWrap() {
    assumeFeatures("retry");
    FhRecorder rec = new FhRecorder();
    rec.reply = (n, fetchdef) -> fhResponse(503, null, null);
    FhHarness h = fhMake(rec::fetch, fhF(new RetryFeature(), fhMap("active", false)));
    h.op(fhOp("load"));
    assertEquals(1, rec.calls.size(), "expected 1 call");
  }

  // --- timeout ----------------------------------------------------------------

  @Test
  public void timeout_slowRequestTimesOut() {
    assumeFeatures("timeout");
    TimeoutFeature f = new TimeoutFeature();
    FhHarness h = fhMake(
        (ctx, url, fetchdef) -> {
          try {
            Thread.sleep(60);
          }
          catch (InterruptedException e) {
            Thread.currentThread().interrupt();
          }
          return fhResponse(200, fhMap("ok", true), null);
        },
        fhF(f, fhMap("ms", 10)));
    FhOpResult res = h.op(fhOp("load"));
    assertEquals("timeout", fhErrCode(res.err), "expected timeout error, got " + res.err);
    assertEquals(1, f.count, "expected 1 timeout");
  }

  @Test
  public void timeout_fastRequestPasses() {
    assumeFeatures("timeout");
    FhHarness h = fhMake(null, fhF(new TimeoutFeature(), fhMap("ms", 1000)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected success: " + res.err);
  }

  @Test
  public void timeout_msZeroDisables() {
    assumeFeatures("timeout");
    FhHarness h = fhMake(null, fhF(new TimeoutFeature(), fhMap("ms", 0)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected success: " + res.err);
  }

  @Test
  public void timeout_inactiveDoesNotWrap() {
    assumeFeatures("timeout");
    FhHarness h = fhMake(null, fhF(new TimeoutFeature(), fhMap("active", false)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected success: " + res.err);
  }

  // --- ratelimit ----------------------------------------------------------------

  @Test
  public void ratelimit_throttlesOnceBurstSpent() {
    assumeFeatures("ratelimit");
    FhClock clock = new FhClock();
    RatelimitFeature f = new RatelimitFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap(
        "rate", 1, "burst", 2,
        "now", (LongSupplier) clock::now,
        "sleep", (IntConsumer) clock::sleep)));
    h.op(fhOp("load"));
    h.op(fhOp("load"));
    h.op(fhOp("load"));
    assertEquals(1, f.throttled, "expected 1 throttle");
    assertTrue(clock.t > 0, "expected the clock to advance while throttled");
  }

  @Test
  public void ratelimit_burstDefaultsToRateAndRefills() {
    assumeFeatures("ratelimit");
    FhClock clock = new FhClock();
    RatelimitFeature f = new RatelimitFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap(
        "rate", 2,
        "now", (LongSupplier) clock::now,
        "sleep", (IntConsumer) clock::sleep)));
    h.op(fhOp("load"));
    h.op(fhOp("load"));
    clock.advance(1000); // refill
    h.op(fhOp("load"));
    assertEquals(0, f.throttled, "expected no throttling after refill");
  }

  @Test
  public void ratelimit_inactiveDoesNotWrap() {
    assumeFeatures("ratelimit");
    RatelimitFeature f = new RatelimitFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("active", false)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected success: " + res.err);
    assertEquals(0, f.throttled, "expected no throttling");
  }

  // --- cache --------------------------------------------------------------------

  @Test
  public void cache_servesRepeatedReadFromCache() {
    assumeFeatures("cache");
    FhRecorder rec = new FhRecorder();
    CacheFeature f = new CacheFeature();
    FhHarness h = fhMake(rec::fetch, fhF(f, fhMap("ttl", 10000)));
    FhOpResult a = h.op(fhOp("load").path("/w/1"));
    FhOpResult b = h.op(fhOp("load").path("/w/1"));
    assertEquals(1, rec.calls.size(), "expected 1 network call");
    assertEquals(RunnerSupport.canon(a.data), RunnerSupport.canon(b.data),
        "expected identical cached data");
    assertEquals(1, f.hit, "expected 1 hit");
  }

  @Test
  public void cache_doesNotCacheNonGet() {
    assumeFeatures("cache");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new CacheFeature(), null));
    h.op(fhOp("create").path("/w"));
    h.op(fhOp("create").path("/w"));
    assertEquals(2, rec.calls.size(), "expected 2 calls");
  }

  @Test
  public void cache_doesNotCacheNon2xx() {
    assumeFeatures("cache");
    FhRecorder rec = new FhRecorder();
    rec.reply = (n, fetchdef) -> fhResponse(500, null, null);
    CacheFeature f = new CacheFeature();
    FhHarness h = fhMake(rec::fetch, fhF(f, null));
    h.op(fhOp("load").path("/w"));
    h.op(fhOp("load").path("/w"));
    assertEquals(2, rec.calls.size(), "expected 2 calls");
    assertEquals(2, f.bypass, "expected 2 bypasses");
  }

  @Test
  public void cache_refetchesAfterTtl() {
    assumeFeatures("cache");
    FhClock clock = new FhClock();
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new CacheFeature(),
        fhMap("ttl", 1000, "now", (LongSupplier) clock::now)));
    h.op(fhOp("load").path("/w"));
    clock.advance(1500);
    h.op(fhOp("load").path("/w"));
    assertEquals(2, rec.calls.size(), "expected 2 calls after ttl expiry");
  }

  @Test
  public void cache_evictsOldestPastMax() {
    assumeFeatures("cache");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new CacheFeature(),
        fhMap("ttl", 10000, "max", 1)));
    h.op(fhOp("load").path("/a"));
    h.op(fhOp("load").path("/b")); // evicts /a
    h.op(fhOp("load").path("/a")); // miss again
    assertEquals(3, rec.calls.size(), "expected 3 calls");
  }

  @Test
  public void cache_inactiveDoesNotWrap() {
    assumeFeatures("cache");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new CacheFeature(), fhMap("active", false)));
    h.op(fhOp("load").path("/x"));
    h.op(fhOp("load").path("/x"));
    assertEquals(2, rec.calls.size(), "expected 2 calls");
  }

  // --- idempotency ----------------------------------------------------------------

  @Test
  public void idempotency_addsKeyToMutatingOps() {
    assumeFeatures("idempotency");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new IdempotencyFeature(), null));
    h.op(fhOp("create").path("/w"));
    assertNotNull(rec.headers(0).get("Idempotency-Key"),
        "expected Idempotency-Key header on create");
  }

  @Test
  public void idempotency_addsKeyByHttpMethod() {
    assumeFeatures("idempotency");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new IdempotencyFeature(), null));
    h.op(fhOp("act").method("PUT").path("/w"));
    assertNotNull(rec.headers(0).get("Idempotency-Key"),
        "expected Idempotency-Key header on PUT");
  }

  @Test
  public void idempotency_leavesReadsUntouched() {
    assumeFeatures("idempotency");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new IdempotencyFeature(), null));
    h.op(fhOp("load").path("/w/1"));
    assertNull(rec.headers(0).get("Idempotency-Key"),
        "expected no Idempotency-Key header on load");
  }

  @Test
  public void idempotency_preservesCallerKeyCustomHeader() {
    assumeFeatures("idempotency");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new IdempotencyFeature(),
        fhMap("header", "X-Idem")));
    h.op(fhOp("create").path("/w").headers(fhMap("X-Idem", "caller-1")));
    assertEquals("caller-1", rec.headers(0).get("X-Idem"),
        "expected caller key preserved");
  }

  @Test
  public void idempotency_injectedKeygen() {
    assumeFeatures("idempotency");
    FhRecorder rec = new FhRecorder();
    IdempotencyFeature f = new IdempotencyFeature();
    FhHarness h = fhMake(rec::fetch, fhF(f, fhMap(
        "keygen", (Supplier<Object>) () -> "K1")));
    h.op(fhOp("create").path("/w"));
    assertEquals("K1", rec.headers(0).get("Idempotency-Key"), "expected injected key");
    assertEquals(1, f.issued, "expected 1 issued");
    assertEquals("K1", f.last, "expected last K1");
  }

  @Test
  public void idempotency_inactiveIsNoop() {
    assumeFeatures("idempotency");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new IdempotencyFeature(), fhMap("active", false)));
    h.op(fhOp("create").path("/w"));
    assertNull(rec.headers(0).get("Idempotency-Key"),
        "inactive idempotency must not add a key");
  }

  // --- rbac -----------------------------------------------------------------------

  @Test
  public void rbac_deniesBeforeAnyCall() {
    assumeFeatures("rbac");
    FhRecorder rec = new FhRecorder();
    RbacFeature f = new RbacFeature();
    FhHarness h = fhMake(rec::fetch, fhF(f, fhMap(
        "rules", fhMap("widget.remove", "admin"),
        "permissions", new ArrayList<>())));
    FhOpResult res = h.op(fhOp("remove").path("/w/1"));
    assertEquals("rbac_denied", fhErrCode(res.err));
    assertEquals(0, rec.calls.size(), "expected no network calls");
    assertEquals(1, f.denied, "expected 1 denial");
  }

  @Test
  public void rbac_allowsHeldPermission() {
    assumeFeatures("rbac");
    List<Object> perms = new ArrayList<>();
    perms.add("admin");
    FhHarness h = fhMake(null, fhF(new RbacFeature(), fhMap(
        "rules", fhMap("widget.remove", "admin"),
        "permissions", perms)));
    FhOpResult res = h.op(fhOp("remove").path("/w/1"));
    assertTrue(res.ok, "expected allow: " + res.err);
  }

  @Test
  public void rbac_opRuleAndWildcardGrant() {
    assumeFeatures("rbac");
    List<Object> perms = new ArrayList<>();
    perms.add("*");
    FhHarness h = fhMake(null, fhF(new RbacFeature(), fhMap(
        "rules", fhMap("load", "read"),
        "permissions", perms)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected wildcard grant: " + res.err);
  }

  @Test
  public void rbac_defaultAllowAndDenyTrue() {
    assumeFeatures("rbac");
    FhHarness allow = fhMake(null, fhF(new RbacFeature(), fhMap(
        "permissions", new ArrayList<>())));
    FhOpResult allowRes = allow.op(fhOp("load"));
    assertTrue(allowRes.ok, "expected default allow: " + allowRes.err);

    FhHarness deny = fhMake(null, fhF(new RbacFeature(), fhMap(
        "deny", true,
        "permissions", new ArrayList<>())));
    FhOpResult denyRes = deny.op(fhOp("load"));
    assertEquals("rbac_denied", fhErrCode(denyRes.err), "expected default deny");
  }

  @Test
  public void rbac_inactiveIsNoop() {
    assumeFeatures("rbac");
    FhHarness h = fhMake(null, fhF(new RbacFeature(), fhMap(
        "active", false, "deny", true)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "inactive rbac must not deny: " + res.err);
  }

  // --- metrics --------------------------------------------------------------------

  @Test
  public void metrics_countsOkAndErrPerOp() {
    assumeFeatures("metrics", "netsim");
    MetricsFeature f = new MetricsFeature();
    FhHarness h = fhMake(null,
        fhF(new NetsimFeature(), fhMap("failTimes", 1, "failStatus", 500)),
        fhF(f, null));
    h.op(fhOp("load"));
    h.op(fhOp("load"));
    h.op(fhOp("list"));
    assertEquals(3, f.total.count, "expected total 3");
    assertEquals(2, f.total.ok, "expected 2 ok");
    assertEquals(1, f.total.err, "expected 1 err");
    assertNotNull(f.ops.get("widget.load"), "expected widget.load bucket");
    assertEquals(2, f.ops.get("widget.load").count, "expected widget.load count 2");
  }

  @Test
  public void metrics_injectedClock() {
    assumeFeatures("metrics");
    FhClock clock = new FhClock();
    MetricsFeature f = new MetricsFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("now", (LongSupplier) clock::now)));
    h.op(fhOp("load"));
    assertEquals(1, f.total.count, "expected 1 recorded op");
    assertEquals(0, f.total.totalMs, "expected 0ms with frozen clock");
  }

  @Test
  public void metrics_inactiveRecordsNothing() {
    assumeFeatures("metrics");
    MetricsFeature f = new MetricsFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("active", false)));
    h.op(fhOp("load"));
    assertEquals(0, f.total.count, "expected no records");
  }

  // --- telemetry ------------------------------------------------------------------

  @Test
  public void telemetry_opensSpansAndPropagatesHeaders() {
    assumeFeatures("telemetry");
    FhRecorder rec = new FhRecorder();
    List<Map<String, Object>> exported = new ArrayList<>();
    TelemetryFeature f = new TelemetryFeature();
    FhHarness h = fhMake(rec::fetch, fhF(f, fhMap(
        "exporter", (Consumer<Map<String, Object>>) exported::add)));
    FhOpResult res = h.op(fhOp("load"));
    assertTrue(res.ok, "expected success: " + res.err);
    assertEquals(1, f.spans.size(), "expected 1 span");
    assertEquals(1, exported.size(), "expected 1 export");
    Map<String, Object> sent = rec.headers(0);
    assertEquals(f.spans.get(0).get("traceId"), sent.get("X-Trace-Id"),
        "expected propagated trace id");
    String traceparent = sent.get("traceparent") instanceof String
        ? (String) sent.get("traceparent") : "";
    assertTrue(Pattern.compile("^00-.+-.+-01$").matcher(traceparent).find(),
        "expected W3C traceparent, got " + traceparent);
  }

  @Test
  public void telemetry_recordsFailedSpan() {
    assumeFeatures("telemetry", "netsim");
    TelemetryFeature f = new TelemetryFeature();
    FhHarness h = fhMake(null,
        fhF(new NetsimFeature(), fhMap("failTimes", 1, "failStatus", 500)),
        fhF(f, null));
    h.op(fhOp("load"));
    assertEquals(1, f.spans.size(), "expected 1 span");
    assertEquals(false, f.spans.get(0).get("ok"), "expected failed span");
  }

  @Test
  public void telemetry_injectedIdgenAndClock() {
    assumeFeatures("telemetry");
    FhClock clock = new FhClock();
    TelemetryFeature f = new TelemetryFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap(
        "idgen", (Function<String, String>) (kind) -> kind + "-X",
        "now", (LongSupplier) clock::now)));
    h.op(fhOp("load"));
    assertEquals("trace-X", f.spans.get(0).get("traceId"), "expected injected trace id");
    assertEquals(0L, f.spans.get(0).get("durationMs"),
        "expected 0ms span with frozen clock");
  }

  @Test
  public void telemetry_inactiveRecordsNothing() {
    assumeFeatures("telemetry");
    TelemetryFeature f = new TelemetryFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("active", false)));
    h.op(fhOp("load"));
    assertEquals(0, f.spans.size(), "expected no spans");
  }

  // --- debug ----------------------------------------------------------------------

  @Test
  public void debug_redactsAndHonoursOnEntryMax() {
    assumeFeatures("debug");
    List<Map<String, Object>> seen = new ArrayList<>();
    DebugFeature f = new DebugFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap(
        "max", 1,
        "onEntry", (Consumer<Map<String, Object>>) seen::add)));
    h.op(fhOp("load").headers(fhMap("authorization", "Bearer secret")));
    h.op(fhOp("list"));
    assertEquals(1, f.entries.size(), "expected ring buffer capped at 1");
    assertEquals(2, seen.size(), "expected onEntry for both ops");
    Map<String, Object> headers = (Map<String, Object>) seen.get(0).get("headers");
    assertEquals("<redacted>", headers.get("authorization"),
        "expected redacted authorization");
  }

  @Test
  public void debug_capturesFailures() {
    assumeFeatures("debug", "netsim");
    DebugFeature f = new DebugFeature();
    FhHarness h = fhMake(null,
        fhF(new NetsimFeature(), fhMap("failTimes", 1, "failStatus", 500)),
        fhF(f, null));
    h.op(fhOp("load"));
    assertEquals(1, f.entries.size(), "expected 1 entry");
    assertEquals(false, f.entries.get(0).get("ok"), "expected failed entry");
  }

  @Test
  public void debug_injectedClockAndCustomRedact() {
    assumeFeatures("debug");
    FhClock clock = new FhClock();
    DebugFeature f = new DebugFeature();
    List<Object> redact = new ArrayList<>();
    redact.add("x-secret");
    FhHarness h = fhMake(null, fhF(f, fhMap(
        "now", (LongSupplier) clock::now,
        "redact", redact)));
    h.op(fhOp("load").headers(fhMap("x-secret", "hide", "x-ok", "show")));
    Map<String, Object> headers =
        (Map<String, Object>) f.entries.get(0).get("headers");
    assertEquals("<redacted>", headers.get("x-secret"), "expected x-secret redacted");
    assertEquals("show", headers.get("x-ok"), "expected x-ok kept");
  }

  @Test
  public void debug_inactiveRecordsNothing() {
    assumeFeatures("debug");
    DebugFeature f = new DebugFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("active", false)));
    h.op(fhOp("load"));
    assertEquals(0, f.entries.size(), "expected no entries");
  }

  // --- audit ----------------------------------------------------------------------

  @Test
  public void audit_oneRecordPerOpSinkActor() {
    assumeFeatures("audit", "netsim");
    List<Map<String, Object>> sunk = new ArrayList<>();
    AuditFeature f = new AuditFeature();
    FhHarness h = fhMake(null,
        fhF(new NetsimFeature(), fhMap("failTimes", 1, "failStatus", 500)),
        fhF(f, fhMap(
            "actor", "svc",
            "max", 5,
            "sink", (Consumer<Map<String, Object>>) sunk::add)));
    h.op(fhOp("remove").path("/w/1"));
    h.op(fhOp("load").ctrl(fhMap("actor", "per-call")));
    assertEquals(2, f.records.size(), "expected 2 records");
    assertEquals("error", f.records.get(0).get("outcome"), "expected error outcome");
    assertEquals("svc", f.records.get(0).get("actor"), "expected svc actor");
    assertEquals("per-call", f.records.get(1).get("actor"), "expected per-call actor");
    assertEquals(2, sunk.size(), "expected 2 sunk records");
  }

  @Test
  public void audit_defaultActorAnonymous() {
    assumeFeatures("audit");
    AuditFeature f = new AuditFeature();
    FhHarness h = fhMake(null, fhF(f, null));
    h.op(fhOp("load"));
    assertEquals("anonymous", f.records.get(0).get("actor"), "expected anonymous actor");
  }

  @Test
  public void audit_injectedClock() {
    assumeFeatures("audit");
    AuditFeature f = new AuditFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("now", (LongSupplier) () -> 42L)));
    h.op(fhOp("load"));
    assertEquals(42L, f.records.get(0).get("ts"), "expected ts 42");
  }

  @Test
  public void audit_inactiveRecordsNothing() {
    assumeFeatures("audit");
    AuditFeature f = new AuditFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("active", false)));
    h.op(fhOp("load"));
    assertEquals(0, f.records.size(), "expected no records");
  }

  // --- clienttrack ----------------------------------------------------------------

  @Test
  public void clienttrack_stableClientIdUniqueRequestIdsUa() {
    assumeFeatures("clienttrack");
    FhRecorder rec = new FhRecorder();
    ClienttrackFeature f = new ClienttrackFeature();
    FhHarness h = fhMake(rec::fetch, fhF(f, fhMap(
        "clientName", "Acme", "clientVersion", "2.0.0")));
    h.op(fhOp("load"));
    h.op(fhOp("load"));
    Map<String, Object> h0 = rec.headers(0);
    Map<String, Object> h1 = rec.headers(1);
    assertEquals("Acme/2.0.0", h0.get("User-Agent"), "expected Acme/2.0.0 UA");
    assertEquals(h0.get("X-Client-Id"), h1.get("X-Client-Id"),
        "expected stable client id");
    assertNotEquals(h0.get("X-Request-Id"), h1.get("X-Request-Id"),
        "expected fresh request ids");
    assertEquals(2, f.requests, "expected 2 tracked requests");
  }

  @Test
  public void clienttrack_doesNotClobberCallerUa() {
    assumeFeatures("clienttrack");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new ClienttrackFeature(), null));
    h.op(fhOp("load").headers(fhMap("User-Agent", "mine")));
    assertEquals("mine", rec.headers(0).get("User-Agent"),
        "expected caller UA preserved");
  }

  @Test
  public void clienttrack_injectedIdgenFixedSession() {
    assumeFeatures("clienttrack");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new ClienttrackFeature(), fhMap(
        "sessionId", "S1",
        "idgen", (Function<String, String>) (kind) -> kind + "-1")));
    h.op(fhOp("load"));
    assertEquals("S1", rec.headers(0).get("X-Client-Id"), "expected fixed session");
    assertEquals("request-1", rec.headers(0).get("X-Request-Id"),
        "expected injected request id");
  }

  @Test
  public void clienttrack_inactiveStampsNothing() {
    assumeFeatures("clienttrack");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new ClienttrackFeature(), fhMap("active", false)));
    h.op(fhOp("load"));
    assertNull(rec.headers(0).get("X-Client-Id"),
        "inactive clienttrack must not stamp headers");
  }

  // --- paging ---------------------------------------------------------------------

  @Test
  public void paging_stampsPageLimitAndReadsHeaders() {
    assumeFeatures("paging");
    FhRecorder rec = new FhRecorder();
    rec.reply = (n, fetchdef) -> {
      List<Object> items = new ArrayList<>();
      items.add(1);
      items.add(2);
      return fhResponse(200, fhMap("items", items), fhMap(
          "x-next-page", "2",
          "x-total-count", "5",
          "link", "</w?page=2>; rel=\"next\""));
    };
    PagingFeature f = new PagingFeature();
    FhHarness h = fhMake(rec::fetch, fhF(f, fhMap("limit", 2)));
    FhOpResult res = h.op(fhOp("list").path("/w"));
    assertTrue(rec.url(0).contains("page=1"), "expected page=1 stamped: " + rec.url(0));
    assertTrue(rec.url(0).contains("limit=2"), "expected limit=2 stamped: " + rec.url(0));
    Map<String, Object> paging = res.result.paging;
    assertEquals(2, paging.get("nextPage"), "expected nextPage 2");
    assertEquals(5, paging.get("totalCount"), "expected totalCount 5");
    assertEquals("/w?page=2", paging.get("next"), "expected link next");
  }

  @Test
  public void paging_bodyCursorAndExplicitCursor() {
    assumeFeatures("paging");
    FhRecorder rec = new FhRecorder();
    rec.reply = (n, fetchdef) ->
        fhResponse(200, fhMap("nextCursor", "abc", "hasMore", true), null);
    FhHarness h = fhMake(rec::fetch, fhF(new PagingFeature(), null));
    FhOpResult res = h.op(fhOp("list").path("/w")
        .ctrl(fhMap("paging", fhMap("cursor", "xyz"))));
    assertTrue(rec.url(0).contains("cursor=xyz"),
        "expected cursor=xyz stamped: " + rec.url(0));
    assertEquals("abc", res.result.paging.get("cursor"), "expected body cursor");
    assertEquals(true, res.result.paging.get("hasMore"), "expected hasMore");
  }

  @Test
  public void paging_nonListNotPaged() {
    assumeFeatures("paging");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new PagingFeature(), null));
    h.op(fhOp("load").path("/w/1"));
    assertFalse(rec.url(0).contains("page="), "expected no page param: " + rec.url(0));
  }

  @Test
  public void paging_inactiveStampsNothing() {
    assumeFeatures("paging");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new PagingFeature(), fhMap("active", false)));
    h.op(fhOp("list").path("/w"));
    assertFalse(rec.url(0).contains("page="),
        "inactive paging must not stamp: " + rec.url(0));
  }

  // --- streaming ------------------------------------------------------------------

  @Test
  public void streaming_streamsListItems() {
    assumeFeatures("streaming");
    FhClock clock = new FhClock();
    FhRecorder rec = new FhRecorder();
    rec.reply = (n, fetchdef) -> {
      List<Object> items = new ArrayList<>();
      items.add("a");
      items.add("b");
      items.add("c");
      return fhResponse(200, items, null);
    };
    FhHarness h = fhMake(rec::fetch, fhF(new StreamingFeature(),
        fhMap("chunkDelay", 5, "sleep", (IntConsumer) clock::sleep)));
    FhOpResult res = h.op(fhOp("list").path("/w"));
    assertTrue(res.result.streaming, "expected streaming result");
    List<Object> seen = new ArrayList<>();
    Iterator<Object> it = res.result.stream.get();
    while (it.hasNext()) {
      seen.add(it.next());
    }
    assertEquals(List.of("a", "b", "c"), seen, "expected streamed items");
    assertEquals(15, clock.t, "expected 15ms paced delay");
  }

  @Test
  public void streaming_batchesWithChunkSize() {
    assumeFeatures("streaming");
    FhRecorder rec = new FhRecorder();
    rec.reply = (n, fetchdef) -> {
      List<Object> items = new ArrayList<>();
      for (int i = 1; i <= 5; i++) {
        items.add(i);
      }
      return fhResponse(200, items, null);
    };
    FhHarness h = fhMake(rec::fetch, fhF(new StreamingFeature(), fhMap("chunkSize", 2)));
    FhOpResult res = h.op(fhOp("list").path("/w"));
    List<Object> batches = new ArrayList<>();
    Iterator<Object> it = res.result.stream.get();
    while (it.hasNext()) {
      batches.add(it.next());
    }
    assertEquals(List.of(List.of(1, 2), List.of(3, 4), List.of(5)), batches,
        "expected chunked batches");
  }

  @Test
  public void streaming_nonListNotStreamed() {
    assumeFeatures("streaming");
    FhHarness h = fhMake(null, fhF(new StreamingFeature(), null));
    FhOpResult res = h.op(fhOp("load"));
    assertFalse(res.result.streaming, "expected no stream on a non-list op");
    assertNull(res.result.stream, "expected no stream fn on a non-list op");
  }

  @Test
  public void streaming_inactiveIsNoop() {
    assumeFeatures("streaming");
    StreamingFeature f = new StreamingFeature();
    FhHarness h = fhMake(null, fhF(f, fhMap("active", false)));
    FhOpResult res = h.op(fhOp("list").path("/w"));
    assertFalse(res.result.streaming, "inactive streaming must not attach");
    assertEquals(0, f.opened, "expected no opened streams");
  }

  // --- proxy ----------------------------------------------------------------------

  @Test
  public void proxy_routesThroughProxy() {
    assumeFeatures("proxy");
    FhRecorder rec = new FhRecorder();
    ProxyFeature f = new ProxyFeature();
    FhHarness h = fhMake(rec::fetch, fhF(f, fhMap("url", "http://proxy:8080")));
    h.op(fhOp("load"));
    assertEquals("http://proxy:8080", rec.fetchdef(0).get("proxy"),
        "expected proxy annotation");
    assertEquals(1, f.routed, "expected 1 routed call");
  }

  @Test
  public void proxy_bypassesNoProxyHosts() {
    assumeFeatures("proxy");
    FhRecorder rec = new FhRecorder();
    List<Object> noProxy = new ArrayList<>();
    noProxy.add("api.test");
    FhHarness h = fhMake(rec::fetch, fhF(new ProxyFeature(), fhMap(
        "url", "http://proxy:8080",
        "noProxy", noProxy)));
    h.op(fhOp("load"));
    assertNull(rec.fetchdef(0).get("proxy"), "expected noProxy bypass");
  }

  @Test
  public void proxy_noUrlIsNoop() {
    assumeFeatures("proxy");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new ProxyFeature(), null));
    h.op(fhOp("load"));
    assertNull(rec.fetchdef(0).get("proxy"), "expected no proxy annotation");
  }

  @Test
  public void proxy_inactiveDoesNotWrap() {
    assumeFeatures("proxy");
    FhRecorder rec = new FhRecorder();
    FhHarness h = fhMake(rec::fetch, fhF(new ProxyFeature(), fhMap(
        "active", false, "url", "http://proxy:8080")));
    h.op(fhOp("load"));
    assertNull(rec.fetchdef(0).get("proxy"), "inactive proxy must not route");
  }

  // --- composition ----------------------------------------------------------------

  @Test
  public void composition_cacheHitSkipsSimulatedFailure() {
    assumeFeatures("cache", "netsim");
    NetsimFeature nf = new NetsimFeature();
    FhHarness h = fhMake(null,
        fhF(nf, fhMap("failEvery", 2)),
        fhF(new CacheFeature(), fhMap("ttl", 10000)));
    FhOpResult a = h.op(fhOp("load").path("/w"));
    assertTrue(a.ok, "first load should succeed: " + a.err);
    FhOpResult b = h.op(fhOp("load").path("/w"));
    assertTrue(b.ok, "second load should hit the cache: " + b.err);
    assertEquals(1, nf.calls, "expected 1 simulated call");
  }
}
