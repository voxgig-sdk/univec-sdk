use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::getp;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn prepare_headers_util(ctx: &Rc<Context>) -> Value {
    let options = match ctx.client.borrow().clone() {
        Some(client) => client.options_map(),
        None => ctx.options.borrow().clone(),
    };

    let headers = getp(&options, "headers");
    if headers.is_noval() || headers.is_null() {
        return Value::empty_map();
    }

    match vs::clone(&headers) {
        Value::Map(m) => Value::Map(m),
        _ => Value::empty_map(),
    }
}
