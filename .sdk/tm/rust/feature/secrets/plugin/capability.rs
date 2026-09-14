// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/capability.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Capabilities (§11.1).
//!
//! A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
//! dependency on something that can do the job, and which instance is
//! doing it is exactly the configuration detail a plugin must not care
//! about.
//!
//! But A BINDING IS TO AN INSTANCE, not to a capability, which is what
//! decides behaviour when the bound provider leaves while another match
//! remains.

use super::types::stable_sort_by;
use super::value::Value;
use super::version::{satisfiesq, version_parts};

/// Rank the matching live providers and return them best-first: highest
/// `version`, then LOWEST `priority` (default 0), then declaration
/// position `pos` ascending.
///
/// `priority` is a field on the capability rather than §7's `order` band,
/// because bands live on POINT BINDINGS: a provider may have several
/// bindings with different bands, or none at all, so a rank reaching for
/// one would be undefined in the common case.
///
/// Without a total rank, "any provider satisfies" is true of the GRAPH and
/// useless to the PLUGIN - two ports could bind different `store`
/// instances, both resolve green, and behave differently, which is
/// precisely the divergence a shared corpus exists to catch.
pub fn resolve_capability(req: &Value, candidates: &[Value]) -> Vec<Value> {
    let mut hits: Vec<Value> = candidates
        .iter()
        .filter(|c| matches(req, &c.get("provides")))
        .cloned()
        .collect();
    stable_sort_by(&mut hits, rank_key);
    hits
}

/// An ABSENT version sorts LAST, whatever the other is - "no version"
/// loses to every version rather than being read as 0.0.0. The leading
/// flag is what expresses that in a sort KEY rather than a comparator.
pub fn rank_key(cand: &Value) -> (i64, Vec<i64>, f64, f64) {
    let prov = cand.get("provides");
    let version = prov.get("version");
    let parts = match version.as_str() {
        Some(text) => version_parts(text).iter().map(|n| -n).collect(),
        None => vec![0, 0, 0],
    };
    (
        if version.as_str().is_some() { 0 } else { 1 },
        parts,
        prov.get("priority").as_num().unwrap_or(0.0),
        cand.get("pos").as_num().unwrap_or(0.0),
    )
}

pub fn matches(req: &Value, prov: &Value) -> bool {
    if !req.get("name").same(&prov.get("name")) {
        return false;
    }

    let range = req.get("range");
    if !range.is_null() {
        let version = prov.get("version");
        if version.is_null() {
            return false;
        }
        if !satisfiesq(&version, &range) {
            return false;
        }
    }

    // `match` is checked against the provider's `attrs`, key by key. A key
    // the provider does not carry is a miss, not a pass: a requirement
    // asking for `transactional: true` must not be satisfied by a provider
    // that never said.
    let want = req.get("match");
    if !want.is_null() {
        let attrs = prov.get("attrs");
        for key in want.keys() {
            if !attrs.has(&key) {
                return false;
            }
            if !matchvalue(&want.get(&key), &attrs.get(&key)) {
                return false;
            }
        }
    }

    true
}

/// PARTIAL MATCH, RECURSING INTO MAPS (§11.1).
///
/// §11.1 defines `match` as "a partial match against `attrs`, with exactly
/// the semantics voxgig/struct and the omni corpus already define for
/// `match` - every leaf in the requirement must be present and equal in
/// the capability, keys not mentioned are not checked."
///
/// Equality is by JSON TYPE as well as value: `transactional: 1` does not
/// satisfy `transactional: true`. RUST NEEDS NO GUARD FOR THAT - `Bool`
/// and `Num` are different variants and no coercion exists between them.
/// The dynamic ports each need one, and `capability/match` pins the
/// behaviour for every port rather than trusting a language's `==`.
///
/// A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
pub fn matchvalue(want: &Value, got: &Value) -> bool {
    if let Value::Map(w) = want {
        let g = match got.as_map() {
            Some(g) => g,
            None => return false,
        };
        return w
            .iter()
            .all(|(k, v)| g.get(k).map(|o| matchvalue(v, o)).unwrap_or(false));
    }

    if let Value::List(w) = want {
        let g = match got.as_list() {
            Some(g) => g,
            None => return false,
        };
        return w.len() == g.len() && w.iter().zip(g.iter()).all(|(a, b)| matchvalue(a, b));
    }

    want.same(got)
}
