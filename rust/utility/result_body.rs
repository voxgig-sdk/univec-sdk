use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::call_json;
use crate::core::response::unreadable_body;
use crate::core::result::SdkResult;
use crate::utility::voxgigstruct::Value;

pub fn result_body_util(ctx: &Rc<Context>) -> Option<Rc<RefCell<SdkResult>>> {
    let response = ctx.response.borrow().clone();
    let result = ctx.result.borrow().clone();

    if let Some(result) = &result {
        if let Some(response) = &response {
            let (json, body, unreadable) = {
                let r = response.borrow();
                (r.json.clone(), r.body.clone(), r.unreadable)
            };
            if matches!(json, Value::Func(_)) && !body.is_noval() && !body.is_null() {
                result.borrow_mut().body = call_json(&json);
            }
            if unreadable {
                let sent = match ctx.spec.borrow().clone() {
                    Some(spec) => spec.borrow().headers.clone(),
                    None => Value::Noval,
                };
                let (status, headers, failed) = {
                    let r = result.borrow();
                    (r.status, r.headers.clone(), r.err.clone())
                };
                result.borrow_mut().err =
                    Some(unreadable_body(ctx, status, &headers, &body, &sent, failed));
            }
        }
    }

    result
}
