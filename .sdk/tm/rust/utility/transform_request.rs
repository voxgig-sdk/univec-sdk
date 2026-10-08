use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{getp, jo, setp, to_map};
use crate::utility::param::call_args;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

// `$action` selects the point (see make_point_util); it is never an API
// field, so the body is a copy without it. The caller's map is left untouched.
fn strip_action(reqdata: Value) -> Value {
    omit_keys(reqdata, &["$action".to_string()])
}

// A header, cookie or query argument travels where prepare_headers_util or
// prepare_query_util sends it, so the body is built from the request data
// without it, unless the point marks it as a field the body keeps.
fn routed_arg_names(ctx: &Rc<Context>) -> Vec<String> {
    let mut names = Vec::new();
    for kind in ["header", "cookie", "query"] {
        for (name, _, _) in call_args(ctx, kind) {
            if !field_arg(ctx, &name) {
                names.push(name);
            }
        }
    }
    names
}

fn field_arg(ctx: &Rc<Context>, name: &str) -> bool {
    let point = ctx.point.borrow().clone();
    ["header", "cookie", "query"].iter().any(|kind| {
        match getp(&getp(&point, "args"), kind) {
            Value::List(al) => al.borrow().iter().any(|ad| {
                matches!(getp(ad, "name"), Value::Str(ref n) if n == name)
                    && matches!(getp(ad, "field"), Value::Bool(true))
            }),
            _ => false,
        }
    })
}

fn omit_keys(reqdata: Value, names: &[String]) -> Value {
    let has = match &reqdata {
        Value::Map(src) => names.iter().any(|n| src.borrow().contains_key(n)),
        _ => false,
    };
    if !has {
        return reqdata;
    }
    let body = Value::empty_map();
    if let Value::Map(src) = &reqdata {
        let entries: Vec<(String, Value)> = src
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        for (k, v) in entries {
            if !names.contains(&k) {
                setp(&body, &k, v);
            }
        }
    }
    body
}

pub fn transform_request_util(ctx: &Rc<Context>) -> Value {
    let spec = ctx.spec.borrow().clone();
    let point = ctx.point.borrow().clone();

    if let Some(sp) = &spec {
        sp.borrow_mut().step = "reqform".to_string();
    }

    let reqdata = omit_keys(ctx.reqdata.borrow().clone(), &routed_arg_names(ctx));

    let transform = to_map(&getp(&point, "transform"));
    if transform.is_noval() {
        return strip_action(reqdata);
    }

    let reqform = getp(&transform, "req");
    if reqform.is_noval() || reqform.is_null() {
        return strip_action(reqdata);
    }

    let store = jo(vec![("reqdata", reqdata.clone())]);
    strip_action(match vs::transform(&store, &reqform, None) {
        Ok(out) => out,
        Err(_) => reqdata,
    })
}
