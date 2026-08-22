use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, to_map};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn done_util(ctx: &Rc<Context>) -> Result<Value, UnivecError> {
    {
        let ctrl = ctx.ctrl.borrow().clone();
        let mut c = ctrl.borrow_mut();
        if c.has_explain() {
            let explain = crate::utility::clean::clean_util(ctx, &c.explain);
            if let Value::Map(_) = getp(&explain, "result") {
                let rm = to_map(&getp(&explain, "result"));
                vs::del_prop(rm, &Value::str("err"));
            }
            c.explain = explain;
        }
    }

    let result = ctx.result.borrow().clone();
    if let Some(res) = result {
        if res.borrow().ok {
            return Ok(res.borrow().resdata.clone());
        }
    }

    crate::utility::make_error::make_error_util(ctx, None)
}
