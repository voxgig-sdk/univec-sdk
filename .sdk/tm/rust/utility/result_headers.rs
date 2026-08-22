use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::result::SdkResult;
use crate::utility::voxgigstruct::Value;

pub fn result_headers_util(ctx: &Rc<Context>) -> Option<Rc<RefCell<SdkResult>>> {
    let response = ctx.response.borrow().clone();
    let result = ctx.result.borrow().clone();

    if let Some(result) = &result {
        let headers = match &response {
            Some(r) => match &r.borrow().headers {
                Value::Map(m) => Value::Map(m.clone()),
                _ => Value::empty_map(),
            },
            None => Value::empty_map(),
        };
        result.borrow_mut().headers = headers;
    }

    result
}
