use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{get_str, setp};
use crate::core::response::Response;
use crate::core::result::SdkResult;
use crate::core::types::OutVal;
use crate::utility::voxgigstruct::Value;

pub fn make_request_util(
    ctx: &Rc<Context>,
) -> Result<Rc<RefCell<Response>>, UnivecError> {
    if let Some(OutVal::Response(resp)) = ctx.out_get("request") {
        return Ok(resp);
    }

    let response = Rc::new(RefCell::new(Response::new(&Value::empty_map())));
    let result = Rc::new(RefCell::new(SdkResult::new(&Value::empty_map())));
    *ctx.result.borrow_mut() = Some(result);

    let spec = ctx.spec.borrow().clone().ok_or_else(|| {
        ctx.make_error("request_no_spec", "Expected context spec property to be defined.")
    })?;

    let fetchdef = match crate::utility::make_fetch_def::make_fetch_def_util(ctx) {
        Ok(fd) => fd,
        Err(err) => {
            response.borrow_mut().err = Some(err);
            *ctx.response.borrow_mut() = Some(response.clone());
            spec.borrow_mut().step = "postrequest".to_string();
            return Ok(response);
        }
    };

    {
        let ctrl = ctx.ctrl.borrow().clone();
        let c = ctrl.borrow();
        if c.has_explain() {
            setp(&c.explain, "fetchdef", fetchdef.clone());
        }
    }

    spec.borrow_mut().step = "prerequest".to_string();

    let url = get_str(&fetchdef, "url").unwrap_or_default();
    let fetched = ctx.util().fetch(ctx, &url, &fetchdef);

    let response = match fetched {
        Err(fetch_err) => {
            response.borrow_mut().err = Some(fetch_err);
            response
        }
        Ok(Value::Map(fm)) => Rc::new(RefCell::new(Response::new(&Value::Map(fm)))),
        Ok(Value::Noval) | Ok(Value::Null) => {
            let r = Rc::new(RefCell::new(Response::new(&Value::empty_map())));
            r.borrow_mut().err =
                Some(ctx.make_error("request_no_response", "response: undefined"));
            r
        }
        Ok(_) => {
            response.borrow_mut().err =
                Some(ctx.make_error("request_invalid_response", "response: invalid type"));
            response
        }
    };

    spec.borrow_mut().step = "postrequest".to_string();
    *ctx.response.borrow_mut() = Some(response.clone());

    Ok(response)
}
