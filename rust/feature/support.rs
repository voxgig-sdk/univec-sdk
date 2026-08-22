// Shared option readers for the feature implementations (mirrors go
// feature/feature_options.go). Feature options arrive as Value maps (from
// SDK options or test harnesses); callables (clocks, sleepers, generators,
// sinks) arrive as Value::Func entries. These helpers normalise access and
// supply defaults, mirroring the `null == opts.x ? def : opts.x` pattern of
// the ts features.

use crate::core::helpers::{call_vfn, getp, now_ms, sleep_ms, to_int};
use crate::utility::voxgigstruct::Value;

pub fn fopt_bool(options: &Value, key: &str, def: bool) -> bool {
    match getp(options, key) {
        Value::Bool(b) => b,
        _ => def,
    }
}

pub fn fopt_int(options: &Value, key: &str, def: i64) -> i64 {
    match getp(options, key) {
        Value::Num(n) => n as i64,
        _ => def,
    }
}

pub fn fopt_num(options: &Value, key: &str, def: f64) -> f64 {
    match getp(options, key) {
        Value::Num(n) => n,
        _ => def,
    }
}

pub fn fopt_str(options: &Value, key: &str, def: &str) -> String {
    match getp(options, key) {
        Value::Str(s) if !s.is_empty() => s,
        _ => def.to_string(),
    }
}

pub fn fopt_map(options: &Value, key: &str) -> Value {
    match getp(options, key) {
        Value::Map(m) => Value::Map(m),
        _ => Value::Noval,
    }
}

pub fn fopt_list(options: &Value, key: &str) -> Value {
    match getp(options, key) {
        Value::List(l) => Value::List(l),
        _ => Value::Noval,
    }
}

/// A list option as strings.
pub fn fopt_str_list(options: &Value, key: &str) -> Option<Vec<String>> {
    match getp(options, key) {
        Value::List(l) => Some(
            l.borrow()
                .iter()
                .filter_map(|v| match v {
                    Value::Str(s) => Some(s.clone()),
                    _ => None,
                })
                .collect(),
        ),
        _ => None,
    }
}

/// The injectable sleep (option "sleep": Value::Func taking ms), defaulting
/// to a real thread sleep. Injected clocks keep tests deterministic.
pub fn fopt_sleep(options: &Value) -> impl Fn(i64) {
    let f = getp(options, "sleep");
    move |ms: i64| {
        if let Value::Func(_) = &f {
            call_vfn(&f, &Value::Num(ms as f64));
        } else if ms > 0 {
            sleep_ms(ms);
        }
    }
}

/// The injectable clock (option "now": Value::Func -> ms), defaulting to
/// the wall clock.
pub fn fopt_now(options: &Value) -> impl Fn() -> i64 {
    let f = getp(options, "now");
    move || {
        if let Value::Func(_) = &f {
            to_int(&call_vfn(&f, &Value::Noval))
        } else {
            now_ms()
        }
    }
}

/// Read a header value case-insensitively.
pub fn fheader_get(headers: &Value, name: &str) -> Option<Value> {
    if let Value::Map(m) = headers {
        let lower = name.to_lowercase();
        for (k, v) in m.borrow().iter() {
            if k.to_lowercase() == lower {
                return Some(v.clone());
            }
        }
    }
    None
}

/// Set a header only when no case-insensitive variant of it exists already
/// (never clobber a caller-provided value).
pub fn fheader_set_default(headers: &Value, name: &str, value: &str) {
    if !matches!(headers, Value::Map(_)) {
        return;
    }
    if fheader_get(headers, name).is_some() {
        return;
    }
    crate::core::helpers::setp(headers, name, Value::str(value));
}

/// The numeric status from a transport-shaped response (map with a
/// "status" entry). None when absent or non-numeric.
pub fn fres_status(res: &Value) -> Option<i64> {
    match getp(res, "status") {
        Value::Num(n) => Some(n as i64),
        _ => None,
    }
}

/// Read a header from a transport-shaped response, case-insensitively, as
/// a string.
pub fn fres_header(res: &Value, name: &str) -> Option<String> {
    let headers = getp(res, "headers");
    if !matches!(headers, Value::Map(_)) {
        return None;
    }
    match fheader_get(&headers, name) {
        Some(Value::Str(s)) => Some(s),
        _ => None,
    }
}

/// Parse a decimal string; def when unparseable.
pub fn fparse_int(s: &str, def: i64) -> i64 {
    s.trim().parse::<i64>().unwrap_or(def)
}
