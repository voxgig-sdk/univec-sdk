// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/version.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Versions and ranges (§11.2).
//!
//! TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
//! concrete version. A requirement declares `range`. A requirement is
//! satisfied when the names match, the `match` passes, and:
//!
//!   the provider's `version` falls inside the requirement's `range`.
//!
//! That is the whole rule. There is no third field and no second
//! comparison - an earlier draft added a provider-side `compat` range,
//! which left three values and no statement of how they combine, and three
//! defensible readings of one declaration is worse than the ambiguity it
//! was introduced to fix.

use super::types::{details, fail, PluginError};
use super::value::Value;

/// A COMPONENT IS BOUNDED, and the bound is the model's, not the host
/// language's. Rust's `u64` and JavaScript's `Number` disagree past 2**53,
/// so `9223372036854775808.0.0` parsed to an exact value in one and a
/// rounded one in the other. 2**31-1 is the smallest bound every target
/// language holds exactly, which makes it the model's.
pub const COMPONENT_MAX: u64 = 2147483647;

fn component(digits: &str, whole: &str, field: &str) -> Result<u64, PluginError> {
    // A component too long for u64 is out of range by definition - the
    // parse failure and the bound check are the same answer, so they give
    // the same code.
    let value: u64 = match digits.parse() {
        Ok(v) => v,
        Err(_) => COMPONENT_MAX + 1,
    };
    if COMPONENT_MAX < value {
        return fail(
            "plugin_bad_range",
            &format!("version component out of range in {}: {}", whole, digits),
            details(&[(field, Value::str(whole))]),
        );
    }
    Ok(value)
}

/// `1`, `1.2` or `1.2.3`, fully anchored. Nothing else - and there is no
/// regex here, so "anchored" is what the code does rather than what an
/// engine was asked for.
fn parts(text: &str, whole: &str, field: &str) -> Option<Result<[u64; 3], PluginError>> {
    let mut out = [0u64; 3];
    let pieces: Vec<&str> = text.split('.').collect();
    if pieces.is_empty() || 3 < pieces.len() {
        return None;
    }
    for (i, piece) in pieces.iter().enumerate() {
        if piece.is_empty() || !piece.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        match component(piece, whole, field) {
            Ok(v) => out[i] = v,
            Err(e) => return Some(Err(e)),
        }
    }
    Some(Ok(out))
}

/// Two forms and no more (§11.2):
///
///   '2.1'    >= 2.1.0 and < 3.0.0
///   '~2.1'   >= 2.1.0 and < 2.2.0
pub fn parse_range(range: &Value) -> Result<Value, PluginError> {
    let text = match range.as_str() {
        Some(s) if !s.is_empty() => s,
        _ => {
            return fail(
                "plugin_bad_range",
                &format!("invalid range: {}", range.json()),
                details(&[("range", range.clone())]),
            )
        }
    };

    let tilde = text.starts_with('~');
    let body = if tilde { &text[1..] } else { text };

    let got = match parts(body, text, "range") {
        Some(Ok(p)) => p,
        Some(Err(e)) => return Err(e),
        None => {
            return fail(
                "plugin_bad_range",
                &format!("invalid range: {}", text),
                details(&[("range", range.clone())]),
            )
        }
    };

    let lo = Value::List(vec![
        Value::Num(got[0] as f64),
        Value::Num(got[1] as f64),
        Value::Num(got[2] as f64),
    ]);
    let hi = if tilde {
        Value::List(vec![
            Value::Num(got[0] as f64),
            Value::Num((got[1] + 1) as f64),
            Value::Num(0.0),
        ])
    } else {
        Value::List(vec![
            Value::Num((got[0] + 1) as f64),
            Value::Num(0.0),
            Value::Num(0.0),
        ])
    };

    let mut out = Value::map();
    out.set("lo", lo);
    out.set("hi", hi);
    Ok(out)
}

pub fn parse_version(version: &Value) -> Result<[u64; 3], PluginError> {
    let text = match version.as_str() {
        Some(s) => s,
        None => {
            return fail(
                "plugin_bad_range",
                &format!("invalid version: {}", version.json()),
                details(&[("version", version.clone())]),
            )
        }
    };
    match parts(text, text, "version") {
        Some(Ok(p)) => Ok(p),
        Some(Err(e)) => Err(e),
        None => fail(
            "plugin_bad_range",
            &format!("invalid version: {}", text),
            details(&[("version", version.clone())]),
        ),
    }
}

/// The one satisfaction predicate: lo <= version < hi.
pub fn satisfies(version: &Value, range: &Value) -> Result<bool, PluginError> {
    let v = parse_version(version)?;
    let r = parse_range(range)?;
    let lo = triple(&r.get("lo"));
    let hi = triple(&r.get("hi"));
    Ok(v >= lo && v < hi)
}

/// satisfies for the internal callers that treat an unparseable version or
/// range as "does not satisfy" - Capability and Graph, both of which run
/// over data the corpus has already admitted.
pub fn satisfiesq(version: &Value, range: &Value) -> bool {
    satisfies(version, range).unwrap_or(false)
}

fn triple(value: &Value) -> [u64; 3] {
    [
        value.at(0).as_num().unwrap_or(0.0) as u64,
        value.at(1).as_num().unwrap_or(0.0) as u64,
        value.at(2).as_num().unwrap_or(0.0) as u64,
    ]
}

/// The version triple as a comparable key, for the capability rank.
pub fn version_parts(text: &str) -> Vec<i64> {
    text.split('.')
        .map(|p| p.parse::<i64>().unwrap_or(0))
        .collect()
}
