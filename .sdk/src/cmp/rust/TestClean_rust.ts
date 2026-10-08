import type {
  ModelEntity
} from '@voxgig/apidef'

import {
  cmp,
  configDefinition,
  each,
  File,
  Content,
  entityCollection,
  targetFeatures,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'


import { rustMethodName } from './utility_rust'


// A custom action is not a trait method the sweep can call by name.
const CRUD = ['list', 'load', 'create', 'update', 'patch', 'remove']

const DIAGNOSTIC = ['log', 'debug', 'audit', 'telemetry', 'cost', 'metrics', 'clienttrack']


// The canary sweep (twin of TestClean_ts). Rust is statically typed, so the
// operation candidates the ts sweep finds by reflection are enumerated here
// at generation time, each with the path parameters its config points
// declare; the sweep still DRIVES them to find the first that completes.
const TestClean = cmp(function TestClean(props: any) {
  const { model } = props.ctx$
  const { target, rustcrate } = props

  const Name = model.const.Name

  const auth = {
    suppressed: isAuthSuppressed(model),
    where: resolveAuthIn(model),
    name: 'header' === resolveAuthIn(model)
      ? resolveAuthName(model).toLowerCase() : resolveAuthName(model),
    basic: isHttpBasicAuth(model),
  }

  const features = Object.keys(targetFeatures(model, target))
    .filter((name) => DIAGNOSTIC.includes(name))
    .sort()

  const configEntity = configDefinition(model, target.name).def.entity || {}

  const candidates: Candidate[] = []
  const entities = each(entityCollection(model)).filter((e: any) => false !== e.active)
  each(entities, (entity: ModelEntity) => {
    const method = rustMethodName(entity.name)
    const ops = Object.keys((entity as any).op || {})
      .filter((op) => CRUD.includes(op))
      .sort((a, b) => CRUD.indexOf(a) - CRUD.indexOf(b))
    for (const op of ops) {
      candidates.push({
        name: entity.name + '.' + op, fn: 'drive_' + method + '_' + op,
        sfn: 'stream_' + method + '_' + op, method, op,
        params: pointParams(configEntity[entity.name]?.op?.[op]),
      })
    }
  })

  File({ name: 'clean_test.' + target.ext }, () => {
    Content(render({ Name, rustcrate, auth, features, candidates }))
  })
})


type Candidate = {
  name: string, fn: string, sfn: string, method: string, op: string, params: string[]
}


// Every path parameter an operation's points declare, as the generated
// config carries them (points[].args.params[].name).
function pointParams(opdef: any): string[] {
  const names: string[] = []
  for (const point of opdef?.points || []) {
    for (const p of point?.args?.params || []) {
      if ('string' === typeof p?.name && !names.includes(p.name)) names.push(p.name)
    }
  }
  return names
}


function render(spec: {
  Name: string,
  rustcrate: string,
  auth: { suppressed: boolean, where: string, name: string, basic: boolean },
  features: string[],
  candidates: Candidate[],
}): string {
  const { Name, rustcrate, auth, features, candidates } = spec

  const drivers = candidates.map((c) => 'list' === c.op
    ? `fn ${c.fn}(sdk: &Rc<${Name}SDK>, mtch: Value, ctrl: Value) -> (Result<Value, ${Name}Error>, Value) {
    let ent = sdk.${c.method}(Value::Noval);
    let out = ent
        .list(mtch, ctrl)
        .map(|items| Value::list(items.iter().map(|e| e.data(None)).collect()));
    (out, ent.matchv(None))
}
`
    : `fn ${c.fn}(sdk: &Rc<${Name}SDK>, mtch: Value, ctrl: Value) -> (Result<Value, ${Name}Error>, Value) {
    let ent = sdk.${c.method}(Value::Noval);
    let out = ent.${c.op}(mtch, ctrl).map(|e| e.data(None));
    (out, ent.matchv(None))
}
`).join('\n') + '\n' + candidates.map((c) =>
    `fn ${c.sfn}(sdk: &Rc<${Name}SDK>, mtch: Value, callopts: Value) -> Result<Vec<Value>, ${Name}Error> {
    sdk.${c.method}(Value::Noval).stream("${c.op}", mtch, callopts).map(|items| items.collect())
}
`).join('\n')

  const table = candidates.map((c) => `    ("${c.name}", ${c.fn}, ${c.sfn}, &[${
    c.params.map((p) => '"' + ruststr(p) + '"').join(', ')}]),`).join('\n')

  return `// Generated canary sweep (see TestClean_rust): no credential leaves the
// SDK in any form, and the sweep can see one when clean is switched off.

#![allow(dead_code, unused_imports)]

use std::cell::RefCell;
use std::rc::Rc;

use ${rustcrate}::core::helpers::{getp, getpath, jo, json_thunk, setp, vfn};
use ${rustcrate}::core::types::OutVal;
use ${rustcrate}::utility::clean;
use ${rustcrate}::utility::voxgigstruct as vs;
use ${rustcrate}::{
    Context, CtxSpec, Entity, Feature, FeatureRef, ${Name}Entity, ${Name}Error, ${Name}SDK, Value,
};

// Generated: the credential's wire placement is fixed when the SDK is built.
const AUTH_SUPPRESSED: bool = ${auth.suppressed};
const AUTH_WHERE: &str = "${ruststr(auth.where)}";
const AUTH_NAME: &str = "${ruststr(auth.name)}";
const AUTH_BASIC: bool = ${auth.basic};

// The diagnostic features this SDK ships.
const FEATURES: &[&str] = &[${features.map((f) => '"' + f + '"').join(', ')}];

const CANARY_APIKEY: &str = "CANARY-APIKEY-k9x2m7q4p1";
const CANARY_SECRET: &str = "CANARY-SECRET-w3e8r5t2y6";
const CANARY_HEADER: &str = "CANARY-HEADER-z1x4c7v0b3";
const CANARY_VALUE: &str = "CANARY-VALUE-n5m8b2v9c4";

const MASK: &str = "[redacted]";

// The sweep's own encoders: a leak of an encoded form must not hide behind
// the SDK's encoder.
fn b64(input: &str) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = input.as_bytes();
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = *chunk.get(1).unwrap_or(&0) as usize;
        let b2 = *chunk.get(2).unwrap_or(&0) as usize;
        out.push(ALPHABET[b0 >> 2] as char);
        out.push(ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)] as char);
        out.push(if 1 < chunk.len() { ALPHABET[((b1 & 0x0f) << 2) | (b2 >> 6)] as char } else { '=' });
        out.push(if 2 < chunk.len() { ALPHABET[b2 & 0x3f] as char } else { '=' });
    }
    out
}

fn pct(input: &str) -> String {
    let mut out = String::new();
    for b in input.bytes() {
        let c = b as char;
        if c.is_ascii_alphanumeric() || "-_.!~*'()".contains(c) {
            out.push(c);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

// Every form a canary can travel in.
fn forms() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for v in [CANARY_APIKEY, CANARY_SECRET, CANARY_HEADER, CANARY_VALUE] {
        out.push(v.to_string());
        out.push(b64(v));
        out.push(pct(v));
    }
    out.push(b64(&format!("{}:{}", CANARY_APIKEY, CANARY_SECRET)));
    out
}

struct Sink {
    name: String,
    text: String,
}

type Sinks = Rc<RefCell<Vec<Sink>>>;

fn push(sinks: &Sinks, name: &str, text: String) {
    sinks.borrow_mut().push(Sink { name: name.to_string(), text });
}

fn push_value(sinks: &Sinks, name: &str, val: &Value) {
    push(sinks, &format!("{}:json", name), vs::jsonify(val, None));
    push(sinks, &format!("{}:debug", name), format!("{:?}", val));
    push(sinks, &format!("{}:string", name), vs::stringify(val, None, false));
}

fn push_error(sinks: &Sinks, name: &str, err: &${Name}Error) {
    push(sinks, &format!("{}:message", name), err.to_string());
    push(sinks, &format!("{}:debug", name), format!("{:?}", err));
    push(sinks, &format!("{}:json", name), err.to_json());
}

fn capture(sinks: &Sinks, name: &'static str) -> Value {
    let sinks = sinks.clone();
    vfn(move |rec| {
        push_value(&sinks, name, rec);
        Value::Noval
    })
}

// Captures the serialised context from inside the pipeline: what a hook
// author would hand to a logger.
struct CaptureFeature {
    sinks: Sinks,
}

impl CaptureFeature {
    fn grab(&self, name: &str, ctx: &Rc<Context>) {
        push(&self.sinks, &format!("{}:debug", name), format!("{:?}", ctx));
        push(&self.sinks, &format!("{}:display", name), format!("{}", ctx));
        push_value(&self.sinks, name, &ctx.to_value());
    }
}

impl Feature for CaptureFeature {
    fn name(&self) -> String {
        "capture".to_string()
    }
    fn active(&self) -> bool {
        true
    }
    fn pre_request(&mut self, ctx: &Rc<Context>) {
        self.grab("ctx@PreRequest", ctx);
    }
    fn pre_response(&mut self, ctx: &Rc<Context>) {
        self.grab("ctx@PreResponse", ctx);
    }
    fn pre_unexpected(&mut self, ctx: &Rc<Context>) {
        self.grab("ctx@PreUnexpected", ctx);
    }
}

// A feature that fails the operation from inside the pipeline, quoting the
// request it saw. A rust hook has no error return, so it fails the result:
// an error make_error receives from a hook, not from the pipeline. For the
// same reason there is no variant failing in PreUnexpected: make_error has
// built and cleaned the error it returns before that hook runs.
struct ThrowFeature;

impl Feature for ThrowFeature {
    fn name(&self) -> String {
        "throwhook".to_string()
    }
    fn active(&self) -> bool {
        true
    }
    fn pre_response(&mut self, ctx: &Rc<Context>) {
        let spec = match ctx.spec.borrow().clone() {
            Some(s) => s.borrow().to_value(),
            None => Value::Noval,
        };
        let err = ctx.make_error("hook", &format!("hook saw {}", vs::jsonify(&spec, None)));
        if let Some(res) = ctx.result.borrow().clone() {
            res.borrow_mut().err = Some(err);
        }
    }
}

// A stream that succeeds, so the pipeline's terminal step never runs. A rust
// stream producer has no error channel, so no stream fails.
struct StreamOkFeature;

impl Feature for StreamOkFeature {
    fn name(&self) -> String {
        "streamok".to_string()
    }
    fn active(&self) -> bool {
        true
    }
    fn pre_done(&mut self, ctx: &Rc<Context>) {
        if let Some(res) = ctx.result.borrow().clone() {
            let items: Vec<Value> = match res.borrow().resdata.clone() {
                Value::List(l) => l.borrow().clone(),
                Value::Noval | Value::Null => Vec::new(),
                other => vec![other],
            };
            let stream: ${rustcrate}::core::result::StreamFn = Rc::new(move || items.clone());
            res.borrow_mut().stream = Some(stream);
        }
    }
}

// A feature that refuses the operation with the SDK's own error, as rbac
// does, whose code quotes a registered value; it records the error
// PreUnexpected hands a hook.
struct DenyFeature {
    sinks: Sinks,
}

impl Feature for DenyFeature {
    fn name(&self) -> String {
        "denyhook".to_string()
    }
    fn active(&self) -> bool {
        true
    }
    fn pre_point(&mut self, ctx: &Rc<Context>) {
        let err = ctx.make_error(&format!("denied:{}", CANARY_VALUE), "denied");
        ctx.out_set("point", OutVal::Err(err));
    }
    fn pre_unexpected(&mut self, ctx: &Rc<Context>) {
        let ctrl = ctx.ctrl.borrow().clone();
        let err = ctrl.borrow().err.clone();
        if let Some(err) = err {
            push_error(&self.sinks, "error", &err);
        }
    }
}

fn response(status: i64, data: Value, headers: &[(&str, &str)]) -> Value {
    let h = jo(vec![("content-type", Value::str("application/json"))]);
    for (k, v) in headers {
        setp(&h, k, Value::str(*v));
    }
    jo(vec![
        ("status", Value::Num(status as f64)),
        ("statusText", Value::str(if status < 400 { "OK" } else { "ERR" })),
        ("headers", h),
        ("body", Value::str(vs::jsonify(&data, None))),
        ("json", json_thunk(data)),
    ])
}

#[derive(Clone, Copy, PartialEq)]
enum Scenario {
    Ok,
    NotFound,
    Server,
    Transport,
    NotJson,
}

const SCENARIOS: [Scenario; 5] = [
    Scenario::Ok,
    Scenario::NotFound,
    Scenario::Server,
    Scenario::Transport,
    Scenario::NotJson,
];

impl Scenario {
    fn name(&self) -> &'static str {
        match self {
            Scenario::Ok => "ok",
            Scenario::NotFound => "notfound",
            Scenario::Server => "server",
            Scenario::Transport => "transport",
            Scenario::NotJson => "notjson",
        }
    }

    fn respond(&self, url: &str) -> Value {
        match self {
            Scenario::Ok => response(
                200,
                jo(vec![("id", Value::str("i1")), ("name", Value::str("n1"))]),
                &[("x-session-token", "RESP-TOKEN-a1b2c3d4e5")],
            ),
            Scenario::NotFound => response(404, jo(vec![("error", Value::str("no such record"))]), &[]),
            Scenario::Server => response(500, jo(vec![("error", Value::str("boom"))]), &[]),
            Scenario::Transport => jo(vec![(
                "__err__",
                Value::str(format!("socket hang up (URL was: \\"{}\\")", url)),
            )]),
            Scenario::NotJson => jo(vec![
                ("status", Value::Num(200.0)),
                ("statusText", Value::str("OK")),
                ("headers", Value::empty_map()),
                ("body", Value::str("<html>")),
                ("json", json_thunk(Value::Noval)),
            ]),
        }
    }
}

// The transport seam: system.fetch is called with [url, fetchdef].
fn transport(scenario: Scenario) -> Value {
    Value::func(move |_inj, args, _r, _st| {
        let url = match vs::get_elem(args, &Value::Num(0.0), Value::Noval) {
            Value::Str(s) => s,
            _ => String::new(),
        };
        scenario.respond(&url)
    })
}

// Offline, as every generated suite is: the test OPTION resolves a required
// server variable to test-<name>, and installs no transport.
fn offline(opts: Value) -> Value {
    setp(&opts, "test", jo(vec![("active", Value::Bool(true))]));
    opts
}

// A client the sweep cannot build leaves nothing swept: a harness error, not
// a leak.
fn construct(opts: Value) -> Rc<${Name}SDK> {
    let opts = offline(opts);
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| ${Name}SDK::new(opts))) {
        Ok(sdk) => sdk,
        Err(cause) => panic!(
            "clean harness: the client could not be constructed, so nothing was swept: {}",
            cause
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| cause.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_default()
        ),
    }
}

fn make_sdk(
    scenario: Scenario,
    sinks: &Sinks,
    cleanopts: Option<Value>,
    extra: Vec<FeatureRef>,
) -> Rc<${Name}SDK> {
    make_sdk_with(scenario, sinks, cleanopts, extra, None)
}

fn make_sdk_with(
    scenario: Scenario,
    sinks: &Sinks,
    cleanopts: Option<Value>,
    extra: Vec<FeatureRef>,
    auth: Option<Value>,
) -> Rc<${Name}SDK> {
    let feature = Value::empty_map();
    for name in FEATURES {
        let fopts = jo(vec![("active", Value::Bool(true))]);
        match *name {
            "log" => setp(&fopts, "logger", capture(sinks, "log")),
            "debug" => setp(&fopts, "onEntry", capture(sinks, "debug")),
            "audit" => setp(&fopts, "sink", capture(sinks, "audit")),
            "telemetry" => setp(&fopts, "exporter", capture(sinks, "telemetry")),
            "cost" => setp(&fopts, "sink", capture(sinks, "cost")),
            _ => {}
        }
        setp(&feature, name, fopts);
    }

    let clean = jo(vec![("values", Value::str(CANARY_VALUE))]);
    if let Some(Value::Map(m)) = cleanopts {
        for (k, v) in m.borrow().iter() {
            setp(&clean, k, v.clone());
        }
    }

    let opts = jo(vec![
        ("apikey", Value::str(CANARY_APIKEY)),
        ("secret", Value::str(CANARY_SECRET)),
        ("headers", jo(vec![("X-Custom-Token", Value::str(CANARY_HEADER))])),
        ("clean", clean),
        ("feature", feature),
        ("system", jo(vec![("fetch", transport(scenario))])),
    ]);
    if let Some(auth) = auth {
        setp(&opts, "auth", auth);
    }
    let sdk = construct(opts);

    // Rust options are pure data, so the extension feature is added after
    // construction (the \`extend\` option of the ts client).
    let f: FeatureRef = Rc::new(RefCell::new(CaptureFeature { sinks: sinks.clone() }));
    sdk.features.borrow_mut().push(f);
    sdk.features.borrow_mut().extend(extra);

    sdk
}

// What the operation returned, and the match its entity then holds.
type Drive = fn(&Rc<${Name}SDK>, Value, Value) -> (Result<Value, ${Name}Error>, Value);
type Stream = fn(&Rc<${Name}SDK>, Value, Value) -> Result<Vec<Value>, ${Name}Error>;

${drivers}
// Generated: every CRUD operation of every active entity, list and load
// first (they need no body), with the path parameters its points declare.
const CANDIDATES: &[(&str, Drive, Stream, &[&str])] = &[
${table}
];

#[derive(Clone)]
struct Target {
    drive: Drive,
    stream: Stream,
    mtch: Value,
}

// The first operation that completes against a plain 200: with no
// arguments, else with every path parameter its points declare filled in.
fn usable_op() -> Option<Target> {
    let plain = construct(jo(vec![
        ("apikey", Value::str(CANARY_APIKEY)),
        ("system", jo(vec![("fetch", transport(Scenario::Ok))])),
    ]));
    for (_name, drive, stream, params) in CANDIDATES {
        let filled = Value::empty_map();
        for p in params.iter() {
            setp(&filled, p, Value::str("p1"));
        }
        for mtch in [Value::empty_map(), filled] {
            if drive(&plain, vs::clone(&mtch), Value::Noval).0.is_ok() {
                return Some(Target { drive: *drive, stream: *stream, mtch });
            }
        }
    }
    None
}

const NOTHING_TO_SWEEP: &str =
    "SKIP: no operation of this SDK completes against a plain 200; nothing to sweep";

fn same_node(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Map(x), Value::Map(y)) => Rc::ptr_eq(x, y),
        _ => false,
    }
}

fn drive(sdk: &Rc<${Name}SDK>, target: &Target, ctrl: Value, sinks: &Sinks) -> Option<${Name}Error> {
    // A caller may keep the record it passed rather than read ctrl.explain.
    let held = getp(&ctrl, "explain");
    let (res, mtch) = (target.drive)(sdk, vs::clone(&target.mtch), ctrl.clone());
    let out = match res {
        Ok(out) => {
            push_value(sinks, "result", &out);
            None
        }
        Err(err) => {
            push_error(sinks, "error", &err);
            Some(err)
        }
    };
    // Raw, as a caller copying the match into another query reads it.
    push_value(sinks, "match", &mtch);
    let explain = getp(&ctrl, "explain");
    if let Value::Map(_) = explain {
        push_value(sinks, "explain", &explain);
    }
    if let Value::Map(_) = held {
        if !same_node(&held, &explain) {
            push_value(sinks, "explain:held", &held);
        }
    }
    out
}

// Header maps keep the caller's spelling; the assertion should not care.
fn header(map: &Value, name: &str) -> Option<String> {
    if let Value::Map(m) = map {
        for (k, v) in m.borrow().iter() {
            if k.to_lowercase() == name.to_lowercase() {
                return match v {
                    Value::Str(s) => Some(s.clone()),
                    other => Some(vs::stringify(other, None, false)),
                };
            }
        }
    }
    None
}

fn leaks(text: &str) -> Vec<String> {
    forms().into_iter().filter(|f| text.contains(f.as_str())).collect()
}

#[test]
fn clean_no_credential_leaves_the_sdk_in_any_form() {
    let Some(target) = usable_op() else {
        println!("{}", NOTHING_TO_SWEEP);
        return;
    };

    let sinks: Sinks = Rc::new(RefCell::new(Vec::new()));
    let mut errors: Vec<(String, ${Name}Error)> = Vec::new();
    let mut explains: Vec<(String, Value)> = Vec::new();

    for scenario in SCENARIOS {
        for variant in ["throw", "explain", "nothrow"] {
            let sdk = make_sdk(scenario, &sinks, None, Vec::new());
            let explain = Value::empty_map();
            let ctrl = match variant {
                "explain" => jo(vec![("explain", explain.clone())]),
                "nothrow" => jo(vec![("throw", Value::Bool(false)), ("explain", explain.clone())]),
                _ => Value::Noval,
            };
            let key = format!("{}/{}", scenario.name(), variant);
            if let Some(err) = drive(&sdk, &target, ctrl, &sinks) {
                errors.push((key.clone(), err));
            }
            if "throw" != variant {
                explains.push((key, explain));
            }
            push(&sinks, "sdk:debug", format!("{:?}", sdk));
            push(&sinks, "sdk:display", format!("{}", sdk));
        }
    }

    // A name given at run time replaces the declared one: the match leaves
    // out whichever name prepare_auth placed.
    let renamed = make_sdk_with(Scenario::Ok, &sinks, None, Vec::new(),
        Some(jo(vec![("name", Value::str("zzcred"))])));
    drive(&renamed, &target, Value::Noval, &sinks);

    // A credential mistyped as a map. The rust validator does not reject it
    // (make_options keeps its input when validation fails), so what the
    // constructor produced is swept instead: the client's prints, and a
    // string quoting the value, cleaned the way a validation message is.
    let mistyped = ${Name}SDK::new(offline(jo(vec![
        ("apikey", jo(vec![("value", Value::str(CANARY_APIKEY))])),
        ("clean", jo(vec![("values", Value::str(CANARY_VALUE))])),
    ])));
    push(&sinks, "mistyped:debug", format!("{:?}", mistyped));
    push(&sinks, "mistyped:display", format!("{}", mistyped));
    push(
        &sinks,
        "mistyped:quoted",
        clean::clean_str(
            &mistyped.get_root_ctx(),
            &format!("apikey: expected string, got {{\\"value\\":\\"{}\\"}}", CANARY_APIKEY),
        ),
    );

    // An error a feature hook raises, quoting the request, with explain on.
    let hooked = make_sdk(
        Scenario::Ok,
        &sinks,
        None,
        vec![Rc::new(RefCell::new(ThrowFeature)) as FeatureRef],
    );
    let hookerr = drive(&hooked, &target, jo(vec![("explain", Value::empty_map())]), &sinks);
    assert!(hookerr.is_some(), "the throwing hook should fail the operation");

    // The explain record a stream call is passed is cleaned however the
    // stream ends: from a feature's producer, or materialised by done.
    for (name, extra) in [
        ("stream-ok", vec![Rc::new(RefCell::new(StreamOkFeature)) as FeatureRef]),
        ("stream-plain", Vec::new()),
    ] {
        let streamed = make_sdk(Scenario::Ok, &sinks, None, extra);
        let explain = Value::empty_map();
        let callopts = jo(vec![("ctrl", jo(vec![("explain", explain.clone())]))]);
        let items = (target.stream)(&streamed, vs::clone(&target.mtch), callopts);
        assert!(items.is_ok(), "{}: only a failing stream raises", name);
        assert!(
            matches!(&explain, Value::Map(m) if 0 < m.borrow().len()),
            "{}: the explain record was not filled",
            name
        );
        push_value(&sinks, &format!("{}:explain", name), &explain);
    }

    // A feature's own error keeps its code, which is cleaned like the
    // message: returned, handed to a hook, and cleaned where a step's error
    // skips make_error.
    let denier = make_sdk(
        Scenario::Ok,
        &sinks,
        None,
        vec![Rc::new(RefCell::new(DenyFeature { sinks: sinks.clone() })) as FeatureRef],
    );
    let denied = drive(&denier, &target, Value::Noval, &sinks)
        .expect("the refusing hook should fail the operation");
    let stepped = clean::clean_error(
        &denier.get_root_ctx(),
        ${Name}Error::new(&format!("stepped:{}", CANARY_VALUE), "stepped"),
    );
    push_error(&sinks, "stepped", &stepped);

    // A client given no clean block at all masks by the schema defaults.
    let bare = construct(jo(vec![
        ("apikey", Value::str(CANARY_APIKEY)),
        ("secret", Value::str(CANARY_SECRET)),
        ("headers", jo(vec![("X-Custom-Token", Value::str(CANARY_HEADER))])),
        ("system", jo(vec![("fetch", transport(Scenario::NotFound))])),
    ]));
    let barerr = drive(&bare, &target, Value::Noval, &sinks)
        .expect("the 404 scenario must throw without a clean block");

    // The raw path returns its failure rather than an error.
    let raw = make_sdk(Scenario::Transport, &sinks, None, Vec::new())
        .direct(jo(vec![("path", Value::str("raw"))]))
        .expect("direct() returns its failure as data");
    assert_eq!(getp(&raw, "ok"), Value::Bool(false), "a transport failure should fail direct()");
    push_value(&sinks, "direct", &raw);

    let leaked: Vec<String> = sinks
        .borrow()
        .iter()
        .filter_map(|s| {
            let found = leaks(&s.text);
            if found.is_empty() {
                None
            } else {
                Some(format!("{} [{}]", s.name, found.join(", ")))
            }
        })
        .collect();

    println!(
        "clean: swept {} surface(s), {} leak(s)",
        sinks.borrow().len(),
        leaked.len()
    );

    assert!(leaked.is_empty(), "credential leaked through: {}", leaked.join("; "));

    // The positive half: the slot the credential travelled in is masked,
    // and an unregistered token in a response header is masked by name.
    let notfound = errors
        .iter()
        .find(|(k, _)| k == "notfound/throw")
        .map(|(_, e)| e.clone())
        .expect("the 404 scenario must throw");
    assert_eq!(notfound.status, 404);

    let headers = getp(&notfound.spec, "headers");
    if !AUTH_SUPPRESSED {
        if "query" == AUTH_WHERE {
            assert_eq!(header(&getp(&notfound.spec, "query"), AUTH_NAME), Some(MASK.to_string()));
        } else if "cookie" == AUTH_WHERE {
            let cookie = header(&headers, "cookie").unwrap_or_default();
            assert!(cookie.contains(MASK), "cookie: {}", cookie);
        } else {
            let cred = header(&headers, AUTH_NAME).unwrap_or_default();
            assert!(cred.ends_with(MASK), "{}: {}", AUTH_NAME, cred);
        }
    }
    assert_eq!(header(&headers, "x-custom-token"), Some(MASK.to_string()));
    assert_eq!(denied.code, format!("denied:{}", MASK));
    assert_eq!(stepped.code, format!("stepped:{}", MASK));
    assert_eq!(
        header(&getp(&barerr.spec, "headers"), "x-custom-token"),
        Some(MASK.to_string())
    );

    let explained = explains
        .iter()
        .find(|(k, _)| k == "ok/explain")
        .map(|(_, e)| e.clone())
        .unwrap_or(Value::Noval);
    let result = getp(&explained, "result");
    assert!(matches!(result, Value::Map(_)), "the explain record should carry the result");
    assert_eq!(header(&getp(&result, "headers"), "x-session-token"), Some(MASK.to_string()));
}

#[test]
fn clean_the_sweep_can_see_a_leak() {
    let Some(target) = usable_op() else {
        println!("{}", NOTHING_TO_SWEEP);
        return;
    };

    let sinks: Sinks = Rc::new(RefCell::new(Vec::new()));
    let sdk = make_sdk(
        Scenario::NotFound,
        &sinks,
        Some(jo(vec![("active", Value::Bool(false))])),
        Vec::new(),
    );
    let err = drive(&sdk, &target, Value::Noval, &sinks).expect("the 404 scenario must throw");

    // Explaining a failure must not cost it its error.
    let quiet: Sinks = Rc::new(RefCell::new(Vec::new()));
    let explained = drive(
        &make_sdk(Scenario::NotFound, &quiet, Some(jo(vec![("active", Value::Bool(false))])), Vec::new()),
        &target,
        jo(vec![("explain", Value::empty_map())]),
        &quiet,
    );
    assert_eq!(
        explained.map(|e| e.msg),
        Some(err.msg.clone()),
        "with clean off, explain lost the error"
    );

    let leaked = sinks.borrow().iter().filter(|s| !leaks(&s.text).is_empty()).count();
    assert!(0 < leaked, "with clean off, nothing showed the canary: the sweep is blind");

    if !AUTH_SUPPRESSED {
        let text = vs::jsonify(&err.spec, None);
        assert!(
            text.contains(CANARY_APIKEY)
                || text.contains(&b64(&format!("{}:{}", CANARY_APIKEY, CANARY_SECRET))),
            "the raw spec should carry the credential when clean is off"
        );
    }
    let _ = AUTH_BASIC;
}

#[test]
fn clean_masks_a_registered_value_used_as_a_name() {
    let sdk = construct(jo(vec![(
        "clean",
        jo(vec![("values", Value::str("ZZVAL-abc123,ZZVAL-xyz789"))]),
    )]));
    let out = clean::clean_util(
        &sdk.get_root_ctx(),
        &jo(vec![
            ("ZZVAL-abc123", Value::Num(1.0)),
            ("ZZVAL-xyz789", Value::Num(2.0)),
            ("plain", Value::Num(3.0)),
        ]),
    );
    let keys: Vec<String> = match &out {
        Value::Map(m) => m.borrow().iter().map(|(k, _)| k.clone()).collect(),
        _ => Vec::new(),
    };
    assert_eq!(keys, vec![MASK.to_string(), format!("{}#1", MASK), "plain".to_string()]);
}

// A feature's name is not a field name: a feature called secrets does not
// make its settings secret, though a sensitive field inside it still is. An
// entity block, of per-entity settings or seeded records keyed by entity name
// and id, is not read at all, and nor are rbac's rules, keyed by entity and
// operation names.
#[test]
fn clean_reads_a_feature_name_as_a_name() {
    let seeded = jo(vec![(
        "zztoken",
        jo(vec![("ZZTOKEN01", jo(vec![("note", Value::str("PLAINRECORD-t5r3e1w9"))]))]),
    )]);
    let sdk = construct(jo(vec![
        ("apikey", Value::str(CANARY_APIKEY)),
        (
            "feature",
            jo(vec![
                (
                    "secrets",
                    jo(vec![
                        ("active", Value::Bool(false)),
                        ("name", Value::str("ZZNAME-feat123")),
                        ("token", Value::str("ZZTOKEN-feat456")),
                    ]),
                ),
                (
                    "rbac",
                    jo(vec![
                        ("active", Value::Bool(false)),
                        ("rules", jo(vec![("zztoken.load", Value::str("PLAINRULE-k7j5h3g1"))])),
                    ]),
                ),
                ("test", jo(vec![("active", Value::Bool(false)), ("entity", seeded)])),
            ]),
        ),
        (
            "entity",
            jo(vec![(
                "zztoken",
                jo(vec![("alias", jo(vec![("zzkey", Value::str("PLAINALIAS-m2n4b6v8"))]))]),
            )]),
        ),
    ]));
    let ctx = sdk.get_root_ctx();
    assert_eq!(
        clean::clean_str(&ctx, "ZZNAME-feat123 ZZTOKEN-feat456"),
        format!("ZZNAME-feat123 {}", MASK)
    );
    assert_eq!(clean::clean_str(&ctx, "record PLAINRECORD-t5r3e1w9"), "record PLAINRECORD-t5r3e1w9");
    assert_eq!(clean::clean_str(&ctx, "alias PLAINALIAS-m2n4b6v8"), "alias PLAINALIAS-m2n4b6v8");
    assert_eq!(clean::clean_str(&ctx, "rule PLAINRULE-k7j5h3g1"), "rule PLAINRULE-k7j5h3g1");
}

#[test]
fn clean_honours_the_generated_config_clean_block() {
    let utility = construct(Value::empty_map()).get_utility();
    let config = jo(vec![(
        "options",
        jo(vec![(
            "clean",
            jo(vec![("keys", Value::str("zzsens")), ("values", Value::str("CONFIG-SEEDED-1"))]),
        )]),
    )]);
    let ctx = utility.make_context(
        CtxSpec {
            options: Some(jo(vec![(
                "clean",
                jo(vec![("values", Value::str("CALLER-SEEDED-2"))]),
            )])),
            config: Some(config.clone()),
            ..Default::default()
        },
        None,
    );
    let opts = utility.make_options(&ctx);
    *ctx.options.borrow_mut() = opts;
    assert_eq!(
        clean::clean_str(&ctx, "a CONFIG-SEEDED-1 b CALLER-SEEDED-2"),
        format!("a {} b {}", MASK, MASK)
    );
    let out = clean::clean_util(
        &ctx,
        &jo(vec![("my_zzsens", Value::str("x")), ("other", Value::str("y"))]),
    );
    assert_eq!(getp(&out, "my_zzsens"), Value::str(MASK));
    assert_eq!(getp(&out, "other"), Value::str("y"));
    assert_eq!(getpath(&["options", "clean", "keys"], &config), Value::str("zzsens"));
    assert_eq!(getpath(&["options", "clean", "values"], &config), Value::str("CONFIG-SEEDED-1"));
}
`
}


function ruststr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}


export {
  TestClean
}
