use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{get_bool, getp, to_map};
use crate::core::types::FeatureRef;
use crate::utility::voxgigstruct::Value;

pub fn feature_init_util(ctx: &Rc<Context>, f: &FeatureRef) {
    let fname = f.borrow().name();
    let mut fopts = Value::empty_map();

    let options = ctx.options.borrow().clone();
    if let Value::Map(_) = options {
        let feature_opts = to_map(&getp(&options, "feature"));
        if let Value::Map(_) = feature_opts {
            let fo = to_map(&getp(&feature_opts, &fname));
            if let Value::Map(_) = fo {
                fopts = fo;
            }
        }
    }

    if get_bool(&fopts, "active") == Some(true) {
        f.borrow_mut().init(ctx, &fopts);
    }
}
