// Generated direct-call tests for the model entity (mirrors the
// go TestDirect generator; the live-mode path uses idmap-provided IDs).

#![allow(unused_variables, unused_imports, dead_code)]

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::*;

use univec_sdk::core::helpers::{getp, ja, jo, json_thunk, setp, to_int, to_map};
use univec_sdk::utility::voxgigstruct as vs;
use univec_sdk::{Value, UnivecSDK};

struct ModelDirectSetup {
    client: Rc<UnivecSDK>,
    calls: Rc<RefCell<Vec<Value>>>,
    live: bool,
    idmap: Value,
}

fn model_direct_setup(mockres: Value) -> ModelDirectSetup {
    load_env_local();

    let calls: Rc<RefCell<Vec<Value>>> = Rc::new(RefCell::new(Vec::new()));

    let env = env_override(jo(vec![
        ("UNIVEC_TEST_MODEL_ENTID", Value::empty_map()),
        ("UNIVEC_TEST_LIVE", Value::str("FALSE")),
        ("UNIVEC_APIKEY", Value::str("NONE")),
    ]));

    let live = getp(&env, "UNIVEC_TEST_LIVE") == Value::str("TRUE");

    if live {
        let client = UnivecSDK::new(jo(vec![("apikey", getp(&env, "UNIVEC_APIKEY"))]));
        let idmap = match to_map(&getp(&env, "UNIVEC_TEST_MODEL_ENTID")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };
        return ModelDirectSetup {
            client,
            calls,
            live: true,
            idmap,
        };
    }

    let c = calls.clone();
    let mock_fetch = Value::func(move |_inj, args, _r, _s| {
        let url = vs::get_elem(args, &Value::Num(0.0), Value::Noval);
        let init = vs::get_elem(args, &Value::Num(1.0), Value::Noval);
        c.borrow_mut().push(jo(vec![("url", url), ("init", init)]));
        let data = if mockres.is_noval() || mockres.is_null() {
            jo(vec![("id", Value::str("direct01"))])
        } else {
            mockres.clone()
        };
        jo(vec![
            ("status", Value::Num(200.0)),
            ("statusText", Value::str("OK")),
            ("headers", Value::empty_map()),
            ("json", json_thunk(data)),
        ])
    });

    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str("http://localhost:8080")),
        ("system", jo(vec![("fetch", mock_fetch)])),
    ]));

    ModelDirectSetup {
        client,
        calls,
        live: false,
        idmap: Value::empty_map(),
    }
}

#[test]
fn model_direct_list() {
    let setup = model_direct_setup(ja(vec![
        jo(vec![("id", Value::str("direct01"))]),
        jo(vec![("id", Value::str("direct02"))]),
    ]));
    let mode = if setup.live { "live" } else { "unit" };
    let (skip, reason) = is_control_skipped("direct", "direct-list-model", mode);
    if skip {
        eprintln!(
            "skip: {}",
            if reason.is_empty() {
                "skipped via sdk-test-control.json".to_string()
            } else {
                reason
            }
        );
        return;
    }
    let client = setup.client.clone();

    let params = Value::empty_map();

    let result = client
        .direct(jo(vec![
            ("path", Value::str("v1/models")),
            ("method", Value::str("GET")),
            ("params", params.clone()),
        ]))
        .expect("direct failed");

    if setup.live {
        // Live mode is lenient: synthetic IDs frequently 4xx and the
        // list-response shape varies wildly across public APIs.
        if getp(&result, "ok") != Value::Bool(true) {
            eprintln!("skip: list call not ok (likely synthetic IDs against live API)");
            return;
        }
        let status = to_int(&getp(&result, "status"));
        if !(200..300).contains(&status) {
            eprintln!("skip: expected 2xx status, got {}", status);
            return;
        }
    } else {
        assert_eq!(getp(&result, "ok"), Value::Bool(true), "expected ok true");
        assert_eq!(to_int(&getp(&result, "status")), 200, "expected status 200");

        let data = getp(&result, "data");
        assert!(
            matches!(data, Value::List(_)),
            "expected data to be an array"
        );
        assert_eq!(vs::size(&data), 2, "expected 2 items");

        assert_eq!(setup.calls.borrow().len(), 1, "expected 1 call");
    }
}
