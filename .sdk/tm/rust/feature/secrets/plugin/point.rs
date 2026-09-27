// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/point.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use std::rc::Rc;

use super::types::{details, fail, stable_sort_by, PluginError};
use super::value::Value;

/// The next link of a chain (§6.2), or the base at the end of it.
pub type NextFn = Rc<dyn Fn(&[Value]) -> Result<Value, PluginError>>;

pub type BindFn = Rc<dyn Fn(Option<&NextFn>, &[Value]) -> Result<Value, PluginError>>;

#[derive(Clone)]
pub struct Bound {
    pub eref: String,
    pub point: String,
    pub func: BindFn,
    pub band: i64,
}

pub const MODES: [&str; 4] = ["emit", "parallel", "serial", "bail"];

/// Fan-out. Return values are ignored except in `bail`.
pub fn point_emit(bindings: &[Bound], mode: &str, arg: &Value) -> Result<Value, PluginError> {
    if "bail" == mode {
        // Stops at the first binding that RETURNS A VALUE - the "handled,
        // stop" case. A `null` RETURN DECLINES (§6.1): rust has one way to
        // say nothing here, and the model's rule is written to that rather
        // than to JavaScript's null/undefined pair. Not truthiness -
        // `false`, `0` and `""` are values.
        for b in bindings.iter() {
            let v = (b.func)(None, std::slice::from_ref(arg))?;
            if !v.is_null() {
                return Ok(v);
            }
        }
        return Ok(Value::Null);
    }

    let mut errors: Vec<Value> = Vec::new();
    for b in bindings.iter() {
        match (b.func)(None, std::slice::from_ref(arg)) {
            Ok(_) => {}
            Err(e) => {
                // `emit` raises synchronously; the collecting modes gather.
                if "emit" == mode {
                    return Err(e);
                }
                errors.push(Value::str(&e.message));
            }
        }
    }
    Ok(if "emit" == mode {
        Value::Null
    } else {
        Value::List(errors)
    })
}

pub fn compose(bindings: &[Bound], base: NextFn) -> NextFn {
    let mut nxt = base;
    for b in bindings.iter().rev() {
        let func = b.func.clone();
        let inner = nxt.clone();
        nxt = Rc::new(move |args: &[Value]| func(Some(&inner), args));
    }
    nxt
}

pub struct Picked {
    pub winner: Option<Bound>,
    pub shadowed: Vec<String>,
}

pub fn point_provider(bindings: &[Bound], spec: &Value) -> Result<Picked, PluginError> {
    if bindings.is_empty() {
        return Ok(Picked {
            winner: None,
            shadowed: Vec::new(),
        });
    }

    if spec.get("exclusive").truthy() && 1 < bindings.len() {
        let mut refs: Vec<String> = bindings.iter().map(|b| b.eref.clone()).collect();
        refs.sort();
        return fail(
            "plugin_point_exclusive",
            &format!(
                "point is exclusive and has {} bindings: {}",
                bindings.len(),
                refs.join(", ")
            ),
            details(&[(
                "refs",
                Value::List(refs.iter().map(|r| Value::str(r)).collect()),
            )]),
        );
    }

    let mut ranked: Vec<Bound> = bindings.to_vec();
    stable_sort_by(&mut ranked, |b| (-b.band, b.eref.clone()));
    Ok(Picked {
        winner: Some(ranked[0].clone()),
        shadowed: ranked[1..].iter().map(|b| b.eref.clone()).collect(),
    })
}
