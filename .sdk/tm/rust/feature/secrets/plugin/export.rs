// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/export.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use super::refs::{canon, parse_ref, refname};
use super::types::{details, fail, PluginError};
use super::value::Value;

/// One published value: which instance, under which key.
#[derive(Clone)]
pub struct Exported {
    pub eref: String,
    pub key: String,
    pub value: Value,
}

pub fn resolve_export(spec: &str, exported: &[Exported]) -> Result<Value, PluginError> {
    let cut = match spec.rfind('/') {
        Some(c) => c,
        None => {
            return fail(
                "plugin_export_ambiguous",
                &format!("export spec needs a key: {}", spec),
                details(&[("spec", Value::str(spec))]),
            )
        }
    };
    let head = &spec[..cut];
    let key = &spec[cut + 1..];

    // A fully qualified ref: exactly one answer or none.
    let want = canon(head);
    for e in exported.iter() {
        if e.eref == want && e.key == key {
            return Ok(e.value.clone());
        }
    }

    // An alias: the name, not a ref. Look at every instance of it.
    let byname: Vec<&Exported> = exported
        .iter()
        .filter(|e| refname(&e.eref) == head && e.key == key)
        .collect();
    if byname.is_empty() {
        return Ok(Value::Null);
    }

    for e in byname.iter() {
        let parsed = parse_ref(&Value::str(&e.eref))?;
        if parsed.get("tag").as_str().unwrap_or("").is_empty() {
            return Ok(e.value.clone());
        }
    }

    if 1 == byname.len() {
        return Ok(byname[0].value.clone());
    }

    let mut refs: Vec<String> = byname.iter().map(|e| e.eref.clone()).collect();
    refs.sort();
    fail(
        "plugin_export_ambiguous",
        &format!(
            "alias {} matches {} instances: {}",
            spec,
            refs.len(),
            refs.join(", ")
        ),
        // `spec` is not one of §12's fields, so it does not render - the
        // same detail map every other port builds, and the same message.
        details(&[
            ("spec", Value::str(spec)),
            (
                "refs",
                Value::List(refs.iter().map(|r| Value::str(r)).collect()),
            ),
        ]),
    )
}
