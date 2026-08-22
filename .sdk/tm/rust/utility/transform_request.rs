use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{getp, jo, to_map};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn transform_request_util(ctx: &Rc<Context>) -> Value {
    let spec = ctx.spec.borrow().clone();
    let point = ctx.point.borrow().clone();

    if let Some(sp) = &spec {
        sp.borrow_mut().step = "reqform".to_string();
    }

    let transform = to_map(&getp(&point, "transform"));
    if transform.is_noval() {
        return ctx.reqdata.borrow().clone();
    }

    let reqform = getp(&transform, "req");
    if reqform.is_noval() || reqform.is_null() {
        return ctx.reqdata.borrow().clone();
    }

    let store = jo(vec![("reqdata", ctx.reqdata.borrow().clone())]);
    match vs::transform(&store, &reqform, None) {
        Ok(reqdata) => reqdata,
        Err(_) => ctx.reqdata.borrow().clone(),
    }
}
