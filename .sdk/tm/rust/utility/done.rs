use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, to_map};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn done_util(ctx: &Rc<Context>) -> Result<Value, UnivecError> {
    clean_explain_util(ctx);

    let result = ctx.result.borrow().clone();
    if let Some(res) = result {
        if res.borrow().ok {
            return Ok(res.borrow().resdata.clone());
        }
    }

    crate::utility::make_error::make_error_util(ctx, None)
}

/// Clean the explain record in place. It is the caller's own map (Control
/// copies the Rc), so its entries are replaced by the cleaned copy's; with
/// clean off the cleaned record is that map, already current.
pub fn clean_explain_util(ctx: &Rc<Context>) {
    let ctrl = ctx.ctrl.borrow().clone();
    let explain = ctrl.borrow().explain.clone();
    let Value::Map(orig) = &explain else {
        return;
    };
    if let Value::Map(cleaned) = crate::utility::clean::clean_util(ctx, &explain) {
        if !Rc::ptr_eq(orig, &cleaned) {
            let entries = cleaned.borrow().clone();
            *orig.borrow_mut() = entries;
        }
    }
    // explain.result is a to_value snapshot, never the live result.
    if let Value::Map(_) = getp(&explain, "result") {
        vs::del_prop(to_map(&getp(&explain, "result")), &Value::str("err"));
    }
}
