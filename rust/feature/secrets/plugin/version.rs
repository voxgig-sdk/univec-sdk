// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/version.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

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

pub fn version_parts(text: &str) -> Vec<i64> {
    text.split('.')
        .map(|p| p.parse::<i64>().unwrap_or(0))
        .collect()
}
