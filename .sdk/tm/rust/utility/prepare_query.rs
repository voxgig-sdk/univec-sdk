use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{getp, setp};
use crate::utility::param::call_args;
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

    // A path parameter travels in the path. The generated config lists them as
    // args.params, which prepare_params reads; params is the older list of names.
    let aparams = getp(&getp(&point, "args"), "params");
    let in_args = |key: &str| -> bool {
        if let Value::List(pl) = &aparams {
            for pd in pl.borrow().iter() {
                if let Value::Str(s) = getp(pd, "name") {
                    if s == key {
                        return true;
                    }
                }
            }
        }
        false
    };

    // A header or cookie parameter travels in the headers, which prepare_headers
    // fills, unless a query parameter shares its name: then both are sent.
    let aheader = getp(&getp(&point, "args"), "header");
    let acookie = getp(&getp(&point, "args"), "cookie");
    let declared = getp(&getp(&point, "args"), "query");
    let in_header = |key: &str| -> bool {
        if let Value::List(ql) = &declared {
            for qd in ql.borrow().iter() {
                if let Value::Str(s) = getp(qd, "name") {
                    if s == key {
                        return false;
                    }
                }
            }
        }
        for located in [&aheader, &acookie] {
            if let Value::List(hl) = located {
                for hd in hl.borrow().iter() {
                    if let Value::Str(s) = getp(hd, "name") {
                        if s == key {
                            return true;
                        }
                    }
                }
            }
        }
        false
    };

    // A query parameter travels under the name the definition gives it, its
    // orig, which the model may have renamed for the caller.
    let aquery = getp(&getp(&point, "args"), "query");
    let wire_name = |key: &str| -> String {
        if let Value::List(ql) = &aquery {
            for qd in ql.borrow().iter() {
                if let (Value::Str(n), Value::Str(o)) = (getp(qd, "name"), getp(qd, "orig")) {
                    if n == key && !o.is_empty() {
                        return o;
                    }
                }
            }
        }
        key.to_string()
    };

    let out = Value::empty_map();
    if let Value::Map(rm) = &reqmatch {
        let entries: Vec<(String, Value)> = rm
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        for (key, val) in entries {
            if !val.is_noval() && !val.is_null() && "$action" != key && !contains(&key) && !in_args(&key)
                && !in_header(&key)
            {
                setp(&out, &wire_name(&key), val);
            }
        }
    }

    // A create or update passes its query arguments in its data.
    for (name, wire, val) in call_args(ctx, "query") {
        if !val.is_noval() && !val.is_null() && !contains(&name) && !in_args(&name) && !in_header(&name) {
            setp(&out, &wire, val);
        }
    }

    out
}
