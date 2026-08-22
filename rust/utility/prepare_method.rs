use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::getp;
use crate::utility::voxgigstruct::Value;

pub fn prepare_method_util(ctx: &Rc<Context>) -> String {
    let opname = ctx.op.borrow().name.clone();

    // The API definition is authoritative: a POST-only or PATCH-based API
    // exposes `update` as POST or PATCH, not the PUT the op name implies.
    // Only fall back to the op-name convention when the point has no method.
    let point = ctx.point.borrow().clone();
    if let Value::Str(pm) = getp(&point, "method") {
        if !pm.is_empty() {
            return pm.to_uppercase();
        }
    }

    match opname.as_str() {
        "create" => "POST",
        "update" => "PUT",
        "load" => "GET",
        "list" => "GET",
        "remove" => "DELETE",
        "patch" => "PATCH",
        _ => "GET",
    }
    .to_string()
}
