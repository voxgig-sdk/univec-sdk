// Generated basic-flow test for the model entity (model-driven;
// mirrors the go TestEntity generator).

#![allow(unused_variables, unused_mut, unused_imports)]

mod common;

use std::rc::Rc;

use common::*;

use univec_sdk::core::helpers::{getp, getpath, ja, jo, now_ms, setp, to_map};
use univec_sdk::utility::voxgigstruct as vs;
use univec_sdk::{test_sdk, Entity, UnivecEntity, UnivecSDK, Value};

// main.kit.test.live.strict is true (the default is true): a live
// request that fails, or a live test missing an input it needs,
// fails the test.
// An account with no record for a test to read skips it either way.
const LIVE_STRICT: bool = true;

#[test]
fn model_entity_instance() {
    let testsdk = test_sdk(Value::Noval, Value::Noval);
    let ent = testsdk.model(Value::Noval);
    assert_eq!(ent.get_name(), "model");
}

#[test]
fn model_entity_stream() {
    // stream() runs the list op through the full pipeline and yields each
    // result item. Seed two entities via test mode; with the `streaming`
    // feature active it yields the feature's incremental items, else it
    // falls back to the materialised items — either way every item yields.
    let seed = jo(vec![(
        "entity",
        jo(vec![(
            "model",
            jo(vec![
                ("strm01", jo(vec![("id", Value::str("strm01"))])),
                ("strm02", jo(vec![("id", Value::str("strm02"))])),
            ]),
        )]),
    )]);

    let sdkopts = jo(vec![(
        "feature",
        jo(vec![("streaming", jo(vec![("active", Value::Bool(true))]))]),
    )]);

    let testsdk = test_sdk(seed.clone(), sdkopts);
    let ent = testsdk.model(Value::Noval);
    let items: Vec<Value> = ent
        .stream("list", Value::empty_map(), Value::empty_map())
        .expect("stream failed")
        .collect();
    assert_eq!(items.len(), 2, "stream should yield both seeded items");

    // Fallback: streaming inactive still yields both materialised items.
    let plainsdk = test_sdk(seed, Value::Noval);
    let plainent = plainsdk.model(Value::Noval);
    let plain_items: Vec<Value> = plainent
        .stream("list", Value::empty_map(), Value::empty_map())
        .expect("stream failed")
        .collect();
    assert_eq!(plain_items.len(), 2, "fallback stream should yield both items");
}

#[test]
fn model_entity_stream_error() {
    let offline = jo(vec![("net", jo(vec![("offline", Value::Bool(true))]))]);
    let err = test_sdk(offline.clone(), Value::Noval)
        .model(Value::Noval)
        .stream("list", Value::empty_map(), Value::empty_map())
        .err()
        .expect("a failed operation should fail the stream");
    assert!(err.msg.contains("offline"), "{}", err.msg);

    let quiet = jo(vec![("ctrl", jo(vec![("throw", Value::Bool(false))]))]);
    assert!(test_sdk(offline, Value::Noval)
        .model(Value::Noval)
        .stream("list", Value::empty_map(), quiet)
        .is_ok());

    if !getp(&getp(&univec_sdk::make_config(), "feature"), "rbac").is_noval() {
        let denied = test_sdk(Value::Noval, jo(vec![(
            "feature",
            jo(vec![("rbac", jo(vec![("active", Value::Bool(true)), ("deny", Value::Bool(true))]))]),
        )]));
        let denyerr = denied
            .model(Value::Noval)
            .stream("list", Value::empty_map(), Value::empty_map())
            .err()
            .expect("a denied operation should fail the stream");
        assert_eq!(denyerr.code, "rbac_denied");
    }
}

#[test]
fn model_entity_stream_ctrl() {
    let explain = Value::empty_map();
    let ctrl = jo(vec![("explain", explain.clone())]);
    let items: Vec<Value> = test_sdk(Value::Noval, Value::Noval)
        .model(Value::Noval)
        .stream("list", Value::empty_map(), jo(vec![("ctrl", ctrl.clone())]))
        .expect("stream failed")
        .collect();
    assert!(getp(&ctrl, "stream").is_noval(), "the stream changed the caller's ctrl");
    let filled = match &explain {
        Value::Map(m) => !m.borrow().is_empty(),
        _ => false,
    };
    assert!(filled, "the caller's explain record was not filled");
}

#[test]
fn model_entity_validate() {
    if getp(&getp(&univec_sdk::make_config(), "feature"), "validate").is_noval() {
        return;
    }
    let client = test_sdk(Value::Noval, jo(vec![(
        "feature",
        jo(vec![("validate", jo(vec![("active", Value::Bool(true))]))]),
    )]));
    let err = client
        .model(Value::Noval)
        .list(jo(vec![("executionProvider", Value::Num(1.0))]), Value::Noval)
        .err()
        .expect("an invalid request should fail");
    assert_eq!(err.code, "validate_failed");
}

#[test]
fn model_entity_basic() {
    let setup = model_basic_setup(Value::Noval);
    // Per-op sdk-test-control.json skip — the basic test exercises a flow
    // with multiple ops; skipping any op skips the whole flow.
    let mode = if setup.live { "live" } else { "unit" };
    for op in ["list"] {
        let (skip, reason) = is_control_skipped("entityOp", &format!("model.{}", op), mode);
        if skip {
            let reason = if reason.is_empty() {
                "skipped via sdk-test-control.json".to_string()
            } else {
                reason
            };
            eprintln!("skip: {}", reason);
            return;
        }
    }
    let client = setup.client.clone();

    // Bootstrap entity data from existing test data (no create step in flow).
    let model_ref01_data_raw = vs::items(&to_map(&getpath(&["existing", "model"], &setup.data)));
    let model_ref01_data = to_map(&vs::get_elem(
        &vs::get_elem(&model_ref01_data_raw, &Value::Num(0.0), Value::Noval),
        &Value::Num(1.0),
        Value::Noval,
    ));
    // LIST
    let model_ref01_ent = client.model(Value::Noval);
    let model_ref01_match = Value::empty_map();

    let model_ref01_list = model_ref01_ent
        .list(model_ref01_match.clone(), Value::Noval)
        .expect("list failed");
    // list resolves to one ENTITY per record; the flow asserts on the
    // records, so map each through data().
    let model_ref01_list = ja(model_ref01_list.iter().map(|e| e.data(None)).collect::<Vec<Value>>());

}

fn model_basic_setup(extra: Value) -> EntityTestSetup {
    load_env_local();

    let mut entity_data_file = manifest_dir();
    entity_data_file.push("..");
    entity_data_file.push(".sdk");
    entity_data_file.push("test");
    entity_data_file.push("entity");
    entity_data_file.push("model");
    entity_data_file.push("ModelTestData.json");

    let entity_data = read_json(&entity_data_file);

    let options = jo(vec![("entity", getp(&entity_data, "existing"))]);

    let client = test_sdk(options, extra.clone());

    // Generate idmap via transform, matching the TS pattern.
    let idmap = vs::transform(
        &ja(vec![Value::str("model01"), Value::str("model02"), Value::str("model03")]),
        &jo(vec![(
            "`$PACK`",
            ja(vec![
                Value::str(""),
                jo(vec![
                    ("`$KEY`", Value::str("`$COPY`")),
                    (
                        "`$VAL`",
                        ja(vec![
                            Value::str("`$FORMAT`"),
                            Value::str("upper"),
                            Value::str("`$COPY`"),
                        ]),
                    ),
                ]),
            ]),
        )]),
        None,
    )
    .unwrap_or_else(|_| Value::empty_map());

    // Whether *_ENTID supplied the idmap, read before env_override consumes
    // it: without it, the ids a live flow binds are the fixture's synthetic ones.
    let entid_env_raw = std::env::var("UNIVEC_TEST_MODEL_ENTID").unwrap_or_default();
    let idmap_overridden =
        !entid_env_raw.trim().is_empty() && entid_env_raw.trim().starts_with('{');

    let env = env_override(jo(vec![
        ("UNIVEC_TEST_MODEL_ENTID", idmap.clone()),
        ("UNIVEC_TEST_LIVE", Value::str("FALSE")),
        ("UNIVEC_TEST_EXPLAIN", Value::str("FALSE")),
        ("UNIVEC_APIKEY", Value::str("")),
    ]));

    let idmap_resolved = match to_map(&getp(&env, "UNIVEC_TEST_MODEL_ENTID")) {
        Value::Map(m) => Value::Map(m),
        _ => to_map(&idmap),
    };

    let live = getp(&env, "UNIVEC_TEST_LIVE") == Value::str("TRUE");

    let client = if live {
        let merged = vs::merge(
            // live_client_options() FIRST, so the generated entries below win:
            // sdk-test-control.json's test.client.options adds to the live
            // client, it does not redirect it.
            &ja(vec![
                live_client_options(),
                jo(vec![("apikey", getp(&env, "UNIVEC_APIKEY"))]),
                // A NON-NODE later entry REPLACES the accumulated map in
                // vs::merge, and the normal call passes Value::Noval - so a
                // a bare extra discarded live_client_options() and the
                // apikey/server map above it, and the live client was
                // constructed with nothing.
                match extra {
                    Value::Map(m) => Value::Map(m),
                    _ => Value::empty_map(),
                },
            ]),
            None,
        );
        UnivecSDK::new(to_map(&merged))
    } else {
        client
    };

    EntityTestSetup {
        client,
        data: entity_data,
        idmap: idmap_resolved,
        env: env.clone(),
        explain: getp(&env, "UNIVEC_TEST_EXPLAIN") == Value::str("TRUE"),
        live,
        synthetic_only: live && !idmap_overridden,
        now: now_ms(),
    }
}
