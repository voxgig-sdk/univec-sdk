// Network-behaviour simulation over the offline mock transport (mirrors
// tm/go/test/netsim_test.go). The `test` feature accepts an optional `net`
// config so unit tests can exercise slow, failing and offline conditions
// without a live server. These checks drive the transport through
// direct(), which needs no entity, so they run for every generated SDK
// regardless of its API shape.

use RUSTCRATE::core::helpers::{getp, jo, now_ms};
use RUSTCRATE::{test_sdk, Value};

#[test]
fn netsim_offline_simulation_fails_request() {
    let client = test_sdk(
        jo(vec![("net", jo(vec![("offline", Value::Bool(true))]))]),
        Value::Noval,
    );
    let res = client
        .direct(jo(vec![("path", Value::str("/ping"))]))
        .expect("direct itself should not error");
    assert_eq!(
        getp(&res, "ok"),
        Value::Bool(false),
        "offline network must fail the call"
    );
}

#[test]
fn netsim_failstatus_simulation_surfaces_status() {
    let client = test_sdk(
        jo(vec![(
            "net",
            jo(vec![
                ("failTimes", Value::Num(1.0)),
                ("failStatus", Value::Num(503.0)),
            ]),
        )]),
        Value::Noval,
    );
    let res = client
        .direct(jo(vec![("path", Value::str("/ping"))]))
        .expect("direct itself should not error");
    assert_eq!(getp(&res, "ok"), Value::Bool(false), "expected failed call");
    assert_eq!(
        getp(&res, "status"),
        Value::Num(503.0),
        "expected simulated 503"
    );
}

#[test]
fn netsim_latency_simulation_delays_request() {
    let delay = 60i64;
    let client = test_sdk(
        jo(vec![(
            "net",
            jo(vec![("latency", Value::Num(delay as f64))]),
        )]),
        Value::Noval,
    );
    let start = now_ms();
    client
        .direct(jo(vec![("path", Value::str("/ping"))]))
        .expect("direct itself should not error");
    let elapsed = now_ms() - start;
    // Generous lower bound to stay robust on slow CI.
    assert!(
        elapsed >= delay - 25,
        "expected >= {}ms latency, got {}ms",
        delay - 25,
        elapsed
    );
}

#[test]
fn netsim_plain_test_sdk_works_without_net() {
    let client = test_sdk(Value::Noval, Value::Noval);
    assert_eq!(*client.mode.borrow(), "test");
}
