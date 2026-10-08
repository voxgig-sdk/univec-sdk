use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, getpath, jo, setp};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

// Every registered secret VALUE (and its encoded forms) is replaced wherever
// it appears in a string, and every value under a sensitive KEY name is
// masked whatever it holds. The registry is the Rc-shared `values` list of
// `options.__derived__.clean`, so a feature registering a value later
// reaches the list every context reads.

const MAXDEPTH: usize = 32;
const CIRCULAR: &str = "[circular]";
const DEFAULT_MASK: &str = "[redacted]";

struct CleanConfig {
    active: bool,
    keys: Vec<String>,
    values: Vec<String>,
    mask: String,
    hint: usize,
}

fn normkey(key: &str) -> String {
    key.to_lowercase()
        .chars()
        .filter(|c| '-' != *c && '_' != *c)
        .collect()
}

fn strs(val: &Value) -> Vec<String> {
    match val {
        Value::List(l) => l
            .borrow()
            .iter()
            .filter_map(|v| match v {
                Value::Str(s) => Some(s.clone()),
                _ => None,
            })
            .collect(),
        Value::Str(s) => s
            .split(',')
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

fn splitkeys(keys: &Value) -> Vec<String> {
    strs(keys)
        .iter()
        .map(|k| normkey(k))
        .filter(|k| !k.is_empty())
        .collect()
}

/// The comma-separated literal values a caller registers; a list is taken
/// as-is for a caller that has one.
pub fn splitvalues(values: &Value) -> Vec<String> {
    strs(values)
}

// The spec carries numbers as strings, so every target reads it alike.
fn count(val: &Value, dflt: usize) -> usize {
    let n = match val {
        Value::Num(n) => *n,
        Value::Str(s) => s.trim().parse::<f64>().unwrap_or(f64::NAN),
        _ => f64::NAN,
    };
    if n.is_finite() && 0.0 <= n {
        n.floor() as usize
    } else {
        dflt
    }
}

/// The derived clean block from a clean option block: what make_options
/// stores under `__derived__.clean`.
pub fn make_clean_config(cleanopts: &Value) -> Value {
    let active = !matches!(getp(cleanopts, "active"), Value::Bool(false));
    let mask = match getp(cleanopts, "mask") {
        Value::Str(s) => s,
        _ => DEFAULT_MASK.to_string(),
    };
    jo(vec![
        ("active", Value::Bool(active)),
        (
            "keys",
            Value::list(splitkeys(&getp(cleanopts, "keys")).into_iter().map(Value::str).collect()),
        ),
        ("values", Value::empty_list()),
        ("mask", Value::str(mask)),
        ("hint", Value::Num(count(&getp(cleanopts, "hint"), 0) as f64)),
        ("min", Value::Num(count(&getp(cleanopts, "min"), 4).max(1) as f64)),
    ])
}

fn derived_block(options: &Value) -> Value {
    getpath(&["__derived__", "clean"], options)
}

// A context without options (make_error is reached with a bare one) falls
// back to the schema defaults, so nothing leaves raw for want of a
// constructor.
fn config_block(ctx: &Context) -> Value {
    let options = ctx.options.borrow().clone();
    let derived = derived_block(&options);
    if let Value::Map(_) = derived {
        return derived;
    }
    make_clean_config(&getp(&crate::core::schema::optspec(), "clean"))
}

fn read_config(block: &Value) -> CleanConfig {
    CleanConfig {
        active: !matches!(getp(block, "active"), Value::Bool(false)),
        keys: strs(&getp(block, "keys")),
        values: strs(&getp(block, "values")),
        mask: match getp(block, "mask") {
            Value::Str(s) => s,
            _ => DEFAULT_MASK.to_string(),
        },
        hint: count(&getp(block, "hint"), 0),
    }
}

/// Standard base64 (RFC 4648), for the encoded form of a registered value
/// and for the `Authorization: Basic` composite.
pub fn base64_encode(input: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);

    for chunk in input.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = *chunk.get(1).unwrap_or(&0) as usize;
        let b2 = *chunk.get(2).unwrap_or(&0) as usize;

        out.push(ALPHABET[b0 >> 2] as char);
        out.push(ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)] as char);
        out.push(if 1 < chunk.len() {
            ALPHABET[((b1 & 0x0f) << 2) | (b2 >> 6)] as char
        } else {
            '='
        });
        out.push(if 2 < chunk.len() {
            ALPHABET[b2 & 0x3f] as char
        } else {
            '='
        });
    }

    out
}

// The encoded forms a value travels in: Basic and Bearer both carry base64,
// a query credential is percent-encoded, and a JSON dump escapes it.
fn forms(value: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![value.to_string()];
    let mut add = |s: String| {
        if !s.is_empty() && !out.contains(&s) {
            out.push(s);
        }
    };
    add(base64_encode(value.as_bytes()));
    add(vs::esc_url(&Value::str(value)));
    let json = vs::jsonify(&Value::str(value), None);
    if 2 <= json.len() {
        add(json[1..json.len() - 1].to_string());
    }
    out
}

/// Register a secret value against an options map. Idempotent; shorter
/// than `min` is not a secret the SDK can mask without blanking ordinary
/// text. A map with no derived block registers nothing.
pub fn clean_add_opts(options: &Value, value: &str) {
    let block = derived_block(options);
    if !matches!(block, Value::Map(_)) {
        return;
    }
    let min = count(&getp(&block, "min"), 4).max(1);
    if value.chars().count() < min {
        return;
    }
    let list = match getp(&block, "values") {
        Value::List(l) => l,
        _ => {
            let l = Value::empty_list();
            setp(&block, "values", l.clone());
            match l {
                Value::List(l) => l,
                _ => return,
            }
        }
    };
    let mut items = list.borrow_mut();
    let mut changed = false;
    for form in forms(value) {
        if form.chars().count() < min {
            continue;
        }
        let present = items.iter().any(|v| matches!(v, Value::Str(s) if *s == form));
        if !present {
            items.push(Value::str(form));
            changed = true;
        }
    }
    if changed {
        items.sort_by(|a, b| {
            let la = a.as_str().map(|s| s.len()).unwrap_or(0);
            let lb = b.as_str().map(|s| s.len()).unwrap_or(0);
            lb.cmp(&la)
        });
    }
}

/// Register a secret value the context's options will mask from now on.
pub fn clean_add(ctx: &Rc<Context>, value: &str) {
    let options = ctx.options.borrow().clone();
    clean_add_opts(&options, value);
}

fn mask_value(cfg: &CleanConfig, value: &str) -> String {
    let n = value.chars().count();
    if 0 < cfg.hint && n > 2 * cfg.hint {
        let tail: String = value.chars().skip(n - cfg.hint).collect();
        return format!("{}{}", cfg.mask, tail);
    }
    cfg.mask.clone()
}

fn clean_string(cfg: &CleanConfig, text: &str) -> String {
    let mut out = text.to_string();
    for value in &cfg.values {
        if out.contains(value.as_str()) {
            out = out.replace(value.as_str(), &mask_value(cfg, value));
        }
    }
    out
}

fn sensitive_key(cfg: &CleanConfig, key: Option<&str>) -> bool {
    let key = match key {
        Some(k) => k,
        None => return false,
    };
    let nk = normkey(key);
    cfg.keys.iter().any(|k| nk.contains(k.as_str()))
}

fn node_ptr(val: &Value) -> Option<usize> {
    match val {
        Value::List(l) => Some(Rc::as_ptr(l) as *const () as usize),
        Value::Map(m) => Some(Rc::as_ptr(m) as *const () as usize),
        _ => None,
    }
}

// A plain-data copy of what is about to leave: functions are dropped,
// cycles are cut, and no live node is shared with the copy - masking the
// copy must never mask the pipeline's own spec.
fn snapshot(cfg: &CleanConfig, val: &Value, key: Option<&str>, depth: usize, seen: &mut Vec<usize>) -> Value {
    match val {
        Value::Noval | Value::Null => val.clone(),
        Value::Str(s) => {
            if sensitive_key(cfg, key) {
                Value::str(mask_value(cfg, s))
            } else {
                Value::str(clean_string(cfg, s))
            }
        }
        Value::Func(_) => Value::Noval,
        Value::Bool(_) | Value::Num(_) | Value::Sentinel(_) => {
            if sensitive_key(cfg, key) {
                Value::str(cfg.mask.clone())
            } else {
                val.clone()
            }
        }
        Value::List(_) | Value::Map(_) => {
            let ptr = node_ptr(val).unwrap_or(0);
            if MAXDEPTH <= depth || seen.contains(&ptr) {
                return Value::str(CIRCULAR);
            }
            if sensitive_key(cfg, key) {
                return Value::str(cfg.mask.clone());
            }
            seen.push(ptr);
            let out = match val {
                Value::List(l) => {
                    let items: Vec<Value> = l
                        .borrow()
                        .iter()
                        .map(|v| snapshot(cfg, v, None, depth + 1, seen))
                        .collect();
                    Value::list(items)
                }
                Value::Map(m) => {
                    let out = Value::empty_map();
                    for (k, v) in m.borrow().iter() {
                        let cv = snapshot(cfg, v, Some(k), depth + 1, seen);
                        if !cv.is_noval() {
                            let name = clean_name(cfg, &out, k);
                            setp(&out, &name, cv);
                        }
                    }
                    out
                }
                _ => Value::Noval,
            };
            seen.pop();
            out
        }
    }
}

// A registered value used as a property name is masked like any other
// string; names that mask alike take a counter, so none is lost.
fn clean_name(cfg: &CleanConfig, out: &Value, key: &str) -> String {
    let taken = |n: &str| match out {
        Value::Map(m) => m.borrow().get(n).is_some(),
        _ => false,
    };
    let name = clean_string(cfg, key);
    if name == key || !taken(&name) {
        return name;
    }
    let mut i = 1;
    while taken(&format!("{}#{}", name, i)) {
        i += 1;
    }
    format!("{}#{}", name, i)
}

fn clean_with(cfg: &CleanConfig, val: &Value) -> Value {
    if !cfg.active {
        return val.clone();
    }
    match val {
        Value::Str(s) => Value::str(clean_string(cfg, s)),
        _ => snapshot(cfg, val, None, 0, &mut Vec::new()),
    }
}

/// Clean a value on its way out. A string is redacted; anything else comes
/// back as a masked plain-data copy. Takes the bare context so a `Debug`
/// impl can reach it.
pub fn clean_value(ctx: &Context, val: &Value) -> Value {
    clean_with(&read_config(&config_block(ctx)), val)
}

pub fn clean_util(ctx: &Rc<Context>, val: &Value) -> Value {
    clean_value(ctx, val)
}

/// String flavour of clean.
pub fn clean_str(ctx: &Rc<Context>, val: &str) -> String {
    let cfg = read_config(&config_block(ctx));
    if !cfg.active {
        return val.to_string();
    }
    clean_string(&cfg, val)
}

/// Clean a value against an options map rather than a context, for a
/// feature that holds the options but no context.
pub fn clean_opts(options: &Value, val: &Value) -> Value {
    let block = derived_block(options);
    if !matches!(block, Value::Map(_)) {
        return val.clone();
    }
    clean_with(&read_config(&block), val)
}

/// Is this key name sensitive under the context's clean configuration?
pub fn clean_key(ctx: &Rc<Context>, key: &str) -> bool {
    sensitive_key(&read_config(&config_block(ctx)), Some(key))
}

/// An error that never passed through make_error, returned as its cleaned
/// self: every text field and both snapshots.
pub fn clean_error(ctx: &Rc<Context>, mut err: UnivecError) -> UnivecError {
    let cfg = read_config(&config_block(ctx));
    if cfg.active {
        err.msg = clean_string(&cfg, &err.msg);
        err.code = clean_string(&cfg, &err.code);
        err.result = clean_with(&cfg, &err.result);
        err.spec = clean_with(&cfg, &err.spec);
    }
    err
}

/// Every scalar under a sensitive name, at any depth and of any shape, is
/// registered against `options`: a credential mistyped as a map or a number
/// is still a credential.
pub fn clean_add_sensitive_opts(options: &Value, val: &Value) {
    let block = derived_block(options);
    if !matches!(block, Value::Map(_)) {
        return;
    }
    let cfg = read_config(&block);
    add_sensitive(&cfg, options, val, false, 0, &mut Vec::new());
}

pub fn clean_add_sensitive(ctx: &Rc<Context>, val: &Value) {
    let options = ctx.options.borrow().clone();
    clean_add_sensitive_opts(&options, val);
}

fn add_sensitive(
    cfg: &CleanConfig,
    options: &Value,
    val: &Value,
    under: bool,
    depth: usize,
    seen: &mut Vec<usize>,
) {
    if MAXDEPTH <= depth {
        return;
    }
    match val {
        Value::Str(s) if under => clean_add_opts(options, s),
        Value::Num(n) if under => clean_add_opts(options, &vs::value::num_to_string(*n)),
        Value::List(_) | Value::Map(_) => {
            let ptr = node_ptr(val).unwrap_or(0);
            if seen.contains(&ptr) {
                return;
            }
            seen.push(ptr);
            match val {
                Value::List(l) => {
                    for v in l.borrow().iter() {
                        add_sensitive(cfg, options, v, under, depth + 1, seen);
                    }
                }
                Value::Map(m) => {
                    for (k, v) in m.borrow().iter() {
                        let sub = under || sensitive_key(cfg, Some(k));
                        add_sensitive(cfg, options, v, sub, depth + 1, seen);
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
}
