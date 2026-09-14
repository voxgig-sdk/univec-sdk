// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/order.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Ordering (§7) - one rule, one place.
//!
//! sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
//! and the third was not far off. This sort is the whole replacement, and
//! the tiers are in this order for a reason:
//!
//!   1 constraints   before/after edges, by ref or by name
//!   2 bands         integer, lower first, default 0
//!   3 declaration   ties break by `pos`
//!
//! CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
//! present. A band expresses a genuine cross-cutting layer; a constraint
//! expresses a relationship between two specific things; and a band chosen
//! by trial and error to fix an ordering bug is a bug wearing a number.

use std::collections::BTreeMap;

use super::refs::refname;
use super::types::{details, fail, stable_sort_by, PluginError};
use super::value::Value;

/// One thing to place: its ref, its declared position, and its ordering
/// block as authored.
#[derive(Clone)]
pub struct Binding {
    pub eref: String,
    pub pos: f64,
    pub order: Value,
}

pub fn resolve_order(bindings: &[Binding], pin: &Value) -> Result<Vec<String>, PluginError> {
    let byref: BTreeMap<String, Binding> = bindings
        .iter()
        .map(|b| (b.eref.clone(), b.clone()))
        .collect();

    // Constraints are edges. A constraint naming an ABSENT binding is
    // satisfied VACUOUSLY (§7) - a plugin ordered `after: 'test'` must
    // load in a host with no test plugin. That is sdkgen's __after__
    // behaviour, kept.
    let mut edges: BTreeMap<String, Vec<String>> = bindings
        .iter()
        .map(|b| (b.eref.clone(), Vec::new()))
        .collect();

    for b in bindings.iter() {
        let block = &b.order;
        // An ABSENT constraint and an EMPTY LIST are both "no constraint".
        if order_declared(&block.get("after")) {
            for t in order_targets(&block.get("after"), bindings) {
                edges.get_mut(&t).unwrap().push(b.eref.clone());
            }
        }
        if order_declared(&block.get("before")) {
            let targets = order_targets(&block.get("before"), bindings);
            edges.get_mut(&b.eref).unwrap().extend(targets);
        }
    }

    // Stable topological sort. Among ready nodes, band first (lower runs
    // first), then `pos` - the position the DOCUMENT visibly states, not
    // the order instances happened to load and not the incarnation `seq`.
    let mut indeg: BTreeMap<String, usize> =
        bindings.iter().map(|b| (b.eref.clone(), 0)).collect();
    for tos in edges.values() {
        for to in tos.iter() {
            *indeg.get_mut(to).unwrap() += 1;
        }
    }

    let mut out: Vec<String> = Vec::new();
    let mut ready: Vec<Binding> = bindings
        .iter()
        .filter(|b| 0 == indeg[&b.eref])
        .cloned()
        .collect();

    while !ready.is_empty() {
        stable_sort_by(&mut ready, |b| (order_band(&b.order), b.pos));
        let nxt = ready.remove(0);
        out.push(nxt.eref.clone());
        for to in edges[&nxt.eref].clone() {
            let d = indeg.get_mut(&to).unwrap();
            *d -= 1;
            if 0 == *d {
                ready.push(byref[&to].clone());
            }
        }
    }

    if out.len() != bindings.len() {
        let stuck: Vec<String> = bindings
            .iter()
            .filter(|b| !out.contains(&b.eref))
            .map(|b| b.eref.clone())
            .collect();
        return fail(
            "plugin_order_cycle",
            &format!("before/after constraints cycle: {}", stuck.join(" -> ")),
            details(&[(
                "cycle",
                Value::List(stuck.iter().map(|r| Value::str(r)).collect()),
            )]),
        );
    }

    applypin(out, &edges, pin)
}

/// An integer, and only an integer: `true` and `"2"` are not bands.
pub fn order_band(block: &Value) -> i64 {
    block.get("band").as_int().unwrap_or(0)
}

/// Was a constraint stated? An absent value and an EMPTY LIST are both
/// no-constraint - and an empty list is TRUTHY in most languages, which is
/// exactly how this class of bug survives a reading.
pub fn order_declared(spec: &Value) -> bool {
    match spec {
        Value::Null => false,
        Value::List(l) => l.iter().any(|one| one.as_str() != Some("")),
        Value::Str(s) => !s.is_empty(),
        _ => true,
    }
}

/// One spelling or a LIST of them. A list fans out to the UNION of what
/// each names, so after: ['a','b'] means after BOTH, and the same instance
/// named twice - once by name, once by ref - is one edge.
pub fn order_targets(spec: &Value, nodes: &[Binding]) -> Vec<String> {
    let specs: Vec<Value> = match spec {
        Value::List(l) => l.clone(),
        other => vec![other.clone()],
    };
    let mut hit: Vec<String> = Vec::new();
    for one in specs.iter() {
        let one = match one.as_str() {
            Some(s) => s,
            None => continue,
        };
        for b in nodes.iter() {
            if hit.contains(&b.eref) {
                continue;
            }
            if b.eref == one || refname(&b.eref) == one {
                hit.push(b.eref.clone());
            }
        }
    }
    hit
}

/// A PIN IS NOT A CONSTRAINT (§7).
///
/// Constraints and bands are negotiable by definition - they are what
/// plugins and documents say they want, and the sort's job is to satisfy
/// them all. A pin is the host stating a structural invariant of its own
/// architecture, which is a different kind of claim and must not lose a
/// tie to a document.
///
/// So a pin PLACES the binding at the named end, and an ordering that
/// would move it away is `plugin_order_pinned` - rejected, not honoured
/// into a broken wrap.
fn applypin(
    order: Vec<String>,
    edges: &BTreeMap<String, Vec<String>>,
    pin: &Value,
) -> Result<Vec<String>, PluginError> {
    if pin.is_null() {
        return Ok(order);
    }

    let mut out = order;

    // SORTED, not insertion order. A pin map is data - it can arrive from
    // a host's own construction options in any order, and two names pinned
    // to the same end are order-sensitive (`{b:'first', a:'first'}` and
    // `{a:'first', b:'first'}` give different results). A BTreeMap is
    // sorted by construction, which is why `Value::Map` is one.
    for name in pin.keys() {
        let want = pin.get(&name);
        let idx = out.iter().position(|r| refname(r) == name);
        let idx = match idx {
            Some(i) => i,
            None => continue,
        };

        // `first`/`outermost` is index 0; `last`/`innermost` is the end.
        // §6.2 makes the first chain binding outermost, which is why the
        // vocabulary is positional and why the two spellings pair this
        // way.
        let wantfirst = matches!(want.as_str(), Some("first") | Some("outermost"));
        let eref = out.remove(idx);
        if wantfirst {
            out.insert(0, eref);
        } else {
            out.push(eref);
        }
    }

    // Now check that the placement did not break a constraint. This is the
    // half that makes a pin a rejection rather than an override: the host
    // wins on position, but it does not get to silently discard a
    // relationship a plugin declared.
    let at: BTreeMap<&String, usize> = out.iter().enumerate().map(|(i, r)| (r, i)).collect();
    for (from, tos) in edges.iter() {
        for to in tos.iter() {
            if at[from] <= at[to] {
                continue;
            }
            return fail(
                "plugin_order_pinned",
                &format!(
                    "a pin would move a binding an ordering constrains: {} must precede {}",
                    from, to
                ),
                details(&[("before", Value::str(from)), ("after", Value::str(to))]),
            );
        }
    }

    Ok(out)
}
