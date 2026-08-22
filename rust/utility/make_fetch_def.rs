use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::setp;
use crate::core::result::SdkResult;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn make_fetch_def_util(ctx: &Rc<Context>) -> Result<Value, UnivecError> {
    let spec = ctx.spec.borrow().clone().ok_or_else(|| {
        ctx.make_error("fetchdef_no_spec", "Expected context spec property to be defined.")
    })?;

    if ctx.result.borrow().is_none() {
        *ctx.result.borrow_mut() =
            Some(Rc::new(RefCell::new(SdkResult::new(&Value::empty_map()))));
    }

    spec.borrow_mut().step = "prepare".to_string();

    let url = crate::utility::make_url::make_url_util(ctx)?;

    spec.borrow_mut().url = url.clone();

    let fetchdef = Value::empty_map();
    setp(&fetchdef, "url", Value::str(url));
    setp(&fetchdef, "method", Value::str(spec.borrow().method.clone()));
    setp(&fetchdef, "headers", spec.borrow().headers.clone());

    let body = spec.borrow().body.clone();
    if !body.is_noval() {
        if let Value::Map(_) = body {
            setp(&fetchdef, "body", Value::str(vs::jsonify(&body, None)));
        } else {
            setp(&fetchdef, "body", body);
        }
    }

    Ok(fetchdef)
}
