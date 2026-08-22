use std::rc::Rc;

use crate::core::context::Context;
use crate::utility::voxgigstruct::Value;

pub fn clean_util(_ctx: &Rc<Context>, val: &Value) -> Value {
    val.clone()
}

/// String flavour of clean (go clean returns the value unchanged).
pub fn clean_str(_ctx: &Rc<Context>, val: &str) -> String {
    val.to_string()
}
