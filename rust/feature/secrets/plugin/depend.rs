// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/depend.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

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

pub fn restartsonloss(req: &Value) -> bool {
    let policy = req.get("policy");
    policy.as_str().unwrap_or("static") != "dynamic"
}

pub fn gatesactivation(req: &Value) -> bool {
    !matches!(req.get("optional"), Value::Bool(true))
}

pub fn restartcausing(req: &Value) -> bool {
    gatesactivation(req) || restartsonloss(req)
}

pub struct Node {
    pub eref: String,
    pub provides: Vec<String>,
    pub requires: Vec<Value>,
}

pub fn dependencycycle(nodes: &[Node]) -> Option<Vec<String>> {
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
