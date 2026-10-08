use std::rc::Rc;

use crate::core::context::Context;
use crate::utility::media::{is_raw_request, raw_body};
use crate::utility::voxgigstruct::Value;

pub fn prepare_body_util(ctx: &Rc<Context>) -> Value {
    let op = ctx.op.borrow().clone();

    if op.input == "data" {
        if is_raw_request(&ctx.point.borrow()) {
            return raw_body(&ctx.reqdata.borrow());
        }
        return crate::utility::transform_request::transform_request_util(ctx);
    }

    Value::Noval
}
