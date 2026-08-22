// Struct corpus runner — drives the shared JSON test spec
// (../.sdk/test/test.json, `struct` subtree) against the vendored voxgig
// struct port. Vendored/adapted from the struct rust port's corpus runner
// (mirrors tm/go/test/struct_runner_test.go).
#![allow(dead_code)]

use std::fs;
use std::path::PathBuf;

use RUSTCRATE::utility::voxgigstruct::ordered_map::OrderedMap;

use RUSTCRATE::utility::voxgigstruct::value::Value;
use RUSTCRATE::utility::voxgigstruct::*;

pub const NULLMARK: &str = "__NULL__";
pub const UNDEFMARK: &str = "__UNDEF__";
pub const EXISTSMARK: &str = "__EXISTS__";

// ---- JSON -> Value -----------------------------------------------------
// The shared SDK test spec, parsed with the crate's own JSON parser (no
// external dependency).

pub fn test_json() -> Value {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("..");
    p.push(".sdk");
    p.push("test");
    p.push("test.json");
    let txt = fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {:?}: {e}", p));
    RUSTCRATE::utility::jsonparse::json_parse(&txt).expect("parse test.json")
}

// ---- value helpers -----------------------------------------------------

// Raw field extraction from corpus entries: preserves a stored JSON null so a
// field declared `null` (e.g. `in: null`, `{val:null}`) reaches the subject as
// Value::Null and is not silently dropped (Group A null-unification only
// applies to the public get_prop API under test, not to test-harness plumbing).
// Mirrors the canonical TS runner reading entry fields by direct property access.
pub fn vget(v: &Value, key: &str) -> Value {
    lookup(v, &Value::str(key))
}

pub fn vget_path(v: &Value, keys: &[&str]) -> Value {
    let mut cur = v.clone();
    for k in keys {
        cur = vget(&cur, k);
    }
    cur
}

pub fn as_i64_opt(v: &Value) -> Option<i64> {
    match v {
        Value::Num(n) => Some(*n as i64),
        _ => None,
    }
}

pub fn as_str_opt(v: &Value) -> Option<String> {
    match v {
        Value::Str(s) => Some(s.clone()),
        _ => None,
    }
}

// fixJSON: deep-replace JSON null (and undefined) with NULLMARK (when
// null_flag). Matches `JSON.parse(JSON.stringify(val, replacer))` with the
// null->NULLMARK replacer used by ts/test/runner.ts.
pub fn fix_json(v: &Value, null_flag: bool) -> Value {
    match v {
        Value::Null | Value::Noval => {
            if null_flag {
                Value::str(NULLMARK)
            } else {
                v.clone()
            }
        }
        Value::List(l) => Value::list(l.borrow().iter().map(|x| fix_json(x, null_flag)).collect()),
        Value::Map(m) => {
            let mut nm = OrderedMap::new();
            for (k, x) in m.borrow().iter() {
                nm.insert(k.clone(), fix_json(x, null_flag));
            }
            Value::map(nm)
        }
        Value::Func(_) => {
            // JSON.stringify drops functions (object key) / -> null (array elem).
            // At the comparison boundary, treat as null-ish.
            if null_flag {
                Value::str(NULLMARK)
            } else {
                Value::Null
            }
        }
        other => other.clone(),
    }
}

// match check for the `match` field of a test entry (substring / regex / etc).
pub fn matchval(check: &Value, base: &Value) -> bool {
    if check == base {
        return true;
    }
    if let Value::Str(cs) = check {
        let bstr = stringify(base, None, false);
        if let Some(rem) = cs.strip_prefix('/').and_then(|s| s.strip_suffix('/')) {
            if let Ok(re) = RUSTCRATE::utility::voxgigstruct::re::Regex::new(rem) {
                return re.is_match(&bstr);
            }
        }
        return bstr
            .to_lowercase()
            .contains(&stringify(check, None, false).to_lowercase());
    }
    false
}

// ---- the test loop -----------------------------------------------------

pub struct Run {
    pub failures: Vec<String>,
    pub passed: usize,
}

impl Run {
    pub fn new() -> Self {
        Run {
            failures: Vec::new(),
            passed: 0,
        }
    }

    /// Run a test set: `label` for messages, `null_flag` matches the TS
    /// `flags.null` (`runset` => true, `runsetflags({null:false})` => false),
    /// `subject` takes the (cloned) `vin` and returns the result Value.
    pub fn run_set<F>(&mut self, set: &Value, null_flag: bool, label: &str, mut subject: F)
    where
        F: FnMut(Value) -> Value,
    {
        if set.is_noval() {
            // Section absent from this SDK's test.json subset.
            return;
        }
        let fixed = fix_json(set, null_flag);
        let testset = vget(&fixed, "set");
        let entries = match testset.as_list() {
            Some(l) => l.borrow().clone(),
            None => {
                self.failures.push(format!("{label}: no `set` array"));
                return;
            }
        };
        for (i, entry) in entries.iter().enumerate() {
            // resolveEntry: missing `out` + null_flag => NULLMARK
            let out0 = vget(entry, "out");
            let expected = if out0.is_noval() && null_flag {
                Value::str(NULLMARK)
            } else {
                out0
            };
            let err_expected = vget(entry, "err");
            let match_spec = vget(entry, "match");

            // `vin` = clone(entry.in) (deep). The subject gets a shallow
            // Rc-clone of it, so any in-place mutation it makes (setpath,
            // setprop, …) is visible through `vin` afterwards.
            let vin = clone(&vget(entry, "in"));
            let res = fix_json(&subject(vin.clone()), null_flag);

            if !err_expected.is_noval() {
                self.failures.push(format!(
                    "{label}#{i}: expected error [{}] but got {}",
                    stringify(&err_expected, Some(80), false),
                    stringify(&res, Some(80), false),
                ));
                continue;
            }

            let mut matched = false;
            if !match_spec.is_noval() {
                // base = { in: entry.in (original), args: [vin (post-call)], out: res }
                let mut base = OrderedMap::new();
                base.insert("in".to_string(), vget(entry, "in"));
                base.insert("args".to_string(), Value::list(vec![vin.clone()]));
                base.insert("out".to_string(), res.clone());
                let base = Value::map(base);
                if let Some(why) = match_check(&match_spec, &base) {
                    self.failures.push(format!(
                        "{label}#{i}: match failed ({why}); got {}",
                        stringify(&res, Some(160), false)
                    ));
                    continue;
                }
                matched = true;
            }

            if res == expected {
                self.passed += 1;
                continue;
            }
            if matched
                && (expected == Value::str(NULLMARK) || expected.is_noval() || expected.is_null())
            {
                self.passed += 1;
                continue;
            }

            self.failures.push(format!(
                "{label}#{i}: in={} -> got {}, want {}",
                stringify(&vget(entry, "in"), Some(120), false),
                stringify(&res, Some(120), false),
                stringify(&expected, Some(120), false),
            ));
        }
    }
}

impl Run {
    /// Like `run_set`, but the subject may return `Err(message)` — matched
    /// (substring / regex, case-insensitive) against the entry's `err` field.
    pub fn run_set_fallible<F>(&mut self, set: &Value, null_flag: bool, label: &str, mut subject: F)
    where
        F: FnMut(Value) -> Result<Value, String>,
    {
        if set.is_noval() {
            // Section absent from this SDK's test.json subset.
            return;
        }
        let fixed = fix_json(set, null_flag);
        let testset = vget(&fixed, "set");
        let entries = match testset.as_list() {
            Some(l) => l.borrow().clone(),
            None => {
                self.failures.push(format!("{label}: no `set` array"));
                return;
            }
        };
        for (i, entry) in entries.iter().enumerate() {
            let out0 = vget(entry, "out");
            let expected = if out0.is_noval() && null_flag {
                Value::str(NULLMARK)
            } else {
                out0
            };
            let err_expected = vget(entry, "err");
            let match_spec = vget(entry, "match");
            let vin = clone(&vget(entry, "in"));
            let result = subject(vin.clone());

            match result {
                Err(msg) => {
                    if err_expected.is_noval() {
                        self.failures
                            .push(format!("{label}#{i}: unexpected error: {msg}"));
                        continue;
                    }
                    let want = match &err_expected {
                        Value::Bool(true) => {
                            self.passed += 1;
                            continue;
                        }
                        Value::Str(s) => s.clone(),
                        other => stringify(other, None, false),
                    };
                    let ok = if let Some(rem) =
                        want.strip_prefix('/').and_then(|s| s.strip_suffix('/'))
                    {
                        RUSTCRATE::utility::voxgigstruct::re::Regex::new(rem)
                            .map(|re| re.is_match(&msg))
                            .unwrap_or(false)
                    } else {
                        msg.to_lowercase().contains(&want.to_lowercase())
                    };
                    if ok {
                        self.passed += 1;
                    } else {
                        self.failures.push(format!(
                            "{label}#{i}: error mismatch: got [{}] want [{}]",
                            msg, want
                        ));
                    }
                }
                Ok(v) => {
                    if !err_expected.is_noval() {
                        self.failures.push(format!(
                            "{label}#{i}: expected error [{}] but got value {}",
                            stringify(&err_expected, Some(80), false),
                            stringify(&fix_json(&v, null_flag), Some(80), false)
                        ));
                        continue;
                    }
                    let res = fix_json(&v, null_flag);
                    let mut matched = false;
                    if !match_spec.is_noval() {
                        let mut base = OrderedMap::new();
                        base.insert("in".to_string(), vget(entry, "in"));
                        base.insert("args".to_string(), Value::list(vec![vin.clone()]));
                        base.insert("out".to_string(), res.clone());
                        let base = Value::map(base);
                        if let Some(why) = match_check(&match_spec, &base) {
                            self.failures
                                .push(format!("{label}#{i}: match failed ({why})"));
                            continue;
                        }
                        matched = true;
                    }
                    if res == expected
                        || (matched && (expected == Value::str(NULLMARK) || expected.is_nullish()))
                    {
                        self.passed += 1;
                    } else {
                        self.failures.push(format!(
                            "{label}#{i}: in={} -> got {}, want {}",
                            stringify(&vget(entry, "in"), Some(120), false),
                            stringify(&res, Some(120), false),
                            stringify(&expected, Some(120), false),
                        ));
                    }
                }
            }
        }
    }
}

/// Walk `check`; every leaf must equal/match `getpath(base, path)`. Returns
/// `Some(reason)` on the first mismatch, `None` if all leaves match.
pub fn match_check(check: &Value, base: &Value) -> Option<String> {
    fn rec(check: &Value, base: &Value, path: &mut Vec<String>) -> Option<String> {
        match check {
            Value::Map(cm) => {
                for (k, cv) in cm.borrow().iter() {
                    path.push(k.clone());
                    let r = rec(cv, base, path);
                    path.pop();
                    if r.is_some() {
                        return r;
                    }
                }
                None
            }
            Value::List(cl) => {
                for (i, cv) in cl.borrow().iter().enumerate() {
                    path.push(i.to_string());
                    let r = rec(cv, base, path);
                    path.pop();
                    if r.is_some() {
                        return r;
                    }
                }
                None
            }
            leaf => {
                let bv = get_path(
                    base,
                    &Value::list(path.iter().cloned().map(Value::Str).collect()),
                    None,
                );
                if leaf == &bv {
                    return None;
                }
                if let Value::Str(s) = leaf {
                    if s == UNDEFMARK && bv.is_noval() {
                        return None;
                    }
                    if s == EXISTSMARK && !bv.is_nullish() {
                        return None;
                    }
                }
                if matchval(leaf, &bv) {
                    return None;
                }
                Some(format!(
                    "{}: {} <=> {}",
                    path.join("."),
                    stringify(leaf, Some(40), false),
                    stringify(&bv, Some(40), false)
                ))
            }
        }
    }
    let mut path = Vec::new();
    rec(check, base, &mut path)
}

// ---- adapters helpers --------------------------------------------------

pub fn b(v: bool) -> Value {
    Value::Bool(v)
}

pub fn inject_def_from_value(v: &Value) -> InjectDef {
    let mut d = InjectDef::default();
    if let Value::Map(_) = v {
        let key = vget(v, "key");
        if !key.is_noval() {
            d.key = Some(key);
        }
        let meta = vget(v, "meta");
        if !meta.is_noval() {
            d.meta = Some(meta);
        }
        let base = vget(v, "base");
        if let Value::Str(s) = base {
            d.base = Some(s);
        }
        let dparent = vget(v, "dparent");
        if !dparent.is_noval() {
            d.dparent = Some(dparent);
        }
        let dpath = vget(v, "dpath");
        if let Value::Str(s) = dpath {
            d.dpath = Some(s.split('.').map(|x| x.to_string()).collect());
        } else if let Value::List(l) = &dpath {
            d.dpath = Some(
                l.borrow()
                    .iter()
                    .map(|x| as_str_opt(x).unwrap_or_default())
                    .collect(),
            );
        }
    }
    d
}

