// Shared SDK test SUPPORT: the helpers the generated entity/direct tests and
// the corpus call sites share — env loading, the sdk-test-control.json skip
// and pacing machinery, corpus access, entity-data conversion, ctx
// construction from a JSON test entry, and the fh* feature-test harness
// (mirrors tm/go/test/testsupport_test.go plus the fh* harness from
// tm/go/test/feature_test.go). Each test binary includes it with
// `mod common;`.
//
// The corpus ENGINE half of this file was retired by the vendor-tag rollout:
// see the note where it used to be, and tests/omni_resolver/mod.rs.

#![allow(dead_code)]

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use univec_sdk::core::helpers::{
    get_bool, get_str, getp, jo, json_thunk, now_ms, setp, to_int, to_map,
};
use univec_sdk::utility::voxgigstruct as vs;
use univec_sdk::{
    json_parse, test_sdk, Context, CtxSpec, FeatureRef, FetcherFn, Operation, OutVal,
    UnivecError, UnivecSDK, Response, SdkResult, Spec, Utility, Value,
};

pub const NULLMARK: &str = "__NULL__";
pub const UNDEFMARK: &str = "__UNDEF__";
pub const EXISTSMARK: &str = "__EXISTS__";

// ---- files ----------------------------------------------------------------

pub fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

pub fn read_json(path: &PathBuf) -> Value {
    let txt = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("failed to read {:?}: {}", path, e));
    json_parse(&txt).unwrap_or_else(|e| panic!("failed to parse {:?}: {}", path, e))
}

/// The shared test spec ../.sdk/test/test.json.
pub fn load_test_spec() -> Value {
    let mut p = manifest_dir();
    p.push("..");
    p.push(".sdk");
    p.push("test");
    p.push("test.json");
    read_json(&p)
}

pub fn get_spec(spec: &Value, keys: &[&str]) -> Value {
    let mut cur = spec.clone();
    for key in keys {
        cur = getp(&cur, key);
    }
    match cur {
        Value::Map(m) => Value::Map(m),
        _ => Value::Noval,
    }
}

// ---- sdk-test-control.json --------------------------------------------------

pub fn load_test_control() -> Value {
    let mut p = manifest_dir();
    p.push("tests");
    p.push("sdk-test-control.json");
    match std::fs::read_to_string(&p) {
        Ok(txt) => json_parse(&txt).unwrap_or(Value::empty_map()),
        Err(_) => Value::empty_map(),
    }
}

/// Check sdk-test-control.json for a skip entry: (skip, reason).
pub fn is_control_skipped(kind: &str, name: &str, mode: &str) -> (bool, String) {
    let ctrl = load_test_control();
    let items = match get_spec(&ctrl, &["test", "skip", mode]) {
        Value::Map(_) => getp(&get_spec(&ctrl, &["test", "skip", mode]), kind),
        _ => Value::Noval,
    };
    if let Value::List(l) = items {
        for item in l.borrow().iter() {
            let reason = get_str(item, "reason").unwrap_or_default();
            if kind == "direct" {
                if get_str(item, "test").as_deref() == Some(name) {
                    return (true, reason);
                }
            }
            if kind == "entityOp" {
                let ent = get_str(item, "entity").unwrap_or_default();
                let op = get_str(item, "op").unwrap_or_default();
                if format!("{}.{}", ent, op) == name {
                    return (true, reason);
                }
            }
        }
    }
    (false, String::new())
}

/// Extra SDK options every LIVE client is constructed with, read from
/// sdk-test-control.json `test.client.options`.
///
/// The generated live client knows two things: the base URL (from the spec)
/// and the credential (from the environment). Everything else about how a
/// particular API wants to be talked to - which features to switch on, and
/// with what settings - is a property of THAT API, known to the project and
/// to nothing in the toolchain.
///
/// Merged UNDER the generated fields, so the suite's own base/apikey/server
/// values win: this ADDS to the live client, it does not redirect it.
///
/// Reserved fields are stripped HERE rather than at each merge site: the
/// generated map only names a field when the model calls for one, so a
/// "base" in this block would face no competing value and would silently
/// redirect the whole suite - credential included - to another host.
pub const LIVE_RESERVED: [&str; 6] =
    ["base", "prefix", "suffix", "server", "apikey", "secret"];

pub fn live_client_options() -> Value {
    let ctrl = load_test_control();
    let out = Value::empty_map();
    if let Value::Map(m) = get_spec(&ctrl, &["test", "client", "options"]) {
        for (k, v) in m.borrow().iter() {
            if !LIVE_RESERVED.contains(&k.as_str()) {
                setp(&out, k, v.clone());
            }
        }
    }
    out
}

/// Configured per-test live delay in ms; default 500.
pub fn live_delay_ms() -> i64 {
    let ctrl = load_test_control();
    match getp(&get_spec(&ctrl, &["test", "live"]), "delayMs") {
        Value::Num(n) if n >= 0.0 => n as i64,
        _ => 500,
    }
}

// ---- env ---------------------------------------------------------------------

/// Load ../.env.local (KEY=VALUE lines) into the process env, once per call.
pub fn load_env_local() {
    let mut p = manifest_dir();
    p.push("..");
    p.push(".env.local");
    let data = match std::fs::read_to_string(&p) {
        Ok(d) => d,
        Err(_) => return,
    };
    for line in data.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, val)) = line.split_once('=') {
            std::env::set_var(key.trim(), val.trim());
        }
    }
}

/// env_override (mirrors go): when UNIVEC_TEST_LIVE or
/// UNIVEC_TEST_OVERRIDE is TRUE, environment variables replace the
/// defaults in `m` (JSON-shaped values are parsed).
pub fn env_override(m: Value) -> Value {
    let live = std::env::var("UNIVEC_TEST_LIVE").unwrap_or_default() == "TRUE";
    let over = std::env::var("UNIVEC_TEST_OVERRIDE").unwrap_or_default() == "TRUE";

    if live || over {
        if let Value::Map(mm) = &m {
            let keys: Vec<String> = mm.borrow().iter().map(|(k, _)| k.clone()).collect();
            for key in keys {
                if let Ok(envval) = std::env::var(&key) {
                    let envval = envval.trim().to_string();
                    if envval.is_empty() {
                        continue;
                    }
                    if envval.starts_with('{') {
                        if let Ok(parsed) = json_parse(&envval) {
                            setp(&m, &key, parsed);
                            continue;
                        }
                    }
                    setp(&m, &key, Value::str(envval));
                }
            }
        }
    }

    if let Ok(explain) = std::env::var("UNIVEC_TEST_EXPLAIN") {
        if !explain.is_empty() {
            setp(&m, "UNIVEC_TEST_EXPLAIN", Value::str(explain));
        }
    }

    m
}

// ---- entity test setup ---------------------------------------------------------

pub struct EntityTestSetup {
    pub client: Rc<UnivecSDK>,
    pub data: Value,
    pub idmap: Value,
    pub env: Value,
    pub explain: bool,
    pub live: bool,
    pub synthetic_only: bool,
    pub now: i64,
}

/// Extract data maps from a list result (rust list results already carry
/// plain data maps).
pub fn entity_list_to_data(list: &Value) -> Value {
    match list {
        Value::List(_) => list.clone(),
        _ => Value::empty_list(),
    }
}

// ---- normalisation + matching ---------------------------------------------------

/// JSON-normalise a Value: functions become Null (like JSON.stringify).
pub fn json_normalize(v: &Value) -> Value {
    match v {
        Value::Func(_) => Value::Null,
        Value::List(l) => Value::list(l.borrow().iter().map(json_normalize).collect()),
        Value::Map(m) => {
            let out = Value::empty_map();
            for (k, x) in m.borrow().iter() {
                setp(&out, k, json_normalize(x));
            }
            out
        }
        other => other.clone(),
    }
}

// The corpus ENGINE that used to live here — `runset` / `runset_named`
// (the entry loop) and `match_deep` / `match_string` (the match engine) —
// is superseded by the vendored @voxgig/omni runner, driven through the
// adapter in tests/omni_resolver/mod.rs (vendor-tag rollout, Decision 4).
// This file keeps its SUPPORT half under its own name — env loading, the
// sdk-test-control skip/pacing machinery, corpus and entity-data access,
// ctx construction from a JSON entry, and the fh feature harness — so the
// emitted call sites did not move.

// ---- ctx construction from JSON test entries --------------------------------------

/// makeCtxFromMap: create a Context from a JSON test entry's ctx or args map.
pub fn make_ctx_from_map(
    ctxmap: &Value,
    client: &Rc<UnivecSDK>,
    utility: &Rc<Utility>,
) -> Rc<Context> {
    let ctxmap = match ctxmap {
        Value::Map(m) => Value::Map(m.clone()),
        _ => Value::empty_map(),
    };

    let ctrl = match to_map(&getp(&ctxmap, "ctrl")) {
        Value::Map(m) => Some(Value::Map(m)),
        _ => None,
    };

    let ctx = Context::new(
        CtxSpec {
            opname: get_str(&ctxmap, "opname"),
            ctrl,
            data: Some(getp(&ctxmap, "data")),
            reqdata: Some(getp(&ctxmap, "reqdata")),
            mtch: Some(getp(&ctxmap, "match")),
            reqmatch: Some(getp(&ctxmap, "reqmatch")),
            options: match getp(&ctxmap, "options") {
                Value::Map(m) => Some(Value::Map(m)),
                _ => None,
            },
            config: match getp(&ctxmap, "config") {
                Value::Map(m) => Some(Value::Map(m)),
                _ => None,
            },
            point: match getp(&ctxmap, "point") {
                Value::Map(m) => Some(Value::Map(m)),
                _ => None,
            },
            ..Default::default()
        },
        None,
    );

    *ctx.client.borrow_mut() = Some(client.clone());
    *ctx.utility.borrow_mut() = Some(utility.clone());

    if ctx.options.borrow().is_noval() {
        *ctx.options.borrow_mut() = client.options_map();
    }

    // Handle spec from JSON map.
    if let Value::Map(_) = getp(&ctxmap, "spec") {
        *ctx.spec.borrow_mut() = Some(Rc::new(RefCell::new(Spec::new(&getp(
            &ctxmap, "spec",
        )))));
    }

    // Handle result from JSON map.
    if let Value::Map(_) = getp(&ctxmap, "result") {
        let res_map = getp(&ctxmap, "result");
        let result = Rc::new(RefCell::new(SdkResult::new(&res_map)));
        if let Value::Map(_) = getp(&res_map, "err") {
            if let Some(msg) = get_str(&getp(&res_map, "err"), "message") {
                result.borrow_mut().err = Some(UnivecError::new("", &msg));
            }
        }
        *ctx.result.borrow_mut() = Some(result);
    }

    // Handle response from JSON map.
    if let Value::Map(_) = getp(&ctxmap, "response") {
        let resp_map = getp(&ctxmap, "response");
        let response = Rc::new(RefCell::new(Response::new(&resp_map)));
        let body = getp(&resp_map, "body");
        if !body.is_noval() && !body.is_null() {
            response.borrow_mut().json = json_thunk(body);
        }
        if let Value::Map(hm) = getp(&resp_map, "headers") {
            let lower = Value::empty_map();
            for (k, v) in hm.borrow().iter() {
                setp(&lower, &k.to_lowercase(), v.clone());
            }
            response.borrow_mut().headers = lower;
        }
        *ctx.response.borrow_mut() = Some(response);
    }

    ctx
}

pub fn fixctx(ctx: &Rc<Context>, client: &Rc<UnivecSDK>) {
    if ctx.options.borrow().is_noval() {
        *ctx.options.borrow_mut() = client.options_map();
    }
}

/// An error from a JSON map like {"message": "...", "code": "..."}.
pub fn err_from_map(m: &Value) -> Option<UnivecError> {
    let msg = get_str(m, "message").unwrap_or_default();
    if msg.is_empty() {
        return None;
    }
    let code = get_str(m, "code").unwrap_or_default();
    Some(UnivecError::new(&code, &msg))
}

// ---- fh harness (mirrors go feature_test.go) ---------------------------------------

/// fh_has_feature: true when this SDK was generated with the named feature.
pub fn fh_has_feature(name: &str) -> bool {
    let config = univec_sdk::make_config();
    let fm = getp(&config, "feature");
    matches!(getp(&fm, name), Value::Map(_))
}

/// fh_present: skip-guard twin of go's fhSkipWithout — returns false (and
/// logs) when any named feature is absent from this SDK.
pub fn fh_present(names: &[&str]) -> bool {
    for name in names {
        if !fh_has_feature(name) {
            eprintln!("skip: feature not present in this SDK: {}", name);
            return false;
        }
    }
    true
}

/// fhClock: a deterministic virtual clock. now() advances only when
/// sleep(ms) is called, so timing-based features can be asserted without
/// real delays. Exposed as Value::Func injectables.
pub struct FhClock {
    pub t: Rc<RefCell<i64>>,
}

impl FhClock {
    pub fn new() -> FhClock {
        FhClock {
            t: Rc::new(RefCell::new(0)),
        }
    }

    pub fn now_fn(&self) -> Value {
        let t = self.t.clone();
        Value::func(move |_i, _v, _r, _s| Value::Num(*t.borrow() as f64))
    }

    pub fn sleep_fn(&self) -> Value {
        let t = self.t.clone();
        Value::func(move |_i, v, _r, _s| {
            if let Value::Num(ms) = v {
                *t.borrow_mut() += *ms as i64;
            }
            Value::Noval
        })
    }

    pub fn t(&self) -> i64 {
        *self.t.borrow()
    }

    pub fn advance(&self, ms: i64) {
        *self.t.borrow_mut() += ms;
    }
}

/// fh_response: a transport-shaped response the pipeline understands.
pub fn fh_response(status: i64, data: Value, headers: Value) -> Value {
    let h = Value::empty_map();
    if let Value::Map(hm) = &headers {
        for (k, v) in hm.borrow().iter() {
            setp(&h, &k.to_lowercase(), v.clone());
        }
    }
    let status_text = if status >= 400 { "ERR" } else { "OK" };
    jo(vec![
        ("status", Value::Num(status as f64)),
        ("statusText", Value::str(status_text)),
        ("body", Value::str("not-used")),
        ("json", json_thunk(data)),
        ("headers", h),
    ])
}

/// A mock transport recording every call, replying via an optional reply
/// closure (default: 200 with a call counter). Returns (fetcher, calls).
pub type FhReply = Rc<dyn Fn(i64, &Value) -> Result<Value, UnivecError>>;

pub fn fh_recorder(reply: Option<FhReply>) -> (FetcherFn, Rc<RefCell<Vec<Value>>>) {
    let calls: Rc<RefCell<Vec<Value>>> = Rc::new(RefCell::new(Vec::new()));
    let c = calls.clone();
    let fetch: FetcherFn = Rc::new(move |_ctx, url, fetchdef| {
        c.borrow_mut().push(jo(vec![
            ("url", Value::str(url)),
            ("fetchdef", fetchdef.clone()),
        ]));
        let n = c.borrow().len() as i64;
        match &reply {
            Some(r) => r(n, fetchdef),
            None => Ok(fh_response(
                200,
                jo(vec![
                    ("ok", Value::Bool(true)),
                    ("n", Value::Num(n as f64)),
                ]),
                Value::Noval,
            )),
        }
    });
    (fetch, calls)
}

pub fn rec_call(calls: &Rc<RefCell<Vec<Value>>>, i: usize) -> Value {
    calls.borrow().get(i).cloned().unwrap_or(Value::Noval)
}

pub fn rec_headers(calls: &Rc<RefCell<Vec<Value>>>, i: usize) -> Value {
    getp(&getp(&rec_call(calls, i), "fetchdef"), "headers")
}

pub fn rec_fetchdef(calls: &Rc<RefCell<Vec<Value>>>, i: usize) -> Value {
    getp(&rec_call(calls, i), "fetchdef")
}

pub fn rec_url(calls: &Rc<RefCell<Vec<Value>>>, i: usize) -> String {
    get_str(&rec_call(calls, i), "url").unwrap_or_default()
}

/// fhHarness: features (in init order) wired to a mock transport and a
/// mini operation pipeline.
pub struct FhHarness {
    pub client: Rc<UnivecSDK>,
    pub utility: Rc<Utility>,
    pub rootctx: Rc<Context>,
    pub base: String,
}

/// fh_make: a real (test-mode) client, an isolated utility whose fetcher is
/// the mock server, and the requested features initialised against it.
/// Fires PostConstruct once wiring is complete.
pub fn fh_make(server: Option<FetcherFn>, features: Vec<(FeatureRef, Value)>) -> FhHarness {
    let client = test_sdk(Value::Noval, Value::Noval);
    client.features.borrow_mut().clear();

    let utility = client.get_utility();
    let server = match server {
        Some(s) => s,
        None => fh_recorder(None).0,
    };
    *utility.fetcher.borrow_mut() = server;

    let rootctx = utility.make_context(
        CtxSpec {
            client: Some(client.clone()),
            utility: Some(utility.clone()),
            ..Default::default()
        },
        Some(&client.get_root_ctx()),
    );

    for (f, options) in features {
        let fopts = jo(vec![("active", Value::Bool(true))]);
        if let Value::Map(m) = &options {
            for (k, v) in m.borrow().iter() {
                setp(&fopts, k, v.clone());
            }
        }
        f.borrow_mut().init(&rootctx, &fopts);
        client.features.borrow_mut().push(f);
    }

    utility.feature_hook(&rootctx, "PostConstruct");

    FhHarness {
        client,
        utility,
        rootctx,
        base: "http://api.test".to_string(),
    }
}

pub struct FhOpSpec {
    pub entity: String,
    pub op: String,
    pub method: String,
    pub path: String,
    pub query: Value,
    pub headers: Value,
    pub body: Value,
    pub ctrl: Value,
}

impl Default for FhOpSpec {
    fn default() -> FhOpSpec {
        FhOpSpec {
            entity: String::new(),
            op: String::new(),
            method: String::new(),
            path: String::new(),
            query: Value::Noval,
            headers: Value::Noval,
            body: Value::Noval,
            ctrl: Value::Noval,
        }
    }
}

pub struct FhOpResult {
    pub ok: bool,
    pub data: Value,
    pub err: Option<UnivecError>,
    pub result: Option<Rc<RefCell<SdkResult>>>,
    pub ctx: Rc<Context>,
}

pub fn fh_default_method(op: &str) -> &'static str {
    match op {
        "create" => "POST",
        "update" => "PATCH",
        "remove" => "DELETE",
        _ => "GET",
    }
}

pub fn fh_build_url(spec: &Rc<RefCell<Spec>>) -> String {
    let (base, path, query) = {
        let s = spec.borrow();
        (s.base.clone(), s.path.clone(), s.query.clone())
    };
    let mut keys: Vec<String> = Vec::new();
    if let Value::Map(qm) = &query {
        for (k, v) in qm.borrow().iter() {
            if !v.is_noval() && !v.is_null() {
                keys.push(k.clone());
            }
        }
    }
    keys.sort();
    let mut qs = String::new();
    for k in keys {
        if !qs.is_empty() {
            qs.push('&');
        }
        let v = getp(&query, &k);
        qs.push_str(&format!(
            "{}={}",
            vs::esc_url(&Value::str(k.clone())),
            vs::esc_url(&Value::str(vs::stringify(&v, None, false)))
        ));
    }
    let mut url = format!("{}{}", base, path);
    if !qs.is_empty() {
        url.push('?');
        url.push_str(&qs);
    }
    url
}

fn fh_populate_result(ctx: &Rc<Context>, fetched: &Result<Value, UnivecError>) {
    let result = Rc::new(RefCell::new(SdkResult::new(&Value::empty_map())));
    *ctx.result.borrow_mut() = Some(result.clone());

    let response_map = match fetched {
        Err(fetch_err) => {
            result.borrow_mut().err = Some(fetch_err.clone());
            return;
        }
        Ok(v) => v,
    };

    if !matches!(response_map, Value::Map(_)) {
        result.borrow_mut().err =
            Some(ctx.make_error("request_no_response", "response: undefined"));
        return;
    }

    let resp = Response::new(response_map);
    {
        let mut r = result.borrow_mut();
        r.status = resp.status;
        r.status_text = resp.status_text.clone();
        if let Value::Map(_) = &resp.headers {
            r.headers = resp.headers.clone();
        }
        if let Value::Func(_) = &resp.json {
            r.body = univec_sdk::call_json(&resp.json);
        }
        r.resdata = r.body.clone();

        if r.status >= 400 {
            r.err = Some(ctx.make_error(
                "request_status",
                &format!("request: {}: {}", r.status, r.status_text),
            ));
        }
        if r.err.is_none() {
            r.ok = true;
        }
    }
}

impl FhHarness {
    /// op: one operation through the mini pipeline (mirrors the generated
    /// entity op code: hook, short-circuit, make*, hook, ...).
    pub fn op(&self, o: FhOpSpec) -> FhOpResult {
        let entity = if o.entity.is_empty() {
            "widget".to_string()
        } else {
            o.entity
        };
        let opname = if o.op.is_empty() {
            "load".to_string()
        } else {
            o.op
        };
        let method = if o.method.is_empty() {
            fh_default_method(&opname).to_string()
        } else {
            o.method
        };
        let ctrl = match o.ctrl {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        let ctx = self.utility.make_context(
            CtxSpec {
                opname: Some(opname.clone()),
                ctrl: Some(ctrl),
                ..Default::default()
            },
            Some(&self.rootctx),
        );
        *ctx.op.borrow_mut() = Rc::new(Operation::new(&jo(vec![
            ("entity", Value::str(entity.clone())),
            ("name", Value::str(opname.clone())),
        ])));

        self.utility.feature_hook(&ctx, "PostConstructEntity");

        self.utility.feature_hook(&ctx, "PrePoint");
        if let Some(OutVal::Err(err)) = ctx.out_get("point") {
            return self.fail(ctx, err);
        }

        self.utility.feature_hook(&ctx, "PreSpec");
        let path = if o.path.is_empty() {
            format!("/{}", entity)
        } else {
            o.path
        };
        let headers = Value::empty_map();
        if let Value::Map(hm) = &o.headers {
            for (k, v) in hm.borrow().iter() {
                setp(&headers, k, v.clone());
            }
        }
        let query = Value::empty_map();
        if let Value::Map(qm) = &o.query {
            for (k, v) in qm.borrow().iter() {
                setp(&query, k, v.clone());
            }
        }
        let spec = Rc::new(RefCell::new(Spec::new(&jo(vec![
            ("method", Value::str(method)),
            ("base", Value::str(self.base.clone())),
            ("path", Value::str(path)),
            ("headers", headers),
            ("query", query),
            ("step", Value::str("start")),
        ]))));
        if !o.body.is_noval() {
            spec.borrow_mut().body = o.body.clone();
        }
        *ctx.spec.borrow_mut() = Some(spec.clone());

        self.utility.feature_hook(&ctx, "PreRequest");
        let url = fh_build_url(&spec);
        spec.borrow_mut().url = url.clone();

        let fetchdef = jo(vec![
            ("url", Value::str(url.clone())),
            ("method", Value::str(spec.borrow().method.clone())),
            ("headers", spec.borrow().headers.clone()),
        ]);
        {
            let body = spec.borrow().body.clone();
            if !body.is_noval() {
                setp(&fetchdef, "body", body);
            }
        }

        let fetched: Result<Value, UnivecError> = match ctx.out_get("request") {
            Some(OutVal::Val(v)) if !v.is_noval() => Ok(v),
            _ => self.utility.fetch(&ctx, &url, &fetchdef),
        };

        if let Ok(rm) = &fetched {
            if let Value::Map(_) = rm {
                *ctx.response.borrow_mut() =
                    Some(Rc::new(RefCell::new(Response::new(rm))));
            }
        }

        self.utility.feature_hook(&ctx, "PreResponse");
        fh_populate_result(&ctx, &fetched);
        self.utility.feature_hook(&ctx, "PreResult");
        self.utility.feature_hook(&ctx, "PreDone");

        let result = ctx.result.borrow().clone();
        let ok_data = result.as_ref().and_then(|r| {
            let r = r.borrow();
            if r.ok {
                Some(r.resdata.clone())
            } else {
                None
            }
        });
        if let Some(data) = ok_data {
            return FhOpResult {
                ok: true,
                data,
                err: None,
                result,
                ctx,
            };
        }

        let err = result
            .as_ref()
            .and_then(|r| r.borrow().err.clone())
            .unwrap_or_else(|| ctx.make_error("op_failed", "operation failed"));
        self.fail(ctx, err)
    }

    fn fail(&self, ctx: Rc<Context>, err: UnivecError) -> FhOpResult {
        {
            let ctrl = ctx.ctrl.borrow().clone();
            ctrl.borrow_mut().err = Some(err.clone());
        }
        self.utility.feature_hook(&ctx, "PreUnexpected");
        let result = ctx.result.borrow().clone();
        FhOpResult {
            ok: false,
            data: Value::Noval,
            err: Some(err),
            result,
            ctx,
        }
    }
}

/// fhErrCode: extract the SDK error code, "" otherwise.
pub fn fh_err_code(err: &Option<UnivecError>) -> String {
    err.as_ref().map(|e| e.code.clone()).unwrap_or_default()
}

// keep to_int referenced for binaries that only use part of this module
pub fn _touch() {
    let _ = to_int(&Value::Noval);
    let _ = get_bool(&Value::Noval, "x");
    let _ = now_ms();
    let _ = entity_list_to_data(&Value::Noval);
}
