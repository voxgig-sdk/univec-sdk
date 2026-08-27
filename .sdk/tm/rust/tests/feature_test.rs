// Behavioural tests for the enterprise features shipped with this SDK
// (mirrors tm/go/test/feature_test.go). Feature behaviour is unit-tested
// by driving each feature through a faithful miniature of the real
// operation pipeline against a configurable mock transport — the same hook
// order and short-circuit rules as the generated entity op code, but with
// no live server and no API-specific fixtures. Each block runs only when
// its feature is present in this SDK (see common::fh_present).

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::*;

use RUSTCRATE::core::helpers::{get_bool, get_str, getp, ja, jo, vfn};
use RUSTCRATE::feature::audit::AuditFeature;
use RUSTCRATE::feature::cache::CacheFeature;
use RUSTCRATE::feature::clienttrack::ClienttrackFeature;
use RUSTCRATE::feature::debug::DebugFeature;
use RUSTCRATE::feature::idempotency::IdempotencyFeature;
use RUSTCRATE::feature::metrics::MetricsFeature;
use RUSTCRATE::feature::netsim::NetsimFeature;
use RUSTCRATE::feature::paging::PagingFeature;
use RUSTCRATE::feature::proxy::ProxyFeature;
use RUSTCRATE::feature::ratelimit::RatelimitFeature;
use RUSTCRATE::feature::rbac::RbacFeature;
use RUSTCRATE::feature::retry::RetryFeature;
use RUSTCRATE::feature::streaming::StreamingFeature;
use RUSTCRATE::feature::telemetry::TelemetryFeature;
use RUSTCRATE::feature::timeout::TimeoutFeature;
use RUSTCRATE::utility::voxgigstruct as vs;
use RUSTCRATE::{Context, FeatureRef, Value};

fn fr<T: RUSTCRATE::Feature + 'static>(f: &Rc<RefCell<T>>) -> FeatureRef {
    f.clone() as FeatureRef
}

fn opspec(op: &str) -> FhOpSpec {
    FhOpSpec {
        op: op.to_string(),
        ..Default::default()
    }
}

// --- netsim -----------------------------------------------------------------

#[test]
fn feature_netsim_fixed_latency_then_delegate() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let clock = FhClock::new();
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("latency", Value::Num(250.0)),
                ("sleep", clock.sleep_fn()),
            ]),
        )],
    );
    let res = h.op(FhOpSpec {
        op: "load".to_string(),
        ctrl: jo(vec![("explain", Value::empty_map())]),
        ..Default::default()
    });
    assert!(res.ok, "expected ok, got err: {:?}", res.err.map(|e| e.msg));
    assert_eq!(clock.t(), 250, "expected 250ms latency");
    assert_eq!(f.borrow().track.borrow().calls, 1, "expected 1 call");
}

#[test]
fn feature_netsim_ranged_latency_in_min_max() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let clock = FhClock::new();
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                (
                    "latency",
                    jo(vec![
                        ("min", Value::Num(100.0)),
                        ("max", Value::Num(300.0)),
                    ]),
                ),
                ("seed", Value::Num(7.0)),
                ("sleep", clock.sleep_fn()),
            ]),
        )],
    );
    h.op(opspec("load"));
    assert!(
        clock.t() >= 100 && clock.t() < 300,
        "expected latency in [100,300), got {}",
        clock.t()
    );
}

#[test]
fn feature_netsim_equal_min_max_latency_exact() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let clock = FhClock::new();
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                (
                    "latency",
                    jo(vec![("min", Value::Num(50.0)), ("max", Value::Num(50.0))]),
                ),
                ("sleep", clock.sleep_fn()),
            ]),
        )],
    );
    h.op(opspec("load"));
    assert_eq!(clock.t(), 50, "expected exactly 50ms");
}

#[test]
fn feature_netsim_fail_times_returns_retryable_status() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("failTimes", Value::Num(2.0)),
                ("failStatus", Value::Num(503.0)),
            ]),
        )],
    );
    let res = h.op(opspec("load"));
    assert_eq!(res.result.unwrap().borrow().status, 503);
    let res = h.op(opspec("load"));
    assert_eq!(res.result.unwrap().borrow().status, 503);
    let res = h.op(opspec("load"));
    assert!(res.ok, "expected third call to succeed");
}

#[test]
fn feature_netsim_fail_every_fails_every_nth() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![(fr(&f), jo(vec![("failEvery", Value::Num(2.0))]))],
    );
    assert!(h.op(opspec("load")).ok, "call 1 should succeed");
    assert!(!h.op(opspec("load")).ok, "call 2 should fail");
    assert!(h.op(opspec("load")).ok, "call 3 should succeed");
}

#[test]
fn feature_netsim_fail_rate_with_seed_deterministic() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![("failRate", Value::Num(1.0)), ("seed", Value::Num(5.0))]),
        )],
    );
    assert!(!h.op(opspec("load")).ok, "expected deterministic failure");
}

#[test]
fn feature_netsim_error_times_connection_error() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("errorTimes", Value::Num(1.0))]))]);
    let res = h.op(opspec("load"));
    assert_eq!(fh_err_code(&res.err), "netsim_conn");
}

#[test]
fn feature_netsim_offline_fails_every_call() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("offline", Value::Bool(true))]))]);
    let res = h.op(opspec("load"));
    assert_eq!(fh_err_code(&res.err), "netsim_offline");
}

#[test]
fn feature_netsim_rate_limit_times_429_retry_after() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("rateLimitTimes", Value::Num(1.0)),
                ("retryAfter", Value::Num(3.0)),
            ]),
        )],
    );
    let res = h.op(opspec("load"));
    let result = res.result.unwrap();
    assert_eq!(result.borrow().status, 429);
    assert_eq!(
        getp(&result.borrow().headers, "retry-after"),
        Value::str("3")
    );
}

#[test]
fn feature_netsim_inactive_does_not_wrap() {
    if !fh_present(&["netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("active", Value::Bool(false)),
                ("offline", Value::Bool(true)),
            ]),
        )],
    );
    assert!(h.op(opspec("load")).ok, "inactive netsim must not simulate");
    assert_eq!(f.borrow().track.borrow().calls, 0);
}

// --- retry ------------------------------------------------------------------

#[test]
fn feature_retry_retries_transient_then_succeeds() {
    if !fh_present(&["retry", "netsim"]) {
        return;
    }
    let clock = FhClock::new();
    let rf = Rc::new(RefCell::new(RetryFeature::new()));
    let nf = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![
            (
                fr(&nf),
                jo(vec![
                    ("failTimes", Value::Num(2.0)),
                    ("failStatus", Value::Num(503.0)),
                ]),
            ),
            (
                fr(&rf),
                jo(vec![
                    ("retries", Value::Num(3.0)),
                    ("minDelay", Value::Num(10.0)),
                    ("jitter", Value::Bool(false)),
                    ("sleep", clock.sleep_fn()),
                ]),
            ),
        ],
    );
    let res = h.op(opspec("load"));
    assert!(res.ok, "expected success after retries");
    assert_eq!(rf.borrow().track.borrow().attempts, 2, "expected 2 retries");
}

#[test]
fn feature_retry_gives_up_after_budget() {
    if !fh_present(&["retry", "netsim"]) {
        return;
    }
    let clock = FhClock::new();
    let rf = Rc::new(RefCell::new(RetryFeature::new()));
    let nf = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![
            (
                fr(&nf),
                jo(vec![
                    ("failTimes", Value::Num(9.0)),
                    ("failStatus", Value::Num(500.0)),
                ]),
            ),
            (
                fr(&rf),
                jo(vec![
                    ("retries", Value::Num(2.0)),
                    ("minDelay", Value::Num(1.0)),
                    ("jitter", Value::Bool(false)),
                    ("sleep", clock.sleep_fn()),
                ]),
            ),
        ],
    );
    let res = h.op(opspec("load"));
    assert_eq!(res.result.unwrap().borrow().status, 500, "expected final 500");
}

#[test]
fn feature_retry_does_not_retry_non_retryable_status() {
    if !fh_present(&["retry"]) {
        return;
    }
    let (server, calls) = fh_recorder(Some(Rc::new(|_n, _fd| {
        Ok(fh_response(404, Value::Noval, Value::Noval))
    })));
    let rf = Rc::new(RefCell::new(RetryFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&rf),
            jo(vec![
                ("retries", Value::Num(3.0)),
                ("minDelay", Value::Num(0.0)),
            ]),
        )],
    );
    h.op(opspec("load"));
    assert_eq!(calls.borrow().len(), 1, "expected 1 call");
}

#[test]
fn feature_retry_retries_transport_error_then_returns_it() {
    if !fh_present(&["retry"]) {
        return;
    }
    let clock = FhClock::new();
    let n = Rc::new(RefCell::new(0));
    let nc = n.clone();
    let server: RUSTCRATE::FetcherFn = Rc::new(move |ctx: &Rc<Context>, _u, _f| {
        *nc.borrow_mut() += 1;
        Err(ctx.make_error("boom", "boom"))
    });
    let rf = Rc::new(RefCell::new(RetryFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&rf),
            jo(vec![
                ("retries", Value::Num(2.0)),
                ("minDelay", Value::Num(1.0)),
                ("jitter", Value::Bool(false)),
                ("sleep", clock.sleep_fn()),
            ]),
        )],
    );
    let res = h.op(opspec("load"));
    assert!(!res.ok, "expected failure");
    assert_eq!(*n.borrow(), 3, "expected 3 attempts");
}

#[test]
fn feature_retry_retries_nil_transport_result() {
    if !fh_present(&["retry"]) {
        return;
    }
    let n = Rc::new(RefCell::new(0));
    let nc = n.clone();
    let server: RUSTCRATE::FetcherFn = Rc::new(move |_c: &Rc<Context>, _u, _f| {
        *nc.borrow_mut() += 1;
        if *nc.borrow() < 2 {
            Ok(Value::Noval)
        } else {
            Ok(fh_response(
                200,
                jo(vec![("ok", Value::Bool(true))]),
                Value::Noval,
            ))
        }
    });
    let rf = Rc::new(RefCell::new(RetryFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&rf),
            jo(vec![
                ("retries", Value::Num(3.0)),
                ("minDelay", Value::Num(0.0)),
            ]),
        )],
    );
    let res = h.op(opspec("load"));
    assert!(res.ok, "expected success");
    assert_eq!(*n.borrow(), 2, "expected 2 attempts");
}

#[test]
fn feature_retry_honours_server_retry_after() {
    if !fh_present(&["retry", "netsim"]) {
        return;
    }
    let clock = FhClock::new();
    let nf = Rc::new(RefCell::new(NetsimFeature::new()));
    let rf = Rc::new(RefCell::new(RetryFeature::new()));
    let h = fh_make(
        None,
        vec![
            (
                fr(&nf),
                jo(vec![
                    ("rateLimitTimes", Value::Num(1.0)),
                    ("retryAfter", Value::Num(2.0)),
                ]),
            ),
            (
                fr(&rf),
                jo(vec![
                    ("retries", Value::Num(2.0)),
                    ("minDelay", Value::Num(10.0)),
                    ("maxDelay", Value::Num(60000.0)),
                    ("jitter", Value::Bool(false)),
                    ("sleep", clock.sleep_fn()),
                ]),
            ),
        ],
    );
    let res = h.op(opspec("load"));
    assert!(res.ok, "expected success");
    assert_eq!(clock.t(), 2000, "expected 2000ms Retry-After wait");
}

#[test]
fn feature_retry_inactive_does_not_wrap() {
    if !fh_present(&["retry"]) {
        return;
    }
    let (server, calls) = fh_recorder(Some(Rc::new(|_n, _fd| {
        Ok(fh_response(503, Value::Noval, Value::Noval))
    })));
    let rf = Rc::new(RefCell::new(RetryFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&rf), jo(vec![("active", Value::Bool(false))]))],
    );
    h.op(opspec("load"));
    assert_eq!(calls.borrow().len(), 1, "expected 1 call");
}

// --- timeout ----------------------------------------------------------------

#[test]
fn feature_timeout_slow_request_times_out() {
    if !fh_present(&["timeout"]) {
        return;
    }
    let server: RUSTCRATE::FetcherFn = Rc::new(|_c: &Rc<Context>, _u, _f| {
        std::thread::sleep(std::time::Duration::from_millis(60));
        Ok(fh_response(
            200,
            jo(vec![("ok", Value::Bool(true))]),
            Value::Noval,
        ))
    });
    let f = Rc::new(RefCell::new(TimeoutFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), jo(vec![("ms", Value::Num(10.0))]))]);
    let res = h.op(opspec("load"));
    assert_eq!(fh_err_code(&res.err), "timeout", "expected timeout error");
    assert_eq!(f.borrow().track.borrow().count, 1, "expected 1 timeout");
}

#[test]
fn feature_timeout_fast_request_passes() {
    if !fh_present(&["timeout"]) {
        return;
    }
    let f = Rc::new(RefCell::new(TimeoutFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("ms", Value::Num(1000.0))]))]);
    assert!(h.op(opspec("load")).ok, "expected success");
}

#[test]
fn feature_timeout_ms_zero_disables() {
    if !fh_present(&["timeout"]) {
        return;
    }
    let f = Rc::new(RefCell::new(TimeoutFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("ms", Value::Num(0.0))]))]);
    assert!(h.op(opspec("load")).ok, "expected success");
}

#[test]
fn feature_timeout_inactive_does_not_wrap() {
    if !fh_present(&["timeout"]) {
        return;
    }
    let f = Rc::new(RefCell::new(TimeoutFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))]);
    assert!(h.op(opspec("load")).ok, "expected success");
}

// --- ratelimit ----------------------------------------------------------------

#[test]
fn feature_ratelimit_throttles_once_burst_spent() {
    if !fh_present(&["ratelimit"]) {
        return;
    }
    let clock = FhClock::new();
    let f = Rc::new(RefCell::new(RatelimitFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("rate", Value::Num(1.0)),
                ("burst", Value::Num(2.0)),
                ("now", clock.now_fn()),
                ("sleep", clock.sleep_fn()),
            ]),
        )],
    );
    h.op(opspec("load"));
    h.op(opspec("load"));
    h.op(opspec("load"));
    assert_eq!(f.borrow().track.borrow().throttled, 1, "expected 1 throttle");
    assert!(clock.t() > 0, "expected the clock to advance while throttled");
}

#[test]
fn feature_ratelimit_burst_defaults_to_rate_and_refills() {
    if !fh_present(&["ratelimit"]) {
        return;
    }
    let clock = FhClock::new();
    let f = Rc::new(RefCell::new(RatelimitFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("rate", Value::Num(2.0)),
                ("now", clock.now_fn()),
                ("sleep", clock.sleep_fn()),
            ]),
        )],
    );
    h.op(opspec("load"));
    h.op(opspec("load"));
    clock.advance(1000); // refill
    h.op(opspec("load"));
    assert_eq!(
        f.borrow().track.borrow().throttled,
        0,
        "expected no throttling after refill"
    );
}

#[test]
fn feature_ratelimit_inactive_does_not_wrap() {
    if !fh_present(&["ratelimit"]) {
        return;
    }
    let f = Rc::new(RefCell::new(RatelimitFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))]);
    assert!(h.op(opspec("load")).ok, "expected success");
    assert_eq!(f.borrow().track.borrow().throttled, 0);
}

// --- cache --------------------------------------------------------------------

#[test]
fn feature_cache_serves_repeated_read_from_cache() {
    if !fh_present(&["cache"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(CacheFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), jo(vec![("ttl", Value::Num(10000.0))]))]);
    let a = h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w/1".to_string(),
        ..Default::default()
    });
    let b = h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w/1".to_string(),
        ..Default::default()
    });
    assert_eq!(calls.borrow().len(), 1, "expected 1 network call");
    assert_eq!(
        json_normalize(&a.data),
        json_normalize(&b.data),
        "expected identical cached data"
    );
    assert_eq!(f.borrow().track.borrow().hit, 1, "expected 1 hit");
}

#[test]
fn feature_cache_does_not_cache_non_get() {
    if !fh_present(&["cache"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(CacheFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    h.op(FhOpSpec {
        op: "create".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    h.op(FhOpSpec {
        op: "create".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert_eq!(calls.borrow().len(), 2, "expected 2 calls");
}

#[test]
fn feature_cache_does_not_cache_non_2xx() {
    if !fh_present(&["cache"]) {
        return;
    }
    let (server, calls) = fh_recorder(Some(Rc::new(|_n, _fd| {
        Ok(fh_response(500, Value::Noval, Value::Noval))
    })));
    let f = Rc::new(RefCell::new(CacheFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert_eq!(calls.borrow().len(), 2, "expected 2 calls");
    assert_eq!(f.borrow().track.borrow().bypass, 2, "expected 2 bypasses");
}

#[test]
fn feature_cache_refetches_after_ttl() {
    if !fh_present(&["cache"]) {
        return;
    }
    let clock = FhClock::new();
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(CacheFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![("ttl", Value::Num(1000.0)), ("now", clock.now_fn())]),
        )],
    );
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    clock.advance(1500);
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert_eq!(calls.borrow().len(), 2, "expected 2 calls after ttl expiry");
}

#[test]
fn feature_cache_evicts_oldest_past_max() {
    if !fh_present(&["cache"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(CacheFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![("ttl", Value::Num(10000.0)), ("max", Value::Num(1.0))]),
        )],
    );
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/a".to_string(),
        ..Default::default()
    });
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/b".to_string(),
        ..Default::default()
    }); // evicts /a
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/a".to_string(),
        ..Default::default()
    }); // miss again
    assert_eq!(calls.borrow().len(), 3, "expected 3 calls");
}

#[test]
fn feature_cache_inactive_does_not_wrap() {
    if !fh_present(&["cache"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(CacheFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))],
    );
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/x".to_string(),
        ..Default::default()
    });
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/x".to_string(),
        ..Default::default()
    });
    assert_eq!(calls.borrow().len(), 2, "expected 2 calls");
}

// --- idempotency ----------------------------------------------------------------

#[test]
fn feature_idempotency_adds_key_to_mutating_ops() {
    if !fh_present(&["idempotency"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(IdempotencyFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    h.op(FhOpSpec {
        op: "create".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert!(
        !getp(&rec_headers(&calls, 0), "Idempotency-Key").is_noval(),
        "expected Idempotency-Key header on create"
    );
}

#[test]
fn feature_idempotency_adds_key_by_http_method() {
    if !fh_present(&["idempotency"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(IdempotencyFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    h.op(FhOpSpec {
        op: "act".to_string(),
        method: "PUT".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert!(
        !getp(&rec_headers(&calls, 0), "Idempotency-Key").is_noval(),
        "expected Idempotency-Key header on PUT"
    );
}

#[test]
fn feature_idempotency_leaves_reads_untouched() {
    if !fh_present(&["idempotency"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(IdempotencyFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w/1".to_string(),
        ..Default::default()
    });
    assert!(
        getp(&rec_headers(&calls, 0), "Idempotency-Key").is_noval(),
        "expected no Idempotency-Key header on load"
    );
}

#[test]
fn feature_idempotency_preserves_caller_key_custom_header() {
    if !fh_present(&["idempotency"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(IdempotencyFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("header", Value::str("X-Idem"))]))],
    );
    h.op(FhOpSpec {
        op: "create".to_string(),
        path: "/w".to_string(),
        headers: jo(vec![("X-Idem", Value::str("caller-1"))]),
        ..Default::default()
    });
    assert_eq!(
        getp(&rec_headers(&calls, 0), "X-Idem"),
        Value::str("caller-1"),
        "expected caller key preserved"
    );
}

#[test]
fn feature_idempotency_injected_keygen() {
    if !fh_present(&["idempotency"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(IdempotencyFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("keygen", vfn(|_v| Value::str("K1")))]))],
    );
    h.op(FhOpSpec {
        op: "create".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert_eq!(
        getp(&rec_headers(&calls, 0), "Idempotency-Key"),
        Value::str("K1"),
        "expected injected key"
    );
    assert_eq!(f.borrow().last, "K1");
    assert_eq!(f.borrow().issued, 1);
}

#[test]
fn feature_idempotency_inactive_is_noop() {
    if !fh_present(&["idempotency"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(IdempotencyFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))],
    );
    h.op(FhOpSpec {
        op: "create".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert!(
        getp(&rec_headers(&calls, 0), "Idempotency-Key").is_noval(),
        "inactive idempotency must not add a key"
    );
}

// --- rbac -----------------------------------------------------------------------

#[test]
fn feature_rbac_denies_before_any_call() {
    if !fh_present(&["rbac"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(RbacFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![
                ("rules", jo(vec![("widget.remove", Value::str("admin"))])),
                ("permissions", Value::empty_list()),
            ]),
        )],
    );
    let res = h.op(FhOpSpec {
        op: "remove".to_string(),
        path: "/w/1".to_string(),
        ..Default::default()
    });
    assert_eq!(fh_err_code(&res.err), "rbac_denied");
    assert_eq!(calls.borrow().len(), 0, "expected no network calls");
    assert_eq!(f.borrow().denied, 1, "expected 1 denial");
}

#[test]
fn feature_rbac_allows_held_permission() {
    if !fh_present(&["rbac"]) {
        return;
    }
    let f = Rc::new(RefCell::new(RbacFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("rules", jo(vec![("widget.remove", Value::str("admin"))])),
                ("permissions", ja(vec![Value::str("admin")])),
            ]),
        )],
    );
    let res = h.op(FhOpSpec {
        op: "remove".to_string(),
        path: "/w/1".to_string(),
        ..Default::default()
    });
    assert!(res.ok, "expected allow");
}

#[test]
fn feature_rbac_op_rule_and_wildcard_grant() {
    if !fh_present(&["rbac"]) {
        return;
    }
    let f = Rc::new(RefCell::new(RbacFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("rules", jo(vec![("load", Value::str("read"))])),
                ("permissions", ja(vec![Value::str("*")])),
            ]),
        )],
    );
    assert!(h.op(opspec("load")).ok, "expected wildcard grant");
}

#[test]
fn feature_rbac_default_allow_and_deny_true() {
    if !fh_present(&["rbac"]) {
        return;
    }
    let fa = Rc::new(RefCell::new(RbacFeature::new()));
    let allow = fh_make(
        None,
        vec![(fr(&fa), jo(vec![("permissions", Value::empty_list())]))],
    );
    assert!(allow.op(opspec("load")).ok, "expected default allow");

    let fd = Rc::new(RefCell::new(RbacFeature::new()));
    let deny = fh_make(
        None,
        vec![(
            fr(&fd),
            jo(vec![
                ("deny", Value::Bool(true)),
                ("permissions", Value::empty_list()),
            ]),
        )],
    );
    let res = deny.op(opspec("load"));
    assert_eq!(fh_err_code(&res.err), "rbac_denied", "expected default deny");
}

#[test]
fn feature_rbac_inactive_is_noop() {
    if !fh_present(&["rbac"]) {
        return;
    }
    let f = Rc::new(RefCell::new(RbacFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("active", Value::Bool(false)),
                ("deny", Value::Bool(true)),
            ]),
        )],
    );
    assert!(h.op(opspec("load")).ok, "inactive rbac must not deny");
}

// --- metrics --------------------------------------------------------------------

#[test]
fn feature_metrics_counts_ok_and_err_per_op() {
    if !fh_present(&["metrics", "netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(MetricsFeature::new()));
    let nf = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![
            (
                fr(&nf),
                jo(vec![
                    ("failTimes", Value::Num(1.0)),
                    ("failStatus", Value::Num(500.0)),
                ]),
            ),
            (fr(&f), Value::Noval),
        ],
    );
    h.op(opspec("load"));
    h.op(opspec("load"));
    h.op(opspec("list"));
    {
        let fb = f.borrow();
        assert_eq!(
            (fb.total.count, fb.total.ok, fb.total.err),
            (3, 2, 1),
            "expected total 3/2/1"
        );
        let wl = fb.ops.get("widget.load").expect("widget.load bucket");
        assert_eq!(wl.count, 2, "expected widget.load count 2");
    }
}

#[test]
fn feature_metrics_injected_clock() {
    if !fh_present(&["metrics"]) {
        return;
    }
    let clock = FhClock::new();
    let f = Rc::new(RefCell::new(MetricsFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("now", clock.now_fn())]))]);
    h.op(opspec("load"));
    assert_eq!(f.borrow().total.count, 1, "expected 1 recorded op");
    assert_eq!(f.borrow().total.total_ms, 0, "expected 0ms with frozen clock");
}

#[test]
fn feature_metrics_inactive_records_nothing() {
    if !fh_present(&["metrics"]) {
        return;
    }
    let f = Rc::new(RefCell::new(MetricsFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))]);
    h.op(opspec("load"));
    assert_eq!(f.borrow().total.count, 0, "expected no records");
}

// --- telemetry ------------------------------------------------------------------

#[test]
fn feature_telemetry_opens_spans_and_propagates_headers() {
    if !fh_present(&["telemetry"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let exported: Rc<RefCell<Vec<Value>>> = Rc::new(RefCell::new(Vec::new()));
    let ec = exported.clone();
    let f = Rc::new(RefCell::new(TelemetryFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![(
                "exporter",
                vfn(move |span| {
                    ec.borrow_mut().push(span.clone());
                    Value::Noval
                }),
            )]),
        )],
    );
    let res = h.op(opspec("load"));
    assert!(res.ok, "expected success");
    assert_eq!(f.borrow().spans.len(), 1, "expected 1 span");
    assert_eq!(exported.borrow().len(), 1, "expected 1 export");
    let sent = rec_headers(&calls, 0);
    assert_eq!(
        getp(&sent, "X-Trace-Id"),
        getp(&f.borrow().spans[0], "traceId"),
        "expected propagated trace id"
    );
    let traceparent = get_str(&sent, "traceparent").unwrap_or_default();
    assert!(
        traceparent.starts_with("00-") && traceparent.ends_with("-01"),
        "expected W3C traceparent, got {:?}",
        traceparent
    );
}

#[test]
fn feature_telemetry_records_failed_span() {
    if !fh_present(&["telemetry", "netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(TelemetryFeature::new()));
    let nf = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![
            (
                fr(&nf),
                jo(vec![
                    ("failTimes", Value::Num(1.0)),
                    ("failStatus", Value::Num(500.0)),
                ]),
            ),
            (fr(&f), Value::Noval),
        ],
    );
    h.op(opspec("load"));
    let fb = f.borrow();
    assert_eq!(fb.spans.len(), 1, "expected 1 span");
    assert_eq!(get_bool(&fb.spans[0], "ok"), Some(false), "expected failed span");
}

#[test]
fn feature_telemetry_injected_idgen_and_clock() {
    if !fh_present(&["telemetry"]) {
        return;
    }
    let clock = FhClock::new();
    let f = Rc::new(RefCell::new(TelemetryFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                (
                    "idgen",
                    vfn(|kind| {
                        Value::str(format!(
                            "{}-X",
                            get_str(&jo(vec![("k", kind.clone())]), "k")
                                .unwrap_or_default()
                        ))
                    }),
                ),
                ("now", clock.now_fn()),
            ]),
        )],
    );
    h.op(opspec("load"));
    let fb = f.borrow();
    assert_eq!(getp(&fb.spans[0], "traceId"), Value::str("trace-X"));
    assert_eq!(getp(&fb.spans[0], "durationMs"), Value::Num(0.0));
}

#[test]
fn feature_telemetry_inactive_records_nothing() {
    if !fh_present(&["telemetry"]) {
        return;
    }
    let f = Rc::new(RefCell::new(TelemetryFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))]);
    h.op(opspec("load"));
    assert_eq!(f.borrow().spans.len(), 0, "expected no spans");
}

// --- debug ----------------------------------------------------------------------

#[test]
fn feature_debug_redacts_and_honours_onentry_max() {
    if !fh_present(&["debug"]) {
        return;
    }
    let seen: Rc<RefCell<Vec<Value>>> = Rc::new(RefCell::new(Vec::new()));
    let sc = seen.clone();
    let f = Rc::new(RefCell::new(DebugFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("max", Value::Num(1.0)),
                (
                    "onEntry",
                    vfn(move |e| {
                        sc.borrow_mut().push(e.clone());
                        Value::Noval
                    }),
                ),
            ]),
        )],
    );
    h.op(FhOpSpec {
        op: "load".to_string(),
        headers: jo(vec![("authorization", Value::str("Bearer secret"))]),
        ..Default::default()
    });
    h.op(opspec("list"));
    assert_eq!(f.borrow().entries.len(), 1, "expected ring buffer capped at 1");
    assert_eq!(seen.borrow().len(), 2, "expected onEntry for both ops");
    let headers = getp(&seen.borrow()[0], "headers");
    assert_eq!(
        getp(&headers, "authorization"),
        Value::str("<redacted>"),
        "expected redacted authorization"
    );
}

#[test]
fn feature_debug_captures_failures() {
    if !fh_present(&["debug", "netsim"]) {
        return;
    }
    let f = Rc::new(RefCell::new(DebugFeature::new()));
    let nf = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![
            (
                fr(&nf),
                jo(vec![
                    ("failTimes", Value::Num(1.0)),
                    ("failStatus", Value::Num(500.0)),
                ]),
            ),
            (fr(&f), Value::Noval),
        ],
    );
    h.op(opspec("load"));
    let fb = f.borrow();
    assert_eq!(fb.entries.len(), 1, "expected 1 entry");
    assert_eq!(get_bool(&fb.entries[0], "ok"), Some(false), "expected failed entry");
}

#[test]
fn feature_debug_injected_clock_and_custom_redact() {
    if !fh_present(&["debug"]) {
        return;
    }
    let clock = FhClock::new();
    let f = Rc::new(RefCell::new(DebugFeature::new()));
    let h = fh_make(
        None,
        vec![(
            fr(&f),
            jo(vec![
                ("now", clock.now_fn()),
                ("redact", ja(vec![Value::str("x-secret")])),
            ]),
        )],
    );
    h.op(FhOpSpec {
        op: "load".to_string(),
        headers: jo(vec![
            ("x-secret", Value::str("hide")),
            ("x-ok", Value::str("show")),
        ]),
        ..Default::default()
    });
    let fb = f.borrow();
    let headers = getp(&fb.entries[0], "headers");
    assert_eq!(getp(&headers, "x-secret"), Value::str("<redacted>"));
    assert_eq!(getp(&headers, "x-ok"), Value::str("show"));
}

#[test]
fn feature_debug_inactive_records_nothing() {
    if !fh_present(&["debug"]) {
        return;
    }
    let f = Rc::new(RefCell::new(DebugFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))]);
    h.op(opspec("load"));
    assert_eq!(f.borrow().entries.len(), 0, "expected no entries");
}

// --- audit ----------------------------------------------------------------------

#[test]
fn feature_audit_one_record_per_op_sink_actor() {
    if !fh_present(&["audit", "netsim"]) {
        return;
    }
    let sunk: Rc<RefCell<Vec<Value>>> = Rc::new(RefCell::new(Vec::new()));
    let sk = sunk.clone();
    let f = Rc::new(RefCell::new(AuditFeature::new()));
    let nf = Rc::new(RefCell::new(NetsimFeature::new()));
    let h = fh_make(
        None,
        vec![
            (
                fr(&nf),
                jo(vec![
                    ("failTimes", Value::Num(1.0)),
                    ("failStatus", Value::Num(500.0)),
                ]),
            ),
            (
                fr(&f),
                jo(vec![
                    ("actor", Value::str("svc")),
                    ("max", Value::Num(5.0)),
                    (
                        "sink",
                        vfn(move |r| {
                            sk.borrow_mut().push(r.clone());
                            Value::Noval
                        }),
                    ),
                ]),
            ),
        ],
    );
    h.op(FhOpSpec {
        op: "remove".to_string(),
        path: "/w/1".to_string(),
        ..Default::default()
    });
    h.op(FhOpSpec {
        op: "load".to_string(),
        ctrl: jo(vec![("actor", Value::str("per-call"))]),
        ..Default::default()
    });
    let fb = f.borrow();
    assert_eq!(fb.records.len(), 2, "expected 2 records");
    assert_eq!(getp(&fb.records[0], "outcome"), Value::str("error"));
    assert_eq!(getp(&fb.records[0], "actor"), Value::str("svc"));
    assert_eq!(getp(&fb.records[1], "actor"), Value::str("per-call"));
    assert_eq!(sunk.borrow().len(), 2, "expected 2 sunk records");
}

#[test]
fn feature_audit_default_actor_anonymous() {
    if !fh_present(&["audit"]) {
        return;
    }
    let f = Rc::new(RefCell::new(AuditFeature::new()));
    let h = fh_make(None, vec![(fr(&f), Value::Noval)]);
    h.op(opspec("load"));
    assert_eq!(
        getp(&f.borrow().records[0], "actor"),
        Value::str("anonymous")
    );
}

#[test]
fn feature_audit_injected_clock() {
    if !fh_present(&["audit"]) {
        return;
    }
    let f = Rc::new(RefCell::new(AuditFeature::new()));
    let h = fh_make(
        None,
        vec![(fr(&f), jo(vec![("now", vfn(|_v| Value::Num(42.0)))]))],
    );
    h.op(opspec("load"));
    assert_eq!(getp(&f.borrow().records[0], "ts"), Value::Num(42.0));
}

#[test]
fn feature_audit_inactive_records_nothing() {
    if !fh_present(&["audit"]) {
        return;
    }
    let f = Rc::new(RefCell::new(AuditFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))]);
    h.op(opspec("load"));
    assert_eq!(f.borrow().records.len(), 0, "expected no records");
}

// --- clienttrack ----------------------------------------------------------------

#[test]
fn feature_clienttrack_stable_client_id_unique_request_ids_ua() {
    if !fh_present(&["clienttrack"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ClienttrackFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![
                ("clientName", Value::str("Acme")),
                ("clientVersion", Value::str("2.0.0")),
            ]),
        )],
    );
    h.op(opspec("load"));
    h.op(opspec("load"));
    let h0 = rec_headers(&calls, 0);
    let h1 = rec_headers(&calls, 1);
    assert_eq!(getp(&h0, "User-Agent"), Value::str("Acme/2.0.0"));
    assert_eq!(
        getp(&h0, "X-Client-Id"),
        getp(&h1, "X-Client-Id"),
        "expected stable client id"
    );
    assert_ne!(
        getp(&h0, "X-Request-Id"),
        getp(&h1, "X-Request-Id"),
        "expected fresh request ids"
    );
    assert_eq!(f.borrow().requests, 2, "expected 2 tracked requests");
}

#[test]
fn feature_clienttrack_does_not_clobber_caller_ua() {
    if !fh_present(&["clienttrack"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ClienttrackFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    h.op(FhOpSpec {
        op: "load".to_string(),
        headers: jo(vec![("User-Agent", Value::str("mine"))]),
        ..Default::default()
    });
    assert_eq!(
        getp(&rec_headers(&calls, 0), "User-Agent"),
        Value::str("mine"),
        "expected caller UA preserved"
    );
}

#[test]
fn feature_clienttrack_injected_idgen_fixed_session() {
    if !fh_present(&["clienttrack"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ClienttrackFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![
                ("sessionId", Value::str("S1")),
                (
                    "idgen",
                    vfn(|kind| match kind {
                        Value::Str(k) => Value::str(format!("{}-1", k)),
                        _ => Value::str("x-1"),
                    }),
                ),
            ]),
        )],
    );
    h.op(opspec("load"));
    assert_eq!(
        getp(&rec_headers(&calls, 0), "X-Client-Id"),
        Value::str("S1"),
        "expected fixed session"
    );
    assert_eq!(
        getp(&rec_headers(&calls, 0), "X-Request-Id"),
        Value::str("request-1"),
        "expected injected request id"
    );
}

#[test]
fn feature_clienttrack_inactive_stamps_nothing() {
    if !fh_present(&["clienttrack"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ClienttrackFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))],
    );
    h.op(opspec("load"));
    assert!(
        getp(&rec_headers(&calls, 0), "X-Client-Id").is_noval(),
        "inactive clienttrack must not stamp headers"
    );
}

// --- paging ---------------------------------------------------------------------

#[test]
fn feature_paging_stamps_page_limit_and_reads_headers() {
    if !fh_present(&["paging"]) {
        return;
    }
    let (server, calls) = fh_recorder(Some(Rc::new(|_n, _fd| {
        Ok(fh_response(
            200,
            jo(vec![(
                "items",
                ja(vec![Value::Num(1.0), Value::Num(2.0)]),
            )]),
            jo(vec![
                ("x-next-page", Value::str("2")),
                ("x-total-count", Value::str("5")),
                ("link", Value::str("</w?page=2>; rel=\"next\"")),
            ]),
        ))
    })));
    let f = Rc::new(RefCell::new(PagingFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), jo(vec![("limit", Value::Num(2.0))]))]);
    let res = h.op(FhOpSpec {
        op: "list".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert!(
        rec_url(&calls, 0).contains("page=1"),
        "expected page=1 stamped, got {}",
        rec_url(&calls, 0)
    );
    assert!(
        rec_url(&calls, 0).contains("limit=2"),
        "expected limit=2 stamped, got {}",
        rec_url(&calls, 0)
    );
    let paging = res.result.unwrap().borrow().paging.clone();
    assert_eq!(getp(&paging, "nextPage"), Value::Num(2.0));
    assert_eq!(getp(&paging, "totalCount"), Value::Num(5.0));
    assert_eq!(getp(&paging, "next"), Value::str("/w?page=2"));
}

#[test]
fn feature_paging_body_cursor_and_explicit_cursor() {
    if !fh_present(&["paging"]) {
        return;
    }
    let (server, calls) = fh_recorder(Some(Rc::new(|_n, _fd| {
        Ok(fh_response(
            200,
            jo(vec![
                ("nextCursor", Value::str("abc")),
                ("hasMore", Value::Bool(true)),
            ]),
            Value::Noval,
        ))
    })));
    let f = Rc::new(RefCell::new(PagingFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    let res = h.op(FhOpSpec {
        op: "list".to_string(),
        path: "/w".to_string(),
        ctrl: jo(vec![(
            "paging",
            jo(vec![("cursor", Value::str("xyz"))]),
        )]),
        ..Default::default()
    });
    assert!(
        rec_url(&calls, 0).contains("cursor=xyz"),
        "expected cursor=xyz stamped, got {}",
        rec_url(&calls, 0)
    );
    let paging = res.result.unwrap().borrow().paging.clone();
    assert_eq!(getp(&paging, "cursor"), Value::str("abc"));
    assert_eq!(getp(&paging, "hasMore"), Value::Bool(true));
}

#[test]
fn feature_paging_non_list_not_paged() {
    if !fh_present(&["paging"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(PagingFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w/1".to_string(),
        ..Default::default()
    });
    assert!(
        !rec_url(&calls, 0).contains("page="),
        "expected no page param, got {}",
        rec_url(&calls, 0)
    );
}

#[test]
fn feature_paging_inactive_stamps_nothing() {
    if !fh_present(&["paging"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(PagingFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))],
    );
    h.op(FhOpSpec {
        op: "list".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert!(
        !rec_url(&calls, 0).contains("page="),
        "inactive paging must not stamp, got {}",
        rec_url(&calls, 0)
    );
}

// --- streaming ------------------------------------------------------------------

#[test]
fn feature_streaming_streams_list_items() {
    if !fh_present(&["streaming"]) {
        return;
    }
    let clock = FhClock::new();
    let (server, _calls) = fh_recorder(Some(Rc::new(|_n, _fd| {
        Ok(fh_response(
            200,
            ja(vec![Value::str("a"), Value::str("b"), Value::str("c")]),
            Value::Noval,
        ))
    })));
    let f = Rc::new(RefCell::new(StreamingFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![
                ("chunkDelay", Value::Num(5.0)),
                ("sleep", clock.sleep_fn()),
            ]),
        )],
    );
    let res = h.op(FhOpSpec {
        op: "list".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    let result = res.result.unwrap();
    assert!(result.borrow().streaming, "expected streaming result");
    let stream = result.borrow().stream.clone().expect("expected stream fn");
    let seen = stream();
    assert_eq!(
        Value::list(seen),
        ja(vec![Value::str("a"), Value::str("b"), Value::str("c")]),
        "expected streamed items"
    );
    assert_eq!(clock.t(), 15, "expected 15ms paced delay");
}

#[test]
fn feature_streaming_batches_with_chunksize() {
    if !fh_present(&["streaming"]) {
        return;
    }
    let (server, _calls) = fh_recorder(Some(Rc::new(|_n, _fd| {
        Ok(fh_response(
            200,
            ja(vec![
                Value::Num(1.0),
                Value::Num(2.0),
                Value::Num(3.0),
                Value::Num(4.0),
                Value::Num(5.0),
            ]),
            Value::Noval,
        ))
    })));
    let f = Rc::new(RefCell::new(StreamingFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("chunkSize", Value::Num(2.0))]))],
    );
    let res = h.op(FhOpSpec {
        op: "list".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    let result = res.result.unwrap();
    let stream = result.borrow().stream.clone().expect("expected stream fn");
    let batches = Value::list(stream());
    let want = ja(vec![
        ja(vec![Value::Num(1.0), Value::Num(2.0)]),
        ja(vec![Value::Num(3.0), Value::Num(4.0)]),
        ja(vec![Value::Num(5.0)]),
    ]);
    assert_eq!(batches, want, "expected chunked batches");
}

#[test]
fn feature_streaming_non_list_not_streamed() {
    if !fh_present(&["streaming"]) {
        return;
    }
    let f = Rc::new(RefCell::new(StreamingFeature::new()));
    let h = fh_make(None, vec![(fr(&f), Value::Noval)]);
    let res = h.op(opspec("load"));
    let result = res.result.unwrap();
    assert!(
        !result.borrow().streaming && result.borrow().stream.is_none(),
        "expected no stream on a non-list op"
    );
}

#[test]
fn feature_streaming_inactive_is_noop() {
    if !fh_present(&["streaming"]) {
        return;
    }
    let f = Rc::new(RefCell::new(StreamingFeature::new()));
    let h = fh_make(None, vec![(fr(&f), jo(vec![("active", Value::Bool(false))]))]);
    let res = h.op(FhOpSpec {
        op: "list".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert!(
        !res.result.unwrap().borrow().streaming,
        "inactive streaming must not attach"
    );
    assert_eq!(f.borrow().opened, 0, "expected no opened streams");
}

// --- proxy ----------------------------------------------------------------------

#[test]
fn feature_proxy_routes_through_proxy() {
    if !fh_present(&["proxy"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ProxyFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("url", Value::str("http://proxy:8080"))]))],
    );
    h.op(opspec("load"));
    assert_eq!(
        getp(&rec_fetchdef(&calls, 0), "proxy"),
        Value::str("http://proxy:8080"),
        "expected proxy annotation"
    );
    assert_eq!(f.borrow().track.borrow().routed, 1, "expected 1 routed call");
}

#[test]
fn feature_proxy_bypasses_noproxy_hosts() {
    if !fh_present(&["proxy"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ProxyFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![
                ("url", Value::str("http://proxy:8080")),
                ("noProxy", ja(vec![Value::str("api.test")])),
            ]),
        )],
    );
    h.op(opspec("load"));
    assert!(
        getp(&rec_fetchdef(&calls, 0), "proxy").is_noval(),
        "expected noProxy bypass"
    );
}

#[test]
fn feature_proxy_fromenv_reads_https_proxy() {
    if !fh_present(&["proxy"]) {
        return;
    }
    let prev = std::env::var("HTTPS_PROXY").ok();
    std::env::set_var("HTTPS_PROXY", "http://env-proxy:8080");

    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ProxyFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(fr(&f), jo(vec![("fromEnv", Value::Bool(true))]))],
    );
    h.op(opspec("load"));

    match prev {
        Some(v) => std::env::set_var("HTTPS_PROXY", v),
        None => std::env::remove_var("HTTPS_PROXY"),
    }

    assert_eq!(
        getp(&rec_fetchdef(&calls, 0), "proxy"),
        Value::str("http://env-proxy:8080"),
        "expected env proxy"
    );
}

#[test]
fn feature_proxy_no_url_is_noop() {
    if !fh_present(&["proxy"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ProxyFeature::new()));
    let h = fh_make(Some(server), vec![(fr(&f), Value::Noval)]);
    h.op(opspec("load"));
    assert!(
        getp(&rec_fetchdef(&calls, 0), "proxy").is_noval(),
        "expected no proxy annotation"
    );
}

#[test]
fn feature_proxy_inactive_does_not_wrap() {
    if !fh_present(&["proxy"]) {
        return;
    }
    let (server, calls) = fh_recorder(None);
    let f = Rc::new(RefCell::new(ProxyFeature::new()));
    let h = fh_make(
        Some(server),
        vec![(
            fr(&f),
            jo(vec![
                ("active", Value::Bool(false)),
                ("url", Value::str("http://proxy:8080")),
            ]),
        )],
    );
    h.op(opspec("load"));
    assert!(
        getp(&rec_fetchdef(&calls, 0), "proxy").is_noval(),
        "inactive proxy must not route"
    );
}

// --- station --------------------------------------------------------------------

// The station adapter (installed by @voxgig/sdkgen-station) with NO open
// station must be an inert no-op that emits nothing and fails nothing
// (station design 3.1). Constructed through the generated make_feature
// factory - never a compile-time module reference - so this file stays
// compilable both with and without the station feature installed: absent,
// the factory answers with the inert BaseFeature and fh_present skips the
// assertions. Bound behaviour (registration, injection, wire events) is
// exercised by the station library's own suite and the consumer-side
// station validation, not here.
#[test]
fn feature_station_inert_without_open_station() {
    if !fh_present(&["station"]) {
        return;
    }
    let f = RUSTCRATE::make_feature("station");
    assert_eq!(
        "station",
        f.borrow().name(),
        "generated factory has a station arm"
    );
    let h = fh_make(None, vec![(f, Value::Noval)]);
    let res = h.op(opspec("load"));
    assert!(res.ok, "expected inert station to pass the op through");
}

// --- composition ----------------------------------------------------------------

#[test]
fn feature_composition_cache_hit_skips_simulated_failure() {
    if !fh_present(&["cache", "netsim"]) {
        return;
    }
    let nf = Rc::new(RefCell::new(NetsimFeature::new()));
    let cf = Rc::new(RefCell::new(CacheFeature::new()));
    let h = fh_make(
        None,
        vec![
            (fr(&nf), jo(vec![("failEvery", Value::Num(2.0))])),
            (fr(&cf), jo(vec![("ttl", Value::Num(10000.0))])),
        ],
    );
    let res = h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert!(res.ok, "first load should succeed");
    let res = h.op(FhOpSpec {
        op: "load".to_string(),
        path: "/w".to_string(),
        ..Default::default()
    });
    assert!(res.ok, "second load should hit the cache");
    assert_eq!(nf.borrow().track.borrow().calls, 1, "expected 1 simulated call");
}

// keep vs referenced
#[test]
fn feature_support_smoke() {
    assert_eq!(vs::stringify(&Value::str("x"), None, false), "x");
}
