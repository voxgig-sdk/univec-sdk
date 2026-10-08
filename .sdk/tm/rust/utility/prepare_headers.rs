use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{getp, setp};
use crate::utility::media::media_headers;
use crate::utility::param::call_args;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn prepare_headers_util(ctx: &Rc<Context>) -> Value {
    let options = match ctx.client.borrow().clone() {
        Some(client) => client.options_map(),
        None => ctx.options.borrow().clone(),
    };

    let headers = getp(&options, "headers");
    let out = if headers.is_noval() || headers.is_null() {
        Value::empty_map()
    } else {
        match vs::clone(&headers) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        }
    };
    let out = media_headers(&ctx.point.borrow(), out);

    // A header argument replaces a default of the same name, whatever its case.
    for (_, wire, val) in call_args(ctx, "header") {
        if !val.is_noval() && !val.is_null() {
            let key = wire.to_lowercase();
            if let Value::Map(m) = &out {
                let same: Vec<String> =
                    m.borrow().keys().filter(|k| k.to_lowercase() == key).cloned().collect();
                for k in same {
                    m.borrow_mut().shift_remove(&k);
                }
            }
            setp(&out, &key, Value::Str(vs::stringify(&val, None, false)));
        }
    }

    // A cookie argument travels in the cookie header, form serialized and
    // percent-encoded, replacing a cookie of the same name among those the
    // caller's headers already send.
    let sent: Vec<(String, String, Value)> = call_args(ctx, "cookie")
        .into_iter()
        .filter(|(_, _, val)| !val.is_noval() && !val.is_null())
        .collect();
    if !sent.is_empty() {
        let names: Vec<String> = sent
            .iter()
            .flat_map(|(_, wire, val)| match val {
                Value::Map(_) => vs::keysof_vec(val)
                    .iter()
                    .map(|k| vs::esc_url(&Value::Str(k.clone())))
                    .collect::<Vec<String>>(),
                _ => vec![wire.clone()],
            })
            .collect();
        let mut kept: Vec<String> = Vec::new();
        if let Value::Map(m) = &out {
            let given: Vec<String> =
                m.borrow().keys().filter(|k| k.to_lowercase() == "cookie").cloned().collect();
            for k in given {
                if let Some(Value::Str(s)) = m.borrow_mut().shift_remove(&k) {
                    kept.extend(cookie_keep(&s, &names));
                }
            }
        }
        for (_, wire, val) in &sent {
            let pair = cookie_pair(wire, val);
            if !pair.is_empty() {
                kept.push(pair);
            }
        }
        if !kept.is_empty() {
            setp(&out, "cookie", Value::Str(kept.join("; ")));
        }
    }

    out
}

// The form style of a cookie parameter: a list repeats the name, a map sends
// its own keys, and every value is percent-encoded.
fn cookie_pair(wire: &str, val: &Value) -> String {
    let esc = |v: &Value| vs::esc_url(&Value::Str(vs::stringify(v, None, false)));
    let pairs: Vec<String> = match val {
        Value::List(items) => {
            items.borrow().iter().map(|item| format!("{}={}", wire, esc(item))).collect()
        }
        Value::Map(m) => vs::keysof_vec(val)
            .iter()
            .map(|k| {
                let v = m.borrow().get(k).cloned().unwrap_or(Value::Null);
                format!("{}={}", vs::esc_url(&Value::Str(k.clone())), esc(&v))
            })
            .collect(),
        _ => vec![format!("{}={}", wire, esc(val))],
    };
    pairs.join("; ")
}

// The caller's cookie pieces with the named cookies removed: a cookie is one
// ;-delimited piece, whatever its value holds.
pub fn cookie_keep(header: &str, names: &[String]) -> Vec<String> {
    let mut kept: Vec<String> = Vec::new();
    for piece in header.split(';') {
        let cookie = piece.trim();
        let name = cookie.split('=').next().unwrap_or("").trim();
        if !cookie.is_empty() && !names.iter().any(|n| n == name) {
            kept.push(cookie.to_string());
        }
    }
    kept
}
