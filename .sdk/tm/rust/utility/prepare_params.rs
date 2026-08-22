use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{get_str, getp, setp, to_map};
use crate::utility::voxgigstruct::Value;

pub fn prepare_params_util(ctx: &Rc<Context>) -> Value {
    let point = ctx.point.borrow().clone();

    let params = match to_map(&getp(&point, "args")) {
        Value::Map(_) => match getp(&to_map(&getp(&point, "args")), "params") {
            Value::List(l) => Value::List(l),
            _ => Value::empty_list(),
        },
        _ => Value::empty_list(),
    };

    let out = Value::empty_map();
    if let Value::List(pl) = &params {
        for pd in pl.borrow().iter() {
            let val = crate::utility::param::param_util(ctx, pd);
            if !val.is_noval() && !val.is_null() {
                if let Value::Map(_) = pd {
                    if let Some(name) = get_str(pd, "name").filter(|n| !n.is_empty()) {
                        setp(&out, &name, val);
                    }
                }
            }
        }
    }

    out
}
