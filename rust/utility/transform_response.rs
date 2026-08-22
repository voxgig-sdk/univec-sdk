use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{getp, to_map};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn transform_response_util(ctx: &Rc<Context>) -> Value {
    let spec = ctx.spec.borrow().clone();
    let result = ctx.result.borrow().clone();
    let point = ctx.point.borrow().clone();

    if let Some(sp) = &spec {
        sp.borrow_mut().step = "resform".to_string();
    }

    let result = match result {
        Some(r) => r,
        None => return Value::Noval,
    };
    if !result.borrow().ok {
        return Value::Noval;
    }

    let transform = to_map(&getp(&point, "transform"));
    if transform.is_noval() {
        return Value::Noval;
    }

    let resform = getp(&transform, "res");
    if resform.is_noval() || resform.is_null() {
        return Value::Noval;
    }

    let store = {
        let r = result.borrow();
        crate::core::helpers::jo(vec![
            ("ok", Value::Bool(r.ok)),
            ("status", Value::Num(r.status as f64)),
            ("statusText", Value::str(r.status_text.clone())),
            ("headers", r.headers.clone()),
            ("body", r.body.clone()),
            ("resdata", r.resdata.clone()),
            ("resmatch", r.resmatch.clone()),
        ])
    };

    match vs::transform(&store, &resform, None) {
        Ok(resdata) => {
            result.borrow_mut().resdata = resdata.clone();
            resdata
        }
        Err(_) => Value::Noval,
    }
}
