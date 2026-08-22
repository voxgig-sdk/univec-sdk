use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{getp, setp};
use crate::utility::voxgigstruct::Value;

pub fn prepare_query_util(ctx: &Rc<Context>) -> Value {
    let point = ctx.point.borrow().clone();
    let reqmatch = match ctx.reqmatch.borrow().clone() {
        Value::Map(m) => Value::Map(m),
        _ => Value::empty_map(),
    };

    let params = match getp(&point, "params") {
        Value::List(l) => Value::List(l),
        _ => Value::empty_list(),
    };

    let contains = |key: &str| -> bool {
        if let Value::List(pl) = &params {
            for v in pl.borrow().iter() {
                if let Value::Str(s) = v {
                    if s == key {
                        return true;
                    }
                }
            }
        }
        false
    };

    let out = Value::empty_map();
    if let Value::Map(rm) = &reqmatch {
        let entries: Vec<(String, Value)> = rm
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        for (key, val) in entries {
            if !val.is_noval() && !val.is_null() && !contains(&key) {
                setp(&out, &key, val);
            }
        }
    }

    out
}
