// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/types.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Shared types. Deliberately small: the design's §19 budget says the
//! library owns naming, configuration, lifecycle, ordering, binding and
//! teardown, and nothing else.
//!
//! RUST FOLLOWS GO'S ONE DELIBERATE CHANGE (§18, P4): errors are RETURNED,
//! not raised. Every fallible signature is `Result<_, PluginError>`, and
//! the corpus compares by CODE, which survives the change intact.

use super::value::Value;

/// §5.1's seven statuses, and no more. A port that adds an eighth is
/// diverging. `loading` and `closing` are observable only from inside a
/// callback or from another thread.
pub const STATUSES: [&str; 7] = [
    "declared", "loaded", "pending", "live", "failed", "loading", "closing",
];

/// §12's detail fields, IN THIS FIXED ORDER.
///
/// The order is part of the contract, not a formatting preference. An
/// earlier draft named six fields while other sections promised
/// diagnostics that had nowhere to go, which would have left each port
/// inventing its own order and breaking message parity.
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

/// Every error carries a §12 code. Ports compare by CODE and never by
/// message: wording is a port's own business, and pinning the words would
/// make every translation a corpus change. The FORMAT, however, is pinned
/// - a parseable message is what makes a log searchable across twenty
/// languages.
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

/// The §12 code of an error, or "" for one this library did not raise.
pub fn codeof(err: &PluginError) -> &str {
    err.code.as_str()
}

/// A detail map, spelled once rather than at forty call sites.
pub fn details(pairs: &[(&str, Value)]) -> Value {
    let mut out = Value::map();
    for (k, v) in pairs {
        out.set(k, v.clone());
    }
    out
}

/// STABLE sort by a computed key. `sort_by` in the standard library is
/// already stable, which is what the canonical's comparators need where
/// they fall through to a `pos` or ref tie-break.
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
