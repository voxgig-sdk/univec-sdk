// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/resolve.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Dynamic resolution (§10.2) - name to candidate module ids.
//!
//! PURE. It returns the ids a host WOULD try, in order; it does not load
//! anything. That separation is what lets the corpus pin resolution in
//! every language including those with no dynamic loading at all, and it
//! is why §15.4 puts real module loading in per-port integration tests
//! rather than here.

use super::value::Value;

pub fn default_sources() -> Vec<Value> {
    let mut src = Value::map();
    src.set("kind", Value::str("module"));
    src.set(
        "prefix",
        Value::List(vec![
            Value::str("@voxgig/plugin-"),
            Value::str("voxgig-plugin-"),
            Value::str("plugin-"),
            Value::str(""),
        ]),
    );
    vec![src]
}

pub fn resolve_candidates(name: &str, sources: &Value) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();

    // A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
    // already a package id; prefixing it produces
    // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    if name.starts_with('@') {
        return vec![name.to_string()];
    }

    let given = sources.as_list().cloned().unwrap_or_default();
    let list = if given.is_empty() {
        default_sources()
    } else {
        given
    };

    for src in list.iter() {
        match src.get("kind").as_str() {
            Some("module") => {
                let prefixes = src.get("prefix");
                let mut list = prefixes.as_list().cloned().unwrap_or_default();
                if list.is_empty() {
                    list = vec![Value::str("")];
                }
                for p in list.iter() {
                    let id = format!("{}{}", p.as_str().unwrap_or(""), name);
                    if !out.contains(&id) {
                        out.push(id);
                    }
                }
            }
            Some("path") => {
                let dir = src.get("dir");
                let dir = dir.as_str().unwrap_or("").trim_end_matches('/');
                let id = format!("{}/{}", dir, name);
                if !out.contains(&id) {
                    out.push(id);
                }
            }
            _ => {}
        }
    }

    out
}

/// A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name with
/// a letter or `@`, so `./local/thing` is not a ref and never reaches
/// candidate generation - seneca allows a path where a plugin name goes,
/// and this design deliberately does not, because a ref is an ADDRESS
/// WITHIN A HOST and a path is a LOCATION ON A DISK.
pub fn resolve_from(from: &Value) -> Vec<Value> {
    vec![from.clone()]
}
