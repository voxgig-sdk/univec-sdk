// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/graph.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Whole-graph resolution (§11.4) - a phase, not a discovery.
//!
//! "Activate, and wait in `pending` if you must" is correct and, on its
//! own, produces a terrible experience: apply twenty instances against a
//! registry missing one thing and you get NINETEEN pending rows and no
//! statement of what is actually wrong.
//!
//! `resolve_graph` is a PURE FUNCTION of the registry and the intended
//! activation set. No callbacks run, no state changes, nothing is touched.
//! It answers for the whole graph at once which instances can be live, and
//! for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
//!
//! The failure mode being designed against is a famous one: OSGi's
//! resolver is correct and its diagnostics are legendarily unusable. A
//! resolver that says "blocked" without saying WHY has moved the problem
//! rather than solved it, so `why` is part of the contract and the corpus
//! pins its shape.

use std::collections::{BTreeMap, BTreeSet};

use super::capability::{matchvalue, resolve_capability};
use super::refs::canon;
use super::value::Value;
use super::version::satisfiesq;

pub fn resolve_graph(nodes: &Value) -> Value {
    let list = nodes.as_list().cloned().unwrap_or_default();
    let mut byref: BTreeMap<String, Value> = BTreeMap::new();
    for n in list.iter() {
        byref.insert(n.get("ref").as_str().unwrap_or("").to_string(), n.clone());
    }

    let mut resolved: BTreeSet<String> = BTreeSet::new();
    let mut blocked: BTreeMap<String, Value> = BTreeMap::new();

    // Fixed point: a node resolves when every mandatory requirement is met
    // by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
    // makes a provider that is itself blocked propagate, rather than each
    // node being judged against the raw registry.
    let mut moved = true;
    while moved {
        moved = false;
        for n in list.iter() {
            let eref = n.get("ref").as_str().unwrap_or("").to_string();
            if resolved.contains(&eref) {
                continue;
            }
            if firstunmet(n, &byref, &resolved).is_some() {
                continue;
            }
            resolved.insert(eref);
            moved = true;
        }
    }

    for n in list.iter() {
        let eref = n.get("ref").as_str().unwrap_or("").to_string();
        if resolved.contains(&eref) {
            continue;
        }
        if let Some(why) = firstunmet(n, &byref, &resolved) {
            blocked.insert(eref, why);
        }
    }

    let mut out = Value::map();
    out.set(
        "resolved",
        Value::List(resolved.iter().map(|r| Value::str(r)).collect()),
    );
    out.set(
        "blocked",
        Value::List(blocked.values().cloned().collect()),
    );
    out
}

/// The FIRST unmet requirement, with the most specific explanation
/// available. Order matters: "no provider at all" and "a provider at the
/// wrong version" are different problems and a reader must not have to
/// guess which they have.
fn firstunmet(
    node: &Value,
    byref: &BTreeMap<String, Value>,
    resolved: &BTreeSet<String>,
) -> Option<Value> {
    let requires = node.get("requires");
    for req in requires.as_list().cloned().unwrap_or_default().iter() {
        if req.get("optional").truthy() {
            continue;
        }
        let name = req.get("name");
        let all = graph_candidates(byref, &name);
        if all.is_empty() {
            return Some(unmet(node, &name, why_kind("absent")));
        }

        let ok = resolve_capability(req, &all);
        if !ok.is_empty() {
            // A provider exists and matches - but if none of them is
            // itself resolved, this node is blocked BEHIND it, and the
            // chain is the useful answer rather than "unmet".
            if ok
                .iter()
                .any(|c| resolved.contains(c.get("ref").as_str().unwrap_or("")))
            {
                continue;
            }
            let mut chain: Vec<String> = ok
                .iter()
                .map(|c| c.get("ref").as_str().unwrap_or("").to_string())
                .collect();
            chain.sort();
            let mut why = Value::map();
            why.set("kind", Value::str("blocked"));
            why.set(
                "chain",
                Value::List(chain.iter().map(|r| Value::str(r)).collect()),
            );
            return Some(unmet(node, &name, why));
        }

        // Providers exist and none matched. Say which test failed.
        let range = req.get("range");
        if !range.is_null() {
            let mut versions: Vec<String> = Vec::new();
            for c in all.iter() {
                let have = c.get("provides").get("version");
                if have.is_null() || !satisfiesq(&have, &range) {
                    versions.push(have.as_str().unwrap_or("(none)").to_string());
                }
            }
            if !versions.is_empty() {
                versions.sort();
                let mut why = Value::map();
                why.set("kind", Value::str("version"));
                why.set("range", range.clone());
                why.set(
                    "found",
                    Value::List(versions.iter().map(|v| Value::str(v)).collect()),
                );
                return Some(unmet(node, &name, why));
            }
        }

        let want = req.get("match");
        if !want.is_null() {
            for c in all.iter() {
                let attrs = c.get("provides").get("attrs");
                for k in want.keys() {
                    if attrs.has(&k) && matchvalue(&want.get(&k), &attrs.get(&k)) {
                        continue;
                    }
                    let mut why = Value::map();
                    why.set("kind", Value::str("match"));
                    why.set("failing", Value::str(&k));
                    why.set("want", want.get(&k));
                    why.set("found", attrs.get(&k));
                    return Some(unmet(node, &name, why));
                }
            }
        }

        return Some(unmet(node, &name, why_kind("absent")));
    }
    None
}

fn why_kind(kind: &str) -> Value {
    let mut why = Value::map();
    why.set("kind", Value::str(kind));
    why
}

fn unmet(node: &Value, name: &Value, why: Value) -> Value {
    let mut out = Value::map();
    out.set("ref", node.get("ref"));
    out.set("unmet", name.clone());
    out.set("why", why);
    out
}

fn graph_candidates(byref: &BTreeMap<String, Value>, name: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    // A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned
    // it here. Considering only declared capabilities made `resolve`
    // answer `absent` about a provider sitting right there and live -
    // section 11.4's job is explaining the graph the runtime reconciles,
    // and it was explaining a different one.
    let asref = canon(name.as_str().unwrap_or(""));
    // The map is sorted, so the walk is - which is the whole reason it is
    // a BTreeMap.
    for node in byref.values() {
        // The ref match WINS OUTRIGHT for that node, as at runtime: one
        // candidate, not two, for a node both named `b` and providing `b`.
        if node.get("ref").as_str().unwrap_or("") == asref {
            let mut cand = Value::map();
            cand.set("ref", node.get("ref"));
            cand.set(
                "pos",
                if node.has("pos") { node.get("pos") } else { Value::Num(0.0) },
            );
            let mut prov = Value::map();
            prov.set("name", name.clone());
            cand.set("provides", prov);
            out.push(cand);
            continue;
        }
        for prov in node.get("provides").as_list().cloned().unwrap_or_default() {
            if !prov.get("name").same(name) {
                continue;
            }
            let mut cand = Value::map();
            cand.set("ref", node.get("ref"));
            cand.set(
                "pos",
                if node.has("pos") {
                    node.get("pos")
                } else {
                    Value::Num(0.0)
                },
            );
            cand.set("provides", prov.clone());
            out.push(cand);
        }
    }
    out
}
