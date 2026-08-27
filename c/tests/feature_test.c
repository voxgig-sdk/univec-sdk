// Behavioural tests for the enterprise features shipped with this SDK
// (C port of tm/rust/tests/feature_test.rs). Each feature is unit-tested by
// driving it through a faithful miniature of the real operation pipeline
// (feature_harness.h) against a configurable mock transport — the same hook
// order and short-circuit rules as the generated entity op code, but with no
// live server and no API-specific fixtures. Each block runs only when its
// feature is present in this SDK (fh_present). Feature internal counters are
// read through feature_track(), mirroring the rust `f.track`/state assertions.

#include "feature_harness.h"

#include <stdio.h>

static int TESTS = 0;
#define RUN(fn)                                                                 \
  do {                                                                         \
    TESTS++;                                                                   \
    fn();                                                                      \
  } while (0)

// ---- reply callbacks for the mock transport --------------------------------

static voxgig_value* rep_404(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)n; (void)fd; (void)ctx; *e = NULL;
  return fh_response(404, v_undef(), v_undef());
}
static voxgig_value* rep_500(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)n; (void)fd; (void)ctx; *e = NULL;
  return fh_response(500, v_undef(), v_undef());
}
static voxgig_value* rep_503(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)n; (void)fd; (void)ctx; *e = NULL;
  return fh_response(503, v_undef(), v_undef());
}
static voxgig_value* rep_boom(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)n; (void)fd;
  *e = context_make_error(ctx, "boom", "boom");
  return NULL;
}
static voxgig_value* rep_nil_then_ok(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)fd; (void)ctx; *e = NULL;
  if (n < 2) return v_undef();
  return fh_response(200, cmap(1, "ok", v_bool(true)), v_undef());
}
static voxgig_value* rep_paging_headers(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)n; (void)fd; (void)ctx; *e = NULL;
  return fh_response(200, cmap(1, "items", clist(2, v_num(1), v_num(2))),
                     cmap(3, "x-next-page", v_str("2"), "x-total-count", v_str("5"),
                          "link", v_str("</w?page=2>; rel=\"next\"")));
}
static voxgig_value* rep_paging_cursor(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)n; (void)fd; (void)ctx; *e = NULL;
  return fh_response(200, cmap(2, "nextCursor", v_str("abc"), "hasMore", v_bool(true)),
                     v_undef());
}
static voxgig_value* rep_stream_list(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)n; (void)fd; (void)ctx; *e = NULL;
  return fh_response(200, clist(3, v_str("a"), v_str("b"), v_str("c")), v_undef());
}
static voxgig_value* rep_stream_nums(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)ud; (void)n; (void)fd; (void)ctx; *e = NULL;
  return fh_response(200, clist(5, v_num(1), v_num(2), v_num(3), v_num(4), v_num(5)),
                     v_undef());
}

// ---- injectable helpers -----------------------------------------------------

static voxgig_value* collect_fn(void* ud, voxgig_value* arg) {
  voxgig_list_push(voxgig_as_list((voxgig_value*)ud), v_share(arg));
  return v_undef();
}
static voxgig_value* keygen_K1(void* ud, voxgig_value* arg) {
  (void)ud; (void)arg; return v_str("K1");
}
static voxgig_value* idgen_suffix_X(void* ud, voxgig_value* arg) {
  (void)ud;
  const char* k = voxgig_is_string(arg) ? voxgig_as_string(arg) : "x";
  char b[64]; snprintf(b, sizeof(b), "%s-X", k); return v_str(b);
}
static voxgig_value* idgen_suffix_1(void* ud, voxgig_value* arg) {
  (void)ud;
  const char* k = voxgig_is_string(arg) ? voxgig_as_string(arg) : "x";
  char b[64]; snprintf(b, sizeof(b), "%s-1", k); return v_str(b);
}
static voxgig_value* const_42(void* ud, voxgig_value* arg) {
  (void)ud; (void)arg; return v_num(42);
}

// Convenience: default op (load /widget).
static FhOpSpec op_load(void) { FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "load"; return o; }

// =============================================================================
// netsim
// =============================================================================

static void test_netsim_fixed_latency_then_delegate(void) {
  if (!fh_present("netsim")) return;
  FhClock clock = fh_clock_new();
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(2, "latency", v_num(250), "sleep", fh_sleep_fn(&clock))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpSpec o = op_load();
  o.ctrl = cmap(1, "explain", v_map());
  FhOpResult res = fh_op(&h, o);
  CHECK(res.ok, "netsim latency: expected ok");
  CHECK_INT_EQ(fh_t(&clock), 250, "netsim latency: expected 250ms");
  CHECK_INT_EQ(fh_track_int(f, "calls"), 1, "netsim latency: 1 call");
}

static void test_netsim_ranged_latency_in_min_max(void) {
  if (!fh_present("netsim")) return;
  FhClock clock = fh_clock_new();
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(3, "latency", cmap(2, "min", v_num(100), "max", v_num(300)),
                            "seed", v_num(7), "sleep", fh_sleep_fn(&clock))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  CHECK(fh_t(&clock) >= 100 && fh_t(&clock) < 300, "netsim ranged latency in [100,300)");
}

static void test_netsim_equal_min_max_latency_exact(void) {
  if (!fh_present("netsim")) return;
  FhClock clock = fh_clock_new();
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(2, "latency", cmap(2, "min", v_num(50), "max", v_num(50)),
                            "sleep", fh_sleep_fn(&clock))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  CHECK_INT_EQ(fh_t(&clock), 50, "netsim equal min/max: exactly 50ms");
}

static void test_netsim_fail_times_returns_retryable_status(void) {
  if (!fh_present("netsim")) return;
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(2, "failTimes", v_num(2), "failStatus", v_num(503))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpResult a = fh_op(&h, op_load());
  CHECK_INT_EQ(a.result->status, 503, "netsim failTimes: 1st 503");
  FhOpResult b = fh_op(&h, op_load());
  CHECK_INT_EQ(b.result->status, 503, "netsim failTimes: 2nd 503");
  FhOpResult c = fh_op(&h, op_load());
  CHECK(c.ok, "netsim failTimes: 3rd ok");
}

static void test_netsim_fail_every_fails_every_nth(void) {
  if (!fh_present("netsim")) return;
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(1, "failEvery", v_num(2))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(fh_op(&h, op_load()).ok, "netsim failEvery: call 1 ok");
  CHECK(!fh_op(&h, op_load()).ok, "netsim failEvery: call 2 fails");
  CHECK(fh_op(&h, op_load()).ok, "netsim failEvery: call 3 ok");
}

static void test_netsim_fail_rate_with_seed_deterministic(void) {
  if (!fh_present("netsim")) return;
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(2, "failRate", v_num(1), "seed", v_num(5))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(!fh_op(&h, op_load()).ok, "netsim failRate: deterministic failure");
}

static void test_netsim_error_times_connection_error(void) {
  if (!fh_present("netsim")) return;
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(1, "errorTimes", v_num(1))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpResult res = fh_op(&h, op_load());
  CHECK_STR_EQ(fh_err_code(res.err), "netsim_conn", "netsim errorTimes: conn error");
}

static void test_netsim_offline_fails_every_call(void) {
  if (!fh_present("netsim")) return;
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(1, "offline", v_bool(true))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpResult res = fh_op(&h, op_load());
  CHECK_STR_EQ(fh_err_code(res.err), "netsim_offline", "netsim offline error");
}

static void test_netsim_rate_limit_times_429_retry_after(void) {
  if (!fh_present("netsim")) return;
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(2, "rateLimitTimes", v_num(1), "retryAfter", v_num(3))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpResult res = fh_op(&h, op_load());
  CHECK_INT_EQ(res.result->status, 429, "netsim rateLimit: 429");
  CHECK_STR_EQ(get_str(res.result->headers, "retry-after"), "3", "netsim rateLimit: retry-after 3");
}

static void test_netsim_inactive_does_not_wrap(void) {
  if (!fh_present("netsim")) return;
  Feature* f = feature_netsim_new();
  FhFeat feats[] = {{f, cmap(2, "active", v_bool(false), "offline", v_bool(true))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(fh_op(&h, op_load()).ok, "inactive netsim must not simulate");
  CHECK_INT_EQ(fh_track_int(f, "calls"), 0, "inactive netsim: 0 calls");
}

// =============================================================================
// retry
// =============================================================================

static void test_retry_retries_transient_then_succeeds(void) {
  if (!fh_present("retry,netsim")) return;
  FhClock clock = fh_clock_new();
  Feature* nf = feature_netsim_new();
  Feature* rf = feature_retry_new();
  FhFeat feats[] = {
    {nf, cmap(2, "failTimes", v_num(2), "failStatus", v_num(503))},
    {rf, cmap(4, "retries", v_num(3), "minDelay", v_num(10), "jitter", v_bool(false),
              "sleep", fh_sleep_fn(&clock))},
  };
  FhHarness h = fh_make(NULL, feats, 2);
  FhOpResult res = fh_op(&h, op_load());
  CHECK(res.ok, "retry transient: expected success after retries");
  CHECK_INT_EQ(fh_track_int(rf, "attempts"), 2, "retry transient: 2 retries");
}

static void test_retry_gives_up_after_budget(void) {
  if (!fh_present("retry,netsim")) return;
  FhClock clock = fh_clock_new();
  Feature* nf = feature_netsim_new();
  Feature* rf = feature_retry_new();
  FhFeat feats[] = {
    {nf, cmap(2, "failTimes", v_num(9), "failStatus", v_num(500))},
    {rf, cmap(4, "retries", v_num(2), "minDelay", v_num(1), "jitter", v_bool(false),
              "sleep", fh_sleep_fn(&clock))},
  };
  FhHarness h = fh_make(NULL, feats, 2);
  FhOpResult res = fh_op(&h, op_load());
  CHECK_INT_EQ(res.result->status, 500, "retry budget: final 500");
}

static void test_retry_does_not_retry_non_retryable_status(void) {
  if (!fh_present("retry")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(rep_404, NULL, &calls);
  Feature* rf = feature_retry_new();
  FhFeat feats[] = {{rf, cmap(2, "retries", v_num(3), "minDelay", v_num(0))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  CHECK_INT_EQ(rec_count(calls), 1, "retry 404: expected 1 call");
}

static void test_retry_retries_transport_error_then_returns_it(void) {
  if (!fh_present("retry")) return;
  FhClock clock = fh_clock_new();
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(rep_boom, NULL, &calls);
  Feature* rf = feature_retry_new();
  FhFeat feats[] = {{rf, cmap(4, "retries", v_num(2), "minDelay", v_num(1),
                             "jitter", v_bool(false), "sleep", fh_sleep_fn(&clock))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpResult res = fh_op(&h, op_load());
  CHECK(!res.ok, "retry transport error: expected failure");
  CHECK_INT_EQ(rec_count(calls), 3, "retry transport error: 3 attempts");
}

static void test_retry_retries_nil_transport_result(void) {
  if (!fh_present("retry")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(rep_nil_then_ok, NULL, &calls);
  Feature* rf = feature_retry_new();
  FhFeat feats[] = {{rf, cmap(2, "retries", v_num(3), "minDelay", v_num(0))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpResult res = fh_op(&h, op_load());
  CHECK(res.ok, "retry nil result: expected success");
  CHECK_INT_EQ(rec_count(calls), 2, "retry nil result: 2 attempts");
}

static void test_retry_honours_server_retry_after(void) {
  if (!fh_present("retry,netsim")) return;
  FhClock clock = fh_clock_new();
  Feature* nf = feature_netsim_new();
  Feature* rf = feature_retry_new();
  FhFeat feats[] = {
    {nf, cmap(2, "rateLimitTimes", v_num(1), "retryAfter", v_num(2))},
    {rf, cmap(5, "retries", v_num(2), "minDelay", v_num(10), "maxDelay", v_num(60000),
              "jitter", v_bool(false), "sleep", fh_sleep_fn(&clock))},
  };
  FhHarness h = fh_make(NULL, feats, 2);
  FhOpResult res = fh_op(&h, op_load());
  CHECK(res.ok, "retry retry-after: expected success");
  CHECK_INT_EQ(fh_t(&clock), 2000, "retry retry-after: 2000ms wait");
}

static void test_retry_inactive_does_not_wrap(void) {
  if (!fh_present("retry")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(rep_503, NULL, &calls);
  Feature* rf = feature_retry_new();
  FhFeat feats[] = {{rf, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  CHECK_INT_EQ(rec_count(calls), 1, "inactive retry: 1 call");
}

// =============================================================================
// timeout (elapsed measured via injectable now which advances on sleep)
// =============================================================================

// A server that "takes" 60ms of virtual time by advancing the shared clock.
static voxgig_value* rep_slow60(void* ud, int64_t n, voxgig_value* fd, Context* ctx, PNError** e) {
  (void)n; (void)fd; (void)ctx; *e = NULL;
  *(int64_t*)ud += 60; // advance virtual clock 60ms
  return fh_response(200, cmap(1, "ok", v_bool(true)), v_undef());
}

static void test_timeout_slow_request_times_out(void) {
  if (!fh_present("timeout")) return;
  FhClock clock = fh_clock_new();
  Fetcher* srv = fh_recorder(rep_slow60, clock.t, NULL);
  Feature* f = feature_timeout_new();
  FhFeat feats[] = {{f, cmap(2, "ms", v_num(10), "now", fh_now_fn(&clock))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpResult res = fh_op(&h, op_load());
  CHECK_STR_EQ(fh_err_code(res.err), "timeout", "timeout: expected timeout error");
  CHECK_INT_EQ(fh_track_int(f, "count"), 1, "timeout: 1 timeout recorded");
}

static void test_timeout_fast_request_passes(void) {
  if (!fh_present("timeout")) return;
  Feature* f = feature_timeout_new();
  FhFeat feats[] = {{f, cmap(1, "ms", v_num(1000))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(fh_op(&h, op_load()).ok, "timeout fast: expected success");
}

static void test_timeout_ms_zero_disables(void) {
  if (!fh_present("timeout")) return;
  Feature* f = feature_timeout_new();
  FhFeat feats[] = {{f, cmap(1, "ms", v_num(0))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(fh_op(&h, op_load()).ok, "timeout ms=0: expected success");
}

static void test_timeout_inactive_does_not_wrap(void) {
  if (!fh_present("timeout")) return;
  Feature* f = feature_timeout_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(fh_op(&h, op_load()).ok, "timeout inactive: expected success");
}

// =============================================================================
// ratelimit
// =============================================================================

static void test_ratelimit_throttles_once_burst_spent(void) {
  if (!fh_present("ratelimit")) return;
  FhClock clock = fh_clock_new();
  Feature* f = feature_ratelimit_new();
  FhFeat feats[] = {{f, cmap(4, "rate", v_num(1), "burst", v_num(2),
                            "now", fh_now_fn(&clock), "sleep", fh_sleep_fn(&clock))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  fh_op(&h, op_load());
  fh_op(&h, op_load());
  CHECK_INT_EQ(fh_track_int(f, "throttled"), 1, "ratelimit: 1 throttle");
  CHECK(fh_t(&clock) > 0, "ratelimit: clock advanced while throttled");
}

static void test_ratelimit_burst_defaults_to_rate_and_refills(void) {
  if (!fh_present("ratelimit")) return;
  FhClock clock = fh_clock_new();
  Feature* f = feature_ratelimit_new();
  FhFeat feats[] = {{f, cmap(3, "rate", v_num(2), "now", fh_now_fn(&clock),
                            "sleep", fh_sleep_fn(&clock))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  fh_op(&h, op_load());
  fh_advance(&clock, 1000); // refill
  fh_op(&h, op_load());
  CHECK_INT_EQ(fh_track_int(f, "throttled"), 0, "ratelimit refill: no throttling");
}

static void test_ratelimit_inactive_does_not_wrap(void) {
  if (!fh_present("ratelimit")) return;
  Feature* f = feature_ratelimit_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(fh_op(&h, op_load()).ok, "ratelimit inactive: expected success");
  CHECK_INT_EQ(fh_track_int(f, "throttled"), 0, "ratelimit inactive: 0 throttled");
}

// =============================================================================
// cache
// =============================================================================

static FhOpSpec op_load_path(const char* path) {
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "load"; o.path = path; return o;
}

static void test_cache_serves_repeated_read_from_cache(void) {
  if (!fh_present("cache")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_cache_new();
  FhFeat feats[] = {{f, cmap(1, "ttl", v_num(10000))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpResult a = fh_op(&h, op_load_path("/w/1"));
  FhOpResult b = fh_op(&h, op_load_path("/w/1"));
  CHECK_INT_EQ(rec_count(calls), 1, "cache: 1 network call");
  CHECK(v_eq(a.data, b.data), "cache: identical cached data");
  CHECK_INT_EQ(fh_track_int(f, "hit"), 1, "cache: 1 hit");
}

static void test_cache_does_not_cache_non_get(void) {
  if (!fh_present("cache")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_cache_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o1; memset(&o1, 0, sizeof(o1)); o1.op = "create"; o1.path = "/w";
  fh_op(&h, o1);
  fh_op(&h, o1);
  CHECK_INT_EQ(rec_count(calls), 2, "cache non-GET: 2 calls");
}

static void test_cache_does_not_cache_non_2xx(void) {
  if (!fh_present("cache")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(rep_500, NULL, &calls);
  Feature* f = feature_cache_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load_path("/w"));
  fh_op(&h, op_load_path("/w"));
  CHECK_INT_EQ(rec_count(calls), 2, "cache non-2xx: 2 calls");
  CHECK_INT_EQ(fh_track_int(f, "bypass"), 2, "cache non-2xx: 2 bypasses");
}

static void test_cache_refetches_after_ttl(void) {
  if (!fh_present("cache")) return;
  FhClock clock = fh_clock_new();
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_cache_new();
  FhFeat feats[] = {{f, cmap(2, "ttl", v_num(1000), "now", fh_now_fn(&clock))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load_path("/w"));
  fh_advance(&clock, 1500);
  fh_op(&h, op_load_path("/w"));
  CHECK_INT_EQ(rec_count(calls), 2, "cache ttl expiry: 2 calls");
}

static void test_cache_evicts_oldest_past_max(void) {
  if (!fh_present("cache")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_cache_new();
  FhFeat feats[] = {{f, cmap(2, "ttl", v_num(10000), "max", v_num(1))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load_path("/a"));
  fh_op(&h, op_load_path("/b")); // evicts /a
  fh_op(&h, op_load_path("/a")); // miss again
  CHECK_INT_EQ(rec_count(calls), 3, "cache evict: 3 calls");
}

static void test_cache_inactive_does_not_wrap(void) {
  if (!fh_present("cache")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_cache_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load_path("/x"));
  fh_op(&h, op_load_path("/x"));
  CHECK_INT_EQ(rec_count(calls), 2, "cache inactive: 2 calls");
}

// =============================================================================
// idempotency
// =============================================================================

static void test_idempotency_adds_key_to_mutating_ops(void) {
  if (!fh_present("idempotency")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_idempotency_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "create"; o.path = "/w";
  fh_op(&h, o);
  CHECK(!v_is_noval(getp(rec_headers(calls, 0), "Idempotency-Key")),
        "idempotency: key on create");
}

static void test_idempotency_adds_key_by_http_method(void) {
  if (!fh_present("idempotency")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_idempotency_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "act"; o.method = "PUT"; o.path = "/w";
  fh_op(&h, o);
  CHECK(!v_is_noval(getp(rec_headers(calls, 0), "Idempotency-Key")),
        "idempotency: key on PUT");
}

static void test_idempotency_leaves_reads_untouched(void) {
  if (!fh_present("idempotency")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_idempotency_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load_path("/w/1"));
  CHECK(v_is_noval(getp(rec_headers(calls, 0), "Idempotency-Key")),
        "idempotency: no key on load");
}

static void test_idempotency_preserves_caller_key_custom_header(void) {
  if (!fh_present("idempotency")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_idempotency_new();
  FhFeat feats[] = {{f, cmap(1, "header", v_str("X-Idem"))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "create"; o.path = "/w";
  o.headers = cmap(1, "X-Idem", v_str("caller-1"));
  fh_op(&h, o);
  CHECK_STR_EQ(get_str(rec_headers(calls, 0), "X-Idem"), "caller-1",
               "idempotency: caller key preserved");
}

static void test_idempotency_injected_keygen(void) {
  if (!fh_present("idempotency")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_idempotency_new();
  FhFeat feats[] = {{f, cmap(1, "keygen", vfn(keygen_K1, NULL))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "create"; o.path = "/w";
  fh_op(&h, o);
  CHECK_STR_EQ(get_str(rec_headers(calls, 0), "Idempotency-Key"), "K1",
               "idempotency: injected key");
  voxgig_value* t = feature_track(f);
  CHECK_STR_EQ(get_str(t, "last"), "K1", "idempotency: last==K1");
  CHECK_INT_EQ(to_int(getp(t, "issued")), 1, "idempotency: issued==1");
}

static void test_idempotency_inactive_is_noop(void) {
  if (!fh_present("idempotency")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_idempotency_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "create"; o.path = "/w";
  fh_op(&h, o);
  CHECK(v_is_noval(getp(rec_headers(calls, 0), "Idempotency-Key")),
        "idempotency inactive: no key");
}

// =============================================================================
// rbac
// =============================================================================

static void test_rbac_denies_before_any_call(void) {
  if (!fh_present("rbac")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_rbac_new();
  FhFeat feats[] = {{f, cmap(2, "rules", cmap(1, "widget.remove", v_str("admin")),
                            "permissions", v_list())}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "remove"; o.path = "/w/1";
  FhOpResult res = fh_op(&h, o);
  CHECK_STR_EQ(fh_err_code(res.err), "rbac_denied", "rbac: denied");
  CHECK_INT_EQ(rec_count(calls), 0, "rbac: no network calls");
  CHECK_INT_EQ(fh_track_int(f, "denied"), 1, "rbac: 1 denial");
}

static void test_rbac_allows_held_permission(void) {
  if (!fh_present("rbac")) return;
  Feature* f = feature_rbac_new();
  FhFeat feats[] = {{f, cmap(2, "rules", cmap(1, "widget.remove", v_str("admin")),
                            "permissions", clist(1, v_str("admin")))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "remove"; o.path = "/w/1";
  CHECK(fh_op(&h, o).ok, "rbac: allow held permission");
}

static void test_rbac_op_rule_and_wildcard_grant(void) {
  if (!fh_present("rbac")) return;
  Feature* f = feature_rbac_new();
  FhFeat feats[] = {{f, cmap(2, "rules", cmap(1, "load", v_str("read")),
                            "permissions", clist(1, v_str("*")))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(fh_op(&h, op_load()).ok, "rbac: wildcard grant");
}

static void test_rbac_default_allow_and_deny_true(void) {
  if (!fh_present("rbac")) return;
  Feature* fa = feature_rbac_new();
  FhFeat af[] = {{fa, cmap(1, "permissions", v_list())}};
  FhHarness allow = fh_make(NULL, af, 1);
  CHECK(fh_op(&allow, op_load()).ok, "rbac: default allow");

  Feature* fd = feature_rbac_new();
  FhFeat df[] = {{fd, cmap(2, "deny", v_bool(true), "permissions", v_list())}};
  FhHarness deny = fh_make(NULL, df, 1);
  FhOpResult res = fh_op(&deny, op_load());
  CHECK_STR_EQ(fh_err_code(res.err), "rbac_denied", "rbac: default deny");
}

static void test_rbac_inactive_is_noop(void) {
  if (!fh_present("rbac")) return;
  Feature* f = feature_rbac_new();
  FhFeat feats[] = {{f, cmap(2, "active", v_bool(false), "deny", v_bool(true))}};
  FhHarness h = fh_make(NULL, feats, 1);
  CHECK(fh_op(&h, op_load()).ok, "rbac inactive: must not deny");
}

// =============================================================================
// metrics
// =============================================================================

static void test_metrics_counts_ok_and_err_per_op(void) {
  if (!fh_present("metrics,netsim")) return;
  Feature* nf = feature_netsim_new();
  Feature* f = feature_metrics_new();
  FhFeat feats[] = {
    {nf, cmap(2, "failTimes", v_num(1), "failStatus", v_num(500))},
    {f, v_undef()},
  };
  FhHarness h = fh_make(NULL, feats, 2);
  fh_op(&h, op_load());
  fh_op(&h, op_load());
  FhOpSpec ol; memset(&ol, 0, sizeof(ol)); ol.op = "list";
  fh_op(&h, ol);
  voxgig_value* t = feature_track(f);
  voxgig_value* total = getp(t, "total");
  CHECK_INT_EQ(to_int(getp(total, "count")), 3, "metrics total count 3");
  CHECK_INT_EQ(to_int(getp(total, "ok")), 2, "metrics total ok 2");
  CHECK_INT_EQ(to_int(getp(total, "err")), 1, "metrics total err 1");
  voxgig_value* wl = getp(getp(t, "ops"), "widget.load");
  CHECK_INT_EQ(to_int(getp(wl, "count")), 2, "metrics widget.load count 2");
}

static void test_metrics_injected_clock(void) {
  if (!fh_present("metrics")) return;
  FhClock clock = fh_clock_new();
  Feature* f = feature_metrics_new();
  FhFeat feats[] = {{f, cmap(1, "now", fh_now_fn(&clock))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  voxgig_value* total = getp(feature_track(f), "total");
  CHECK_INT_EQ(to_int(getp(total, "count")), 1, "metrics: 1 recorded op");
  CHECK_INT_EQ(to_int(getp(total, "totalMs")), 0, "metrics: 0ms frozen clock");
}

static void test_metrics_inactive_records_nothing(void) {
  if (!fh_present("metrics")) return;
  Feature* f = feature_metrics_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  CHECK_INT_EQ(to_int(getp(getp(feature_track(f), "total"), "count")), 0,
               "metrics inactive: no records");
}

// =============================================================================
// telemetry
// =============================================================================

static void test_telemetry_opens_spans_and_propagates_headers(void) {
  if (!fh_present("telemetry")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  voxgig_value* exported = v_list();
  Feature* f = feature_telemetry_new();
  FhFeat feats[] = {{f, cmap(1, "exporter", vfn(collect_fn, exported))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpResult res = fh_op(&h, op_load());
  CHECK(res.ok, "telemetry: expected success");
  CHECK_INT_EQ(fh_track_int(f, "spans"), 1, "telemetry: 1 span");
  CHECK_INT_EQ((int)voxgig_list_len(voxgig_as_list(exported)), 1, "telemetry: 1 export");
  voxgig_value* span = voxgig_getelem(exported, v_int(0), v_undef());
  voxgig_value* sent = rec_headers(calls, 0);
  CHECK(v_eq(getp(sent, "X-Trace-Id"), getp(span, "traceId")),
        "telemetry: propagated trace id");
  const char* tp = get_str(sent, "traceparent");
  CHECK(tp && strncmp(tp, "00-", 3) == 0 && strlen(tp) >= 3 &&
            strcmp(tp + strlen(tp) - 3, "-01") == 0,
        "telemetry: W3C traceparent shape");
}

static void test_telemetry_records_failed_span(void) {
  if (!fh_present("telemetry,netsim")) return;
  voxgig_value* exported = v_list();
  Feature* nf = feature_netsim_new();
  Feature* f = feature_telemetry_new();
  FhFeat feats[] = {
    {nf, cmap(2, "failTimes", v_num(1), "failStatus", v_num(500))},
    {f, cmap(1, "exporter", vfn(collect_fn, exported))},
  };
  FhHarness h = fh_make(NULL, feats, 2);
  fh_op(&h, op_load());
  CHECK_INT_EQ(fh_track_int(f, "spans"), 1, "telemetry fail: 1 span");
  voxgig_value* span = voxgig_getelem(exported, v_int(0), v_undef());
  bool ok = true;
  CHECK(get_bool(span, "ok", &ok) && ok == false, "telemetry fail: span ok=false");
}

static void test_telemetry_injected_idgen_and_clock(void) {
  if (!fh_present("telemetry")) return;
  FhClock clock = fh_clock_new();
  voxgig_value* exported = v_list();
  Feature* f = feature_telemetry_new();
  FhFeat feats[] = {{f, cmap(3, "idgen", vfn(idgen_suffix_X, NULL), "now", fh_now_fn(&clock),
                            "exporter", vfn(collect_fn, exported))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  voxgig_value* span = voxgig_getelem(exported, v_int(0), v_undef());
  CHECK_STR_EQ(get_str(span, "traceId"), "trace-X", "telemetry idgen: traceId");
  CHECK_INT_EQ(to_int(getp(span, "durationMs")), 0, "telemetry clock: 0ms");
}

static void test_telemetry_inactive_records_nothing(void) {
  if (!fh_present("telemetry")) return;
  Feature* f = feature_telemetry_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  CHECK_INT_EQ(fh_track_int(f, "spans"), 0, "telemetry inactive: no spans");
}

// =============================================================================
// debug
// =============================================================================

static void test_debug_redacts_and_honours_onentry_max(void) {
  if (!fh_present("debug")) return;
  voxgig_value* seen = v_list();
  Feature* f = feature_debug_new();
  FhFeat feats[] = {{f, cmap(2, "max", v_num(1), "onEntry", vfn(collect_fn, seen))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpSpec o = op_load();
  o.headers = cmap(1, "authorization", v_str("Bearer secret"));
  fh_op(&h, o);
  FhOpSpec ol; memset(&ol, 0, sizeof(ol)); ol.op = "list";
  fh_op(&h, ol);
  CHECK_INT_EQ(fh_track_int(f, "entries"), 1, "debug: ring buffer capped at 1");
  CHECK_INT_EQ((int)voxgig_list_len(voxgig_as_list(seen)), 2, "debug: onEntry for both ops");
  voxgig_value* headers = getp(voxgig_getelem(seen, v_int(0), v_undef()), "headers");
  CHECK_STR_EQ(get_str(headers, "authorization"), "<redacted>", "debug: redacted authorization");
}

static void test_debug_captures_failures(void) {
  if (!fh_present("debug,netsim")) return;
  voxgig_value* seen = v_list();
  Feature* nf = feature_netsim_new();
  Feature* f = feature_debug_new();
  FhFeat feats[] = {
    {nf, cmap(2, "failTimes", v_num(1), "failStatus", v_num(500))},
    {f, cmap(1, "onEntry", vfn(collect_fn, seen))},
  };
  FhHarness h = fh_make(NULL, feats, 2);
  fh_op(&h, op_load());
  CHECK_INT_EQ(fh_track_int(f, "entries"), 1, "debug fail: 1 entry");
  bool ok = true;
  voxgig_value* e0 = voxgig_getelem(seen, v_int(0), v_undef());
  CHECK(get_bool(e0, "ok", &ok) && ok == false, "debug fail: entry ok=false");
}

static void test_debug_injected_clock_and_custom_redact(void) {
  if (!fh_present("debug")) return;
  FhClock clock = fh_clock_new();
  voxgig_value* seen = v_list();
  Feature* f = feature_debug_new();
  FhFeat feats[] = {{f, cmap(3, "now", fh_now_fn(&clock), "redact", clist(1, v_str("x-secret")),
                            "onEntry", vfn(collect_fn, seen))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpSpec o = op_load();
  o.headers = cmap(2, "x-secret", v_str("hide"), "x-ok", v_str("show"));
  fh_op(&h, o);
  voxgig_value* headers = getp(voxgig_getelem(seen, v_int(0), v_undef()), "headers");
  CHECK_STR_EQ(get_str(headers, "x-secret"), "<redacted>", "debug custom redact: x-secret");
  CHECK_STR_EQ(get_str(headers, "x-ok"), "show", "debug custom redact: x-ok kept");
}

static void test_debug_inactive_records_nothing(void) {
  if (!fh_present("debug")) return;
  Feature* f = feature_debug_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  CHECK_INT_EQ(fh_track_int(f, "entries"), 0, "debug inactive: no entries");
}

// =============================================================================
// audit
// =============================================================================

static void test_audit_one_record_per_op_sink_actor(void) {
  if (!fh_present("audit,netsim")) return;
  voxgig_value* sunk = v_list();
  Feature* nf = feature_netsim_new();
  Feature* f = feature_audit_new();
  FhFeat feats[] = {
    {nf, cmap(2, "failTimes", v_num(1), "failStatus", v_num(500))},
    {f, cmap(3, "actor", v_str("svc"), "max", v_num(5), "sink", vfn(collect_fn, sunk))},
  };
  FhHarness h = fh_make(NULL, feats, 2);
  FhOpSpec o1; memset(&o1, 0, sizeof(o1)); o1.op = "remove"; o1.path = "/w/1";
  fh_op(&h, o1);
  FhOpSpec o2 = op_load();
  o2.ctrl = cmap(1, "actor", v_str("per-call"));
  fh_op(&h, o2);
  CHECK_INT_EQ(fh_track_int(f, "records"), 2, "audit: 2 records");
  voxgig_value* r0 = voxgig_getelem(sunk, v_int(0), v_undef());
  voxgig_value* r1 = voxgig_getelem(sunk, v_int(1), v_undef());
  CHECK_STR_EQ(get_str(r0, "outcome"), "error", "audit: r0 outcome error");
  CHECK_STR_EQ(get_str(r0, "actor"), "svc", "audit: r0 actor svc");
  CHECK_STR_EQ(get_str(r1, "actor"), "per-call", "audit: r1 actor per-call");
  CHECK_INT_EQ((int)voxgig_list_len(voxgig_as_list(sunk)), 2, "audit: 2 sunk");
}

static void test_audit_default_actor_anonymous(void) {
  if (!fh_present("audit")) return;
  voxgig_value* sunk = v_list();
  Feature* f = feature_audit_new();
  FhFeat feats[] = {{f, cmap(1, "sink", vfn(collect_fn, sunk))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  CHECK_STR_EQ(get_str(voxgig_getelem(sunk, v_int(0), v_undef()), "actor"), "anonymous",
               "audit: default actor anonymous");
}

static void test_audit_injected_clock(void) {
  if (!fh_present("audit")) return;
  voxgig_value* sunk = v_list();
  Feature* f = feature_audit_new();
  FhFeat feats[] = {{f, cmap(2, "now", vfn(const_42, NULL), "sink", vfn(collect_fn, sunk))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  CHECK_INT_EQ(to_int(getp(voxgig_getelem(sunk, v_int(0), v_undef()), "ts")), 42,
               "audit injected clock: ts==42");
}

static void test_audit_inactive_records_nothing(void) {
  if (!fh_present("audit")) return;
  Feature* f = feature_audit_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(NULL, feats, 1);
  fh_op(&h, op_load());
  CHECK_INT_EQ(fh_track_int(f, "records"), 0, "audit inactive: no records");
}

// =============================================================================
// clienttrack
// =============================================================================

static void test_clienttrack_stable_client_id_unique_request_ids_ua(void) {
  if (!fh_present("clienttrack")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_clienttrack_new();
  FhFeat feats[] = {{f, cmap(2, "clientName", v_str("Acme"), "clientVersion", v_str("2.0.0"))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  fh_op(&h, op_load());
  voxgig_value* h0 = rec_headers(calls, 0);
  voxgig_value* h1 = rec_headers(calls, 1);
  CHECK_STR_EQ(get_str(h0, "User-Agent"), "Acme/2.0.0", "clienttrack: UA");
  CHECK_STR_EQ(get_str(h0, "X-Client-Id"), get_str(h1, "X-Client-Id"), "clienttrack: stable client id");
  CHECK(strcmp(get_str(h0, "X-Request-Id"), get_str(h1, "X-Request-Id")) != 0,
        "clienttrack: fresh request ids");
  CHECK_INT_EQ(fh_track_int(f, "requests"), 2, "clienttrack: 2 tracked requests");
}

static void test_clienttrack_does_not_clobber_caller_ua(void) {
  if (!fh_present("clienttrack")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_clienttrack_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o = op_load();
  o.headers = cmap(1, "User-Agent", v_str("mine"));
  fh_op(&h, o);
  CHECK_STR_EQ(get_str(rec_headers(calls, 0), "User-Agent"), "mine",
               "clienttrack: caller UA preserved");
}

static void test_clienttrack_injected_idgen_fixed_session(void) {
  if (!fh_present("clienttrack")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_clienttrack_new();
  FhFeat feats[] = {{f, cmap(2, "sessionId", v_str("S1"), "idgen", vfn(idgen_suffix_1, NULL))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  CHECK_STR_EQ(get_str(rec_headers(calls, 0), "X-Client-Id"), "S1", "clienttrack: fixed session");
  CHECK_STR_EQ(get_str(rec_headers(calls, 0), "X-Request-Id"), "request-1",
               "clienttrack: injected request id");
}

static void test_clienttrack_inactive_stamps_nothing(void) {
  if (!fh_present("clienttrack")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_clienttrack_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  CHECK(v_is_noval(getp(rec_headers(calls, 0), "X-Client-Id")),
        "clienttrack inactive: no headers");
}

// =============================================================================
// paging
// =============================================================================

static FhOpSpec op_list_path(const char* path) {
  FhOpSpec o; memset(&o, 0, sizeof(o)); o.op = "list"; o.path = path; return o;
}

static void test_paging_stamps_page_limit_and_reads_headers(void) {
  if (!fh_present("paging")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(rep_paging_headers, NULL, &calls);
  Feature* f = feature_paging_new();
  FhFeat feats[] = {{f, cmap(1, "limit", v_num(2))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpResult res = fh_op(&h, op_list_path("/w"));
  CHECK(strstr(rec_url(calls, 0), "page=1") != NULL, "paging: page=1 stamped");
  CHECK(strstr(rec_url(calls, 0), "limit=2") != NULL, "paging: limit=2 stamped");
  voxgig_value* paging = res.result->paging;
  CHECK_INT_EQ(to_int(getp(paging, "nextPage")), 2, "paging: nextPage 2");
  CHECK_INT_EQ(to_int(getp(paging, "totalCount")), 5, "paging: totalCount 5");
  CHECK_STR_EQ(get_str(paging, "next"), "/w?page=2", "paging: next");
}

static void test_paging_body_cursor_and_explicit_cursor(void) {
  if (!fh_present("paging")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(rep_paging_cursor, NULL, &calls);
  Feature* f = feature_paging_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpSpec o = op_list_path("/w");
  o.ctrl = cmap(1, "paging", cmap(1, "cursor", v_str("xyz")));
  FhOpResult res = fh_op(&h, o);
  CHECK(strstr(rec_url(calls, 0), "cursor=xyz") != NULL, "paging: cursor=xyz stamped");
  voxgig_value* paging = res.result->paging;
  CHECK_STR_EQ(get_str(paging, "cursor"), "abc", "paging: cursor abc");
  bool hm = false;
  CHECK(get_bool(paging, "hasMore", &hm) && hm, "paging: hasMore true");
}

static void test_paging_non_list_not_paged(void) {
  if (!fh_present("paging")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_paging_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load_path("/w/1"));
  CHECK(strstr(rec_url(calls, 0), "page=") == NULL, "paging: no page param on load");
}

static void test_paging_inactive_stamps_nothing(void) {
  if (!fh_present("paging")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_paging_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_list_path("/w"));
  CHECK(strstr(rec_url(calls, 0), "page=") == NULL, "paging inactive: no stamp");
}

// =============================================================================
// streaming
// =============================================================================

static void test_streaming_streams_list_items(void) {
  if (!fh_present("streaming")) return;
  FhClock clock = fh_clock_new();
  Fetcher* srv = fh_recorder(rep_stream_list, NULL, NULL);
  Feature* f = feature_streaming_new();
  FhFeat feats[] = {{f, cmap(2, "chunkDelay", v_num(5), "sleep", fh_sleep_fn(&clock))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpResult res = fh_op(&h, op_list_path("/w"));
  CHECK(res.result->streaming, "streaming: expected streaming result");
  CHECK(res.result->stream != NULL, "streaming: stream fn present");
  voxgig_value* seen = res.result->stream(res.result->stream_ud);
  CHECK(v_eq(seen, clist(3, v_str("a"), v_str("b"), v_str("c"))), "streaming: streamed items");
  CHECK_INT_EQ(fh_t(&clock), 15, "streaming: 15ms paced delay");
}

static void test_streaming_batches_with_chunksize(void) {
  if (!fh_present("streaming")) return;
  Fetcher* srv = fh_recorder(rep_stream_nums, NULL, NULL);
  Feature* f = feature_streaming_new();
  FhFeat feats[] = {{f, cmap(1, "chunkSize", v_num(2))}};
  FhHarness h = fh_make(srv, feats, 1);
  FhOpResult res = fh_op(&h, op_list_path("/w"));
  voxgig_value* batches = res.result->stream(res.result->stream_ud);
  voxgig_value* want = clist(3, clist(2, v_num(1), v_num(2)), clist(2, v_num(3), v_num(4)),
                            clist(1, v_num(5)));
  CHECK(v_eq(batches, want), "streaming: chunked batches");
}

static void test_streaming_non_list_not_streamed(void) {
  if (!fh_present("streaming")) return;
  Feature* f = feature_streaming_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpResult res = fh_op(&h, op_load());
  CHECK(!res.result->streaming && res.result->stream == NULL,
        "streaming: no stream on a non-list op");
}

static void test_streaming_inactive_is_noop(void) {
  if (!fh_present("streaming")) return;
  Feature* f = feature_streaming_new();
  FhFeat feats[] = {{f, cmap(1, "active", v_bool(false))}};
  FhHarness h = fh_make(NULL, feats, 1);
  FhOpResult res = fh_op(&h, op_list_path("/w"));
  CHECK(!res.result->streaming, "streaming inactive: must not attach");
  CHECK_INT_EQ(fh_track_int(f, "opened"), 0, "streaming inactive: 0 opened");
}

// =============================================================================
// proxy
// =============================================================================

static void test_proxy_routes_through_proxy(void) {
  if (!fh_present("proxy")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_proxy_new();
  FhFeat feats[] = {{f, cmap(1, "url", v_str("http://proxy:8080"))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  CHECK_STR_EQ(get_str(rec_fetchdef(calls, 0), "proxy"), "http://proxy:8080",
               "proxy: annotation");
  CHECK_INT_EQ(fh_track_int(f, "routed"), 1, "proxy: 1 routed call");
}

static void test_proxy_bypasses_noproxy_hosts(void) {
  if (!fh_present("proxy")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_proxy_new();
  FhFeat feats[] = {{f, cmap(2, "url", v_str("http://proxy:8080"),
                            "noProxy", clist(1, v_str("api.test")))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  CHECK(v_is_noval(getp(rec_fetchdef(calls, 0), "proxy")), "proxy: noProxy bypass");
}

static void test_proxy_fromenv_reads_https_proxy(void) {
  if (!fh_present("proxy")) return;
  setenv("HTTPS_PROXY", "http://env-proxy:8080", 1);
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_proxy_new();
  FhFeat feats[] = {{f, cmap(1, "fromEnv", v_bool(true))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  unsetenv("HTTPS_PROXY");
  CHECK_STR_EQ(get_str(rec_fetchdef(calls, 0), "proxy"), "http://env-proxy:8080",
               "proxy: env proxy");
}

static void test_proxy_no_url_is_noop(void) {
  if (!fh_present("proxy")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_proxy_new();
  FhFeat feats[] = {{f, v_undef()}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  CHECK(v_is_noval(getp(rec_fetchdef(calls, 0), "proxy")), "proxy: no annotation");
}

static void test_proxy_inactive_does_not_wrap(void) {
  if (!fh_present("proxy")) return;
  voxgig_value* calls;
  Fetcher* srv = fh_recorder(NULL, NULL, &calls);
  Feature* f = feature_proxy_new();
  FhFeat feats[] = {{f, cmap(2, "active", v_bool(false), "url", v_str("http://proxy:8080"))}};
  FhHarness h = fh_make(srv, feats, 1);
  fh_op(&h, op_load());
  CHECK(v_is_noval(getp(rec_fetchdef(calls, 0), "proxy")), "proxy inactive: no route");
}

// =============================================================================
// composition
// =============================================================================

static void test_composition_cache_hit_skips_simulated_failure(void) {
  if (!fh_present("cache,netsim")) return;
  Feature* nf = feature_netsim_new();
  Feature* cf = feature_cache_new();
  FhFeat feats[] = {
    {nf, cmap(1, "failEvery", v_num(2))},
    {cf, cmap(1, "ttl", v_num(10000))},
  };
  FhHarness h = fh_make(NULL, feats, 2);
  CHECK(fh_op(&h, op_load_path("/w")).ok, "composition: first load ok");
  CHECK(fh_op(&h, op_load_path("/w")).ok, "composition: second load hits cache");
  CHECK_INT_EQ(fh_track_int(nf, "calls"), 1, "composition: 1 simulated call");
}

// =============================================================================

int main(void) {
  // netsim
  RUN(test_netsim_fixed_latency_then_delegate);
  RUN(test_netsim_ranged_latency_in_min_max);
  RUN(test_netsim_equal_min_max_latency_exact);
  RUN(test_netsim_fail_times_returns_retryable_status);
  RUN(test_netsim_fail_every_fails_every_nth);
  RUN(test_netsim_fail_rate_with_seed_deterministic);
  RUN(test_netsim_error_times_connection_error);
  RUN(test_netsim_offline_fails_every_call);
  RUN(test_netsim_rate_limit_times_429_retry_after);
  RUN(test_netsim_inactive_does_not_wrap);
  // retry
  RUN(test_retry_retries_transient_then_succeeds);
  RUN(test_retry_gives_up_after_budget);
  RUN(test_retry_does_not_retry_non_retryable_status);
  RUN(test_retry_retries_transport_error_then_returns_it);
  RUN(test_retry_retries_nil_transport_result);
  RUN(test_retry_honours_server_retry_after);
  RUN(test_retry_inactive_does_not_wrap);
  // timeout
  RUN(test_timeout_slow_request_times_out);
  RUN(test_timeout_fast_request_passes);
  RUN(test_timeout_ms_zero_disables);
  RUN(test_timeout_inactive_does_not_wrap);
  // ratelimit
  RUN(test_ratelimit_throttles_once_burst_spent);
  RUN(test_ratelimit_burst_defaults_to_rate_and_refills);
  RUN(test_ratelimit_inactive_does_not_wrap);
  // cache
  RUN(test_cache_serves_repeated_read_from_cache);
  RUN(test_cache_does_not_cache_non_get);
  RUN(test_cache_does_not_cache_non_2xx);
  RUN(test_cache_refetches_after_ttl);
  RUN(test_cache_evicts_oldest_past_max);
  RUN(test_cache_inactive_does_not_wrap);
  // idempotency
  RUN(test_idempotency_adds_key_to_mutating_ops);
  RUN(test_idempotency_adds_key_by_http_method);
  RUN(test_idempotency_leaves_reads_untouched);
  RUN(test_idempotency_preserves_caller_key_custom_header);
  RUN(test_idempotency_injected_keygen);
  RUN(test_idempotency_inactive_is_noop);
  // rbac
  RUN(test_rbac_denies_before_any_call);
  RUN(test_rbac_allows_held_permission);
  RUN(test_rbac_op_rule_and_wildcard_grant);
  RUN(test_rbac_default_allow_and_deny_true);
  RUN(test_rbac_inactive_is_noop);
  // metrics
  RUN(test_metrics_counts_ok_and_err_per_op);
  RUN(test_metrics_injected_clock);
  RUN(test_metrics_inactive_records_nothing);
  // telemetry
  RUN(test_telemetry_opens_spans_and_propagates_headers);
  RUN(test_telemetry_records_failed_span);
  RUN(test_telemetry_injected_idgen_and_clock);
  RUN(test_telemetry_inactive_records_nothing);
  // debug
  RUN(test_debug_redacts_and_honours_onentry_max);
  RUN(test_debug_captures_failures);
  RUN(test_debug_injected_clock_and_custom_redact);
  RUN(test_debug_inactive_records_nothing);
  // audit
  RUN(test_audit_one_record_per_op_sink_actor);
  RUN(test_audit_default_actor_anonymous);
  RUN(test_audit_injected_clock);
  RUN(test_audit_inactive_records_nothing);
  // clienttrack
  RUN(test_clienttrack_stable_client_id_unique_request_ids_ua);
  RUN(test_clienttrack_does_not_clobber_caller_ua);
  RUN(test_clienttrack_injected_idgen_fixed_session);
  RUN(test_clienttrack_inactive_stamps_nothing);
  // paging
  RUN(test_paging_stamps_page_limit_and_reads_headers);
  RUN(test_paging_body_cursor_and_explicit_cursor);
  RUN(test_paging_non_list_not_paged);
  RUN(test_paging_inactive_stamps_nothing);
  // streaming
  RUN(test_streaming_streams_list_items);
  RUN(test_streaming_batches_with_chunksize);
  RUN(test_streaming_non_list_not_streamed);
  RUN(test_streaming_inactive_is_noop);
  // proxy
  RUN(test_proxy_routes_through_proxy);
  RUN(test_proxy_bypasses_noproxy_hosts);
  RUN(test_proxy_fromenv_reads_https_proxy);
  RUN(test_proxy_no_url_is_noop);
  RUN(test_proxy_inactive_does_not_wrap);
  // composition
  RUN(test_composition_cache_hit_skips_simulated_failure);

  printf("feature: %d behaviors run\n", TESTS);
  TEST_SUMMARY("feature");
}
