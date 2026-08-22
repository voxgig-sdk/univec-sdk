// Primary utility tests — run the shared `primary` subtree of
// ../.sdk/test/test.json against the SDK pipeline utilities (mirrors
// tm/go/test/primary_utility_test.go).

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::*;

use RUSTCRATE::core::helpers::{get_str, getp, ja, jo, setp, to_map, vfn};
use RUSTCRATE::utility::voxgigstruct as vs;
use RUSTCRATE::{
    new as new_sdk, test_sdk, BaseFeature, Context, CtxSpec, Feature, FeatureRef, Operation,
    UnivecSDK, SdkResult, Spec, Utility, Value,
};

fn primary() -> Value {
    let spec = load_test_spec();
    let primary = get_spec(&spec, &["primary"]);
    assert!(
        matches!(primary, Value::Map(_)),
        "primary section not found in test.json"
    );
    primary
}

fn base_client() -> (Rc<UnivecSDK>, Rc<Utility>) {
    let client = test_sdk(Value::Noval, Value::Noval);
    let utility = client.get_utility();
    (client, utility)
}

// Helper: create basic test context.
fn make_test_ctx(client: &Rc<UnivecSDK>, utility: &Rc<Utility>) -> Rc<Context> {
    utility.make_context(
        CtxSpec {
            opname: Some("load".to_string()),
            client: Some(client.clone()),
            utility: Some(utility.clone()),
            ..Default::default()
        },
        Some(&client.get_root_ctx()),
    )
}

// Helper: create full test context with point and match.
fn make_test_full_ctx(client: &Rc<UnivecSDK>, utility: &Rc<Utility>) -> Rc<Context> {
    let ctx = make_test_ctx(client, utility);
    *ctx.point.borrow_mut() = jo(vec![
        ("parts", ja(vec![Value::str("items"), Value::str("{id}")])),
        (
            "args",
            jo(vec![(
                "params",
                ja(vec![jo(vec![
                    ("name", Value::str("id")),
                    ("reqd", Value::Bool(true)),
                ])]),
            )]),
        ),
        ("params", ja(vec![Value::str("id")])),
        ("alias", Value::empty_map()),
        ("select", Value::empty_map()),
        ("active", Value::Bool(true)),
        ("transform", Value::empty_map()),
    ]);
    *ctx.mtch.borrow_mut() = jo(vec![("id", Value::str("item01"))]);
    *ctx.reqmatch.borrow_mut() = jo(vec![("id", Value::str("item01"))]);
    ctx
}

#[test]
fn primary_utility_exists() {
    // The rust utility methods are statically bound; a live smoke test
    // stands in for go's nil-checks.
    let (client, utility) = base_client();
    let ctx = make_test_ctx(&client, &utility);
    assert_eq!(utility.prepare_method(&ctx), "GET");
    assert!(matches!(utility.prepare_headers(&ctx), Value::Map(_)));
    assert!(matches!(utility.prepare_query(&ctx), Value::Map(_)));
    assert!(matches!(utility.prepare_params(&ctx), Value::Map(_)));
    assert!(matches!(utility.make_options(&ctx), Value::Map(_)));
    let _ = utility.clean(&ctx, &Value::str("x"));
}

#[test]
fn primary_clean_basic() {
    let (client, utility) = base_client();
    let ctx = make_test_ctx(&client, &utility);
    let val = jo(vec![
        ("key", Value::str("secret123")),
        ("name", Value::str("test")),
    ]);
    let cleaned = utility.clean(&ctx, &val);
    assert!(!cleaned.is_noval(), "cleaned should not be nil");
}

#[test]
fn primary_done_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(&get_spec(&primary, &["done", "basic"]), &mut |entry| {
        let ctx = make_ctx_from_map(&getp(entry, "ctx"), &client, &utility);
        fixctx(&ctx, &client);
        utility.done(&ctx)
    });
}

#[test]
fn primary_make_error_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(&get_spec(&primary, &["makeError", "basic"]), &mut |entry| {
        let args = match getp(entry, "args") {
            Value::List(l) => Value::List(l),
            _ => ja(vec![Value::empty_map()]),
        };
        let ctxmap = vs::get_elem(&args, &Value::Num(0.0), Value::empty_map());
        let ctx = make_ctx_from_map(&ctxmap, &client, &utility);
        fixctx(&ctx, &client);

        let err = match vs::get_elem(&args, &Value::Num(1.0), Value::Noval) {
            Value::Map(m) => err_from_map(&Value::Map(m)),
            _ => None,
        };

        utility.make_error(&ctx, err)
    });
}

#[test]
fn primary_make_error_no_throw() {
    let (client, utility) = base_client();
    let ctx = make_test_full_ctx(&client, &utility);
    {
        let ctrl = ctx.ctrl.borrow().clone();
        ctrl.borrow_mut().throw = Some(false);
    }
    *ctx.result.borrow_mut() = Some(Rc::new(RefCell::new(SdkResult::new(&jo(vec![
        ("ok", Value::Bool(false)),
        ("resdata", jo(vec![("id", Value::str("safe01"))])),
    ])))));

    let out = utility
        .make_error(&ctx, Some(ctx.make_error("test_code", "test message")))
        .expect("expected no error");
    assert_eq!(getp(&out, "id"), Value::str("safe01"));
}

#[test]
fn primary_feature_add_basic() {
    let (client, utility) = base_client();
    let ctx = make_test_ctx(&client, &utility);
    let start_len = client.features.borrow().len();

    let feature: FeatureRef = Rc::new(RefCell::new(BaseFeature::new()));
    utility.feature_add(&ctx, feature);

    assert_eq!(client.features.borrow().len(), start_len + 1);
}

// Helper: test hook feature for the featureHook test (custom hook name).
struct TestHookFeature {
    base: BaseFeature,
    called: Rc<RefCell<bool>>,
}

impl Feature for TestHookFeature {
    fn name(&self) -> String {
        self.base.name.clone()
    }
    fn active(&self) -> bool {
        self.base.active
    }
    fn custom_hook(&mut self, name: &str, _ctx: &Rc<Context>) {
        if name == "TestHook" {
            *self.called.borrow_mut() = true;
        }
    }
}

#[test]
fn primary_feature_hook_basic() {
    let client = test_sdk(Value::Noval, Value::Noval);
    let utility = client.get_utility();
    let ctx = make_test_ctx(&client, &utility);

    let called = Rc::new(RefCell::new(false));
    let hook_feature: FeatureRef = Rc::new(RefCell::new(TestHookFeature {
        base: BaseFeature::new(),
        called: called.clone(),
    }));
    *client.features.borrow_mut() = vec![hook_feature];

    utility.feature_hook(&ctx, "TestHook");
    assert!(*called.borrow(), "expected TestHook to be called");
}

// Helper: test init feature for the featureInit tests.
struct TestInitFeature {
    name: String,
    active: bool,
    init_called: Rc<RefCell<bool>>,
}

impl Feature for TestInitFeature {
    fn name(&self) -> String {
        self.name.clone()
    }
    fn active(&self) -> bool {
        self.active
    }
    fn init(&mut self, _ctx: &Rc<Context>, _options: &Value) {
        *self.init_called.borrow_mut() = true;
    }
}

#[test]
fn primary_feature_init_basic() {
    let client = test_sdk(Value::Noval, Value::Noval);
    let utility = client.get_utility();
    let ctx = make_test_ctx(&client, &utility);
    setp(
        &ctx.options.borrow(),
        "feature",
        jo(vec![(
            "initfeat",
            jo(vec![("active", Value::Bool(true))]),
        )]),
    );

    let init_called = Rc::new(RefCell::new(false));
    let feature: FeatureRef = Rc::new(RefCell::new(TestInitFeature {
        name: "initfeat".to_string(),
        active: true,
        init_called: init_called.clone(),
    }));

    utility.feature_init(&ctx, &feature);
    assert!(*init_called.borrow(), "expected init to be called");
}

#[test]
fn primary_feature_init_inactive() {
    let client = test_sdk(Value::Noval, Value::Noval);
    let utility = client.get_utility();
    let ctx = make_test_ctx(&client, &utility);
    setp(
        &ctx.options.borrow(),
        "feature",
        jo(vec![(
            "nofeat",
            jo(vec![("active", Value::Bool(false))]),
        )]),
    );

    let init_called = Rc::new(RefCell::new(false));
    let feature: FeatureRef = Rc::new(RefCell::new(TestInitFeature {
        name: "nofeat".to_string(),
        active: false,
        init_called: init_called.clone(),
    }));

    utility.feature_init(&ctx, &feature);
    assert!(
        !*init_called.borrow(),
        "expected init NOT to be called for inactive feature"
    );
}

#[test]
fn primary_fetcher_live() {
    let calls: Rc<RefCell<Vec<Value>>> = Rc::new(RefCell::new(Vec::new()));
    let c = calls.clone();
    let live_client = UnivecSDK::new(jo(vec![(
        "system",
        jo(vec![(
            "fetch",
            vfn(move |args| {
                c.borrow_mut().push(args.clone());
                jo(vec![
                    ("status", Value::Num(200.0)),
                    ("statusText", Value::str("OK")),
                ])
            }),
        )]),
    )]));
    let live_utility = live_client.get_utility();
    let ctx = live_utility.make_context(
        CtxSpec {
            opname: Some("load".to_string()),
            client: Some(live_client.clone()),
            utility: Some(live_utility.clone()),
            ..Default::default()
        },
        None,
    );

    let fetchdef = jo(vec![
        ("method", Value::str("GET")),
        ("headers", Value::empty_map()),
    ]);
    live_utility
        .fetch(&ctx, "http://example.com/test", &fetchdef)
        .expect("expected no error");
    assert_eq!(calls.borrow().len(), 1, "expected 1 call");
    let url = vs::get_elem(&calls.borrow()[0], &Value::Num(0.0), Value::Noval);
    assert_eq!(url, Value::str("http://example.com/test"));
}

#[test]
fn primary_fetcher_blocked_test_mode() {
    // A live SDK then set mode to test (not using test_sdk, which installs
    // the test feature's mock transport).
    let blocked_client = UnivecSDK::new(jo(vec![(
        "system",
        jo(vec![("fetch", vfn(|_args| Value::empty_map()))]),
    )]));
    *blocked_client.mode.borrow_mut() = "test".to_string();

    let blocked_utility = blocked_client.get_utility();
    let ctx = blocked_utility.make_context(
        CtxSpec {
            opname: Some("load".to_string()),
            client: Some(blocked_client.clone()),
            utility: Some(blocked_utility.clone()),
            ..Default::default()
        },
        None,
    );

    let fetchdef = jo(vec![
        ("method", Value::str("GET")),
        ("headers", Value::empty_map()),
    ]);
    let err = blocked_utility
        .fetch(&ctx, "http://example.com/test", &fetchdef)
        .err()
        .expect("expected error for test mode fetch");
    assert!(
        err.msg.to_lowercase().contains("blocked"),
        "expected error containing 'blocked', got {}",
        err.msg
    );
}

#[test]
fn primary_make_context_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["makeContext", "basic"]),
        &mut |entry| {
            let vin = getp(entry, "in");
            if let Value::Map(_) = vin {
                let ctx = make_ctx_from_map(&vin, &client, &utility);
                let out = jo(vec![("id", Value::str(ctx.id.clone()))]);
                let op = ctx.op.borrow().clone();
                setp(
                    &out,
                    "op",
                    jo(vec![
                        ("name", Value::str(op.name.clone())),
                        ("input", Value::str(op.input.clone())),
                    ]),
                );
                return Ok(out);
            }
            Ok(Value::Noval)
        },
    );
}

#[test]
fn primary_make_fetch_def_basic() {
    let (client, utility) = base_client();
    let ctx = make_test_full_ctx(&client, &utility);
    *ctx.spec.borrow_mut() = Some(Rc::new(RefCell::new(Spec::new(&jo(vec![
        ("base", Value::str("http://localhost:8080")),
        ("prefix", Value::str("/api")),
        ("path", Value::str("items/{id}")),
        ("suffix", Value::str("")),
        ("params", jo(vec![("id", Value::str("item01"))])),
        ("query", Value::empty_map()),
        (
            "headers",
            jo(vec![("content-type", Value::str("application/json"))]),
        ),
        ("method", Value::str("GET")),
        ("step", Value::str("start")),
    ])))));
    *ctx.result.borrow_mut() = Some(Rc::new(RefCell::new(SdkResult::new(
        &Value::empty_map(),
    ))));

    let fetchdef = utility.make_fetch_def(&ctx).expect("should not error");
    assert_eq!(getp(&fetchdef, "method"), Value::str("GET"));
    let url = get_str(&fetchdef, "url").unwrap_or_default();
    assert!(
        url.contains("/api/items/item01"),
        "expected url to contain /api/items/item01, got {}",
        url
    );
    assert_eq!(
        getp(&getp(&fetchdef, "headers"), "content-type"),
        Value::str("application/json")
    );
    assert!(getp(&fetchdef, "body").is_noval(), "expected no body");
}

#[test]
fn primary_make_fetch_def_with_body() {
    let (client, utility) = base_client();
    let ctx = make_test_full_ctx(&client, &utility);
    *ctx.spec.borrow_mut() = Some(Rc::new(RefCell::new(Spec::new(&jo(vec![
        ("base", Value::str("http://localhost:8080")),
        ("prefix", Value::str("")),
        ("path", Value::str("items")),
        ("suffix", Value::str("")),
        ("params", Value::empty_map()),
        ("query", Value::empty_map()),
        ("headers", Value::empty_map()),
        ("method", Value::str("POST")),
        ("step", Value::str("start")),
        ("body", jo(vec![("name", Value::str("test"))])),
    ])))));
    *ctx.result.borrow_mut() = Some(Rc::new(RefCell::new(SdkResult::new(
        &Value::empty_map(),
    ))));

    let fetchdef = utility.make_fetch_def(&ctx).expect("should not error");
    assert_eq!(getp(&fetchdef, "method"), Value::str("POST"));
    let body = get_str(&fetchdef, "body").expect("expected body string");
    assert!(
        body.contains("\"name\""),
        "expected body to contain name, got {}",
        body
    );
}

#[test]
fn primary_make_options_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["makeOptions", "basic"]),
        &mut |entry| {
            let vin = getp(entry, "in");
            let ctx = utility.make_context(
                CtxSpec {
                    options: match getp(&vin, "options") {
                        Value::Map(m) => Some(Value::Map(m)),
                        _ => None,
                    },
                    config: match getp(&vin, "config") {
                        Value::Map(m) => Some(Value::Map(m)),
                        _ => None,
                    },
                    ..Default::default()
                },
                None,
            );
            *ctx.client.borrow_mut() = Some(client.clone());
            *ctx.utility.borrow_mut() = Some(utility.clone());
            Ok(utility.make_options(&ctx))
        },
    );
}

#[test]
fn primary_make_request_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["makeRequest", "basic"]),
        &mut |entry| {
            let ctxmap = getp(entry, "ctx");
            let ctx = make_ctx_from_map(&ctxmap, &client, &utility);
            *ctx.options.borrow_mut() = client.options_map();

            utility.make_request(&ctx)?;

            // Update entry ctx for match checking.
            if let Value::Map(_) = &ctxmap {
                if ctx.response.borrow().is_some() {
                    setp(&ctxmap, "response", Value::str("exists"));
                }
                if ctx.result.borrow().is_some() {
                    setp(&ctxmap, "result", Value::str("exists"));
                }
            }

            Ok(Value::Noval)
        },
    );
}

#[test]
fn primary_make_response_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["makeResponse", "basic"]),
        &mut |entry| {
            let ctxmap = getp(entry, "ctx");
            let ctx = make_ctx_from_map(&ctxmap, &client, &utility);
            fixctx(&ctx, &client);

            utility.make_response(&ctx)?;

            // Update entry ctx for match checking with result data.
            if let (Value::Map(_), Some(result)) = (&ctxmap, ctx.result.borrow().clone()) {
                let r = result.borrow();
                setp(
                    &ctxmap,
                    "result",
                    jo(vec![
                        ("ok", Value::Bool(r.ok)),
                        ("status", Value::Num(r.status as f64)),
                        ("statusText", Value::str(r.status_text.clone())),
                        ("headers", r.headers.clone()),
                        ("body", r.body.clone()),
                    ]),
                );
            }

            Ok(Value::Noval)
        },
    );
}

#[test]
fn primary_make_result_basic() {
    let (client, utility) = base_client();
    let ctx = make_test_full_ctx(&client, &utility);
    *ctx.spec.borrow_mut() = Some(Rc::new(RefCell::new(Spec::new(&jo(vec![
        ("base", Value::str("http://localhost:8080")),
        ("prefix", Value::str("/api")),
        ("path", Value::str("items/{id}")),
        ("params", jo(vec![("id", Value::str("item01"))])),
        ("query", Value::empty_map()),
        ("headers", Value::empty_map()),
        ("method", Value::str("GET")),
        ("step", Value::str("start")),
    ])))));
    *ctx.result.borrow_mut() = Some(Rc::new(RefCell::new(SdkResult::new(&jo(vec![
        ("ok", Value::Bool(true)),
        ("status", Value::Num(200.0)),
        ("statusText", Value::str("OK")),
        ("headers", Value::empty_map()),
        (
            "resdata",
            jo(vec![
                ("id", Value::str("item01")),
                ("name", Value::str("Test")),
            ]),
        ),
    ])))));

    let result = utility.make_result(&ctx).expect("expected no error");
    assert_eq!(result.borrow().status, 200);
}

#[test]
fn primary_make_result_no_spec() {
    let (client, utility) = base_client();
    let ctx = make_test_full_ctx(&client, &utility);
    *ctx.spec.borrow_mut() = None;
    *ctx.result.borrow_mut() = Some(Rc::new(RefCell::new(SdkResult::new(&jo(vec![
        ("ok", Value::Bool(true)),
        ("status", Value::Num(200.0)),
    ])))));
    assert!(
        utility.make_result(&ctx).is_err(),
        "expected error for nil spec"
    );
}

#[test]
fn primary_make_result_no_result() {
    let (client, utility) = base_client();
    let ctx = make_test_full_ctx(&client, &utility);
    *ctx.spec.borrow_mut() = Some(Rc::new(RefCell::new(Spec::new(&jo(vec![(
        "step",
        Value::str("start"),
    )])))));
    *ctx.result.borrow_mut() = None;
    assert!(
        utility.make_result(&ctx).is_err(),
        "expected error for nil result"
    );
}

#[test]
fn primary_make_spec_basic() {
    let primary = primary();
    let setup_opts = get_spec(&primary, &["makeSpec", "DEF", "setup", "a"]);
    let spec_client = test_sdk(Value::Noval, setup_opts);
    let spec_utility = spec_client.get_utility();

    runset(&get_spec(&primary, &["makeSpec", "basic"]), &mut |entry| {
        let ctxmap = getp(entry, "ctx");
        let ctx = make_ctx_from_map(&ctxmap, &spec_client, &spec_utility);
        *ctx.options.borrow_mut() = spec_client.options_map();

        spec_utility.make_spec(&ctx)?;

        // Update entry ctx for match.
        if let (Value::Map(_), Some(spec)) = (&ctxmap, ctx.spec.borrow().clone()) {
            let s = spec.borrow();
            setp(
                &ctxmap,
                "spec",
                jo(vec![
                    ("base", Value::str(s.base.clone())),
                    ("prefix", Value::str(s.prefix.clone())),
                    ("suffix", Value::str(s.suffix.clone())),
                    ("method", Value::str(s.method.clone())),
                    ("params", s.params.clone()),
                    ("query", s.query.clone()),
                    ("headers", s.headers.clone()),
                    ("step", Value::str(s.step.clone())),
                ]),
            );
        }

        Ok(Value::Noval)
    });
}

#[test]
fn primary_make_point_basic() {
    let (client, utility) = base_client();
    let ctx = make_test_ctx(&client, &utility);
    let point = jo(vec![
        ("parts", ja(vec![Value::str("items"), Value::str("{id}")])),
        ("args", jo(vec![("params", Value::empty_list())])),
        ("params", Value::empty_list()),
        ("alias", Value::empty_map()),
        ("select", Value::empty_map()),
        ("active", Value::Bool(true)),
        ("transform", Value::empty_map()),
    ]);
    *ctx.op.borrow_mut() = Rc::new(Operation::new(&jo(vec![
        ("entity", Value::str("x")),
        ("name", Value::str("load")),
        ("points", ja(vec![point])),
    ])));

    utility.make_point(&ctx).expect("expected no error");
    assert!(
        !ctx.point.borrow().is_noval(),
        "expected point to be set"
    );
}

#[test]
fn primary_make_url_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(&get_spec(&primary, &["makeUrl", "basic"]), &mut |entry| {
        let ctxmap = getp(entry, "ctx");
        let ctx = make_ctx_from_map(&ctxmap, &client, &utility);
        if ctx.result.borrow().is_none() {
            *ctx.result.borrow_mut() = Some(Rc::new(RefCell::new(SdkResult::new(
                &Value::empty_map(),
            ))));
        }
        utility.make_url(&ctx).map(Value::str)
    });
}

#[test]
fn primary_operator_basic() {
    let (_client, _utility) = base_client();
    let primary = primary();
    runset(&get_spec(&primary, &["operator", "basic"]), &mut |entry| {
        let vin = getp(entry, "in");
        let op = Operation::new(&vin);
        Ok(jo(vec![
            ("entity", Value::str(op.entity.clone())),
            ("name", Value::str(op.name.clone())),
            ("input", Value::str(op.input.clone())),
            ("points", op.points.clone()),
        ]))
    });
}

#[test]
fn primary_param_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(&get_spec(&primary, &["param", "basic"]), &mut |entry| {
        let args = getp(entry, "args");
        if vs::size(&args) < 2 {
            return Ok(Value::Noval);
        }

        let ctxmap = vs::get_elem(&args, &Value::Num(0.0), Value::empty_map());
        let ctx = make_ctx_from_map(&ctxmap, &client, &utility);
        let paramdef = vs::get_elem(&args, &Value::Num(1.0), Value::Noval);

        let result = utility.param(&ctx, &paramdef);

        // Copy spec alias back to entry ctx for matching.
        if let Value::Map(_) = getp(&getp(&getp(entry, "match"), "ctx"), "spec") {
            let entry_ctx = match getp(entry, "ctx") {
                Value::Map(m) => Value::Map(m),
                _ => {
                    let e = Value::empty_map();
                    setp(entry, "ctx", e.clone());
                    e
                }
            };
            if let Some(spec) = ctx.spec.borrow().clone() {
                setp(
                    &entry_ctx,
                    "spec",
                    jo(vec![("alias", spec.borrow().alias.clone())]),
                );
            }
        }

        Ok(result)
    });
}

#[test]
fn primary_prepare_auth_basic() {
    let primary = primary();
    let setup_opts = get_spec(&primary, &["prepareAuth", "DEF", "setup", "a"]);
    let auth_client = test_sdk(Value::Noval, setup_opts);
    let auth_utility = auth_client.get_utility();

    runset(
        &get_spec(&primary, &["prepareAuth", "basic"]),
        &mut |entry| {
            let ctxmap = getp(entry, "ctx");
            let ctx = make_ctx_from_map(&ctxmap, &auth_client, &auth_utility);
            fixctx(&ctx, &auth_client);

            auth_utility.prepare_auth(&ctx)?;

            // Update entry ctx for match.
            if let (Value::Map(_), Some(spec)) = (&ctxmap, ctx.spec.borrow().clone()) {
                setp(
                    &ctxmap,
                    "spec",
                    jo(vec![("headers", spec.borrow().headers.clone())]),
                );
            }

            Ok(Value::Noval)
        },
    );
}

#[test]
fn primary_prepare_body_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["prepareBody", "basic"]),
        &mut |entry| {
            let ctx = make_ctx_from_map(&getp(entry, "ctx"), &client, &utility);
            fixctx(&ctx, &client);
            Ok(utility.prepare_body(&ctx))
        },
    );
}

#[test]
fn primary_prepare_headers_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["prepareHeaders", "basic"]),
        &mut |entry| {
            let ctx = make_ctx_from_map(&getp(entry, "ctx"), &client, &utility);
            Ok(utility.prepare_headers(&ctx))
        },
    );
}

#[test]
fn primary_prepare_method_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["prepareMethod", "basic"]),
        &mut |entry| {
            let ctx = make_ctx_from_map(&getp(entry, "ctx"), &client, &utility);
            Ok(Value::str(utility.prepare_method(&ctx)))
        },
    );
}

#[test]
fn primary_prepare_params_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["prepareParams", "basic"]),
        &mut |entry| {
            let ctx = make_ctx_from_map(&getp(entry, "ctx"), &client, &utility);
            Ok(utility.prepare_params(&ctx))
        },
    );
}

// Was two hand-written cases that had drifted out of the shared corpus (the
// preparePath fixture shipped as an empty `set: []`). Now driven by the
// corpus like every other section, so all ports assert the same separator /
// blank-segment behaviour.
#[test]
fn primary_prepare_path_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["preparePath", "basic"]),
        &mut |entry| {
            let ctx = make_ctx_from_map(&getp(entry, "ctx"), &client, &utility);
            Ok(Value::str(utility.prepare_path(&ctx)))
        },
    );
}

#[test]
fn primary_prepare_query_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["prepareQuery", "basic"]),
        &mut |entry| {
            let ctx = make_ctx_from_map(&getp(entry, "ctx"), &client, &utility);
            Ok(utility.prepare_query(&ctx))
        },
    );
}

#[test]
fn primary_result_basic_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["resultBasic", "basic"]),
        &mut |entry| {
            let ctx = make_ctx_from_map(&getp(entry, "ctx"), &client, &utility);
            fixctx(&ctx, &client);

            let result = utility.result_basic(&ctx);

            let out = Value::empty_map();
            if let Some(result) = result {
                let r = result.borrow();
                setp(&out, "status", Value::Num(r.status as f64));
                setp(&out, "statusText", Value::str(r.status_text.clone()));
                if let Some(err) = &r.err {
                    setp(
                        &out,
                        "err",
                        jo(vec![("message", Value::str(err.msg.clone()))]),
                    );
                }
            }

            Ok(out)
        },
    );
}

#[test]
fn primary_result_body_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["resultBody", "basic"]),
        &mut |entry| {
            let ctxmap = getp(entry, "ctx");
            let ctx = make_ctx_from_map(&ctxmap, &client, &utility);

            utility.result_body(&ctx);

            if let (Value::Map(_), Some(result)) = (&ctxmap, ctx.result.borrow().clone()) {
                setp(
                    &ctxmap,
                    "result",
                    jo(vec![("body", result.borrow().body.clone())]),
                );
            }

            Ok(Value::Noval)
        },
    );
}

#[test]
fn primary_result_headers_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["resultHeaders", "basic"]),
        &mut |entry| {
            let ctxmap = getp(entry, "ctx");
            let ctx = make_ctx_from_map(&ctxmap, &client, &utility);

            utility.result_headers(&ctx);

            if let (Value::Map(_), Some(result)) = (&ctxmap, ctx.result.borrow().clone()) {
                setp(
                    &ctxmap,
                    "result",
                    jo(vec![("headers", result.borrow().headers.clone())]),
                );
            }

            Ok(Value::Noval)
        },
    );
}

#[test]
fn primary_transform_request_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["transformRequest", "basic"]),
        &mut |entry| {
            let ctxmap = getp(entry, "ctx");
            let ctx = make_ctx_from_map(&ctxmap, &client, &utility);

            let result = utility.transform_request(&ctx);

            // Update entry ctx for match (step changed).
            if let Some(spec) = ctx.spec.borrow().clone() {
                if let Value::Map(_) = getp(&ctxmap, "spec") {
                    setp(
                        &getp(&ctxmap, "spec"),
                        "step",
                        Value::str(spec.borrow().step.clone()),
                    );
                }
            }

            Ok(result)
        },
    );
}

#[test]
fn primary_transform_response_basic() {
    let (client, utility) = base_client();
    let primary = primary();
    runset(
        &get_spec(&primary, &["transformResponse", "basic"]),
        &mut |entry| {
            let ctxmap = getp(entry, "ctx");
            let ctx = make_ctx_from_map(&ctxmap, &client, &utility);

            let result = utility.transform_response(&ctx);

            if let Some(spec) = ctx.spec.borrow().clone() {
                if let Value::Map(_) = getp(&ctxmap, "spec") {
                    setp(
                        &getp(&ctxmap, "spec"),
                        "step",
                        Value::str(spec.borrow().step.clone()),
                    );
                }
            }

            Ok(result)
        },
    );
}

// keep new_sdk / to_map referenced (parity helpers).
#[test]
fn primary_new_sdk_smoke() {
    let client = new_sdk();
    assert_eq!(*client.mode.borrow(), "live");
    let _ = to_map(&Value::Noval);
}
