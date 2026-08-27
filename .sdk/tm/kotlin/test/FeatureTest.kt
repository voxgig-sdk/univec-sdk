package KOTLINPACKAGE.sdktest

// Behavioural tests for the enterprise features shipped with this SDK (retry,
// cache, rbac, telemetry, ...), driven through the offline feature-test
// harness (FeatureHarness). Each block runs only when its feature is present.

import java.util.function.Consumer
import java.util.function.Function
import java.util.function.IntConsumer
import java.util.function.LongSupplier
import java.util.function.Supplier

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.Test

import KOTLINPACKAGE.feature.AuditFeature
import KOTLINPACKAGE.feature.CacheFeature
import KOTLINPACKAGE.feature.ClienttrackFeature
import KOTLINPACKAGE.feature.DebugFeature
import KOTLINPACKAGE.feature.IdempotencyFeature
import KOTLINPACKAGE.feature.MetricsFeature
import KOTLINPACKAGE.feature.NetsimFeature
import KOTLINPACKAGE.feature.PagingFeature
import KOTLINPACKAGE.feature.ProxyFeature
import KOTLINPACKAGE.feature.RatelimitFeature
import KOTLINPACKAGE.feature.RbacFeature
import KOTLINPACKAGE.feature.RetryFeature
import KOTLINPACKAGE.feature.StreamingFeature
import KOTLINPACKAGE.feature.TelemetryFeature
import KOTLINPACKAGE.feature.TimeoutFeature
import KOTLINPACKAGE.sdktest.FeatureHarness.FhClock
import KOTLINPACKAGE.sdktest.FeatureHarness.FhRecorder
import KOTLINPACKAGE.sdktest.FeatureHarness.fhErrCode
import KOTLINPACKAGE.sdktest.FeatureHarness.fhF
import KOTLINPACKAGE.sdktest.FeatureHarness.fhHasFeature
import KOTLINPACKAGE.sdktest.FeatureHarness.fhMake
import KOTLINPACKAGE.sdktest.FeatureHarness.fhMap
import KOTLINPACKAGE.sdktest.FeatureHarness.fhOp
import KOTLINPACKAGE.sdktest.FeatureHarness.fhResponse

@Suppress("UNCHECKED_CAST")
class FeatureTest {

  private fun assumeFeatures(vararg names: String) {
    for (name in names) {
      Assumptions.assumeTrue(fhHasFeature(name), "feature not present in this SDK: $name")
    }
  }

  private fun sleepFn(clock: FhClock): IntConsumer = IntConsumer { clock.sleep(it) }
  private fun nowFn(clock: FhClock): LongSupplier = LongSupplier { clock.now() }

  // --- netsim -----------------------------------------------------------------

  @Test
  fun netsim_fixedLatencyThenDelegate() {
    assumeFeatures("netsim")
    val clock = FhClock()
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("latency", 250, "sleep", sleepFn(clock))))
    val res = h.op(fhOp("load").ctrl(fhMap("explain", linkedMapOf<String, Any?>())))
    assertTrue(res.ok, "expected ok, got err: ${res.err}")
    assertEquals(250L, clock.t, "expected 250ms latency")
    assertEquals(1, f.calls, "expected 1 call")
  }

  @Test
  fun netsim_rangedLatencyInMinMax() {
    assumeFeatures("netsim")
    val clock = FhClock()
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("latency", fhMap("min", 100, "max", 300), "seed", 7, "sleep", sleepFn(clock))))
    h.op(fhOp("load"))
    assertTrue(clock.t in 100L until 300L, "expected latency in [100,300), got ${clock.t}")
  }

  @Test
  fun netsim_equalMinMaxLatencyExact() {
    assumeFeatures("netsim")
    val clock = FhClock()
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("latency", fhMap("min", 50, "max", 50), "sleep", sleepFn(clock))))
    h.op(fhOp("load"))
    assertEquals(50L, clock.t, "expected exactly 50ms")
  }

  @Test
  fun netsim_failTimesReturnsRetryableStatus() {
    assumeFeatures("netsim")
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("failTimes", 2, "failStatus", 503)))
    assertEquals(503, h.op(fhOp("load")).result!!.status)
    assertEquals(503, h.op(fhOp("load")).result!!.status)
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected third call to succeed, got err: ${res.err}")
  }

  @Test
  fun netsim_failEveryFailsEveryNth() {
    assumeFeatures("netsim")
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("failEvery", 2)))
    assertTrue(h.op(fhOp("load")).ok, "call 1 should succeed")
    assertFalse(h.op(fhOp("load")).ok, "call 2 should fail")
    assertTrue(h.op(fhOp("load")).ok, "call 3 should succeed")
  }

  @Test
  fun netsim_failRateWithSeedDeterministic() {
    assumeFeatures("netsim")
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("failRate", 1, "seed", 5)))
    assertFalse(h.op(fhOp("load")).ok, "expected deterministic failure")
  }

  @Test
  fun netsim_errorTimesConnectionError() {
    assumeFeatures("netsim")
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("errorTimes", 1)))
    val res = h.op(fhOp("load"))
    assertEquals("netsim_conn", fhErrCode(res.err))
  }

  @Test
  fun netsim_offlineFailsEveryCall() {
    assumeFeatures("netsim")
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("offline", true)))
    val res = h.op(fhOp("load"))
    assertEquals("netsim_offline", fhErrCode(res.err))
  }

  @Test
  fun netsim_rateLimitTimes429RetryAfter() {
    assumeFeatures("netsim")
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("rateLimitTimes", 1, "retryAfter", 3)))
    val res = h.op(fhOp("load"))
    assertEquals(429, res.result!!.status)
    assertEquals("3", res.result!!.headers["retry-after"])
  }

  @Test
  fun netsim_inactiveDoesNotWrap() {
    assumeFeatures("netsim")
    val f = NetsimFeature()
    val h = fhMake(null, fhF(f, fhMap("active", false, "offline", true)))
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "inactive netsim must not simulate: ${res.err}")
    assertEquals(0, f.calls, "expected 0 simulated calls")
  }

  // --- retry ------------------------------------------------------------------

  @Test
  fun retry_retriesTransientThenSucceeds() {
    assumeFeatures("retry", "netsim")
    val clock = FhClock()
    val rf = RetryFeature()
    val h = fhMake(
      null,
      fhF(NetsimFeature(), fhMap("failTimes", 2, "failStatus", 503)),
      fhF(rf, fhMap("retries", 3, "minDelay", 10, "jitter", false, "sleep", sleepFn(clock))),
    )
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected success after retries: ${res.err}")
    assertEquals(2, rf.attempts, "expected 2 retries")
  }

  @Test
  fun retry_givesUpAfterBudget() {
    assumeFeatures("retry", "netsim")
    val clock = FhClock()
    val rf = RetryFeature()
    val h = fhMake(
      null,
      fhF(NetsimFeature(), fhMap("failTimes", 9, "failStatus", 500)),
      fhF(rf, fhMap("retries", 2, "minDelay", 1, "jitter", false, "sleep", sleepFn(clock))),
    )
    val res = h.op(fhOp("load"))
    assertEquals(500, res.result!!.status, "expected final 500")
  }

  @Test
  fun retry_doesNotRetryNonRetryableStatus() {
    assumeFeatures("retry")
    val rec = FhRecorder()
    rec.reply = { _, _ -> fhResponse(404, null, null) }
    val h = fhMake(rec::fetch, fhF(RetryFeature(), fhMap("retries", 3, "minDelay", 0)))
    h.op(fhOp("load"))
    assertEquals(1, rec.calls.size, "expected 1 call")
  }

  @Test
  fun retry_retriesTransportErrorThenReturnsIt() {
    assumeFeatures("retry")
    val clock = FhClock()
    val n = intArrayOf(0)
    val h = fhMake(
      { ctx, _, _ -> n[0]++; throw ctx.makeError("boom", "boom") },
      fhF(RetryFeature(), fhMap("retries", 2, "minDelay", 1, "jitter", false, "sleep", sleepFn(clock))),
    )
    val res = h.op(fhOp("load"))
    assertFalse(res.ok, "expected failure")
    assertEquals(3, n[0], "expected 3 attempts")
  }

  @Test
  fun retry_retriesNilTransportResult() {
    assumeFeatures("retry")
    val n = intArrayOf(0)
    val h = fhMake(
      { _, _, _ ->
        n[0]++
        if (n[0] < 2) null else fhResponse(200, fhMap("ok", true), null)
      },
      fhF(RetryFeature(), fhMap("retries", 3, "minDelay", 0)),
    )
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected success, got ${res.err}")
    assertEquals(2, n[0], "expected 2 attempts")
  }

  @Test
  fun retry_honoursServerRetryAfter() {
    assumeFeatures("retry", "netsim")
    val clock = FhClock()
    val h = fhMake(
      null,
      fhF(NetsimFeature(), fhMap("rateLimitTimes", 1, "retryAfter", 2)),
      fhF(RetryFeature(), fhMap("retries", 2, "minDelay", 10, "maxDelay", 60000, "jitter", false, "sleep", sleepFn(clock))),
    )
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected success: ${res.err}")
    assertEquals(2000L, clock.t, "expected 2000ms Retry-After wait")
  }

  @Test
  fun retry_inactiveDoesNotWrap() {
    assumeFeatures("retry")
    val rec = FhRecorder()
    rec.reply = { _, _ -> fhResponse(503, null, null) }
    val h = fhMake(rec::fetch, fhF(RetryFeature(), fhMap("active", false)))
    h.op(fhOp("load"))
    assertEquals(1, rec.calls.size, "expected 1 call")
  }

  // --- timeout ----------------------------------------------------------------

  @Test
  fun timeout_slowRequestTimesOut() {
    assumeFeatures("timeout")
    val f = TimeoutFeature()
    val h = fhMake(
      { _, _, _ ->
        try {
          Thread.sleep(60)
        } catch (e: InterruptedException) {
          Thread.currentThread().interrupt()
        }
        fhResponse(200, fhMap("ok", true), null)
      },
      fhF(f, fhMap("ms", 10)),
    )
    val res = h.op(fhOp("load"))
    assertEquals("timeout", fhErrCode(res.err), "expected timeout error, got ${res.err}")
    assertEquals(1, f.count, "expected 1 timeout")
  }

  @Test
  fun timeout_fastRequestPasses() {
    assumeFeatures("timeout")
    val h = fhMake(null, fhF(TimeoutFeature(), fhMap("ms", 1000)))
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected success: ${res.err}")
  }

  @Test
  fun timeout_msZeroDisables() {
    assumeFeatures("timeout")
    val h = fhMake(null, fhF(TimeoutFeature(), fhMap("ms", 0)))
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected success: ${res.err}")
  }

  @Test
  fun timeout_inactiveDoesNotWrap() {
    assumeFeatures("timeout")
    val h = fhMake(null, fhF(TimeoutFeature(), fhMap("active", false)))
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected success: ${res.err}")
  }

  // --- ratelimit ----------------------------------------------------------------

  @Test
  fun ratelimit_throttlesOnceBurstSpent() {
    assumeFeatures("ratelimit")
    val clock = FhClock()
    val f = RatelimitFeature()
    val h = fhMake(null, fhF(f, fhMap("rate", 1, "burst", 2, "now", nowFn(clock), "sleep", sleepFn(clock))))
    h.op(fhOp("load"))
    h.op(fhOp("load"))
    h.op(fhOp("load"))
    assertEquals(1, f.throttled, "expected 1 throttle")
    assertTrue(clock.t > 0, "expected the clock to advance while throttled")
  }

  @Test
  fun ratelimit_burstDefaultsToRateAndRefills() {
    assumeFeatures("ratelimit")
    val clock = FhClock()
    val f = RatelimitFeature()
    val h = fhMake(null, fhF(f, fhMap("rate", 2, "now", nowFn(clock), "sleep", sleepFn(clock))))
    h.op(fhOp("load"))
    h.op(fhOp("load"))
    clock.advance(1000)
    h.op(fhOp("load"))
    assertEquals(0, f.throttled, "expected no throttling after refill")
  }

  @Test
  fun ratelimit_inactiveDoesNotWrap() {
    assumeFeatures("ratelimit")
    val f = RatelimitFeature()
    val h = fhMake(null, fhF(f, fhMap("active", false)))
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected success: ${res.err}")
    assertEquals(0, f.throttled, "expected no throttling")
  }

  // --- cache --------------------------------------------------------------------

  @Test
  fun cache_servesRepeatedReadFromCache() {
    assumeFeatures("cache")
    val rec = FhRecorder()
    val f = CacheFeature()
    val h = fhMake(rec::fetch, fhF(f, fhMap("ttl", 10000)))
    val a = h.op(fhOp("load").path("/w/1"))
    val b = h.op(fhOp("load").path("/w/1"))
    assertEquals(1, rec.calls.size, "expected 1 network call")
    assertEquals(RunnerSupport.canon(a.data), RunnerSupport.canon(b.data), "expected identical cached data")
    assertEquals(1, f.hit, "expected 1 hit")
  }

  @Test
  fun cache_doesNotCacheNonGet() {
    assumeFeatures("cache")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(CacheFeature(), null))
    h.op(fhOp("create").path("/w"))
    h.op(fhOp("create").path("/w"))
    assertEquals(2, rec.calls.size, "expected 2 calls")
  }

  @Test
  fun cache_doesNotCacheNon2xx() {
    assumeFeatures("cache")
    val rec = FhRecorder()
    rec.reply = { _, _ -> fhResponse(500, null, null) }
    val f = CacheFeature()
    val h = fhMake(rec::fetch, fhF(f, null))
    h.op(fhOp("load").path("/w"))
    h.op(fhOp("load").path("/w"))
    assertEquals(2, rec.calls.size, "expected 2 calls")
    assertEquals(2, f.bypass, "expected 2 bypasses")
  }

  @Test
  fun cache_refetchesAfterTtl() {
    assumeFeatures("cache")
    val clock = FhClock()
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(CacheFeature(), fhMap("ttl", 1000, "now", nowFn(clock))))
    h.op(fhOp("load").path("/w"))
    clock.advance(1500)
    h.op(fhOp("load").path("/w"))
    assertEquals(2, rec.calls.size, "expected 2 calls after ttl expiry")
  }

  @Test
  fun cache_evictsOldestPastMax() {
    assumeFeatures("cache")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(CacheFeature(), fhMap("ttl", 10000, "max", 1)))
    h.op(fhOp("load").path("/a"))
    h.op(fhOp("load").path("/b"))
    h.op(fhOp("load").path("/a"))
    assertEquals(3, rec.calls.size, "expected 3 calls")
  }

  @Test
  fun cache_inactiveDoesNotWrap() {
    assumeFeatures("cache")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(CacheFeature(), fhMap("active", false)))
    h.op(fhOp("load").path("/x"))
    h.op(fhOp("load").path("/x"))
    assertEquals(2, rec.calls.size, "expected 2 calls")
  }

  // --- idempotency ----------------------------------------------------------------

  @Test
  fun idempotency_addsKeyToMutatingOps() {
    assumeFeatures("idempotency")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(IdempotencyFeature(), null))
    h.op(fhOp("create").path("/w"))
    assertNotNull(rec.headers(0)["Idempotency-Key"], "expected Idempotency-Key header on create")
  }

  @Test
  fun idempotency_addsKeyByHttpMethod() {
    assumeFeatures("idempotency")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(IdempotencyFeature(), null))
    h.op(fhOp("act").method("PUT").path("/w"))
    assertNotNull(rec.headers(0)["Idempotency-Key"], "expected Idempotency-Key header on PUT")
  }

  @Test
  fun idempotency_leavesReadsUntouched() {
    assumeFeatures("idempotency")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(IdempotencyFeature(), null))
    h.op(fhOp("load").path("/w/1"))
    assertNull(rec.headers(0)["Idempotency-Key"], "expected no Idempotency-Key header on load")
  }

  @Test
  fun idempotency_preservesCallerKeyCustomHeader() {
    assumeFeatures("idempotency")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(IdempotencyFeature(), fhMap("header", "X-Idem")))
    h.op(fhOp("create").path("/w").headers(fhMap("X-Idem", "caller-1")))
    assertEquals("caller-1", rec.headers(0)["X-Idem"], "expected caller key preserved")
  }

  @Test
  fun idempotency_injectedKeygen() {
    assumeFeatures("idempotency")
    val rec = FhRecorder()
    val f = IdempotencyFeature()
    val h = fhMake(rec::fetch, fhF(f, fhMap("keygen", Supplier<Any?> { "K1" })))
    h.op(fhOp("create").path("/w"))
    assertEquals("K1", rec.headers(0)["Idempotency-Key"], "expected injected key")
    assertEquals(1, f.issued, "expected 1 issued")
    assertEquals("K1", f.last, "expected last K1")
  }

  @Test
  fun idempotency_inactiveIsNoop() {
    assumeFeatures("idempotency")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(IdempotencyFeature(), fhMap("active", false)))
    h.op(fhOp("create").path("/w"))
    assertNull(rec.headers(0)["Idempotency-Key"], "inactive idempotency must not add a key")
  }

  // --- rbac -----------------------------------------------------------------------

  @Test
  fun rbac_deniesBeforeAnyCall() {
    assumeFeatures("rbac")
    val rec = FhRecorder()
    val f = RbacFeature()
    val h = fhMake(rec::fetch, fhF(f, fhMap("rules", fhMap("widget.remove", "admin"), "permissions", mutableListOf<Any?>())))
    val res = h.op(fhOp("remove").path("/w/1"))
    assertEquals("rbac_denied", fhErrCode(res.err))
    assertEquals(0, rec.calls.size, "expected no network calls")
    assertEquals(1, f.denied, "expected 1 denial")
  }

  @Test
  fun rbac_allowsHeldPermission() {
    assumeFeatures("rbac")
    val perms = mutableListOf<Any?>("admin")
    val h = fhMake(null, fhF(RbacFeature(), fhMap("rules", fhMap("widget.remove", "admin"), "permissions", perms)))
    val res = h.op(fhOp("remove").path("/w/1"))
    assertTrue(res.ok, "expected allow: ${res.err}")
  }

  @Test
  fun rbac_opRuleAndWildcardGrant() {
    assumeFeatures("rbac")
    val perms = mutableListOf<Any?>("*")
    val h = fhMake(null, fhF(RbacFeature(), fhMap("rules", fhMap("load", "read"), "permissions", perms)))
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected wildcard grant: ${res.err}")
  }

  @Test
  fun rbac_defaultAllowAndDenyTrue() {
    assumeFeatures("rbac")
    val allow = fhMake(null, fhF(RbacFeature(), fhMap("permissions", mutableListOf<Any?>())))
    val allowRes = allow.op(fhOp("load"))
    assertTrue(allowRes.ok, "expected default allow: ${allowRes.err}")

    val deny = fhMake(null, fhF(RbacFeature(), fhMap("deny", true, "permissions", mutableListOf<Any?>())))
    val denyRes = deny.op(fhOp("load"))
    assertEquals("rbac_denied", fhErrCode(denyRes.err), "expected default deny")
  }

  @Test
  fun rbac_inactiveIsNoop() {
    assumeFeatures("rbac")
    val h = fhMake(null, fhF(RbacFeature(), fhMap("active", false, "deny", true)))
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "inactive rbac must not deny: ${res.err}")
  }

  // --- metrics --------------------------------------------------------------------

  @Test
  fun metrics_countsOkAndErrPerOp() {
    assumeFeatures("metrics", "netsim")
    val f = MetricsFeature()
    val h = fhMake(
      null,
      fhF(NetsimFeature(), fhMap("failTimes", 1, "failStatus", 500)),
      fhF(f, null),
    )
    h.op(fhOp("load"))
    h.op(fhOp("load"))
    h.op(fhOp("list"))
    assertEquals(3, f.total.count, "expected total 3")
    assertEquals(2, f.total.ok, "expected 2 ok")
    assertEquals(1, f.total.err, "expected 1 err")
    assertNotNull(f.ops["widget.load"], "expected widget.load bucket")
    assertEquals(2, f.ops["widget.load"]!!.count, "expected widget.load count 2")
  }

  @Test
  fun metrics_injectedClock() {
    assumeFeatures("metrics")
    val clock = FhClock()
    val f = MetricsFeature()
    val h = fhMake(null, fhF(f, fhMap("now", nowFn(clock))))
    h.op(fhOp("load"))
    assertEquals(1, f.total.count, "expected 1 recorded op")
    assertEquals(0L, f.total.totalMs, "expected 0ms with frozen clock")
  }

  @Test
  fun metrics_inactiveRecordsNothing() {
    assumeFeatures("metrics")
    val f = MetricsFeature()
    val h = fhMake(null, fhF(f, fhMap("active", false)))
    h.op(fhOp("load"))
    assertEquals(0, f.total.count, "expected no records")
  }

  // --- telemetry ------------------------------------------------------------------

  @Test
  fun telemetry_opensSpansAndPropagatesHeaders() {
    assumeFeatures("telemetry")
    val rec = FhRecorder()
    val exported = mutableListOf<MutableMap<String, Any?>>()
    val f = TelemetryFeature()
    val h = fhMake(rec::fetch, fhF(f, fhMap("exporter", Consumer<MutableMap<String, Any?>> { exported.add(it) })))
    val res = h.op(fhOp("load"))
    assertTrue(res.ok, "expected success: ${res.err}")
    assertEquals(1, f.spans.size, "expected 1 span")
    assertEquals(1, exported.size, "expected 1 export")
    val sent = rec.headers(0)
    assertEquals(f.spans[0]["traceId"], sent["X-Trace-Id"], "expected propagated trace id")
    val traceparent = if (sent["traceparent"] is String) sent["traceparent"] as String else ""
    assertTrue(Regex("^00-.+-.+-01$").containsMatchIn(traceparent), "expected W3C traceparent, got $traceparent")
  }

  @Test
  fun telemetry_recordsFailedSpan() {
    assumeFeatures("telemetry", "netsim")
    val f = TelemetryFeature()
    val h = fhMake(
      null,
      fhF(NetsimFeature(), fhMap("failTimes", 1, "failStatus", 500)),
      fhF(f, null),
    )
    h.op(fhOp("load"))
    assertEquals(1, f.spans.size, "expected 1 span")
    assertEquals(false, f.spans[0]["ok"], "expected failed span")
  }

  @Test
  fun telemetry_injectedIdgenAndClock() {
    assumeFeatures("telemetry")
    val clock = FhClock()
    val f = TelemetryFeature()
    val h = fhMake(null, fhF(f, fhMap("idgen", Function<String, String> { kind -> "$kind-X" }, "now", nowFn(clock))))
    h.op(fhOp("load"))
    assertEquals("trace-X", f.spans[0]["traceId"], "expected injected trace id")
    assertEquals(0L, f.spans[0]["durationMs"], "expected 0ms span with frozen clock")
  }

  @Test
  fun telemetry_inactiveRecordsNothing() {
    assumeFeatures("telemetry")
    val f = TelemetryFeature()
    val h = fhMake(null, fhF(f, fhMap("active", false)))
    h.op(fhOp("load"))
    assertEquals(0, f.spans.size, "expected no spans")
  }

  // --- debug ----------------------------------------------------------------------

  @Test
  fun debug_redactsAndHonoursOnEntryMax() {
    assumeFeatures("debug")
    val seen = mutableListOf<MutableMap<String, Any?>>()
    val f = DebugFeature()
    val h = fhMake(null, fhF(f, fhMap("max", 1, "onEntry", Consumer<MutableMap<String, Any?>> { seen.add(it) })))
    h.op(fhOp("load").headers(fhMap("authorization", "Bearer secret")))
    h.op(fhOp("list"))
    assertEquals(1, f.entries.size, "expected ring buffer capped at 1")
    assertEquals(2, seen.size, "expected onEntry for both ops")
    val headers = seen[0]["headers"] as MutableMap<String, Any?>
    assertEquals("<redacted>", headers["authorization"], "expected redacted authorization")
  }

  @Test
  fun debug_capturesFailures() {
    assumeFeatures("debug", "netsim")
    val f = DebugFeature()
    val h = fhMake(
      null,
      fhF(NetsimFeature(), fhMap("failTimes", 1, "failStatus", 500)),
      fhF(f, null),
    )
    h.op(fhOp("load"))
    assertEquals(1, f.entries.size, "expected 1 entry")
    assertEquals(false, f.entries[0]["ok"], "expected failed entry")
  }

  @Test
  fun debug_injectedClockAndCustomRedact() {
    assumeFeatures("debug")
    val clock = FhClock()
    val f = DebugFeature()
    val redact = mutableListOf<Any?>("x-secret")
    val h = fhMake(null, fhF(f, fhMap("now", nowFn(clock), "redact", redact)))
    h.op(fhOp("load").headers(fhMap("x-secret", "hide", "x-ok", "show")))
    val headers = f.entries[0]["headers"] as MutableMap<String, Any?>
    assertEquals("<redacted>", headers["x-secret"], "expected x-secret redacted")
    assertEquals("show", headers["x-ok"], "expected x-ok kept")
  }

  @Test
  fun debug_inactiveRecordsNothing() {
    assumeFeatures("debug")
    val f = DebugFeature()
    val h = fhMake(null, fhF(f, fhMap("active", false)))
    h.op(fhOp("load"))
    assertEquals(0, f.entries.size, "expected no entries")
  }

  // --- audit ----------------------------------------------------------------------

  @Test
  fun audit_oneRecordPerOpSinkActor() {
    assumeFeatures("audit", "netsim")
    val sunk = mutableListOf<MutableMap<String, Any?>>()
    val f = AuditFeature()
    val h = fhMake(
      null,
      fhF(NetsimFeature(), fhMap("failTimes", 1, "failStatus", 500)),
      fhF(f, fhMap("actor", "svc", "max", 5, "sink", Consumer<MutableMap<String, Any?>> { sunk.add(it) })),
    )
    h.op(fhOp("remove").path("/w/1"))
    h.op(fhOp("load").ctrl(fhMap("actor", "per-call")))
    assertEquals(2, f.records.size, "expected 2 records")
    assertEquals("error", f.records[0]["outcome"], "expected error outcome")
    assertEquals("svc", f.records[0]["actor"], "expected svc actor")
    assertEquals("per-call", f.records[1]["actor"], "expected per-call actor")
    assertEquals(2, sunk.size, "expected 2 sunk records")
  }

  @Test
  fun audit_defaultActorAnonymous() {
    assumeFeatures("audit")
    val f = AuditFeature()
    val h = fhMake(null, fhF(f, null))
    h.op(fhOp("load"))
    assertEquals("anonymous", f.records[0]["actor"], "expected anonymous actor")
  }

  @Test
  fun audit_injectedClock() {
    assumeFeatures("audit")
    val f = AuditFeature()
    val h = fhMake(null, fhF(f, fhMap("now", LongSupplier { 42L })))
    h.op(fhOp("load"))
    assertEquals(42L, f.records[0]["ts"], "expected ts 42")
  }

  @Test
  fun audit_inactiveRecordsNothing() {
    assumeFeatures("audit")
    val f = AuditFeature()
    val h = fhMake(null, fhF(f, fhMap("active", false)))
    h.op(fhOp("load"))
    assertEquals(0, f.records.size, "expected no records")
  }

  // --- clienttrack ----------------------------------------------------------------

  @Test
  fun clienttrack_stableClientIdUniqueRequestIdsUa() {
    assumeFeatures("clienttrack")
    val rec = FhRecorder()
    val f = ClienttrackFeature()
    val h = fhMake(rec::fetch, fhF(f, fhMap("clientName", "Acme", "clientVersion", "2.0.0")))
    h.op(fhOp("load"))
    h.op(fhOp("load"))
    val h0 = rec.headers(0)
    val h1 = rec.headers(1)
    assertEquals("Acme/2.0.0", h0["User-Agent"], "expected Acme/2.0.0 UA")
    assertEquals(h0["X-Client-Id"], h1["X-Client-Id"], "expected stable client id")
    assertNotEquals(h0["X-Request-Id"], h1["X-Request-Id"], "expected fresh request ids")
    assertEquals(2, f.requests, "expected 2 tracked requests")
  }

  @Test
  fun clienttrack_doesNotClobberCallerUa() {
    assumeFeatures("clienttrack")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(ClienttrackFeature(), null))
    h.op(fhOp("load").headers(fhMap("User-Agent", "mine")))
    assertEquals("mine", rec.headers(0)["User-Agent"], "expected caller UA preserved")
  }

  @Test
  fun clienttrack_injectedIdgenFixedSession() {
    assumeFeatures("clienttrack")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(ClienttrackFeature(), fhMap("sessionId", "S1", "idgen", Function<String, String> { kind -> "$kind-1" })))
    h.op(fhOp("load"))
    assertEquals("S1", rec.headers(0)["X-Client-Id"], "expected fixed session")
    assertEquals("request-1", rec.headers(0)["X-Request-Id"], "expected injected request id")
  }

  @Test
  fun clienttrack_inactiveStampsNothing() {
    assumeFeatures("clienttrack")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(ClienttrackFeature(), fhMap("active", false)))
    h.op(fhOp("load"))
    assertNull(rec.headers(0)["X-Client-Id"], "inactive clienttrack must not stamp headers")
  }

  // --- paging ---------------------------------------------------------------------

  @Test
  fun paging_stampsPageLimitAndReadsHeaders() {
    assumeFeatures("paging")
    val rec = FhRecorder()
    rec.reply = { _, _ ->
      val items = mutableListOf<Any?>(1, 2)
      fhResponse(200, fhMap("items", items), fhMap("x-next-page", "2", "x-total-count", "5", "link", "</w?page=2>; rel=\"next\""))
    }
    val f = PagingFeature()
    val h = fhMake(rec::fetch, fhF(f, fhMap("limit", 2)))
    val res = h.op(fhOp("list").path("/w"))
    assertTrue(rec.url(0).contains("page=1"), "expected page=1 stamped: ${rec.url(0)}")
    assertTrue(rec.url(0).contains("limit=2"), "expected limit=2 stamped: ${rec.url(0)}")
    val paging = res.result!!.paging!!
    assertEquals(2, paging["nextPage"], "expected nextPage 2")
    assertEquals(5, paging["totalCount"], "expected totalCount 5")
    assertEquals("/w?page=2", paging["next"], "expected link next")
  }

  @Test
  fun paging_bodyCursorAndExplicitCursor() {
    assumeFeatures("paging")
    val rec = FhRecorder()
    rec.reply = { _, _ -> fhResponse(200, fhMap("nextCursor", "abc", "hasMore", true), null) }
    val h = fhMake(rec::fetch, fhF(PagingFeature(), null))
    val res = h.op(fhOp("list").path("/w").ctrl(fhMap("paging", fhMap("cursor", "xyz"))))
    assertTrue(rec.url(0).contains("cursor=xyz"), "expected cursor=xyz stamped: ${rec.url(0)}")
    assertEquals("abc", res.result!!.paging!!["cursor"], "expected body cursor")
    assertEquals(true, res.result!!.paging!!["hasMore"], "expected hasMore")
  }

  @Test
  fun paging_nonListNotPaged() {
    assumeFeatures("paging")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(PagingFeature(), null))
    h.op(fhOp("load").path("/w/1"))
    assertFalse(rec.url(0).contains("page="), "expected no page param: ${rec.url(0)}")
  }

  @Test
  fun paging_inactiveStampsNothing() {
    assumeFeatures("paging")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(PagingFeature(), fhMap("active", false)))
    h.op(fhOp("list").path("/w"))
    assertFalse(rec.url(0).contains("page="), "inactive paging must not stamp: ${rec.url(0)}")
  }

  // --- streaming ------------------------------------------------------------------

  @Test
  fun streaming_streamsListItems() {
    assumeFeatures("streaming")
    val clock = FhClock()
    val rec = FhRecorder()
    rec.reply = { _, _ -> fhResponse(200, mutableListOf<Any?>("a", "b", "c"), null) }
    val h = fhMake(rec::fetch, fhF(StreamingFeature(), fhMap("chunkDelay", 5, "sleep", sleepFn(clock))))
    val res = h.op(fhOp("list").path("/w"))
    assertTrue(res.result!!.streaming, "expected streaming result")
    val seen = mutableListOf<Any?>()
    val it = res.result!!.stream!!.get()
    while (it.hasNext()) {
      seen.add(it.next())
    }
    assertEquals(listOf("a", "b", "c"), seen, "expected streamed items")
    assertEquals(15L, clock.t, "expected 15ms paced delay")
  }

  @Test
  fun streaming_batchesWithChunkSize() {
    assumeFeatures("streaming")
    val rec = FhRecorder()
    rec.reply = { _, _ -> fhResponse(200, mutableListOf<Any?>(1, 2, 3, 4, 5), null) }
    val h = fhMake(rec::fetch, fhF(StreamingFeature(), fhMap("chunkSize", 2)))
    val res = h.op(fhOp("list").path("/w"))
    val batches = mutableListOf<Any?>()
    val it = res.result!!.stream!!.get()
    while (it.hasNext()) {
      batches.add(it.next())
    }
    assertEquals(listOf(listOf(1, 2), listOf(3, 4), listOf(5)), batches, "expected chunked batches")
  }

  @Test
  fun streaming_nonListNotStreamed() {
    assumeFeatures("streaming")
    val h = fhMake(null, fhF(StreamingFeature(), null))
    val res = h.op(fhOp("load"))
    assertFalse(res.result!!.streaming, "expected no stream on a non-list op")
    assertNull(res.result!!.stream, "expected no stream fn on a non-list op")
  }

  @Test
  fun streaming_inactiveIsNoop() {
    assumeFeatures("streaming")
    val f = StreamingFeature()
    val h = fhMake(null, fhF(f, fhMap("active", false)))
    val res = h.op(fhOp("list").path("/w"))
    assertFalse(res.result!!.streaming, "inactive streaming must not attach")
    assertEquals(0, f.opened, "expected no opened streams")
  }

  // --- proxy ----------------------------------------------------------------------

  @Test
  fun proxy_routesThroughProxy() {
    assumeFeatures("proxy")
    val rec = FhRecorder()
    val f = ProxyFeature()
    val h = fhMake(rec::fetch, fhF(f, fhMap("url", "http://proxy:8080")))
    h.op(fhOp("load"))
    assertEquals("http://proxy:8080", rec.fetchdef(0)["proxy"], "expected proxy annotation")
    assertEquals(1, f.routed, "expected 1 routed call")
  }

  @Test
  fun proxy_bypassesNoProxyHosts() {
    assumeFeatures("proxy")
    val rec = FhRecorder()
    val noProxy = mutableListOf<Any?>("api.test")
    val h = fhMake(rec::fetch, fhF(ProxyFeature(), fhMap("url", "http://proxy:8080", "noProxy", noProxy)))
    h.op(fhOp("load"))
    assertNull(rec.fetchdef(0)["proxy"], "expected noProxy bypass")
  }

  @Test
  fun proxy_noUrlIsNoop() {
    assumeFeatures("proxy")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(ProxyFeature(), null))
    h.op(fhOp("load"))
    assertNull(rec.fetchdef(0)["proxy"], "expected no proxy annotation")
  }

  @Test
  fun proxy_inactiveDoesNotWrap() {
    assumeFeatures("proxy")
    val rec = FhRecorder()
    val h = fhMake(rec::fetch, fhF(ProxyFeature(), fhMap("active", false, "url", "http://proxy:8080")))
    h.op(fhOp("load"))
    assertNull(rec.fetchdef(0)["proxy"], "inactive proxy must not route")
  }

  // --- composition ----------------------------------------------------------------

  @Test
  fun composition_cacheHitSkipsSimulatedFailure() {
    assumeFeatures("cache", "netsim")
    val nf = NetsimFeature()
    val h = fhMake(
      null,
      fhF(nf, fhMap("failEvery", 2)),
      fhF(CacheFeature(), fhMap("ttl", 10000)),
    )
    val a = h.op(fhOp("load").path("/w"))
    assertTrue(a.ok, "first load should succeed: ${a.err}")
    val b = h.op(fhOp("load").path("/w"))
    assertTrue(b.ok, "second load should hit the cache: ${b.err}")
    assertEquals(1, nf.calls, "expected 1 simulated call")
  }
}
