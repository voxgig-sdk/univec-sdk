// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/env.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Environment overrides (§9.5) - level 7 of the ladder.
//!
//! One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
//!
//! ```text
//!   VOXGIG_PLUGIN_PROFILE            the profile name
//!   VOXGIG_PLUGIN_<REF>_<PATH>       one option
//!   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
//! ```
//!
//! THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
//! OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` ->
//! `_`. But `_` is legal in a name and in a tag, and the mapping folds
//! case, so `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
//!
//! Rather than restrict a grammar the rest of the stack already uses, the
//! host DETECTS THE COLLISION: it encodes every ref it holds, and a key
//! two refs claim is `plugin_env_ambiguous`, naming both.

use std::collections::BTreeMap;

use super::refs::{canon_ref, refname};
use super::types::{details, fail, stable_sort_by, PluginError};
use super::value::{self, Value};

pub const ENV_PREFIX: &str = "VOXGIG_PLUGIN_";

/// `retry$fast` -> `RETRY__FAST`.
pub fn encode_ref(eref: &str) -> String {
    eref.replace('$', "__").replace('.', "_").to_uppercase()
}

pub fn apply_env(input: &Value) -> Result<Value, PluginError> {
    let env = input.get("env");
    let reserved = input.get("reserved");

    let mut refs: Vec<String> = Vec::new();
    for r in input.get("refs").as_list().cloned().unwrap_or_default().iter() {
        refs.push(canon_ref(r)?);
    }

    let mut out = Value::map();
    out.set("options", Value::map());
    out.set("active", Value::List(Vec::new()));
    out.set("inactive", Value::List(Vec::new()));

    // Encode every ref the host holds, and refuse a key that two of them
    // claim. Done up front so the collision is reported even when no
    // environment variable exercises it - a latent ambiguity is still an
    // ambiguity, and finding it at deploy time is the failure this exists
    // to prevent.
    let mut byencoded: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for r in refs.iter() {
        byencoded.entry(encode_ref(r)).or_default().push(r.clone());
    }
    for (e, group) in byencoded.iter() {
        if group.len() <= 1 {
            continue;
        }
        let mut pair = group.clone();
        pair.sort();
        return fail(
            "plugin_env_ambiguous",
            &format!(
                "refs collide in the environment encoding as {}: {}",
                e,
                pair.join(", ")
            ),
            details(&[(
                "refs",
                Value::List(pair.iter().map(|r| Value::str(r)).collect()),
            )]),
        );
    }

    // Longest encoded ref first, so `retry$fast` wins over `retry` on
    // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    let mut encoded: Vec<String> = byencoded.keys().cloned().collect();
    stable_sort_by(&mut encoded, |e| -(e.len() as i64));

    for key in env.keys() {
        if !key.starts_with(ENV_PREFIX) {
            continue;
        }
        let rest = &key[ENV_PREFIX.len()..];

        if "PROFILE" == rest {
            out.set("profile", env.get(&key));
            continue;
        }

        if "ACTIVE" == rest || "INACTIVE" == rest {
            let field = if "ACTIVE" == rest { "active" } else { "inactive" };
            let mut list = out.get(field).as_list().cloned().unwrap_or_default();
            for raw in env_split(&env.get(&key)) {
                let eref = canon_ref(&Value::str(&raw))?;
                // The reservation covers EVERY input layer (§9.1).
                // VOXGIG_PLUGIN_INACTIVE=station is easier to set than
                // editing a config file, and INACTIVE has the final word -
                // so guarding documents alone would leave the one lever
                // this mechanism exists to deny wide open.
                env_checkreserved(&eref, &reserved)?;
                list.push(Value::str(&eref));
            }
            out.set(field, Value::List(list));
            continue;
        }

        let enc = encoded
            .iter()
            .find(|e| rest == e.as_str() || rest.starts_with(&format!("{}_", e)));
        let enc = match enc {
            Some(e) => e.clone(),
            None => continue, // not for any ref this host holds
        };

        let eref = byencoded[&enc][0].clone();
        env_checkreserved(&eref, &reserved)?;

        if rest == enc {
            continue; // a ref with no path sets nothing
        }

        let path: Vec<String> = rest[enc.len() + 1..]
            .to_lowercase()
            .split('_')
            .map(|s| s.to_string())
            .collect();

        let mut options = out.get("options");
        if options.get(&eref).as_map().is_none() {
            options.set(&eref, Value::map());
        }
        if let Value::Map(m) = &mut options {
            if let Some(node) = m.get_mut(&eref) {
                set_path(node, &path, env_parsevalue(&env.get(&key)));
            }
        }
        out.set("options", options);
    }

    Ok(out)
}

/// Write a value at a dotted path, creating maps on the way down. A map is
/// REPLACED when the path needs to descend through a scalar - the same
/// rule every other port applies, and the reason it is written out here is
/// that rust cannot express it as a chain of `//=`.
fn set_path(node: &mut Value, path: &[String], value: Value) {
    if 1 == path.len() {
        node.set(&path[0], value);
        return;
    }
    let key = &path[0];
    if node.get(key).as_map().is_none() {
        node.set(key, Value::map());
    }
    if let Value::Map(m) = node {
        if let Some(child) = m.get_mut(key) {
            set_path(child, &path[1..], value);
        }
    }
}

fn env_split(value: &Value) -> Vec<String> {
    let text = value.as_str().unwrap_or("");
    text.split(',')
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect()
}

fn env_checkreserved(eref: &str, reserved: &Value) -> Result<(), PluginError> {
    let list = match reserved.as_list() {
        Some(l) if !l.is_empty() => l,
        _ => return Ok(()),
    };
    let name = refname(eref);
    if !list.iter().any(|r| r.as_str() == Some(name.as_str())) {
        return Ok(());
    }
    fail(
        "plugin_ref_reserved",
        &format!("ref is reserved by the host: {}", eref),
        details(&[("ref", Value::str(eref))]),
    )
}

/// Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
/// `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
/// looks like rather than a parse error.
fn env_parsevalue(value: &Value) -> Value {
    match value.as_str() {
        Some(text) => value::parse(text).unwrap_or_else(|_| value.clone()),
        None => value.clone(),
    }
}
