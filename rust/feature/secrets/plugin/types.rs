// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/types.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use super::value::Value;

pub const STATUSES: [&str; 7] = [
    "declared", "loaded", "pending", "live", "failed", "loading", "closing",
];

pub const DETAIL_ORDER: [&str; 16] = [
    "host", "ref", "name", "tag", "point", "key", "capability", "range", "version", "match",
    "candidates", "cycle", "holders", "refs", "path", "cause",
];

/// `plugin/<code>: <text> [<key>=<value> ...]`
///
/// Values render as COMPACT JSON, so a value containing a space or a
/// bracket cannot break the parse, and a list renders as a JSON array. The
/// bracket is absent entirely when no field applies.
pub fn formaterror(code: &str, text: &str, details: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    for key in DETAIL_ORDER.iter() {
        if !details.has(key) {
            continue;
        }
        parts.push(format!("{}={}", key, details.get(key).json()));
    }
    let tail = if parts.is_empty() {
        String::new()
    } else {
        format!(" [{}]", parts.join(" "))
    };
    format!("plugin/{}: {}{}", code, text, tail)
}

#[derive(Clone, Debug)]
pub struct PluginError {
    pub code: String,
    pub text: String,
    pub details: Value,
    pub message: String,
}

impl PluginError {
    pub fn new(code: &str, text: &str, details: Value) -> PluginError {
        PluginError {
            code: code.to_string(),
            text: text.to_string(),
            message: formaterror(code, text, &details),
            details,
        }
    }

    /// An error a PLUGIN raised that carries no §12 code. `Host::run`
    /// wraps exactly these and leaves coded ones alone, because the code
    /// is the error's identity.
    pub fn bare(text: &str) -> PluginError {
        PluginError {
            code: String::new(),
            text: text.to_string(),
            details: Value::Null,
            message: text.to_string(),
        }
    }
}

impl std::fmt::Display for PluginError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::fmt::Debug for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.json())
    }
}

pub fn fail<T>(code: &str, text: &str, details: Value) -> Result<T, PluginError> {
    Err(PluginError::new(code, text, details))
}

pub fn codeof(err: &PluginError) -> &str {
    err.code.as_str()
}

pub fn details(pairs: &[(&str, Value)]) -> Value {
    let mut out = Value::map();
    for (k, v) in pairs {
        out.set(k, v.clone());
    }
    out
}

pub fn stable_sort_by<T, K, F>(list: &mut [T], keyof: F)
where
    F: Fn(&T) -> K,
    K: PartialOrd,
{
    list.sort_by(|a, b| {
        let ka = keyof(a);
        let kb = keyof(b);
        ka.partial_cmp(&kb).unwrap_or(std::cmp::Ordering::Equal)
    });
}
