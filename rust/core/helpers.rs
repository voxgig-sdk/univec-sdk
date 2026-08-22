// Shared Value helpers for the Univec SDK pipeline. The SDK data model
// is the vendored voxgig struct `Value` type (utility/voxgigstruct) — the
// JSON-shaped, reference-stable (Rc<RefCell>) node used for ctx data, specs,
// options, transport payloads and results, exactly as the Go SDK passes
// map[string]any around.

use std::cell::RefCell;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::core::error::UnivecError;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::major::Injection;
use vs::Value;

// UnsupportedOp is returned by entity stub methods for operations the
// underlying API spec doesn't define. The static UnivecEntity trait
// requires every CRUD method on every entity, so absent ops must still be
// callable — they error at runtime instead of failing to compile.
pub fn unsupported_op(opname: &str, entityname: &str) -> UnivecError {
    UnivecError::new(
        "unsupported_op",
        &format!(
            "operation '{}' not supported by entity '{}'",
            opname, entityname
        ),
    )
}

/// Property read: `getp(map, "key")` — Noval when absent (mirrors GetProp).
pub fn getp(val: &Value, key: &str) -> Value {
    vs::get_prop(val, &Value::str(key), Value::Noval)
}

/// Path read on a Value store.
pub fn getpath(path: &[&str], store: &Value) -> Value {
    let p = Value::list(path.iter().map(|s| Value::str(*s)).collect());
    vs::get_path(store, &p, None)
}

/// Property write (no-op when val is not a node).
pub fn setp(val: &Value, key: &str, newval: Value) {
    vs::set_prop(val.clone(), &Value::str(key), newval);
}

/// Map literal builder: `jo(vec![("a", v)])`.
pub fn jo(pairs: Vec<(&str, Value)>) -> Value {
    Value::map_of(pairs.into_iter().map(|(k, v)| (k.to_string(), v)))
}

/// List literal builder.
pub fn ja(items: Vec<Value>) -> Value {
    Value::list(items)
}

/// Go `ToMapAny`: the value if it is a map, Noval otherwise.
pub fn to_map(v: &Value) -> Value {
    match v {
        Value::Map(_) => v.clone(),
        _ => Value::Noval,
    }
}

/// Go `ToInt`: numeric coercion with -1 default.
pub fn to_int(v: &Value) -> i64 {
    match v {
        Value::Num(n) => *n as i64,
        _ => -1,
    }
}

pub fn get_str(m: &Value, key: &str) -> Option<String> {
    match getp(m, key) {
        Value::Str(s) => Some(s),
        _ => None,
    }
}

pub fn get_bool(m: &Value, key: &str) -> Option<bool> {
    match getp(m, key) {
        Value::Bool(b) => Some(b),
        _ => None,
    }
}

pub fn get_i64(m: &Value, key: &str) -> Option<i64> {
    match getp(m, key) {
        Value::Num(n) => Some(n as i64),
        _ => None,
    }
}

pub fn get_f64(m: &Value, key: &str) -> Option<f64> {
    match getp(m, key) {
        Value::Num(n) => Some(n),
        _ => None,
    }
}

/// Wall clock in milliseconds.
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Real sleep in milliseconds.
pub fn sleep_ms(ms: i64) {
    if ms > 0 {
        std::thread::sleep(std::time::Duration::from_millis(ms as u64));
    }
}

// Small thread-local LCG for ids and jitter (std has no rand; determinism
// is not required here — injectable generators cover the tests).
thread_local! {
    static RAND_SEED: RefCell<i64> = RefCell::new(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos() as i64 + d.as_millis() as i64)
            .unwrap_or(123456789)
    );
}

/// Pseudo-random integer in [0, n).
pub fn rand_int(n: i64) -> i64 {
    if n <= 0 {
        return 0;
    }
    RAND_SEED.with(|s| {
        let mut seed = s.borrow_mut();
        *seed = (seed.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7fffffff;
        *seed % n
    })
}

/// Call a `Value::Func` callable with a single argument. The voxgig struct
/// NativeFn signature is injector-shaped `(inj, val, ref, store)`; SDK
/// callables (injected clocks, key generators, mock transports, custom
/// utilities) receive their argument via `val` and ignore the rest.
pub fn call_vfn(f: &Value, arg: &Value) -> Value {
    match f {
        Value::Func(nf) => {
            let inj = Injection::from_def(None);
            nf(&inj, arg, "", &Value::Noval)
        }
        _ => Value::Noval,
    }
}

/// Wrap a plain single-argument closure as a `Value::Func`.
pub fn vfn<F>(f: F) -> Value
where
    F: Fn(&Value) -> Value + 'static,
{
    Value::func(move |_inj, val, _r, _s| f(val))
}

/// Call the transport-shaped response `json` entry (a `Value::Func`)
/// yielding the parsed body.
pub fn call_json(json: &Value) -> Value {
    call_vfn(json, &Value::Noval)
}

/// Build a `json` thunk that returns a fixed value.
pub fn json_thunk(data: Value) -> Value {
    Value::func(move |_i, _v, _r, _s| data.clone())
}
