
use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, ja, jo, json_thunk, rand_int, setp, to_map};
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::*;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub struct TestFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
}

impl TestFeature {
    pub fn new() -> TestFeature {
        TestFeature {
            name: "test".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
        }
    }
}

fn envelope(ctx: &Rc<Context>, data: Value) -> Value {
    if data.is_noval() || data.is_null() {
        return data;
    }
    let restf = crate::core::helpers::getpath(&["transform", "res"], &ctx.point.borrow());
    if let Value::Str(spec) = restf {
        // Rebuild whatever nesting the transform unwraps: a GraphQL op unwraps
        // `body.data.<field>`, not just one envelope property.
        if let Some(inner) = spec.strip_prefix("`body.").and_then(|r| r.strip_suffix('`')) {
            if !inner.is_empty() {
                let mut out = data;
                for seg in inner.split('.').rev() {
                    out = jo(vec![(seg, out)]);
                }
                return out;
            }
        }
    }
    data
}

fn respond(ctx: &Rc<Context>, status: i64, data: Value, extra: Vec<(&str, Value)>) -> Value {
    let payload = envelope(ctx, data);
    let out = jo(vec![
        ("status", Value::Num(status as f64)),
        ("statusText", Value::str("OK")),
        ("json", json_thunk(payload)),
        ("body", Value::str("not-used")),
    ]);
    for (k, v) in extra {
        setp(&out, k, v);
    }
    out
}

// For single-entity ops (load, remove) with an empty explicit match, fall
// back to the id the entity client already knows from a prior create/load
// (in ctx.mtch / ctx.data). Mirrors the TS mock where param() resolves the
// id from that accumulated state.
fn resolve_match(ctx: &Rc<Context>, explicit: &Value) -> Value {
    if vs::size(explicit) > 0 {
        return explicit.clone();
    }
    for src in [ctx.mtch.borrow().clone(), ctx.data.borrow().clone()] {
        let v = getp(&src, "id");
        if !v.is_noval() && !v.is_null() && v != Value::str("__UNDEFINED__") {
            return jo(vec![("id", v)]);
        }
    }
    Value::empty_map()
}

fn point_terminal(p: &Value) -> bool {
    match getp(p, "parts") {
        Value::List(l) => match l.borrow().last() {
            Some(Value::Str(s)) => s.starts_with('{'),
            _ => false,
        },
        _ => false,
    }
}

fn point_depth(p: &Value) -> usize {
    match getp(p, "parts") {
        Value::List(l) => l.borrow().len(),
        _ => 0,
    }
}

// The entity's own endpoint: a terminal `{param}` marks a record route, and
// among equals the shallower path wins (the same rule as make_point).
fn pick_point(points: &Value) -> Value {
    let list: Vec<Value> = match points {
        Value::List(l) => l.borrow().clone(),
        _ => return Value::Noval,
    };
    let mut point = match list.first() {
        Some(p) => p.clone(),
        None => return Value::Noval,
    };
    for cand in list.iter().skip(1) {
        if point_terminal(cand) != point_terminal(&point) {
            if point_terminal(cand) {
                point = cand.clone();
            }
        } else if point_depth(cand) < point_depth(&point) {
            point = cand.clone();
        }
    }
    point
}

fn reqd_names(point: &Value, kind: &str) -> Value {
    let args_path = crate::core::helpers::getpath(&["args", kind], point);
    let reqd_args = vs::select(&args_path, &jo(vec![("reqd", Value::Bool(true))]));
    vs::transform(
        &reqd_args,
        &ja(vec![
            Value::str("`$EACH`"),
            Value::str(""),
            Value::str("`$KEY.name`"),
        ]),
        None,
    )
    .unwrap_or_else(|_| Value::empty_list())
}

fn build_args(ctx: &Rc<Context>, args: &Value) -> Value {
    let op = ctx.op.borrow().clone();
    let opname = op.name.clone();
    let entname = match ctx.entity.borrow().clone() {
        Some(e) => e.get_name(),
        None => op.entity.clone(),
    };

    let points = crate::core::helpers::getpath(
        &["entity", &entname, "op", &opname, "points"],
        &ctx.config.borrow(),
    );
    let point = pick_point(&points);

    // Path AND query: a path-only read misses a query-addressed record
    // (e.g. GET /result?trace_id=), which has no path param at all.
    let reqd_params = reqd_names(&point, "params");
    let reqd_query = reqd_names(&point, "query");

    let qand = Value::empty_list();
    let q = jo(vec![("`$AND`", qand.clone())]);

    if let Value::Map(_) = args {
        let keys = vs::keysof_vec(args);
        for key in keys {
            let is_id = key == "id";
            let is_reqd = !vs::is_empty(&vs::select(&reqd_params, &Value::str(key.clone())))
                || !vs::is_empty(&vs::select(&reqd_query, &Value::str(key.clone())));

            if is_id || is_reqd {
                let v = ctx.util().param(ctx, &Value::str(key.clone()));
                let ka = getp(&op.alias, &key);

                let qor = Value::list(vec![jo(vec![(key.as_str(), v.clone())])]);
                if let Value::Str(kas) = &ka {
                    if let Value::List(l) = &qor {
                        l.borrow_mut().push(jo(vec![(kas.as_str(), v.clone())]));
                    }
                }

                if let Value::List(l) = &qand {
                    l.borrow_mut().push(jo(vec![("`$OR`", qor)]));
                }
            }
        }
    }

    {
        let ctrl = ctx.ctrl.borrow().clone();
        let c = ctrl.borrow();
        if c.has_explain() {
            setp(&c.explain, "test", jo(vec![("query", q.clone())]));
        }
    }

    q
}

fn test_fetch(
    entity: &Value,
    ctx: &Rc<Context>,
    _fullurl: &str,
    _fetchdef: &Value,
) -> Result<Value, UnivecError> {
    let op = ctx.op.borrow().clone();
    let entmap = match to_map(&getp(entity, &op.entity)) {
        Value::Map(m) => Value::Map(m),
        _ => Value::empty_map(),
    };

    match op.name.as_str() {
        "load" => {
            let m = resolve_match(ctx, &ctx.reqmatch.borrow().clone());
            let args = build_args(ctx, &m);
            let found = vs::select(&entmap, &args);
            let ent = vs::get_elem(&found, &Value::Num(0.0), Value::Noval);
            if ent.is_noval() || ent.is_null() {
                return Ok(respond(ctx, 404,
                    Value::Noval,
                    vec![("statusText", Value::str("Not found"))],
                ));
            }
            vs::del_prop(ent.clone(), &Value::str("$KEY"));
            Ok(respond(ctx, 200, vs::clone(&ent), vec![]))
        }

        "list" => {
            let args = build_args(ctx, &ctx.reqmatch.borrow().clone());
            let found = vs::select(&entmap, &args);
            if found.is_noval() || found.is_null() {
                return Ok(respond(ctx, 404,
                    Value::Noval,
                    vec![("statusText", Value::str("Not found"))],
                ));
            }
            if let Value::List(l) = &found {
                for item in l.borrow().iter() {
                    vs::del_prop(item.clone(), &Value::str("$KEY"));
                }
            }
            Ok(respond(ctx, 200, vs::clone(&found), vec![]))
        }

        "update" => {
            let reqdata = ctx.reqdata.borrow().clone();
            let update_match = Value::empty_map();
            if let Value::Map(_) = reqdata {
                let idv = getp(&reqdata, "id");
                if !idv.is_noval() {
                    setp(&update_match, "id", idv);
                }
                if let Value::Str(alias_id) = getp(&op.alias, "id") {
                    let av = getp(&reqdata, &alias_id);
                    if !av.is_noval() {
                        setp(&update_match, &alias_id, av);
                    }
                }
            }
            let update_match = if vs::size(&update_match) == 0 {
                resolve_match(ctx, &Value::empty_map())
            } else {
                update_match
            };
            let args = build_args(ctx, &update_match);
            let found = vs::select(&entmap, &args);
            let ent = vs::get_elem(&found, &Value::Num(0.0), Value::Noval);
            if ent.is_noval() || ent.is_null() {
                // update miss: 404, never another record
                return Ok(respond(ctx, 404,
                    Value::Noval,
                    vec![("statusText", Value::str("Not found"))],
                ));
            }
            if let (Value::Map(_), Value::Map(_)) = (&ent, &reqdata) {
                vs::merge(&Value::list(vec![ent.clone(), reqdata.clone()]), None);
            }
            vs::del_prop(ent.clone(), &Value::str("$KEY"));
            Ok(respond(ctx, 200, vs::clone(&ent), vec![]))
        }

        "remove" => {
            let m = resolve_match(ctx, &ctx.reqmatch.borrow().clone());
            let args = build_args(ctx, &m);
            let found = vs::select(&entmap, &args);
            let ent = vs::get_elem(&found, &Value::Num(0.0), Value::Noval);
            // Remove only the first matched entity. If nothing matches,
            // succeed as a no-op rather than erroring.
            if let Value::Map(_) = &ent {
                let id = getp(&ent, "id");
                vs::del_prop(entmap, &id);
            }
            Ok(respond(ctx, 200, Value::Noval, vec![]))
        }

        "create" => {
            let _ = build_args(ctx, &ctx.reqdata.borrow().clone());
            let mut id = ctx.util().param(ctx, &Value::str("id"));
            if id.is_noval() || id.is_null() {
                id = Value::str(format!(
                    "{:04x}{:04x}{:04x}{:04x}",
                    rand_int(0x10000),
                    rand_int(0x10000),
                    rand_int(0x10000),
                    rand_int(0x10000)
                ));
            }

            let ent = vs::clone(&ctx.reqdata.borrow().clone());
            if let Value::Map(_) = &ent {
                setp(&ent, "id", id.clone());
                if let Value::Str(id_str) = &id {
                    setp(&entmap, id_str, ent.clone());
                }
                vs::del_prop(ent.clone(), &Value::str("$KEY"));
                return Ok(respond(ctx, 200, vs::clone(&ent), vec![]));
            }
            Ok(respond(ctx, 200, ent, vec![]))
        }

        _ => Ok(respond(ctx, 404,
            Value::Noval,
            vec![("statusText", Value::str("Unknown operation"))],
        )),
    }
}

// make_netsim wraps a transport with simulated network conditions: latency
// (fixed or {min,max}), a budget of first-N failures (`failTimes` ->
// `failStatus`), first-N connection errors (`errorTimes`), or a hard
// `offline` outage. Counter-driven, so simulations are deterministic
// across a test.
fn make_netsim(net: Value, inner: FetcherFn) -> FetcherFn {
    let netcalls = Rc::new(RefCell::new(0i64));

    Rc::new(move |ctx, url, fetchdef| {
        let call = {
            let mut n = netcalls.borrow_mut();
            *n += 1;
            *n
        };

        let pick_latency = || -> i64 {
            let l = getp(&net, "latency");
            if l.is_noval() || l.is_null() {
                return 0;
            }
            if let Value::Map(_) = l {
                let min = fopt_int(&l, "min", 0);
                let max = fopt_int(&l, "max", min);
                if max <= min {
                    return min;
                }
                return min + ((max - min) >> 1);
            }
            fopt_int(&net, "latency", 0).max(0)
        };

        let sleep = fopt_sleep(&net);

        if fopt_bool(&net, "offline", false) {
            sleep(pick_latency());
            return Err(ctx.make_error(
                "netsim_offline",
                &format!("Simulated network offline (URL was: \"{}\")", url),
            ));
        }
        if call <= fopt_int(&net, "errorTimes", 0) {
            sleep(pick_latency());
            return Err(ctx.make_error(
                "netsim_conn",
                &format!("Simulated connection error (call {})", call),
            ));
        }
        if call <= fopt_int(&net, "failTimes", 0) {
            sleep(pick_latency());
            let status = fopt_int(&net, "failStatus", 503);
            return Ok(jo(vec![
                ("status", Value::Num(status as f64)),
                ("statusText", Value::str("Simulated Failure")),
                ("body", Value::str("not-used")),
                ("json", json_thunk(Value::Noval)),
                ("headers", Value::empty_map()),
            ]));
        }
        sleep(pick_latency());
        inner(ctx, url, fetchdef)
    })
}

impl Feature for TestFeature {
    fn name(&self) -> String {
        self.name.clone()
    }
    fn active(&self) -> bool {
        self.active
    }
    fn add_options(&self) -> Option<Value> {
        self.add_opts.clone()
    }

    fn init(&mut self, ctx: &Rc<Context>, options: &Value) {
        self.options = options.clone();

        let entity = match to_map(&getp(options, "entity")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        if let Some(client) = ctx.client.borrow().clone() {
            *client.mode.borrow_mut() = "test".to_string();
        }

        // Ensure entity ids are correct.
        let mut fix_ids = |key: &Value, val: &Value, _parent: &Value, path: &[String]| -> Value {
            if path.len() == 2 {
                if let Value::Map(_) = val {
                    if let Value::Str(k) = key {
                        setp(val, "id", Value::str(k.clone()));
                    }
                }
            }
            val.clone()
        };
        vs::walk(entity.clone(), Some(&mut fix_ids), None, None);

        let entity_fixture = entity;
        let test_fetcher: FetcherFn = Rc::new(move |ctx2, url, fetchdef| {
            test_fetch(&entity_fixture, ctx2, url, fetchdef)
        });

        // Optional network behaviour simulation over the mock transport.
        // Enable per test via `test_sdk({"net": ...}, Noval)`. When `net` is
        // absent the mock behaves exactly as before (no wrapping), so
        // existing generated tests are unaffected.
        let net = to_map(&getp(options, "net"));
        let util = ctx.util();
        if net.is_noval() {
            *util.fetcher.borrow_mut() = test_fetcher;
        } else {
            *util.fetcher.borrow_mut() = make_netsim(net, test_fetcher);
        }
    }
}
