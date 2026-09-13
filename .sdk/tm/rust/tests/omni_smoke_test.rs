// Smoke tests for the vendored omni runner itself: a runner that cannot FAIL
// a bad entry would turn every corpus suite vacuously green, so pin the
// failure paths, not just the happy one. (The Rust peer of
// tm/ts/test/omni.test.ts and tm/go/test/omnismoke_test.go.)
//
// The resolver accumulates group failures rather than panicking, so these
// tests can assert that a failure HAPPENED without failing themselves.

mod omni_resolver;

use std::cell::RefCell;
use std::rc::Rc;

use omni_resolver::{raw_unsorted_keys, spec_path, Json, Run};

use RUSTCRATE::utility::voxgigstruct::value::Value;
use RUSTCRATE::utility::voxgigstruct::{get_path, set_path};

// A minimal in-memory spec: no fixture file, no OMNI block (lenient v0, like
// the shared corpus).
fn smokespec() -> Json {
    let basic = Json::map(vec![(
        "set",
        Json::list(vec![
            Json::map(vec![("in", Json::Num(1.0)), ("out", Json::Num(2.0))]),
            Json::map(vec![("in", Json::Num(41.0)), ("out", Json::Num(42.0))]),
        ]),
    )]);

    let bad = Json::map(vec![(
        "set",
        Json::list(vec![Json::map(vec![
            ("in", Json::Num(1.0)),
            ("out", Json::Num(999.0)),
        ])]),
    )]);

    let err = Json::map(vec![(
        "set",
        Json::list(vec![Json::map(vec![
            ("in", Json::Num(0.0)),
            ("err", Json::str("zero refused")),
        ])]),
    )]);

    // A ctx entry whose assertion is on state the subject writes AFTER the
    // call: the case decision 3 (`retargetctx`) exists for.
    let ctx = Json::map(vec![(
        "set",
        Json::list(vec![Json::map(vec![
            ("ctx", Json::map(vec![("n", Json::Num(3.0))])),
            (
                "match",
                Json::map(vec![(
                    "ctx",
                    Json::map(vec![("seen", Json::Num(3.0))]),
                )]),
            ),
        ])]),
    )]);

    Json::map(vec![(
        "primary",
        Json::map(vec![(
            "smoke",
            Json::map(vec![
                ("basic", basic),
                ("bad", bad),
                ("err", err),
                ("ctx", ctx),
            ]),
        )]),
    )])
}

fn smokerun() -> Run {
    Run::over(smokespec(), "smoke")
}

// n -> n + 1, refusing zero.
fn inc(val: Value) -> Result<Value, String> {
    match val {
        Value::Num(num) if 0.0 == num => Err("smoke: zero refused".to_string()),
        Value::Num(num) => Ok(Value::Num(num + 1.0)),
        other => Ok(other),
    }
}

#[test]
fn omni_runset_passes_a_correct_subject() {
    let mut run = smokerun();
    let set = run.set(&["basic"]);
    run.run_set_fallible(&set, true, "smoke-basic", inc);

    assert!(
        run.failures.is_empty(),
        "a correct subject was reported as failing: {:?}",
        run.failures
    );
    assert_eq!(2, run.passed, "both entries should have run");
}

#[test]
fn omni_runset_fails_a_wrong_result() {
    let mut run = smokerun();
    let set = run.set(&["bad"]);
    run.run_set_fallible(&set, true, "smoke-bad", inc);

    assert!(
        !run.failures.is_empty(),
        "a wrong result went unreported - the corpus suites would be vacuously green"
    );
    assert!(
        run.failures[0].contains("result mismatch"),
        "expected a result mismatch failure, got: {}",
        run.failures[0]
    );
    assert_eq!(0, run.passed, "a failing group must count no passes");
}

#[test]
fn omni_runset_matches_an_expected_error_and_fails_a_missing_one() {
    let mut run = smokerun();
    let set = run.set(&["err"]);
    run.run_set_fallible(&set, true, "smoke-err", inc);
    assert!(
        run.failures.is_empty(),
        "an expected error was not matched: {:?}",
        run.failures
    );

    let mut run = smokerun();
    let set = run.set(&["err"]);
    run.run_set_fallible(&set, true, "smoke-err", |val| Ok(val));
    assert!(
        !run.failures.is_empty(),
        "a missing expected error went unreported"
    );
    assert!(
        run.failures[0].contains("expected error did not occur"),
        "expected an expected-error failure, got: {}",
        run.failures[0]
    );
}

// Decision 2 + 3: a subject's post-call write into args[0] is what a
// `match: {ctx: ...}` assertion reads. Without `retargetctx` (or without the
// argument write-back) this group cannot pass — which is exactly why the
// nine `primary` ctx assertions are not vacuous.
#[test]
fn omni_ctx_assertions_see_post_call_state() {
    let mut run = smokerun();
    let set = run.set(&["ctx"]);
    run.run_set_args(&set, true, "smoke-ctx", |args| {
        let ctx = args[0].clone();
        let n = get_path(&ctx, &Value::str("n"), None);
        set_path(&ctx, &Value::str("seen"), n, None);
        Ok(Value::Noval)
    });

    assert!(
        run.failures.is_empty(),
        "a post-call ctx assertion was not seen: {:?}",
        run.failures
    );
    assert_eq!(1, run.passed);
}

// The same group with the write REMOVED must go red: proof the assertion is
// really being checked and not quietly skipped.
#[test]
fn omni_ctx_assertions_fail_without_the_write_back() {
    let mut run = smokerun();
    let set = run.set(&["ctx"]);
    run.run_set_args(&set, true, "smoke-ctx", |_args| Ok(Value::Noval));

    assert!(
        !run.failures.is_empty(),
        "an unmet ctx assertion went unreported"
    );
}

// An absent group is SKIPPED, and says so - it must never be counted as
// passing.
#[test]
fn omni_absent_group_is_named_not_silent() {
    let mut run = smokerun();
    let set = run.set(&["nosuchgroup"]);
    run.run_set_fallible(&set, true, "smoke-missing", inc);

    assert!(run.failures.is_empty());
    assert_eq!(0, run.passed);
    assert_eq!(vec!["smoke-missing".to_string()], run.skipped);
}

// Decision 5's tripwire: omni's BTreeMap sorts map keys, so an out-of-order
// map in the corpus would be silently reordered on the way into a subject.
//
// It reads the corpus FILE. Going through `corpus()` would hand the check a
// `Json::Map`, which is a `BTreeMap` — already sorted by the parse — so the
// comparison would be a sorted list against itself and the tripwire could
// never fire. `key_order_scan_fires_on_an_out_of_order_map` below is the
// proof that this one can.
#[test]
fn corpus_maps_are_in_sorted_key_order() {
    let path = spec_path();
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("cannot read the corpus at {}: {}", path, err));
    let scan = raw_unsorted_keys(&text);

    // A scan that read nothing must not pass as a scan that found nothing.
    assert!(
        1000 < scan.maps,
        "the key-order scan inspected only {} maps in {} — it is not reading \
         the real corpus",
        scan.maps,
        path
    );

    if let Some(found) = scan.unsorted {
        panic!(
            "corpus map is not in sorted key order, so omni's BTreeMap would \
             reorder it before a subject sees it: {}",
            found
        );
    }
}

// The tripwire's own tripwire: a key-order check that cannot report disorder
// is worse than none, because it reads as a guarantee. Feed it disorder.
#[test]
fn key_order_scan_fires_on_an_out_of_order_map() {
    let sorted = r#"{"a": 1, "b": {"c": [1, 2, {"d": true, "e": null}]}}"#;
    let scan = raw_unsorted_keys(sorted);
    assert_eq!(3, scan.maps, "every map must be inspected");
    assert!(scan.unsorted.is_none(), "sorted input reported as unsorted");

    let unsorted = r#"{"a": 1, "b": {"zzz": 1, "aaa": 2}}"#;
    let scan = raw_unsorted_keys(unsorted);
    assert_eq!(
        Some("b: [\"zzz\", \"aaa\"]".to_string()),
        scan.unsorted,
        "an out-of-order map was not reported"
    );

    // Nested inside a list, and reported by its authored path.
    let inlist = r#"{"a": [{"m": 0}, {"z": 1, "y": 2}]}"#;
    assert_eq!(
        Some("a.1: [\"z\", \"y\"]".to_string()),
        raw_unsorted_keys(inlist).unsorted
    );

    // Keys are compared DECODED, the way a BTreeMap<String, _> holds them.
    assert!(raw_unsorted_keys(r#"{"a\nb": 1, "z": 2}"#).unsorted.is_none());
    assert!(raw_unsorted_keys(r#"{"z": 1, "a\nb": 2}"#).unsorted.is_some());
    assert!(raw_unsorted_keys(r#"{"\u00e9": 1}"#).unsorted.is_none());
}

// The runner must refuse a spec it cannot faithfully run, rather than
// mis-running it quietly.
#[test]
fn omni_refuses_a_future_spec_version() {
    let spec = Json::map(vec![
        (
            "OMNI",
            Json::map(vec![("version", Json::Num(99.0))]),
        ),
        (
            "primary",
            Json::map(vec![("smoke", Json::map(vec![]))]),
        ),
    ]);

    let refused = std::panic::catch_unwind(|| {
        let _ = Run::over(spec, "smoke");
    });
    assert!(refused.is_err(), "a future spec version was accepted");
}

// Keep the Rc/RefCell imports honest for builds that do not use them above.
#[test]
fn smoke_support() {
    let cell = Rc::new(RefCell::new(0));
    *cell.borrow_mut() += 1;
    assert_eq!(1, *cell.borrow());
}
