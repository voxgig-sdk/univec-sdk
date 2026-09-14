// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/point.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Extension points (§6). Three kinds, chosen because they are what the
//! two existing systems actually needed, and no more.
//!
//! A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
//! deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
//! undoable, but "this instance holds slot 3 of the request chain" is
//! undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
//! paper called *Listeners Considered Harmful*, and for exactly this
//! reason.

use std::rc::Rc;

use super::types::{details, fail, stable_sort_by, PluginError};
use super::value::Value;

/// The next link of a chain (§6.2), or the base at the end of it.
pub type NextFn = Rc<dyn Fn(&[Value]) -> Result<Value, PluginError>>;

/// EVERY binding has one signature, whatever kind of point it is on: a
/// hook and a provider ignore the `next` they are handed, a chain uses it.
/// One signature is what lets `bound` return a single list the three
/// callers share, rather than three parallel registries that can disagree
/// about which instance holds slot 3.
pub type BindFn = Rc<dyn Fn(Option<&NextFn>, &[Value]) -> Result<Value, PluginError>>;

#[derive(Clone)]
pub struct Bound {
    pub eref: String,
    pub point: String,
    pub func: BindFn,
    pub band: i64,
}

/// §6.1: "fan-out" is not one answer but four. In a language with
/// asynchrony, "call every binding" hides a decision - start them all and
/// wait, await each in turn, or do not wait - and a design that leaves it
/// unsaid gets four different answers from four ports, in the concurrency
/// behaviour of production code no corpus entry happens to cover.
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

/// Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2).
///
/// Recomputed by the host whenever the live set changes, and cached
/// between changes. Plugins receive `next` as an argument; they never see
/// or store the previous value of anything. A plugin that stashes `next`
/// and calls it after deactivation is a bug the host cannot prevent, and
/// this says so rather than pretending otherwise.
pub fn compose(bindings: &[Bound], base: NextFn) -> NextFn {
    let mut nxt = base;
    for b in bindings.iter().rev() {
        let func = b.func.clone();
        let inner = nxt.clone();
        nxt = Rc::new(move |args: &[Value]| func(Some(&inner), args));
    }
    nxt
}

/// At most one live implementation (§6.3). The winner is the highest band,
/// ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
/// silently ignored.
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
