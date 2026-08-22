use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::getp;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn prepare_path_util(ctx: &Rc<Context>) -> String {
    let point = ctx.point.borrow().clone();

    let parts = match getp(&point, "parts") {
        Value::List(l) => Value::List(l),
        _ => Value::empty_list(),
    };

    vs::join(&parts, Some("/"), true)
}
