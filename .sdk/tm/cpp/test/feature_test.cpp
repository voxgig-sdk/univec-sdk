// Univec SDK — behavioural tests for the enterprise features (retry,
// cache, rbac, telemetry, ...), driven through the offline feature-test
// harness (mirrors java test/FeatureTest.java). Each block runs only when
// its feature is present in this SDK.

#include <chrono>
#include <regex>
#include <thread>
#include <vector>

#include "harness.hpp"

// The enterprise feature classes exercised below. Every feature header is
// shipped with the runtime; blocks whose feature is absent from this SDK's
// config are skipped at runtime via `have(...)` but must still compile.
#include "../feature/audit.hpp"
#include "../feature/cache.hpp"
#include "../feature/clienttrack.hpp"
#include "../feature/debug.hpp"
#include "../feature/idempotency.hpp"
#include "../feature/metrics.hpp"
#include "../feature/netsim.hpp"
#include "../feature/paging.hpp"
#include "../feature/proxy.hpp"
#include "../feature/ratelimit.hpp"
#include "../feature/rbac.hpp"
#include "../feature/retry.hpp"
#include "../feature/streaming.hpp"
#include "../feature/telemetry.hpp"
#include "../feature/timeout.hpp"

using namespace sdk;
using namespace sdk::fh;

// Every enterprise feature is present in this generated SDK; `have` mirrors
// JUnit's Assumptions.assumeTrue (skip when a feature is absent).
static bool have(std::initializer_list<std::string> names) {
  for (const auto& n : names) if (!fhHasFeature(n)) return false;
  return true;
}

// ---- injectable-callback builders (struct-func Values) ----------------

static Value keygenFn(const std::string& k) {
  vs::Injector fn = [k](vs::Injection&, const Value&, const std::string&, const Value&) { return Value(k); };
  return Value(fn);
}
static Value idgenFn(const std::string& suffix) { // kind -> kind + suffix
  vs::Injector fn = [suffix](vs::Injection&, const Value& args, const std::string&, const Value&) {
    return Value(as_str(vs::getelem(args, Value(int64_t(0)))) + suffix);
  };
  return Value(fn);
}
static Value collectFn(Value sink) { // Consumer<record>
  vs::Injector fn = [sink](vs::Injection&, const Value& args, const std::string&, const Value&) {
    sink.as_list()->push_back(vs::getelem(args, Value(int64_t(0))));
    return Value::undef();
  };
  return Value(fn);
}

template <typename T>
static FhFeature FF(std::shared_ptr<T> f, const Value& opts) { return fhF(f, opts); }

// ============================ netsim ===================================

static void netsim_fixedLatencyThenDelegate() {
  if (!have({"netsim"})) return;
  FhClock clock;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"latency", Value(250)}, {"sleep", clock.sleepFn()}}))});
  FhOpResult res = h->op(fhOp("load").setCtrl(fhMap({{"explain", vmap()}})));
  ASSERT_TRUE(res.ok, "expected ok");
  ASSERT_EQ(clock.t, (long long)250, "expected 250ms latency");
  ASSERT_EQ(f->calls, 1, "expected 1 call");
}

static void netsim_rangedLatencyInMinMax() {
  if (!have({"netsim"})) return;
  FhClock clock;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"latency", fhMap({{"min", Value(100)}, {"max", Value(300)}})},
                                        {"seed", Value(7)}, {"sleep", clock.sleepFn()}}))});
  h->op(fhOp("load"));
  ASSERT_TRUE(clock.t >= 100 && clock.t < 300, "expected latency in [100,300)");
}

static void netsim_equalMinMaxLatencyExact() {
  if (!have({"netsim"})) return;
  FhClock clock;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"latency", fhMap({{"min", Value(50)}, {"max", Value(50)}})},
                                        {"sleep", clock.sleepFn()}}))});
  h->op(fhOp("load"));
  ASSERT_EQ(clock.t, (long long)50, "expected exactly 50ms");
}

static void netsim_failTimesReturnsRetryableStatus() {
  if (!have({"netsim"})) return;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"failTimes", Value(2)}, {"failStatus", Value(503)}}))});
  ASSERT_EQ(h->op(fhOp("load")).result->status, 503, "call1 503");
  ASSERT_EQ(h->op(fhOp("load")).result->status, 503, "call2 503");
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected third call to succeed");
}

static void netsim_failEveryFailsEveryNth() {
  if (!have({"netsim"})) return;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"failEvery", Value(2)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "call 1 should succeed");
  ASSERT_FALSE(h->op(fhOp("load")).ok, "call 2 should fail");
  ASSERT_TRUE(h->op(fhOp("load")).ok, "call 3 should succeed");
}

static void netsim_failRateWithSeedDeterministic() {
  if (!have({"netsim"})) return;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"failRate", Value(1)}, {"seed", Value(5)}}))});
  ASSERT_FALSE(h->op(fhOp("load")).ok, "expected deterministic failure");
}

static void netsim_errorTimesConnectionError() {
  if (!have({"netsim"})) return;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"errorTimes", Value(1)}}))});
  ASSERT_EQ(fhErrCode(h->op(fhOp("load")).err), std::string("netsim_conn"), "expected netsim_conn");
}

static void netsim_offlineFailsEveryCall() {
  if (!have({"netsim"})) return;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"offline", Value(true)}}))});
  ASSERT_EQ(fhErrCode(h->op(fhOp("load")).err), std::string("netsim_offline"), "expected netsim_offline");
}

static void netsim_rateLimitTimes429RetryAfter() {
  if (!have({"netsim"})) return;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"rateLimitTimes", Value(1)}, {"retryAfter", Value(3)}}))});
  FhOpResult res = h->op(fhOp("load"));
  ASSERT_EQ(res.result->status, 429, "expected 429");
  ASSERT_EQ_VAL(getp(res.result->headers, "retry-after"), Value("3"), "expected retry-after 3");
}

static void netsim_inactiveDoesNotWrap() {
  if (!have({"netsim"})) return;
  auto f = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"active", Value(false)}, {"offline", Value(true)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "inactive netsim must not simulate");
  ASSERT_EQ(f->calls, 0, "expected 0 simulated calls");
}

// ============================ retry ====================================

static void retry_retriesTransientThenSucceeds() {
  if (!have({"retry", "netsim"})) return;
  FhClock clock;
  auto rf = std::make_shared<RetryFeature>();
  auto h = fhMake(nullptr, {
      FF(std::make_shared<NetsimFeature>(), fhMap({{"failTimes", Value(2)}, {"failStatus", Value(503)}})),
      FF(rf, fhMap({{"retries", Value(3)}, {"minDelay", Value(10)}, {"jitter", Value(false)}, {"sleep", clock.sleepFn()}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected success after retries");
  ASSERT_EQ(rf->attempts, 2, "expected 2 retries");
}

static void retry_givesUpAfterBudget() {
  if (!have({"retry", "netsim"})) return;
  FhClock clock;
  auto rf = std::make_shared<RetryFeature>();
  auto h = fhMake(nullptr, {
      FF(std::make_shared<NetsimFeature>(), fhMap({{"failTimes", Value(9)}, {"failStatus", Value(500)}})),
      FF(rf, fhMap({{"retries", Value(2)}, {"minDelay", Value(1)}, {"jitter", Value(false)}, {"sleep", clock.sleepFn()}}))});
  ASSERT_EQ(h->op(fhOp("load")).result->status, 500, "expected final 500");
}

static void retry_doesNotRetryNonRetryableStatus() {
  if (!have({"retry"})) return;
  auto rec = std::make_shared<FhRecorder>();
  rec->reply = [](int, const Value&) { return fhResponse(404, Value(nullptr), Value::undef()); };
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<RetryFeature>(), fhMap({{"retries", Value(3)}, {"minDelay", Value(0)}}))});
  h->op(fhOp("load"));
  ASSERT_EQ((int)rec->calls.size(), 1, "expected 1 call");
}

static void retry_retriesTransportErrorThenReturnsIt() {
  if (!have({"retry"})) return;
  FhClock clock;
  auto n = std::make_shared<int>(0);
  FetcherFn server = [n](CtxPtr ctx, const std::string&, const Value&) -> Value {
    (*n)++;
    throw ctx->makeError("boom", "boom");
  };
  auto h = fhMake(server, {FF(std::make_shared<RetryFeature>(), fhMap({{"retries", Value(2)}, {"minDelay", Value(1)}, {"jitter", Value(false)}, {"sleep", clock.sleepFn()}}))});
  FhOpResult res = h->op(fhOp("load"));
  ASSERT_FALSE(res.ok, "expected failure");
  ASSERT_EQ(*n, 3, "expected 3 attempts");
}

static void retry_retriesNilTransportResult() {
  if (!have({"retry"})) return;
  auto n = std::make_shared<int>(0);
  FetcherFn server = [n](CtxPtr, const std::string&, const Value&) -> Value {
    (*n)++;
    if (*n < 2) return Value::undef();
    return fhResponse(200, fhMap({{"ok", Value(true)}}), Value::undef());
  };
  auto h = fhMake(server, {FF(std::make_shared<RetryFeature>(), fhMap({{"retries", Value(3)}, {"minDelay", Value(0)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected success");
  ASSERT_EQ(*n, 2, "expected 2 attempts");
}

static void retry_honoursServerRetryAfter() {
  if (!have({"retry", "netsim"})) return;
  FhClock clock;
  auto h = fhMake(nullptr, {
      FF(std::make_shared<NetsimFeature>(), fhMap({{"rateLimitTimes", Value(1)}, {"retryAfter", Value(2)}})),
      FF(std::make_shared<RetryFeature>(), fhMap({{"retries", Value(2)}, {"minDelay", Value(10)}, {"maxDelay", Value(60000)}, {"jitter", Value(false)}, {"sleep", clock.sleepFn()}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected success");
  ASSERT_EQ(clock.t, (long long)2000, "expected 2000ms Retry-After wait");
}

static void retry_inactiveDoesNotWrap() {
  if (!have({"retry"})) return;
  auto rec = std::make_shared<FhRecorder>();
  rec->reply = [](int, const Value&) { return fhResponse(503, Value(nullptr), Value::undef()); };
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<RetryFeature>(), fhMap({{"active", Value(false)}}))});
  h->op(fhOp("load"));
  ASSERT_EQ((int)rec->calls.size(), 1, "expected 1 call");
}

// ============================ timeout ==================================

static void timeout_slowRequestTimesOut() {
  if (!have({"timeout"})) return;
  auto f = std::make_shared<TimeoutFeature>();
  FetcherFn server = [](CtxPtr, const std::string&, const Value&) -> Value {
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    return fhResponse(200, fhMap({{"ok", Value(true)}}), Value::undef());
  };
  auto h = fhMake(server, {FF(f, fhMap({{"ms", Value(10)}}))});
  FhOpResult res = h->op(fhOp("load"));
  ASSERT_EQ(fhErrCode(res.err), std::string("timeout"), "expected timeout error");
  ASSERT_EQ(f->count, 1, "expected 1 timeout");
}

static void timeout_fastRequestPasses() {
  if (!have({"timeout"})) return;
  auto h = fhMake(nullptr, {FF(std::make_shared<TimeoutFeature>(), fhMap({{"ms", Value(1000)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected success");
}

static void timeout_msZeroDisables() {
  if (!have({"timeout"})) return;
  auto h = fhMake(nullptr, {FF(std::make_shared<TimeoutFeature>(), fhMap({{"ms", Value(0)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected success");
}

static void timeout_inactiveDoesNotWrap() {
  if (!have({"timeout"})) return;
  auto h = fhMake(nullptr, {FF(std::make_shared<TimeoutFeature>(), fhMap({{"active", Value(false)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected success");
}

// ============================ ratelimit ================================

static void ratelimit_throttlesOnceBurstSpent() {
  if (!have({"ratelimit"})) return;
  FhClock clock;
  auto f = std::make_shared<RatelimitFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"rate", Value(1)}, {"burst", Value(2)}, {"now", clock.nowFn()}, {"sleep", clock.sleepFn()}}))});
  h->op(fhOp("load"));
  h->op(fhOp("load"));
  h->op(fhOp("load"));
  ASSERT_EQ(f->throttled, 1, "expected 1 throttle");
  ASSERT_TRUE(clock.t > 0, "expected the clock to advance while throttled");
}

static void ratelimit_burstDefaultsToRateAndRefills() {
  if (!have({"ratelimit"})) return;
  FhClock clock;
  auto f = std::make_shared<RatelimitFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"rate", Value(2)}, {"now", clock.nowFn()}, {"sleep", clock.sleepFn()}}))});
  h->op(fhOp("load"));
  h->op(fhOp("load"));
  clock.advance(1000);
  h->op(fhOp("load"));
  ASSERT_EQ(f->throttled, 0, "expected no throttling after refill");
}

static void ratelimit_inactiveDoesNotWrap() {
  if (!have({"ratelimit"})) return;
  auto f = std::make_shared<RatelimitFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"active", Value(false)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected success");
  ASSERT_EQ(f->throttled, 0, "expected no throttling");
}

// ============================ cache ====================================

static void cache_servesRepeatedReadFromCache() {
  if (!have({"cache"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto f = std::make_shared<CacheFeature>();
  auto h = fhMake(server, {FF(f, fhMap({{"ttl", Value(10000)}}))});
  FhOpResult a = h->op(fhOp("load").setPath("/w/1"));
  FhOpResult b = h->op(fhOp("load").setPath("/w/1"));
  ASSERT_EQ((int)rec->calls.size(), 1, "expected 1 network call");
  ASSERT_EQ_VAL(a.data, b.data, "expected identical cached data");
  ASSERT_EQ(f->hit, 1, "expected 1 hit");
}

static void cache_doesNotCacheNonGet() {
  if (!have({"cache"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<CacheFeature>(), Value::undef())});
  h->op(fhOp("create").setPath("/w"));
  h->op(fhOp("create").setPath("/w"));
  ASSERT_EQ((int)rec->calls.size(), 2, "expected 2 calls");
}

static void cache_doesNotCacheNon2xx() {
  if (!have({"cache"})) return;
  auto rec = std::make_shared<FhRecorder>();
  rec->reply = [](int, const Value&) { return fhResponse(500, Value(nullptr), Value::undef()); };
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto f = std::make_shared<CacheFeature>();
  auto h = fhMake(server, {FF(f, Value::undef())});
  h->op(fhOp("load").setPath("/w"));
  h->op(fhOp("load").setPath("/w"));
  ASSERT_EQ((int)rec->calls.size(), 2, "expected 2 calls");
  ASSERT_EQ(f->bypass, 2, "expected 2 bypasses");
}

static void cache_refetchesAfterTtl() {
  if (!have({"cache"})) return;
  FhClock clock;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<CacheFeature>(), fhMap({{"ttl", Value(1000)}, {"now", clock.nowFn()}}))});
  h->op(fhOp("load").setPath("/w"));
  clock.advance(1500);
  h->op(fhOp("load").setPath("/w"));
  ASSERT_EQ((int)rec->calls.size(), 2, "expected 2 calls after ttl expiry");
}

static void cache_evictsOldestPastMax() {
  if (!have({"cache"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<CacheFeature>(), fhMap({{"ttl", Value(10000)}, {"max", Value(1)}}))});
  h->op(fhOp("load").setPath("/a"));
  h->op(fhOp("load").setPath("/b"));
  h->op(fhOp("load").setPath("/a"));
  ASSERT_EQ((int)rec->calls.size(), 3, "expected 3 calls");
}

static void cache_inactiveDoesNotWrap() {
  if (!have({"cache"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<CacheFeature>(), fhMap({{"active", Value(false)}}))});
  h->op(fhOp("load").setPath("/x"));
  h->op(fhOp("load").setPath("/x"));
  ASSERT_EQ((int)rec->calls.size(), 2, "expected 2 calls");
}

// ============================ idempotency ==============================

static void idempotency_addsKeyToMutatingOps() {
  if (!have({"idempotency"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<IdempotencyFeature>(), Value::undef())});
  h->op(fhOp("create").setPath("/w"));
  ASSERT_TRUE(!getp(rec->headers(0), "Idempotency-Key").is_undef(), "expected Idempotency-Key on create");
}

static void idempotency_addsKeyByHttpMethod() {
  if (!have({"idempotency"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<IdempotencyFeature>(), Value::undef())});
  h->op(fhOp("act").setMethod("PUT").setPath("/w"));
  ASSERT_TRUE(!getp(rec->headers(0), "Idempotency-Key").is_undef(), "expected Idempotency-Key on PUT");
}

static void idempotency_leavesReadsUntouched() {
  if (!have({"idempotency"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<IdempotencyFeature>(), Value::undef())});
  h->op(fhOp("load").setPath("/w/1"));
  ASSERT_TRUE(getp(rec->headers(0), "Idempotency-Key").is_undef(), "expected no key on load");
}

static void idempotency_preservesCallerKeyCustomHeader() {
  if (!have({"idempotency"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<IdempotencyFeature>(), fhMap({{"header", Value("X-Idem")}}))});
  h->op(fhOp("create").setPath("/w").setHeaders(fhMap({{"X-Idem", Value("caller-1")}})));
  ASSERT_EQ_VAL(getp(rec->headers(0), "X-Idem"), Value("caller-1"), "expected caller key preserved");
}

static void idempotency_injectedKeygen() {
  if (!have({"idempotency"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto f = std::make_shared<IdempotencyFeature>();
  auto h = fhMake(server, {FF(f, fhMap({{"keygen", keygenFn("K1")}}))});
  h->op(fhOp("create").setPath("/w"));
  ASSERT_EQ_VAL(getp(rec->headers(0), "Idempotency-Key"), Value("K1"), "expected injected key");
  ASSERT_EQ(f->issued, 1, "expected 1 issued");
  ASSERT_EQ(f->last, std::string("K1"), "expected last K1");
}

static void idempotency_inactiveIsNoop() {
  if (!have({"idempotency"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<IdempotencyFeature>(), fhMap({{"active", Value(false)}}))});
  h->op(fhOp("create").setPath("/w"));
  ASSERT_TRUE(getp(rec->headers(0), "Idempotency-Key").is_undef(), "inactive must not add a key");
}

// ============================ rbac =====================================

static void rbac_deniesBeforeAnyCall() {
  if (!have({"rbac"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto f = std::make_shared<RbacFeature>();
  auto h = fhMake(server, {FF(f, fhMap({{"rules", fhMap({{"widget.remove", Value("admin")}})}, {"permissions", vlist()}}))});
  FhOpResult res = h->op(fhOp("remove").setPath("/w/1"));
  ASSERT_EQ(fhErrCode(res.err), std::string("rbac_denied"), "expected rbac_denied");
  ASSERT_EQ((int)rec->calls.size(), 0, "expected no network calls");
  ASSERT_EQ(f->denied, 1, "expected 1 denial");
}

static void rbac_allowsHeldPermission() {
  if (!have({"rbac"})) return;
  auto h = fhMake(nullptr, {FF(std::make_shared<RbacFeature>(), fhMap({{"rules", fhMap({{"widget.remove", Value("admin")}})}, {"permissions", vlist({Value("admin")})}}))});
  ASSERT_TRUE(h->op(fhOp("remove").setPath("/w/1")).ok, "expected allow");
}

static void rbac_opRuleAndWildcardGrant() {
  if (!have({"rbac"})) return;
  auto h = fhMake(nullptr, {FF(std::make_shared<RbacFeature>(), fhMap({{"rules", fhMap({{"load", Value("read")}})}, {"permissions", vlist({Value("*")})}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected wildcard grant");
}

static void rbac_defaultAllowAndDenyTrue() {
  if (!have({"rbac"})) return;
  auto allow = fhMake(nullptr, {FF(std::make_shared<RbacFeature>(), fhMap({{"permissions", vlist()}}))});
  ASSERT_TRUE(allow->op(fhOp("load")).ok, "expected default allow");
  auto deny = fhMake(nullptr, {FF(std::make_shared<RbacFeature>(), fhMap({{"deny", Value(true)}, {"permissions", vlist()}}))});
  ASSERT_EQ(fhErrCode(deny->op(fhOp("load")).err), std::string("rbac_denied"), "expected default deny");
}

static void rbac_inactiveIsNoop() {
  if (!have({"rbac"})) return;
  auto h = fhMake(nullptr, {FF(std::make_shared<RbacFeature>(), fhMap({{"active", Value(false)}, {"deny", Value(true)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "inactive rbac must not deny");
}

// ============================ metrics ==================================

static void metrics_countsOkAndErrPerOp() {
  if (!have({"metrics", "netsim"})) return;
  auto f = std::make_shared<MetricsFeature>();
  auto h = fhMake(nullptr, {
      FF(std::make_shared<NetsimFeature>(), fhMap({{"failTimes", Value(1)}, {"failStatus", Value(500)}})),
      FF(f, Value::undef())});
  h->op(fhOp("load"));
  h->op(fhOp("load"));
  h->op(fhOp("list"));
  ASSERT_EQ(f->total.count, 3, "expected total 3");
  ASSERT_EQ(f->total.ok, 2, "expected 2 ok");
  ASSERT_EQ(f->total.err, 1, "expected 1 err");
  ASSERT_TRUE(f->ops.count("widget.load") > 0, "expected widget.load bucket");
  ASSERT_EQ(f->ops["widget.load"].count, 2, "expected widget.load count 2");
}

static void metrics_injectedClock() {
  if (!have({"metrics"})) return;
  FhClock clock;
  auto f = std::make_shared<MetricsFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"now", clock.nowFn()}}))});
  h->op(fhOp("load"));
  ASSERT_EQ(f->total.count, 1, "expected 1 recorded op");
  ASSERT_EQ(f->total.totalMs, (long long)0, "expected 0ms with frozen clock");
}

static void metrics_inactiveRecordsNothing() {
  if (!have({"metrics"})) return;
  auto f = std::make_shared<MetricsFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"active", Value(false)}}))});
  h->op(fhOp("load"));
  ASSERT_EQ(f->total.count, 0, "expected no records");
}

// ============================ telemetry ================================

static void telemetry_opensSpansAndPropagatesHeaders() {
  if (!have({"telemetry"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  Value exported = vlist();
  auto f = std::make_shared<TelemetryFeature>();
  auto h = fhMake(server, {FF(f, fhMap({{"exporter", collectFn(exported)}}))});
  ASSERT_TRUE(h->op(fhOp("load")).ok, "expected success");
  ASSERT_EQ((int)f->spans.as_list()->size(), 1, "expected 1 span");
  ASSERT_EQ((int)exported.as_list()->size(), 1, "expected 1 export");
  Value sent = rec->headers(0);
  ASSERT_EQ_VAL(getp((*f->spans.as_list())[0], "traceId"), getp(sent, "X-Trace-Id"), "expected propagated trace id");
  std::string tp = as_str(getp(sent, "traceparent"));
  ASSERT_TRUE(std::regex_search(tp, std::regex("^00-.+-.+-01$")), "expected W3C traceparent");
}

static void telemetry_recordsFailedSpan() {
  if (!have({"telemetry", "netsim"})) return;
  auto f = std::make_shared<TelemetryFeature>();
  auto h = fhMake(nullptr, {
      FF(std::make_shared<NetsimFeature>(), fhMap({{"failTimes", Value(1)}, {"failStatus", Value(500)}})),
      FF(f, Value::undef())});
  h->op(fhOp("load"));
  ASSERT_EQ((int)f->spans.as_list()->size(), 1, "expected 1 span");
  ASSERT_EQ_VAL(getp((*f->spans.as_list())[0], "ok"), Value(false), "expected failed span");
}

static void telemetry_injectedIdgenAndClock() {
  if (!have({"telemetry"})) return;
  FhClock clock;
  auto f = std::make_shared<TelemetryFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"idgen", idgenFn("-X")}, {"now", clock.nowFn()}}))});
  h->op(fhOp("load"));
  ASSERT_EQ_VAL(getp((*f->spans.as_list())[0], "traceId"), Value("trace-X"), "expected injected trace id");
  ASSERT_EQ(as_long(getp((*f->spans.as_list())[0], "durationMs")), (long long)0, "expected 0ms span");
}

static void telemetry_inactiveRecordsNothing() {
  if (!have({"telemetry"})) return;
  auto f = std::make_shared<TelemetryFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"active", Value(false)}}))});
  h->op(fhOp("load"));
  ASSERT_EQ((int)f->spans.as_list()->size(), 0, "expected no spans");
}

// ============================ debug ====================================

static void debug_redactsAndHonoursOnEntryMax() {
  if (!have({"debug"})) return;
  Value seen = vlist();
  auto f = std::make_shared<DebugFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"max", Value(1)}, {"onEntry", collectFn(seen)}}))});
  h->op(fhOp("load").setHeaders(fhMap({{"authorization", Value("Bearer secret")}})));
  h->op(fhOp("list"));
  ASSERT_EQ((int)f->entries.as_list()->size(), 1, "expected ring buffer capped at 1");
  ASSERT_EQ((int)seen.as_list()->size(), 2, "expected onEntry for both ops");
  Value headers = getp((*seen.as_list())[0], "headers");
  ASSERT_EQ_VAL(getp(headers, "authorization"), Value("<redacted>"), "expected redacted authorization");
}

static void debug_capturesFailures() {
  if (!have({"debug", "netsim"})) return;
  auto f = std::make_shared<DebugFeature>();
  auto h = fhMake(nullptr, {
      FF(std::make_shared<NetsimFeature>(), fhMap({{"failTimes", Value(1)}, {"failStatus", Value(500)}})),
      FF(f, Value::undef())});
  h->op(fhOp("load"));
  ASSERT_EQ((int)f->entries.as_list()->size(), 1, "expected 1 entry");
  ASSERT_EQ_VAL(getp((*f->entries.as_list())[0], "ok"), Value(false), "expected failed entry");
}

static void debug_injectedClockAndCustomRedact() {
  if (!have({"debug"})) return;
  FhClock clock;
  auto f = std::make_shared<DebugFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"now", clock.nowFn()}, {"redact", vlist({Value("x-secret")})}}))});
  h->op(fhOp("load").setHeaders(fhMap({{"x-secret", Value("hide")}, {"x-ok", Value("show")}})));
  Value headers = getp((*f->entries.as_list())[0], "headers");
  ASSERT_EQ_VAL(getp(headers, "x-secret"), Value("<redacted>"), "expected x-secret redacted");
  ASSERT_EQ_VAL(getp(headers, "x-ok"), Value("show"), "expected x-ok kept");
}

static void debug_inactiveRecordsNothing() {
  if (!have({"debug"})) return;
  auto f = std::make_shared<DebugFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"active", Value(false)}}))});
  h->op(fhOp("load"));
  ASSERT_EQ((int)f->entries.as_list()->size(), 0, "expected no entries");
}

// ============================ audit ====================================

static void audit_oneRecordPerOpSinkActor() {
  if (!have({"audit", "netsim"})) return;
  Value sunk = vlist();
  auto f = std::make_shared<AuditFeature>();
  auto h = fhMake(nullptr, {
      FF(std::make_shared<NetsimFeature>(), fhMap({{"failTimes", Value(1)}, {"failStatus", Value(500)}})),
      FF(f, fhMap({{"actor", Value("svc")}, {"max", Value(5)}, {"sink", collectFn(sunk)}}))});
  h->op(fhOp("remove").setPath("/w/1"));
  h->op(fhOp("load").setCtrl(fhMap({{"actor", Value("per-call")}})));
  ASSERT_EQ((int)f->records.as_list()->size(), 2, "expected 2 records");
  ASSERT_EQ_VAL(getp((*f->records.as_list())[0], "outcome"), Value("error"), "expected error outcome");
  ASSERT_EQ_VAL(getp((*f->records.as_list())[0], "actor"), Value("svc"), "expected svc actor");
  ASSERT_EQ_VAL(getp((*f->records.as_list())[1], "actor"), Value("per-call"), "expected per-call actor");
  ASSERT_EQ((int)sunk.as_list()->size(), 2, "expected 2 sunk records");
}

static void audit_defaultActorAnonymous() {
  if (!have({"audit"})) return;
  auto f = std::make_shared<AuditFeature>();
  auto h = fhMake(nullptr, {FF(f, Value::undef())});
  h->op(fhOp("load"));
  ASSERT_EQ_VAL(getp((*f->records.as_list())[0], "actor"), Value("anonymous"), "expected anonymous actor");
}

static void audit_injectedClock() {
  if (!have({"audit"})) return;
  auto f = std::make_shared<AuditFeature>();
  vs::Injector nowfn = [](vs::Injection&, const Value&, const std::string&, const Value&) { return Value((long long)42); };
  auto h = fhMake(nullptr, {FF(f, fhMap({{"now", Value(nowfn)}}))});
  h->op(fhOp("load"));
  ASSERT_EQ(as_long(getp((*f->records.as_list())[0], "ts")), (long long)42, "expected ts 42");
}

static void audit_inactiveRecordsNothing() {
  if (!have({"audit"})) return;
  auto f = std::make_shared<AuditFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"active", Value(false)}}))});
  h->op(fhOp("load"));
  ASSERT_EQ((int)f->records.as_list()->size(), 0, "expected no records");
}

// ============================ clienttrack ==============================

static void clienttrack_stableClientIdUniqueRequestIdsUa() {
  if (!have({"clienttrack"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto f = std::make_shared<ClienttrackFeature>();
  auto h = fhMake(server, {FF(f, fhMap({{"clientName", Value("Acme")}, {"clientVersion", Value("2.0.0")}}))});
  h->op(fhOp("load"));
  h->op(fhOp("load"));
  Value h0 = rec->headers(0);
  Value h1 = rec->headers(1);
  ASSERT_EQ_VAL(getp(h0, "User-Agent"), Value("Acme/2.0.0"), "expected Acme/2.0.0 UA");
  ASSERT_EQ_VAL(getp(h0, "X-Client-Id"), getp(h1, "X-Client-Id"), "expected stable client id");
  ASSERT_TRUE(getp(h0, "X-Request-Id") != getp(h1, "X-Request-Id"), "expected fresh request ids");
  ASSERT_EQ(f->requests, 2, "expected 2 tracked requests");
}

static void clienttrack_doesNotClobberCallerUa() {
  if (!have({"clienttrack"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<ClienttrackFeature>(), Value::undef())});
  h->op(fhOp("load").setHeaders(fhMap({{"User-Agent", Value("mine")}})));
  ASSERT_EQ_VAL(getp(rec->headers(0), "User-Agent"), Value("mine"), "expected caller UA preserved");
}

static void clienttrack_injectedIdgenFixedSession() {
  if (!have({"clienttrack"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<ClienttrackFeature>(), fhMap({{"sessionId", Value("S1")}, {"idgen", idgenFn("-1")}}))});
  h->op(fhOp("load"));
  ASSERT_EQ_VAL(getp(rec->headers(0), "X-Client-Id"), Value("S1"), "expected fixed session");
  ASSERT_EQ_VAL(getp(rec->headers(0), "X-Request-Id"), Value("request-1"), "expected injected request id");
}

static void clienttrack_inactiveStampsNothing() {
  if (!have({"clienttrack"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<ClienttrackFeature>(), fhMap({{"active", Value(false)}}))});
  h->op(fhOp("load"));
  ASSERT_TRUE(getp(rec->headers(0), "X-Client-Id").is_undef(), "inactive must not stamp headers");
}

// ============================ paging ===================================

static void paging_stampsPageLimitAndReadsHeaders() {
  if (!have({"paging"})) return;
  auto rec = std::make_shared<FhRecorder>();
  rec->reply = [](int, const Value&) {
    return fhResponse(200, fhMap({{"items", vlist({Value(1), Value(2)})}}),
                      fhMap({{"x-next-page", Value("2")}, {"x-total-count", Value("5")}, {"link", Value("</w?page=2>; rel=\"next\"")}}));
  };
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto f = std::make_shared<PagingFeature>();
  auto h = fhMake(server, {FF(f, fhMap({{"limit", Value(2)}}))});
  FhOpResult res = h->op(fhOp("list").setPath("/w"));
  ASSERT_TRUE(rec->url(0).find("page=1") != std::string::npos, "expected page=1 stamped");
  ASSERT_TRUE(rec->url(0).find("limit=2") != std::string::npos, "expected limit=2 stamped");
  Value paging = res.result->paging;
  ASSERT_EQ(as_int(getp(paging, "nextPage")), 2, "expected nextPage 2");
  ASSERT_EQ(as_int(getp(paging, "totalCount")), 5, "expected totalCount 5");
  ASSERT_EQ_VAL(getp(paging, "next"), Value("/w?page=2"), "expected link next");
}

static void paging_bodyCursorAndExplicitCursor() {
  if (!have({"paging"})) return;
  auto rec = std::make_shared<FhRecorder>();
  rec->reply = [](int, const Value&) { return fhResponse(200, fhMap({{"nextCursor", Value("abc")}, {"hasMore", Value(true)}}), Value::undef()); };
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<PagingFeature>(), Value::undef())});
  FhOpResult res = h->op(fhOp("list").setPath("/w").setCtrl(fhMap({{"paging", fhMap({{"cursor", Value("xyz")}})}})));
  ASSERT_TRUE(rec->url(0).find("cursor=xyz") != std::string::npos, "expected cursor=xyz stamped");
  ASSERT_EQ_VAL(getp(res.result->paging, "cursor"), Value("abc"), "expected body cursor");
  ASSERT_EQ_VAL(getp(res.result->paging, "hasMore"), Value(true), "expected hasMore");
}

static void paging_nonListNotPaged() {
  if (!have({"paging"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<PagingFeature>(), Value::undef())});
  h->op(fhOp("load").setPath("/w/1"));
  ASSERT_TRUE(rec->url(0).find("page=") == std::string::npos, "expected no page param");
}

static void paging_inactiveStampsNothing() {
  if (!have({"paging"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<PagingFeature>(), fhMap({{"active", Value(false)}}))});
  h->op(fhOp("list").setPath("/w"));
  ASSERT_TRUE(rec->url(0).find("page=") == std::string::npos, "inactive paging must not stamp");
}

// ============================ streaming =================================

static void streaming_streamsListItems() {
  if (!have({"streaming"})) return;
  FhClock clock;
  auto rec = std::make_shared<FhRecorder>();
  rec->reply = [](int, const Value&) { return fhResponse(200, vlist({Value("a"), Value("b"), Value("c")}), Value::undef()); };
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<StreamingFeature>(), fhMap({{"chunkDelay", Value(5)}, {"sleep", clock.sleepFn()}}))});
  FhOpResult res = h->op(fhOp("list").setPath("/w"));
  ASSERT_TRUE(res.result->streaming, "expected streaming result");
  Value seen = vlist();
  for (const auto& v : res.result->stream()) seen.as_list()->push_back(v);
  ASSERT_EQ_VAL(seen, vlist({Value("a"), Value("b"), Value("c")}), "expected streamed items");
  ASSERT_EQ(clock.t, (long long)15, "expected 15ms paced delay");
}

static void streaming_batchesWithChunkSize() {
  if (!have({"streaming"})) return;
  auto rec = std::make_shared<FhRecorder>();
  rec->reply = [](int, const Value&) { return fhResponse(200, vlist({Value(1), Value(2), Value(3), Value(4), Value(5)}), Value::undef()); };
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<StreamingFeature>(), fhMap({{"chunkSize", Value(2)}}))});
  FhOpResult res = h->op(fhOp("list").setPath("/w"));
  Value batches = vlist();
  for (const auto& v : res.result->stream()) batches.as_list()->push_back(v);
  Value expected = vlist({vlist({Value(1), Value(2)}), vlist({Value(3), Value(4)}), vlist({Value(5)})});
  ASSERT_EQ_VAL(batches, expected, "expected chunked batches");
}

static void streaming_nonListNotStreamed() {
  if (!have({"streaming"})) return;
  auto h = fhMake(nullptr, {FF(std::make_shared<StreamingFeature>(), Value::undef())});
  FhOpResult res = h->op(fhOp("load"));
  ASSERT_FALSE(res.result->streaming, "expected no stream on a non-list op");
  ASSERT_FALSE((bool)res.result->stream, "expected no stream fn on a non-list op");
}

static void streaming_inactiveIsNoop() {
  if (!have({"streaming"})) return;
  auto f = std::make_shared<StreamingFeature>();
  auto h = fhMake(nullptr, {FF(f, fhMap({{"active", Value(false)}}))});
  FhOpResult res = h->op(fhOp("list").setPath("/w"));
  ASSERT_FALSE(res.result->streaming, "inactive streaming must not attach");
  ASSERT_EQ(f->opened, 0, "expected no opened streams");
}

// ============================ proxy ====================================

static void proxy_routesThroughProxy() {
  if (!have({"proxy"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto f = std::make_shared<ProxyFeature>();
  auto h = fhMake(server, {FF(f, fhMap({{"url", Value("http://proxy:8080")}}))});
  h->op(fhOp("load"));
  ASSERT_EQ_VAL(getp(rec->fetchdef(0), "proxy"), Value("http://proxy:8080"), "expected proxy annotation");
  ASSERT_EQ(f->routed, 1, "expected 1 routed call");
}

static void proxy_bypassesNoProxyHosts() {
  if (!have({"proxy"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<ProxyFeature>(), fhMap({{"url", Value("http://proxy:8080")}, {"noProxy", vlist({Value("api.test")})}}))});
  h->op(fhOp("load"));
  ASSERT_TRUE(getp(rec->fetchdef(0), "proxy").is_undef(), "expected noProxy bypass");
}

static void proxy_noUrlIsNoop() {
  if (!have({"proxy"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<ProxyFeature>(), Value::undef())});
  h->op(fhOp("load"));
  ASSERT_TRUE(getp(rec->fetchdef(0), "proxy").is_undef(), "expected no proxy annotation");
}

static void proxy_inactiveDoesNotWrap() {
  if (!have({"proxy"})) return;
  auto rec = std::make_shared<FhRecorder>();
  FetcherFn server = [rec](CtxPtr c, const std::string& u, const Value& fd) { return rec->fetch(c, u, fd); };
  auto h = fhMake(server, {FF(std::make_shared<ProxyFeature>(), fhMap({{"active", Value(false)}, {"url", Value("http://proxy:8080")}}))});
  h->op(fhOp("load"));
  ASSERT_TRUE(getp(rec->fetchdef(0), "proxy").is_undef(), "inactive proxy must not route");
}

// ============================ composition ==============================

static void composition_cacheHitSkipsSimulatedFailure() {
  if (!have({"cache", "netsim"})) return;
  auto nf = std::make_shared<NetsimFeature>();
  auto h = fhMake(nullptr, {
      FF(nf, fhMap({{"failEvery", Value(2)}})),
      FF(std::make_shared<CacheFeature>(), fhMap({{"ttl", Value(10000)}}))});
  ASSERT_TRUE(h->op(fhOp("load").setPath("/w")).ok, "first load should succeed");
  ASSERT_TRUE(h->op(fhOp("load").setPath("/w")).ok, "second load should hit the cache");
  ASSERT_EQ(nf->calls, 1, "expected 1 simulated call");
}

int main() {
  T_RUN(netsim_fixedLatencyThenDelegate);
  T_RUN(netsim_rangedLatencyInMinMax);
  T_RUN(netsim_equalMinMaxLatencyExact);
  T_RUN(netsim_failTimesReturnsRetryableStatus);
  T_RUN(netsim_failEveryFailsEveryNth);
  T_RUN(netsim_failRateWithSeedDeterministic);
  T_RUN(netsim_errorTimesConnectionError);
  T_RUN(netsim_offlineFailsEveryCall);
  T_RUN(netsim_rateLimitTimes429RetryAfter);
  T_RUN(netsim_inactiveDoesNotWrap);

  T_RUN(retry_retriesTransientThenSucceeds);
  T_RUN(retry_givesUpAfterBudget);
  T_RUN(retry_doesNotRetryNonRetryableStatus);
  T_RUN(retry_retriesTransportErrorThenReturnsIt);
  T_RUN(retry_retriesNilTransportResult);
  T_RUN(retry_honoursServerRetryAfter);
  T_RUN(retry_inactiveDoesNotWrap);

  T_RUN(timeout_slowRequestTimesOut);
  T_RUN(timeout_fastRequestPasses);
  T_RUN(timeout_msZeroDisables);
  T_RUN(timeout_inactiveDoesNotWrap);

  T_RUN(ratelimit_throttlesOnceBurstSpent);
  T_RUN(ratelimit_burstDefaultsToRateAndRefills);
  T_RUN(ratelimit_inactiveDoesNotWrap);

  T_RUN(cache_servesRepeatedReadFromCache);
  T_RUN(cache_doesNotCacheNonGet);
  T_RUN(cache_doesNotCacheNon2xx);
  T_RUN(cache_refetchesAfterTtl);
  T_RUN(cache_evictsOldestPastMax);
  T_RUN(cache_inactiveDoesNotWrap);

  T_RUN(idempotency_addsKeyToMutatingOps);
  T_RUN(idempotency_addsKeyByHttpMethod);
  T_RUN(idempotency_leavesReadsUntouched);
  T_RUN(idempotency_preservesCallerKeyCustomHeader);
  T_RUN(idempotency_injectedKeygen);
  T_RUN(idempotency_inactiveIsNoop);

  T_RUN(rbac_deniesBeforeAnyCall);
  T_RUN(rbac_allowsHeldPermission);
  T_RUN(rbac_opRuleAndWildcardGrant);
  T_RUN(rbac_defaultAllowAndDenyTrue);
  T_RUN(rbac_inactiveIsNoop);

  T_RUN(metrics_countsOkAndErrPerOp);
  T_RUN(metrics_injectedClock);
  T_RUN(metrics_inactiveRecordsNothing);

  T_RUN(telemetry_opensSpansAndPropagatesHeaders);
  T_RUN(telemetry_recordsFailedSpan);
  T_RUN(telemetry_injectedIdgenAndClock);
  T_RUN(telemetry_inactiveRecordsNothing);

  T_RUN(debug_redactsAndHonoursOnEntryMax);
  T_RUN(debug_capturesFailures);
  T_RUN(debug_injectedClockAndCustomRedact);
  T_RUN(debug_inactiveRecordsNothing);

  T_RUN(audit_oneRecordPerOpSinkActor);
  T_RUN(audit_defaultActorAnonymous);
  T_RUN(audit_injectedClock);
  T_RUN(audit_inactiveRecordsNothing);

  T_RUN(clienttrack_stableClientIdUniqueRequestIdsUa);
  T_RUN(clienttrack_doesNotClobberCallerUa);
  T_RUN(clienttrack_injectedIdgenFixedSession);
  T_RUN(clienttrack_inactiveStampsNothing);

  T_RUN(paging_stampsPageLimitAndReadsHeaders);
  T_RUN(paging_bodyCursorAndExplicitCursor);
  T_RUN(paging_nonListNotPaged);
  T_RUN(paging_inactiveStampsNothing);

  T_RUN(streaming_streamsListItems);
  T_RUN(streaming_batchesWithChunkSize);
  T_RUN(streaming_nonListNotStreamed);
  T_RUN(streaming_inactiveIsNoop);

  T_RUN(proxy_routesThroughProxy);
  T_RUN(proxy_bypassesNoProxyHosts);
  T_RUN(proxy_noUrlIsNoop);
  T_RUN(proxy_inactiveDoesNotWrap);

  T_RUN(composition_cacheHitSkipsSimulatedFailure);

  return sdktest::summary("feature_test");
}
