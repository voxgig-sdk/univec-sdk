// Behavioural tests for the secrets feature (vendored @voxgig/sekreto).
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because the feature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic. With
// the feature inactive nothing changes at all. With it active and the
// option unset, the chain supplies the credential instead.
//
// EVERY CLIENT HERE IS LIVE, and the thing counted is `system.fetch` - the
// real transport the whole fetcher chain ends at. That is deliberate, and
// it is the mistake this file exists to avoid: under `test_sdk` the test
// feature REPLACES the transport with its own in-memory mock, so a counter
// hung off `system.fetch` is never reached, and "no request was sent" would
// hold for a healthy SDK carrying no secrets feature at all. An assertion
// that cannot fail pins no rule. So each fail-closed case proves its own
// counter FIRST, with the same construction and a WORKING provider: one
// request must reach `system.fetch` carrying the resolved credential. Only
// then does a zero from the broken provider mean REFUSED rather than
// UNWIRED. And the refusal is matched on the PROVIDER'S OWN message, so an
// unrelated failure cannot stand in for fail-closed.
//
// This file lives in the `feature/` container on purpose: `target add`
// trims it, along with the feature source and the vendored library, for a
// project whose model does not select `secrets`.

use std::cell::RefCell;
use std::rc::Rc;

use univec_sdk::core::context::CtxSpec;
use univec_sdk::core::helpers::{
    call_vfn, get_str, getp, getpath, ja, jo, json_thunk, to_int, vfn,
};
use univec_sdk::core::spec::Spec;
use univec_sdk::{UnivecSDK, Value};

const BASE: &str = "http://secrets.test/api";

// ---- the counted transport ---------------------------------------------

/// One recorded request, SNAPSHOT at the moment it was handed to the
/// transport.
///
/// A snapshot, not the fetchdef itself, and that is load-bearing: the
/// fetchdef's `headers` map is an Rc the retry path rewrites IN PLACE, so
/// a recorder that kept the live map would report every earlier call as
/// carrying the LAST token - and "the retry carried a new credential"
/// would pass whether or not it did.
#[derive(Clone)]
struct Call {
    url: String,
    auth: Option<String>,
    body: Option<String>,
}

/// A `system.fetch` that records every call it is handed, so "sent" is a
/// fact about the wire rather than about a mock somewhere up the chain.
#[derive(Clone)]
struct Wire {
    calls: Rc<RefCell<Vec<Call>>>,
    /// One status per API call, the last repeating - so a case can say
    /// "401 then 200" without counting calls itself.
    apistatus: Rc<Vec<i64>>,
    /// The access tokens the token endpoint issues, in order.
    tokens: Rc<Vec<String>>,
    /// The token endpoint path, relative to base.
    tokenpath: String,
    /// The JSON field the token endpoint answers in.
    tokenfield: String,
    /// Statuses for the token endpoint itself (the last repeating).
    tokenstatus: Rc<Vec<i64>>,
    issued: Rc<RefCell<usize>>,
    apicalls: Rc<RefCell<usize>>,
}

impl Wire {
    fn new() -> Wire {
        Wire {
            calls: Rc::new(RefCell::new(Vec::new())),
            apistatus: Rc::new(vec![200]),
            tokens: Rc::new(vec![
                "ACCESS01".to_string(),
                "ACCESS02".to_string(),
                "ACCESS03".to_string(),
            ]),
            tokenpath: "auth/token".to_string(),
            tokenfield: "access_token".to_string(),
            tokenstatus: Rc::new(vec![200]),
            issued: Rc::new(RefCell::new(0)),
            apicalls: Rc::new(RefCell::new(0)),
        }
    }

    fn apistatus(mut self, statuses: &[i64]) -> Wire {
        self.apistatus = Rc::new(statuses.to_vec());
        self
    }

    fn tokenstatus(mut self, statuses: &[i64]) -> Wire {
        self.tokenstatus = Rc::new(statuses.to_vec());
        self
    }

    fn tokenpath(mut self, path: &str, field: &str) -> Wire {
        self.tokenpath = path.to_string();
        self.tokenfield = field.to_string();
        self
    }

    fn istoken(&self, url: &str) -> bool {
        url.ends_with(&format!("/{}", self.tokenpath))
    }

    /// The Value::Func that goes into `system.fetch`.
    fn fetch(&self) -> Value {
        let w = self.clone();
        vfn(move |arg| {
            let url = match getp(arg, "0") {
                Value::Str(s) => s,
                _ => String::new(),
            };
            let fetchdef = getp(arg, "1");
            w.calls.borrow_mut().push(Call {
                url: url.clone(),
                auth: authof(&fetchdef),
                body: get_str(&fetchdef, "body"),
            });

            if w.istoken(&url) {
                let n = *w.issued.borrow();
                *w.issued.borrow_mut() = n + 1;
                let status = pick(&w.tokenstatus, n);
                let body = if (200..300).contains(&status) {
                    jo(vec![(
                        w.tokenfield.as_str(),
                        Value::str(pickstr(&w.tokens, n)),
                    )])
                } else {
                    jo(vec![("error", Value::str("nope"))])
                };
                return response(status, body);
            }

            let n = *w.apicalls.borrow();
            *w.apicalls.borrow_mut() = n + 1;
            let status = pick(&w.apistatus, n);
            response(status, jo(vec![("ok", Value::Bool(status < 400))]))
        })
    }

    fn api(&self) -> Vec<Call> {
        self.calls
            .borrow()
            .iter()
            .filter(|c| !self.istoken(&c.url))
            .cloned()
            .collect()
    }

    fn token(&self) -> Vec<Call> {
        self.calls
            .borrow()
            .iter()
            .filter(|c| self.istoken(&c.url))
            .cloned()
            .collect()
    }

    fn sent(&self) -> usize {
        self.calls.borrow().len()
    }

    /// What went out, for a failure message that names the leak rather
    /// than just its count.
    fn trace(&self) -> String {
        self.calls
            .borrow()
            .iter()
            .map(|c| format!("{} auth={:?}", c.url, c.auth))
            .collect::<Vec<String>>()
            .join(", ")
    }
}

fn pick(list: &Rc<Vec<i64>>, n: usize) -> i64 {
    list[n.min(list.len() - 1)]
}

fn pickstr(list: &Rc<Vec<String>>, n: usize) -> String {
    list[n.min(list.len() - 1)].clone()
}

fn response(status: i64, body: Value) -> Value {
    jo(vec![
        ("status", Value::Num(status as f64)),
        ("headers", Value::empty_map()),
        ("json", json_thunk(body)),
    ])
}

fn authof(fetchdef: &Value) -> Option<String> {
    match getpath(&["headers", "authorization"], fetchdef) {
        Value::Str(s) => Some(s),
        _ => None,
    }
}

// The Authorization header carries the SPEC's credential prefix, which a
// TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
// `Bearer <token>`, an apiKey scheme the raw token. So assert on the
// CREDENTIAL and let the prefix be whatever this SDK's API declares -
// pinning the whole header value passes only for a prefix-less API, and
// this file ships to every project that selects the feature.
fn credential_is(header: Option<String>, token: &str) {
    let got = header.unwrap_or_default();
    assert!(
        got == token || got.ends_with(&format!(" {}", token)),
        "expected the Authorization header to carry {}, got: {:?}",
        token,
        got
    );
}

fn call_auth(calls: &[Call], i: usize) -> Option<String> {
    calls.get(i).and_then(|c| c.auth.clone())
}

// ---- clients ------------------------------------------------------------

// `allow.op` is named explicitly: a project that narrows the default set
// would otherwise turn the raw-path cases into a false RED (the control leg
// refused before it reached the transport), and the rule under test lives
// at the transport, downstream of the allow gate either way.
//
// `base` is named explicitly too: a LIVE client whose model has a templated
// base URL panics on a missing server variable at construction, and this
// file ships to every project.
fn sdk(wire: &Wire, secrets: Vec<(&str, Value)>) -> Rc<UnivecSDK> {
    let fopts = jo(vec![("active", Value::Bool(true))]);
    for (k, v) in secrets {
        univec_sdk::core::helpers::setp(&fopts, k, v);
    }

    UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        ("feature", jo(vec![("secrets", fopts)])),
    ]))
}

fn providers(list: Vec<Value>) -> (&'static str, Value) {
    ("providers", Value::list(list))
}

/// A `memory` provider spec: the chain, with no process-wide state, so
/// tests running in parallel cannot see each other's credentials.
fn memory(key: &str, value: &str) -> Value {
    jo(vec![
        ("kind", Value::str("memory")),
        ("values", jo(vec![(key, Value::str(value))])),
    ])
}

/// A provider written as a plain callable - the Value-shaped half of the
/// custom-provider seam.
fn callable<F>(f: F) -> Value
where
    F: Fn(&str) -> Value + 'static,
{
    vfn(move |arg| match arg {
        Value::Str(name) => f(name),
        _ => Value::Noval,
    })
}

fn working() -> Value {
    callable(|name| {
        if "apikey" == name {
            Value::str("RAWKEY01")
        } else {
            Value::Noval
        }
    })
}

const BROKEN_MSG: &str = "vault unreachable";

fn broken() -> Value {
    callable(|_name| jo(vec![("__err__", Value::str(BROKEN_MSG))]))
}

/// The feature's public accessor, published on the client's shared map.
fn secrets_call(client: &Rc<UnivecSDK>, args: Vec<Value>) -> Value {
    let shared = client.get_root_ctx().shared.borrow().clone();
    let f = getp(&shared, "secrets");
    assert!(
        matches!(f, Value::Func(_)),
        "the secrets accessor is not published: the feature never initialised"
    );
    call_vfn(&f, &Value::list(args))
}

// ---- the ENTITY path ----------------------------------------------------

/// One request through the REAL entity-request utility, on the client's own
/// utility - the one the feature wrapped.
///
/// `direct()` and `graphql()` are the raw paths and are exercised as
/// themselves below; this is the OTHER half, and it cannot be reached by
/// naming an entity because this file is a TEMPLATE and no project's entity
/// names are known here. `make_request` is the utility every generated
/// entity op ends at, so driving it directly exercises the same seam with
/// the same wiring.
fn entity_request(client: &Rc<UnivecSDK>, path: &str) -> Option<String> {
    let rootctx = client.get_root_ctx();
    let utility = rootctx.util();

    let ctx = utility.make_context(
        CtxSpec {
            opname: Some("list".to_string()),
            ..Default::default()
        },
        Some(&rootctx),
    );

    let spec = Rc::new(RefCell::new(Spec::new(&jo(vec![
        ("base", Value::str(BASE)),
        ("path", Value::str(path)),
        ("method", Value::str("GET")),
        ("headers", Value::empty_map()),
        ("step", Value::str("start")),
    ]))));
    *ctx.spec.borrow_mut() = Some(spec);

    utility.feature_hook(&ctx, "PreSpec");
    utility.prepare_auth(&ctx).expect("prepare_auth");

    match utility.make_request(&ctx) {
        Ok(response) => response.borrow().err.as_ref().map(|e| e.msg.clone()),
        Err(err) => Some(err.msg),
    }
}

// ---- the chain ----------------------------------------------------------

#[test]
fn inactive_leaves_the_apikey_option_exactly_as_it_was() {
    let wire = Wire::new();

    // Not `sdk()`: the point is a client with the feature OFF.
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("apikey", Value::str("OPTKEY01")),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(false)),
                    providers(vec![memory("APIKEY", "CHAINKEY01")]),
                ]),
            )]),
        ),
    ]));

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.sent(), 1);
    credential_is(call_auth(&wire.api(), 0), "OPTKEY01");

    // No feature, no accessor.
    let shared = client.get_root_ctx().shared.borrow().clone();
    assert!(
        !matches!(getp(&shared, "secrets"), Value::Func(_)),
        "an inactive feature must publish nothing"
    );
}

#[test]
fn apikey_option_still_wins_over_the_chain() {
    let wire = Wire::new();

    // The explicit credential is a CLIENT option, not a feature option -
    // that is the whole point: `apikey` keeps its old meaning and the
    // feature seats it first in the chain.
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("apikey", Value::str("OPTKEY01")),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(true)),
                    providers(vec![memory("APIKEY", "CHAINKEY01")]),
                ]),
            )]),
        ),
    ]));

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    credential_is(call_auth(&wire.api(), 0), "OPTKEY01");

    // The explicit option is a real store, not a special case: a directed
    // read names it like any other.
    let got = secrets_call(
        &client,
        vec![
            Value::str("getfrom"),
            Value::str("options"),
            Value::str("apikey"),
        ],
    );
    assert_eq!(
        got,
        Value::str("OPTKEY01"),
        "the explicit apikey is not seated as the `options` memory store"
    );
}

#[test]
fn an_omitted_apikey_defers_to_the_chain() {
    let wire = Wire::new();
    let client = sdk(&wire, vec![providers(vec![memory("APIKEY", "CHAINKEY01")])]);

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    credential_is(call_auth(&wire.api(), 0), "CHAINKEY01");

    // The options map is FROZEN: the credential lives in feature state, and
    // a feature that wrote the shared options would be visible everywhere.
    assert_eq!(
        getp(&client.options_map(), "apikey"),
        Value::str(""),
        "the feature must not write the shared options map"
    );
    assert_eq!(
        secrets_call(&client, vec![Value::str("credential")]),
        Value::str("CHAINKEY01")
    );
}

#[test]
fn an_explicitly_empty_apikey_also_defers_to_the_chain() {
    let wire = Wire::new();
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("apikey", Value::str("")),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(true)),
                    providers(vec![memory("APIKEY", "CHAINKEY01")]),
                ]),
            )]),
        ),
    ]));

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    credential_is(call_auth(&wire.api(), 0), "CHAINKEY01");
}

// `auth: null` - the documented way to disable auth outright, which
// prepare_auth honours before it ever reads the apikey, and which the
// transport injection must honour too.
#[test]
fn auth_null_suppresses_the_credential_chain_or_no_chain() {
    let wire = Wire::new();
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("auth", Value::Null),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(true)),
                    providers(vec![memory("APIKEY", "CHAINKEY01")]),
                ]),
            )]),
        ),
    ]));

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.sent(), 1, "the request must still go out");
    assert_eq!(
        call_auth(&wire.api(), 0),
        None,
        "nothing may be sent when auth is suppressed, but the wire carried: {}",
        wire.trace()
    );

    // The suppression survives option validation rather than being replaced
    // by the optspec's default auth map.
    //
    // Read from the RAW map: `getp` applies the Group A rule and answers
    // the alt for a stored null, so it cannot tell an absent auth from a
    // suppressed one - and only the latter is a suppression.
    let opts = client.options_map();
    let suppressed = match &opts {
        Value::Map(m) => matches!(m.borrow().get("auth"), Some(Value::Null)),
        _ => false,
    };
    assert!(suppressed, "auth: null did not survive make_options");
}

#[test]
fn auth_null_suppresses_an_explicit_apikey_too() {
    let wire = Wire::new();
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("apikey", Value::str("OPTKEY01")),
        ("auth", Value::Null),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(true)),
                    providers(vec![memory("APIKEY", "CHAINKEY01")]),
                ]),
            )]),
        ),
    ]));

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(call_auth(&wire.api(), 0), None, "wire: {}", wire.trace());
}

#[test]
fn a_miss_everywhere_leaves_the_header_off() {
    let wire = Wire::new();
    let client = sdk(
        &wire,
        vec![providers(vec![callable(|_name| Value::Noval)])],
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    // A MISS falls through: the request still goes out, unauthenticated.
    assert_eq!(wire.sent(), 1, "a miss must not refuse the request");
    assert_eq!(call_auth(&wire.api(), 0), None);
}

// A MISS is not an ERROR: the chain CONTINUES past a provider that simply
// does not have the secret. The other half of sekreto's invariant, and the
// half that must not be "fixed" by making every miss fail.
#[test]
fn a_miss_falls_through_to_the_next_provider() {
    let wire = Wire::new();
    let asked: Rc<RefCell<i64>> = Rc::new(RefCell::new(0));
    let n = asked.clone();

    let client = sdk(
        &wire,
        vec![providers(vec![
            callable(move |_name| {
                *n.borrow_mut() += 1;
                Value::Noval
            }),
            memory("APIKEY", "SECOND01"),
        ])],
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(*asked.borrow(), 1, "the first provider was never asked");
    credential_is(call_auth(&wire.api(), 0), "SECOND01");
}


#[test]
fn a_callable_provider_is_accepted_verbatim() {
    let wire = Wire::new();
    let asked: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(Vec::new()));
    let seen = asked.clone();

    let client = sdk(
        &wire,
        vec![providers(vec![callable(move |name| {
            seen.borrow_mut().push(name.to_string());
            Value::str("CUSTOM01")
        })])],
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    credential_is(call_auth(&wire.api(), 0), "CUSTOM01");
    assert_eq!(asked.borrow().clone(), vec!["apikey".to_string()]);
}

// ---- FAIL-CLOSED: a provider ERROR is not a miss -------------------------
//
// sekreto's miss-vs-error invariant: a MISS falls through to the next
// provider, an ERROR does not. A broken vault must never degrade into an
// unauthenticated request.

#[test]
fn a_provider_error_fails_direct_rather_than_sending() {
    // THE RULE, asserted first so a regression reports the leak itself.
    let wire = Wire::new();
    let res = sdk(&wire, vec![providers(vec![broken()])])
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct itself should not error");

    assert_eq!(
        wire.sent(),
        0,
        "a request must not go out unauthenticated because a provider broke, \
         but one reached system.fetch: {}",
        wire.trace()
    );
    assert_eq!(getp(&res, "ok"), Value::Bool(false));
    let err = get_str(&res, "err").unwrap_or_default();
    assert!(
        err.contains(BROKEN_MSG),
        "expected the provider's own message, got: {}",
        err
    );

    // CONTROL, which makes that zero mean REFUSED rather than UNWIRED: the
    // same construction with a WORKING provider must reach the same
    // transport, once, carrying the credential.
    let control = Wire::new();
    let ok = sdk(&control, vec![providers(vec![working()])])
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(
        getp(&ok, "ok"),
        Value::Bool(true),
        "the control request failed: {:?}",
        get_str(&ok, "err")
    );
    assert_eq!(
        control.sent(),
        1,
        "the control request never reached system.fetch, so this test cannot \
         observe a request going out at all"
    );
    credential_is(call_auth(&control.api(), 0), "RAWKEY01");
}

#[test]
fn a_provider_error_fails_graphql_rather_than_sending() {
    let wire = Wire::new();
    let res = sdk(&wire, vec![providers(vec![broken()])])
        .graphql("{ thing }", Value::empty_map(), Value::empty_map())
        .expect("graphql itself should not error");

    assert_eq!(
        wire.sent(),
        0,
        "a graphql request must not go out unauthenticated, but one reached \
         system.fetch: {}",
        wire.trace()
    );
    assert_eq!(getp(&res, "ok"), Value::Bool(false));
    let err = get_str(&res, "err").unwrap_or_default();
    assert!(
        err.contains(BROKEN_MSG),
        "expected the provider's own message, got: {}",
        err
    );

    let control = Wire::new();
    let ok = sdk(&control, vec![providers(vec![working()])])
        .graphql("{ thing }", Value::empty_map(), Value::empty_map())
        .expect("graphql");

    assert_eq!(
        getp(&ok, "ok"),
        Value::Bool(true),
        "the control request failed: {:?}",
        get_str(&ok, "err")
    );
    assert_eq!(
        control.sent(),
        1,
        "the control request never reached system.fetch, so this test cannot \
         observe a request going out at all"
    );
    credential_is(call_auth(&control.api(), 0), "RAWKEY01");
}

#[test]
fn a_provider_error_fails_the_entity_path_rather_than_sending() {
    let wire = Wire::new();
    let err = entity_request(&sdk(&wire, vec![providers(vec![broken()])]), "/thing");

    assert_eq!(
        wire.sent(),
        0,
        "an entity request must not go out unauthenticated, but one reached \
         system.fetch: {}",
        wire.trace()
    );
    let err = err.unwrap_or_default();
    assert!(
        err.contains(BROKEN_MSG),
        "expected the provider's own message, got: {}",
        err
    );

    let control = Wire::new();
    let ok = entity_request(&sdk(&control, vec![providers(vec![working()])]), "/thing");

    assert_eq!(ok, None, "the control request failed: {:?}", ok);
    assert_eq!(
        control.sent(),
        1,
        "the control request never reached system.fetch, so this test cannot \
         observe a request going out at all"
    );
    credential_is(call_auth(&control.api(), 0), "RAWKEY01");
}

// A CHAIN that cannot be BUILT is the same rule one step earlier: an
// unknown provider kind (a typo in a project's model) must refuse the
// request rather than send it without a credential.
#[test]
fn an_unknown_provider_kind_refuses_rather_than_sending() {
    let wire = Wire::new();
    let res = sdk(
        &wire,
        vec![providers(vec![jo(vec![(
            "kind",
            Value::str("nosuchkind"),
        )])])],
    )
    .direct(jo(vec![("path", Value::str("/thing"))]))
    .expect("direct");

    assert_eq!(
        wire.sent(),
        0,
        "a chain that could not be built must not send: {}",
        wire.trace()
    );
    assert_eq!(getp(&res, "ok"), Value::Bool(false));
    let err = get_str(&res, "err").unwrap_or_default();
    assert!(
        err.contains("unknown provider kind"),
        "expected sekreto's own refusal, got: {}",
        err
    );

    let control = Wire::new();
    sdk(&control, vec![providers(vec![working()])])
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");
    assert_eq!(control.sent(), 1, "the control request never reached the wire");
}

// A MALFORMED entry is the same rule again, and the one a typed port can
// get wrong silently: `providers` is a Value list, so an entry that is
// neither a callable nor a spec map (a bare "hashicorp" where a spec was
// meant) matches no arm. Dropping it leaves the chain quietly SHORTER than
// the options say - a fail-OPEN that sends the request without the
// credential the project configured. It must refuse instead, carrying
// sekreto's own wording, on every wire path.
const MALFORMED_MSG: &str = "sekreto: not a provider or a provider spec";

#[test]
fn a_malformed_provider_entry_refuses_rather_than_being_dropped() {
    // CONTROL first: the same construction with a WORKING provider reaches
    // the transport exactly once, carrying its credential. Without this a
    // zero below could mean UNWIRED rather than REFUSED.
    let control = Wire::new();
    let ok = sdk(&control, vec![providers(vec![working()])])
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");
    assert_eq!(
        getp(&ok, "ok"),
        Value::Bool(true),
        "the control request failed: {:?}",
        get_str(&ok, "err")
    );
    assert_eq!(
        control.sent(),
        1,
        "the control request never reached system.fetch, so this test cannot \
         observe a request going out at all"
    );
    credential_is(call_auth(&control.api(), 0), "RAWKEY01");

    let malformed = || providers(vec![Value::str("hashicorp")]);
    let refused = |what: &str, err: String, wire: &Wire| {
        assert_eq!(
            wire.sent(),
            0,
            "{}: a malformed provider entry must refuse, not be dropped, but a \
             request reached system.fetch: {}",
            what,
            wire.trace()
        );
        assert!(
            err.contains(MALFORMED_MSG) && err.contains("hashicorp"),
            "{}: expected sekreto's own refusal naming the entry, got: {}",
            what,
            err
        );
    };

    // The raw paths. This port runs no feature hooks on direct()/graphql()
    // (Main.fragment.rs raw_request calls utility.fetch directly), so the
    // refusal is the TRANSPORT gate's, the same seam the tests above use.
    let wire = Wire::new();
    let res = sdk(&wire, vec![malformed()])
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct itself should not error");
    refused("direct", get_str(&res, "err").unwrap_or_default(), &wire);
    assert_eq!(getp(&res, "ok"), Value::Bool(false));

    let wire = Wire::new();
    let res = sdk(&wire, vec![malformed()])
        .graphql("{ thing }", Value::empty_map(), Value::empty_map())
        .expect("graphql itself should not error");
    refused("graphql", get_str(&res, "err").unwrap_or_default(), &wire);
    assert_eq!(getp(&res, "ok"), Value::Bool(false));

    // The entity path.
    let wire = Wire::new();
    let err = entity_request(&sdk(&wire, vec![malformed()]), "/thing");
    refused("entity", err.unwrap_or_default(), &wire);
}

// The provider VOCABULARY. The generated plugins.rs index IS the set of
// kinds this SDK can build (upstream sekreto's contract since its registry
// was retired), so every definition it declares must carry a usable name -
// an empty or duplicated one is a kind nothing can name.
#[test]
fn the_selected_plugin_kinds_have_distinct_names() {
    let defs = univec_sdk::feature::secrets::plugins::definitions();
    let mut names: Vec<String> = defs.iter().map(|d| d.name.clone()).collect();
    let count = names.len();
    names.sort();
    names.dedup();

    assert_eq!(names.len(), count, "duplicate plugin kind: {:?}", names);
    assert!(
        names.iter().all(|n| !n.is_empty()),
        "a plugin definition with no name is a kind nothing can select"
    );
}

// A SELECTED plugin kind is really in the vocabulary.
//
// Construction is where an unknown kind is refused, so a chain that names
// the kind and still reaches the wire IS the check. The memory store comes
// FIRST so sekreto's first-hit rule answers from it and the vault is never
// contacted - the kind has to be declarable, not reachable.
//
// Conditional on the kind being selected, because this file ships to
// projects that take the feature without the `vault` plugin group.
#[test]
fn a_selected_plugin_kind_is_in_the_sdk_vocabulary() {
    let defs = univec_sdk::feature::secrets::plugins::definitions();
    if !defs.iter().any(|d| "hashicorp" == d.name) {
        // No vault group in this project's model: nothing to assert.
        return;
    }

    let wire = Wire::new();
    let client = sdk(
        &wire,
        vec![providers(vec![
            memory("APIKEY", "VOCAB01"),
            jo(vec![
                ("kind", Value::str("hashicorp")),
                ("addr", Value::str("https://vault.test")),
                ("token", Value::str("x")),
            ]),
        ])],
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.api().len(), 1, "the chain was refused: {}", wire.trace());
    credential_is(call_auth(&wire.api(), 0), "VOCAB01");
}


// A settled failure must not be held forever: a transient vault outage
// would otherwise poison the client permanently, every later operation
// failing with the original error long after the vault recovered.
#[test]
fn a_provider_recovers_after_a_transient_failure() {
    let wire = Wire::new();
    let calls = Rc::new(RefCell::new(0i64));
    let n = calls.clone();

    let client = sdk(
        &wire,
        vec![providers(vec![callable(move |_name| {
            *n.borrow_mut() += 1;
            if 1 == *n.borrow() {
                jo(vec![("__err__", Value::str(BROKEN_MSG))])
            } else {
                Value::str("RECOVERED01")
            }
        })])],
    );

    let first = client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");
    assert_eq!(getp(&first, "ok"), Value::Bool(false));
    assert_eq!(wire.sent(), 0);

    let second = client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");
    assert_eq!(
        getp(&second, "ok"),
        Value::Bool(true),
        "the second attempt should recover: {:?}",
        get_str(&second, "err")
    );
    credential_is(call_auth(&wire.api(), 0), "RECOVERED01");
}

// `cache: false` is documented as "every resolve asks the chain again".
#[test]
fn cache_false_asks_the_chain_on_every_request() {
    let wire = Wire::new();
    let calls = Rc::new(RefCell::new(0i64));
    let n = calls.clone();

    let client = sdk(
        &wire,
        vec![
            ("cache", Value::Bool(false)),
            providers(vec![callable(move |_name| {
                *n.borrow_mut() += 1;
                Value::str(format!("KEY{}", n.borrow()))
            })]),
        ],
    );

    for _ in 0..2 {
        client
            .direct(jo(vec![("path", Value::str("/thing"))]))
            .expect("direct");
    }

    assert!(
        1 < *calls.borrow(),
        "the chain was asked once and cached, despite cache: false"
    );
    credential_is(call_auth(&wire.api(), 0), "KEY1");
    credential_is(call_auth(&wire.api(), 1), "KEY2");
}

// A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this feature
// used to override from the layer above.
//
// DEFAULT caching here, which is the whole point: `cache: true` is about
// holding a HIT (the test below pins that half), and keeping the settled
// resolution after a miss meant the chain was never asked again for the life
// of the client. A secret provisioned after startup (a mounted file, a vault
// policy granted a minute late) was invisible forever.
#[test]
fn cache_true_re_asks_after_a_miss() {
    let wire = Wire::new();
    let calls = Rc::new(RefCell::new(0i64));
    let present = Rc::new(RefCell::new(false));
    let n = calls.clone();
    let p = present.clone();

    let client = sdk(
        &wire,
        vec![providers(vec![callable(move |_name| {
            *n.borrow_mut() += 1;
            if *p.borrow() {
                Value::str("LATEKEY01")
            } else {
                Value::Noval
            }
        })])],
    );

    client
        .direct(jo(vec![("path", Value::str("/one"))]))
        .expect("direct");
    assert_eq!(
        call_auth(&wire.api(), 0),
        None,
        "the chain has nothing yet, so no credential should go out: {}",
        wire.trace()
    );

    let asked = *calls.borrow();
    assert!(0 < asked, "the chain was never asked");

    // The secret is provisioned while the client is live.
    *present.borrow_mut() = true;

    client
        .direct(jo(vec![("path", Value::str("/two"))]))
        .expect("direct");

    assert!(
        asked < *calls.borrow(),
        "the MISS was cached: a secret that appears later can never be picked up"
    );
    credential_is(call_auth(&wire.api(), 1), "LATEKEY01");
}

// The other half of the same rule: a HIT is still cached by default, so the
// fix above must not turn every request into a chain walk.
#[test]
fn cache_true_keeps_a_hit() {
    let wire = Wire::new();
    let calls = Rc::new(RefCell::new(0i64));
    let n = calls.clone();

    let client = sdk(
        &wire,
        vec![providers(vec![callable(move |_name| {
            *n.borrow_mut() += 1;
            Value::str("STABLEKEY01")
        })])],
    );

    for _ in 0..2 {
        client
            .direct(jo(vec![("path", Value::str("/thing"))]))
            .expect("direct");
    }

    assert_eq!(
        *calls.borrow(),
        1,
        "a hit must be cached under the default cache: true"
    );
}

// An UNCACHED miss after a hit is a revocation: the resolved value must
// stop going out.
#[test]
fn an_uncached_miss_retracts_the_credential() {
    let wire = Wire::new();
    let calls = Rc::new(RefCell::new(0i64));
    let n = calls.clone();

    let client = sdk(
        &wire,
        vec![
            ("cache", Value::Bool(false)),
            providers(vec![callable(move |_name| {
                *n.borrow_mut() += 1;
                if 1 == *n.borrow() {
                    Value::str("ONCE01")
                } else {
                    Value::Noval
                }
            })]),
        ],
    );

    for _ in 0..2 {
        client
            .direct(jo(vec![("path", Value::str("/thing"))]))
            .expect("direct");
    }

    credential_is(call_auth(&wire.api(), 0), "ONCE01");
    assert_eq!(
        call_auth(&wire.api(), 1),
        None,
        "a revoked credential kept going out: {}",
        wire.trace()
    );
}

#[test]
fn the_secret_name_is_configurable() {
    let wire = Wire::new();
    let client = sdk(
        &wire,
        vec![
            ("name", Value::str("api.token")),
            providers(vec![memory("API_TOKEN", "TOKKEY01")]),
        ],
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    credential_is(call_auth(&wire.api(), 0), "TOKKEY01");
}

#[test]
fn sekreto_is_live_for_arbitrary_secrets_and_redaction() {
    let wire = Wire::new();
    let client = sdk(
        &wire,
        vec![providers(vec![memory("DB_PASSWORD", "dbpass01")])],
    );

    assert_eq!(
        secrets_call(&client, vec![Value::str("get"), Value::str("db.password")]),
        Value::str("dbpass01")
    );
    assert_eq!(
        secrets_call(
            &client,
            vec![
                Value::str("redact"),
                Value::str("the password is dbpass01, keep it safe")
            ]
        ),
        Value::str("the password is [redacted], keep it safe")
    );
}

// ---- ACCESS-TOKEN EXCHANGE ----------------------------------------------
//
// What the chain resolves is a REFRESH token, which is POSTed to a token
// endpoint for a short-lived ACCESS token; the access token is what the
// Authorization header carries; and when the API answers 401 the client
// buys another and tries the same request again, once.

const REFRESH: &str = "REFRESH01";

fn exchange(extra: Vec<(&str, Value)>) -> (&'static str, Value) {
    let x = jo(vec![("active", Value::Bool(true))]);
    for (k, v) in extra {
        univec_sdk::core::helpers::setp(&x, k, v);
    }
    ("exchange", x)
}

fn exchange_sdk(wire: &Wire, extra: Vec<(&str, Value)>) -> Rc<UnivecSDK> {
    let mut opts: Vec<(&str, Value)> = vec![
        ("name", Value::str("refresh_token")),
        providers(vec![memory("REFRESH_TOKEN", REFRESH)]),
    ];
    opts.extend(extra);
    sdk(wire, opts)
}

fn bodyof(call: &Call) -> Value {
    let raw = call.body.clone().unwrap_or_default();
    univec_sdk::json_parse(&raw).unwrap_or(Value::Noval)
}

#[test]
fn the_refresh_token_buys_an_access_token_and_the_request_carries_it() {
    let wire = Wire::new();
    let client = exchange_sdk(&wire, vec![exchange(vec![])]);

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.token().len(), 1, "expected exactly one token purchase");
    assert_eq!(
        getp(&bodyof(&wire.token()[0]), "refresh_token"),
        Value::str(REFRESH),
        "the refresh token is sent in the request field"
    );
    assert_eq!(wire.api().len(), 1);
    credential_is(call_auth(&wire.api(), 0), "ACCESS01");
}

#[test]
fn an_explicit_exchange_refresh_wins_over_the_chain() {
    let wire = Wire::new();
    let client = exchange_sdk(
        &wire,
        vec![exchange(vec![("refresh", Value::str("EXPLICIT01"))])],
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(
        getp(&bodyof(&wire.token()[0]), "refresh_token"),
        Value::str("EXPLICIT01")
    );
}

#[test]
fn one_purchase_serves_many_requests() {
    let wire = Wire::new();
    let client = exchange_sdk(&wire, vec![exchange(vec![])]);

    for path in ["/one", "/two", "/three"] {
        client
            .direct(jo(vec![("path", Value::str(path))]))
            .expect("direct");
    }

    assert_eq!(
        wire.token().len(),
        1,
        "a token still working must not be re-bought"
    );
    assert_eq!(wire.api().len(), 3);
}

#[test]
fn an_expiry_buys_another_token_and_retries_the_same_request() {
    let wire = Wire::new().apistatus(&[401, 200]);
    let client = exchange_sdk(&wire, vec![exchange(vec![])]);

    let res = client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.token().len(), 2, "expected a second token purchase");
    assert_eq!(wire.api().len(), 2, "expected the request to be retried");
    credential_is(call_auth(&wire.api(), 0), "ACCESS01");
    // The retry must carry the NEW token, not the spent one.
    credential_is(call_auth(&wire.api(), 1), "ACCESS02");
    assert_eq!(
        getp(&res, "ok"),
        Value::Bool(true),
        "the caller sees the successful retry"
    );
}

#[test]
fn the_retry_happens_once_not_in_a_loop() {
    // Every API call is refused: a second refusal on a token bought moments
    // ago is a real failure, and spinning on it would hang instead.
    let wire = Wire::new().apistatus(&[401]);
    let client = exchange_sdk(&wire, vec![exchange(vec![])]);

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.api().len(), 2, "exactly one retry");
    assert_eq!(wire.token().len(), 2);
}

#[test]
fn a_status_outside_exchange_statuses_is_not_an_expiry() {
    let wire = Wire::new().apistatus(&[403]);
    let client = exchange_sdk(&wire, vec![exchange(vec![])]);

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.api().len(), 1, "403 is not in the default statuses");
    assert_eq!(wire.token().len(), 1);
}

#[test]
fn exchange_statuses_are_configurable() {
    let wire = Wire::new().apistatus(&[403, 200]);
    let client = exchange_sdk(
        &wire,
        vec![exchange(vec![(
            "statuses",
            Value::list(vec![Value::Num(403.0)]),
        )])],
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.api().len(), 2, "403 was declared an expiry");
}

#[test]
fn the_endpoint_and_field_names_are_configurable_and_the_body_is_serialised() {
    // A JSON-HOSTILE refresh token: it must arrive as this literal value,
    // which only holds if the body is serialised rather than concatenated.
    const NASTY: &str = "re\"fresh\\01\nline";

    let wire = Wire::new().tokenpath("oauth/grant", "token");
    let client = sdk(
        &wire,
        vec![
            ("name", Value::str("refresh_token")),
            providers(vec![memory("REFRESH_TOKEN", NASTY)]),
            exchange(vec![
                ("path", Value::str("oauth/grant")),
                ("request", Value::str("grant")),
                ("response", Value::str("token")),
            ]),
        ],
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.token().len(), 1);
    assert!(
        wire.token()[0].url.ends_with("/oauth/grant"),
        "the token endpoint is relative to base: {}",
        wire.token()[0].url
    );
    assert_eq!(
        getp(&bodyof(&wire.token()[0]), "grant"),
        Value::str(NASTY),
        "the refresh token must survive serialisation intact"
    );
    credential_is(call_auth(&wire.api(), 0), "ACCESS01");
}

#[test]
fn an_explicit_apikey_is_spent_before_anything_is_bought() {
    let wire = Wire::new();
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("apikey", Value::str("HELDTOKEN01")),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(true)),
                    ("name", Value::str("refresh_token")),
                    providers(vec![memory("REFRESH_TOKEN", REFRESH)]),
                    exchange(vec![]),
                ]),
            )]),
        ),
    ]));

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.token().len(), 0, "nothing needed buying");
    credential_is(call_auth(&wire.api(), 0), "HELDTOKEN01");
}

#[test]
fn a_held_apikey_that_has_expired_falls_through_to_the_exchange() {
    let wire = Wire::new().apistatus(&[401, 200]);
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("apikey", Value::str("STALETOKEN01")),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(true)),
                    ("name", Value::str("refresh_token")),
                    providers(vec![memory("REFRESH_TOKEN", REFRESH)]),
                    exchange(vec![]),
                ]),
            )]),
        ),
    ]));

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    credential_is(call_auth(&wire.api(), 0), "STALETOKEN01");
    credential_is(call_auth(&wire.api(), 1), "ACCESS01");
}

#[test]
fn no_refresh_token_anywhere_is_an_error_not_an_unauthenticated_call() {
    let wire = Wire::new();
    let client = sdk(
        &wire,
        vec![
            ("name", Value::str("refresh_token")),
            providers(vec![]),
            exchange(vec![]),
        ],
    );

    let res = client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(getp(&res, "ok"), Value::Bool(false));
    assert_eq!(
        wire.api().len(),
        0,
        "a request must not go out unauthenticated because the chain was empty: {}",
        wire.trace()
    );
    let err = get_str(&res, "err").unwrap_or_default();
    assert!(
        err.contains("no refresh token"),
        "expected the exchange's own message, got: {}",
        err
    );
}

#[test]
fn a_failing_token_endpoint_surfaces_the_api_refusal_not_a_spin() {
    // The first purchase succeeds; the second (after the 401) does not.
    let wire = Wire::new().apistatus(&[401]).tokenstatus(&[200, 500]);
    let client = exchange_sdk(&wire, vec![exchange(vec![])]);

    let res = client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("the caller got an answer rather than a hang");

    assert_eq!(getp(&res, "status"), Value::Num(401.0));
    assert_eq!(wire.api().len(), 1, "no retry after a failed purchase");
}

#[test]
fn exchange_auth_null_suppresses_and_is_never_retried() {
    let wire = Wire::new().apistatus(&[401]);
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str(BASE)),
        ("auth", Value::Null),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        ("system", jo(vec![("fetch", wire.fetch())])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(true)),
                    ("name", Value::str("refresh_token")),
                    providers(vec![memory("REFRESH_TOKEN", REFRESH)]),
                    exchange(vec![]),
                ]),
            )]),
        ),
    ]));

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(
        wire.api().len(),
        1,
        "a suppressed request must not be retried"
    );
    assert_eq!(
        call_auth(&wire.api(), 0),
        None,
        "no credential may be sent when auth is suppressed: {}",
        wire.trace()
    );

    // AND NO PURCHASE. resolve() runs before with_refresh's suppression
    // check, so the refresh token used to go to the token endpoint in a
    // request body even here. Stopping the retry does not unsend it, and
    // only the token endpoint can see this.
    assert_eq!(
        wire.token().len(),
        0,
        "auth null suppressed the credential but the refresh token was still \
         POSTed to the exchange endpoint: {}",
        wire.trace()
    );
}

// The exchange with NO system.fetch: the ordinary case, where make_options
// leaves the seam unset and the purchase takes its own raw HTTP path. There
// is no token endpoint to talk to here, so what this pins is that the
// fallback EXISTS and reports - before this, `buy` with no custom transport
// simply had nothing to call - and that a failed purchase refuses the
// operation rather than sending it unauthenticated.
#[test]
fn the_exchange_has_a_raw_transport_when_no_system_fetch_is_given() {
    // Port 1 is reserved and never listening, so the connection is refused
    // immediately rather than hanging on a timeout.
    let client = UnivecSDK::new(jo(vec![
        ("base", Value::str("http://127.0.0.1:1/api")),
        ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
        (
            "feature",
            jo(vec![(
                "secrets",
                jo(vec![
                    ("active", Value::Bool(true)),
                    ("name", Value::str("refresh_token")),
                    providers(vec![memory("REFRESH_TOKEN", REFRESH)]),
                    exchange(vec![]),
                ]),
            )]),
        ),
    ]));

    let res = client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(getp(&res, "ok"), Value::Bool(false));
    let err = get_str(&res, "err").unwrap_or_default();
    assert!(
        err.contains("token exchange"),
        "expected the exchange's own refusal from the raw transport, got: {}",
        err
    );
}


// TEST MODE BUYS NOTHING: the test feature replaces the transport so no
// request leaves the process, and an exchange would be the one call it
// could not stop.
#[test]
fn test_mode_buys_nothing_and_needs_no_token_endpoint() {
    let wire = Wire::new();
    let client = univec_sdk::test_sdk(
        Value::Noval,
        jo(vec![
            ("base", Value::str(BASE)),
            ("allow", jo(vec![("op", Value::str("direct,graphql"))])),
            ("system", jo(vec![("fetch", wire.fetch())])),
            (
                "feature",
                jo(vec![(
                    "secrets",
                    jo(vec![
                        ("active", Value::Bool(true)),
                        ("name", Value::str("refresh_token")),
                        providers(vec![memory("REFRESH_TOKEN", REFRESH)]),
                        exchange(vec![]),
                    ]),
                )]),
            ),
        ]),
    );

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.sent(), 0, "test mode must not do IO");
    // A deterministic placeholder, so offline suites need no configuration.
    assert_eq!(
        secrets_call(&client, vec![Value::str("credential")]),
        Value::str("test-access_token")
    );
}

// The exchange OFF leaves the feature exactly as it was.
#[test]
fn exchange_off_leaves_the_feature_exactly_as_it_was() {
    let wire = Wire::new();
    let client = sdk(&wire, vec![providers(vec![memory("APIKEY", "PLAINKEY01")])]);

    client
        .direct(jo(vec![("path", Value::str("/thing"))]))
        .expect("direct");

    assert_eq!(wire.token().len(), 0, "nothing may be bought");
    credential_is(call_auth(&wire.api(), 0), "PLAINKEY01");
}

// Keep `to_int`/`ja` referenced: they belong to the seam this file
// documents (transport-shaped responses, the system.fetch argument list),
// and an unused import would be a warning in a template that ships.
#[test]
fn helpers_are_the_ones_the_seam_uses() {
    assert_eq!(to_int(&Value::Num(401.0)), 401);
    assert!(matches!(ja(vec![Value::Noval]), Value::List(_)));
}
