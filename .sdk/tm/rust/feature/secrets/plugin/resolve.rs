// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/resolve.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

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

pub fn resolve_from(from: &Value) -> Vec<Value> {
    vec![from.clone()]
}
