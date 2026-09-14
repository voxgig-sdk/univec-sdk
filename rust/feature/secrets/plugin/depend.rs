// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/depend.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Dependency cardinality, policy, and the restart graph (§11.3).
//!
//! TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
//! because only it knows what it can cope with:
//!
//! ```text
//!                | static (default)          | dynamic
//!   -------------|---------------------------|--------------------------
//!   mandatory    | unmet -> pending;         | unmet -> pending;
//!   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
//!                |          recursively      |          notified
//!   -------------|---------------------------|--------------------------
//!   optional:true| never gates activation;   | never gates activation;
//!                | a change deactivates and  | a change is a
//!                | reactivates               | notification, nothing else
//! ```
//!
//! `dynamic` means the plugin has said, IN WRITING, that it can survive
//! its provider being swapped underneath it. It is not the default because
//! most plugins cannot, and the cost of wrongly assuming they can is a
//! live instance holding a dead reference.
//!
//! The rebinding-preference axis is deliberately omitted. OSGi has
//! reluctant vs greedy and it is a knob every author must understand to
//! read anyone else's component; we take always-reluctant. Three axes were
//! more than the model can carry across twenty ports.

use std::collections::{BTreeMap, BTreeSet};

use super::types::{details, fail, PluginError};
use super::value::Value;
use super::refs::canon;

/// A bare string is shorthand for `{name}`.
pub fn normrequire(raw: &Value) -> Value {
    if let Value::Str(_) = raw {
        let mut out = Value::map();
        out.set("name", raw.clone());
        return out;
    }
    match raw {
        Value::Map(_) => raw.clone(),
        _ => Value::map(),
    }
}

/// The requirements a definition declared, normalized.
///
/// BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
///
/// The instance-level `policy` and `optional` list are how a DOCUMENT
/// states the axis without editing the definition, and they apply to every
/// requirement. The per-requirement form is the one §11.1's object syntax
/// exists for, and it is strictly more expressive: an instance that is
/// `static` on its store and `dynamic` on its metrics cannot be written at
/// all at the instance level.
///
/// `optional` unions rather than overriding - both spellings are
/// statements that this requirement need not gate activation, and there is
/// no reading under which one of them means "actually, mandatory".
pub fn requirements(options: &Value) -> Vec<Value> {
    let raw = options.get("requires");
    let marked = options.get("optional");
    let fallback = options.get("policy");

    let mut out = Vec::new();
    for item in raw.as_list().cloned().unwrap_or_default().iter() {
        let mut req = normrequire(item);
        let ismarked = marked
            .as_list()
            .map(|l| l.iter().any(|m| m.same(&req.get("name"))))
            .unwrap_or(false);
        if req.get("optional").truthy() || ismarked {
            req.set("optional", Value::Bool(true));
        }
        if req.get("policy").is_null() && !fallback.is_null() {
            req.set("policy", fallback.clone());
        }
        out.push(req);
    }
    out
}

/// Does losing this requirement's SELECTED provider restart the consumer?
/// The mandatory ones under `static`, and the `static` optional ones -
/// both make a capability change deactivate and reactivate. `dynamic`
/// never restarts.
pub fn restartsonloss(req: &Value) -> bool {
    let policy = req.get("policy");
    policy.as_str().unwrap_or("static") != "dynamic"
}

/// Does an unmet requirement keep the consumer out of `live`?
///
/// Cardinality alone decides this, NOT policy. `dynamic` is a statement
/// about surviving a SWAP, not about starting without the thing at all - a
/// mandatory-dynamic consumer still waits in `pending` for its first
/// provider.
pub fn gatesactivation(req: &Value) -> bool {
    !matches!(req.get("optional"), Value::Bool(true))
}

/// Edges that can cause a restart, which is exactly the set a cycle must
/// be detected over (§11.3).
///
/// ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
/// exclusion was for: two plugins that optionally and dynamically consume
/// each other's capabilities both activate happily, neither gates on the
/// other, and each is merely notified when the other appears. Nothing
/// restarts, so nothing oscillates.
///
/// An earlier draft of §11.3 excluded EVERY optional edge and thereby
/// admitted the non-terminating case it was trying to permit.
pub fn restartcausing(req: &Value) -> bool {
    gatesactivation(req) || restartsonloss(req)
}

/// One node of the requirement graph, as plain data for the pure detector.
pub struct Node {
    pub eref: String,
    pub provides: Vec<String>,
    pub requires: Vec<Value>,
}

/// A cycle through restart-causing requirements is
/// `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
/// because the failure it describes is a non-terminating reconcile and the
/// only safe time to report that is before it starts.
///
/// The graph is over capabilities, not refs: an edge runs from a consumer
/// to EVERY node that provides what it needs, because any of them could be
/// the one selected and a cycle through any is a cycle. A node also
/// satisfies its own name as a ref (§11.1), which is why the ref is a
/// provider of itself here.
pub fn dependencycycle(nodes: &[Node]) -> Option<Vec<String>> {
    // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    // matched differently - a capability by its exact name, a ref through
    // the canonical spelling (section 4 rule 5) - and one map keyed by
    // both can only do one of them. Keyed by both and looked up raw, as
    // this was, a cycle spelled `a$`/`b$` found no providers and EVADED
    // the load-time check that exists to catch a non-terminating
    // reconcile.
    let mut bycap: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut isref: BTreeSet<String> = BTreeSet::new();
    for n in nodes.iter() {
        isref.insert(n.eref.clone());
        for cap in n.provides.iter() {
            bycap.entry(cap.clone()).or_default().push(n.eref.clone());
        }
    }

    let mut edges: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for n in nodes.iter() {
        let mut out: Vec<String> = Vec::new();
        for req in n.requires.iter() {
            if !restartcausing(req) {
                continue;
            }
            let name = req.get("name");
            let name = name.as_str().unwrap_or("");
            let mut from: Vec<String> = bycap.get(name).cloned().unwrap_or_default();
            // A node satisfies its own name AS A REF (section 11.1),
            // canonically - exactly what `providersof` does at runtime.
            // `canon` hands back a name no ref could have unchanged, and
            // no instance ref can equal one, so it is the tolerant test.
            let asref = canon(name);
            if isref.contains(&asref) && !from.contains(&asref) {
                from.push(asref);
            }
            for p in from.iter() {
                if *p != n.eref && !out.contains(p) {
                    out.push(p.clone());
                }
            }
        }
        out.sort();
        edges.insert(n.eref.clone(), out);
    }

    // Iterative DFS with an explicit stack: twenty ports, and several of
    // them have no recursion budget worth relying on.
    const WHITE: u8 = 0;
    const GREY: u8 = 1;
    const BLACK: u8 = 2;
    let mut colour: BTreeMap<String, u8> =
        nodes.iter().map(|n| (n.eref.clone(), WHITE)).collect();

    let starts: Vec<String> = edges.keys().cloned().collect();
    for start in starts.iter() {
        if WHITE != colour[start] {
            continue;
        }

        let mut path: Vec<String> = vec![start.clone()];
        let mut stack: Vec<(String, usize)> = vec![(start.clone(), 0)];
        colour.insert(start.clone(), GREY);

        while !stack.is_empty() {
            let top = stack.last_mut().unwrap();
            let outs = &edges[&top.0];
            if outs.len() <= top.1 {
                let done = top.0.clone();
                colour.insert(done, BLACK);
                stack.pop();
                path.pop();
                continue;
            }
            let nxt = outs[top.1].clone();
            top.1 += 1;
            if GREY == colour[&nxt] {
                // Report the cycle itself, not the walk that found it.
                let at = path.iter().position(|p| *p == nxt).unwrap_or(0);
                let mut cycle: Vec<String> = path[at..].to_vec();
                cycle.push(nxt);
                return Some(cycle);
            }
            if BLACK == colour[&nxt] {
                continue;
            }
            colour.insert(nxt.clone(), GREY);
            path.push(nxt.clone());
            stack.push((nxt, 0));
        }
    }
    None
}

/// Raise on a cycle, naming it. Separate from the detector so the detector
/// stays pure and corpus-testable.
pub fn checkcycle(nodes: &[Node]) -> Result<(), PluginError> {
    match dependencycycle(nodes) {
        None => Ok(()),
        Some(cycle) => fail(
            "plugin_dependency_cycle",
            &format!("requirements cycle: {}", cycle.join(" -> ")),
            details(&[(
                "cycle",
                Value::List(cycle.iter().map(|r| Value::str(r)).collect()),
            )]),
        ),
    }
}
