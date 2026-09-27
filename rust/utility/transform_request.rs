use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{getp, jo, setp, to_map};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

// `$action` selects the point (see make_point_util); it is never an API
// field, so the body is a copy without it. The caller's map is left untouched.
fn strip_action(reqdata: Value) -> Value {
    let has = match &reqdata {
        Value::Map(src) => src.borrow().contains_key("$action"),
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
            if "$action" != k {
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

    let transform = to_map(&getp(&point, "transform"));
    if transform.is_noval() {
        return strip_action(ctx.reqdata.borrow().clone());
    }

    let reqform = getp(&transform, "req");
    if reqform.is_noval() || reqform.is_null() {
        return strip_action(ctx.reqdata.borrow().clone());
    }

    let store = jo(vec![("reqdata", ctx.reqdata.borrow().clone())]);
    strip_action(match vs::transform(&store, &reqform, None) {
        Ok(reqdata) => reqdata,
        Err(_) => ctx.reqdata.borrow().clone(),
    })
}
