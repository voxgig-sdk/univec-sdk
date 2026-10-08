use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{get_str, getp, to_map};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn param_util(ctx: &Rc<Context>, paramdef: &Value) -> Value {
    let point = ctx.point.borrow().clone();
    let spec = ctx.spec.borrow().clone();

    let pt = vs::typify(paramdef);

    let key = if 0 != ((vs::T_STRING as i64) & pt) {
        match paramdef {
            Value::Str(s) => s.clone(),
            _ => String::new(),
        }
    } else {
        get_str(paramdef, "name").unwrap_or_default()
    };

    let akey = param_alias(&point, &key);
    if !akey.is_empty()
        && getp(&ctx.reqmatch.borrow().clone(), &key).is_noval()
        && getp(&ctx.mtch.borrow().clone(), &key).is_noval()
    {
        if let Some(sp) = &spec {
            let alias = sp.borrow().alias.clone();
            crate::core::helpers::setp(&alias, &akey, Value::str(key.clone()));
        }
    }

    param_value(ctx, &point, &key)
}

// The name a point gives a parameter in the call, if it renames it.
fn param_alias(point: &Value, key: &str) -> String {
    if point.is_noval() {
        return String::new();
    }
    let alias = to_map(&getp(point, "alias"));
    if alias.is_noval() {
        return String::new();
    }
    get_str(&alias, key).unwrap_or_default()
}

// The value the call or its entity gives a point's parameter, under its name
// or the point's alias for it.
pub fn param_value(ctx: &Rc<Context>, point: &Value, key: &str) -> Value {
    let akey = param_alias(point, key);
    let mtch = ctx.mtch.borrow().clone();
    let reqmatch = ctx.reqmatch.borrow().clone();
    let data = ctx.data.borrow().clone();
    let reqdata = ctx.reqdata.borrow().clone();

    let mut val = getp(&reqmatch, key);

    if val.is_noval() {
        val = getp(&mtch, key);
    }

    if val.is_noval() && !akey.is_empty() {
        val = getp(&reqmatch, &akey);
    }

    if val.is_noval() {
        val = getp(&reqdata, key);
    }

    if val.is_noval() {
        val = getp(&data, key);
    }

    if val.is_noval() && !akey.is_empty() {
        val = getp(&reqdata, &akey);
        if val.is_noval() {
            val = getp(&data, &akey);
        }
    }

    val
}


// The arguments a point declares in one location, query or header, each as
// its name, the name it travels under, and the value this call passes in its
// match or else its data. Unlike a path parameter, the entity's stored match
// and data never supply one.
pub fn call_args(ctx: &Rc<Context>, kind: &str) -> Vec<(String, String, Value)> {
    let point = ctx.point.borrow().clone();
    let mut out = Vec::new();
    if let Value::List(al) = getp(&getp(&point, "args"), kind) {
        let reqmatch = ctx.reqmatch.borrow().clone();
        let reqdata = ctx.reqdata.borrow().clone();
        for ad in al.borrow().iter() {
            let name = match getp(ad, "name") {
                Value::Str(n) if !n.is_empty() => n,
                _ => continue,
            };
            let wire = match getp(ad, "orig") {
                Value::Str(o) if !o.is_empty() => o,
                _ => name.clone(),
            };
            let mut val = getp(&reqmatch, &name);
            if val.is_noval() || val.is_null() {
                val = getp(&reqdata, &name);
            }
            out.push((name, wire, val));
        }
    }
    out
}
