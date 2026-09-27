// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/capability.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use super::types::stable_sort_by;
use super::value::Value;
use super::version::{satisfiesq, version_parts};

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
