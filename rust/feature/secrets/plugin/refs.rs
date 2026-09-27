// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/refs.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use super::types::{details, fail, PluginError};
use super::value::Value;

pub const REF_MAX: usize = 1024;

/// §4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
pub fn check_name(name: &Value) -> bool {
    let text = match name.as_str() {
        Some(s) => s,
        None => return false,
    };
    if text.is_empty() || REF_MAX < text.chars().count() {
        return false;
    }
    let mut chars = text.chars();
    let first = chars.next().unwrap();
    if !(first.is_ascii_alphabetic() || '@' == first) {
        return false;
    }
    chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '~' | '_' | '-' | '/'))
}

pub fn check_tag(tag: &Value) -> bool {
    let text = match tag.as_str() {
        Some(s) => s,
        None => return false,
    };
    // The empty tag is an ordinary tag (§4 rule 2). The single-instance
    // case writes no tag and never learns tags exist.
    if text.is_empty() {
        return true;
    }
    if REF_MAX < text.chars().count() {
        return false;
    }
    text.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '~' | '_' | '-'))
}

pub fn parse_ref(value: &Value) -> Result<Value, PluginError> {
    let text = match value.as_str() {
        Some(s) => s,
        None => return fail("plugin_bad_name", "ref must be a string", Value::Null),
    };

    let (name, tag) = match text.find('$') {
        Some(cut) => (&text[..cut], &text[cut + 1..]),
        None => (text, ""),
    };
    let namev = Value::str(name);
    let tagv = Value::str(tag);

    if !check_name(&namev) {
        return fail(
            "plugin_bad_name",
            &format!("invalid plugin name: {}", name),
            details(&[("name", namev)]),
        );
    }
    if !check_tag(&tagv) {
        return fail(
            "plugin_bad_tag",
            &format!("invalid plugin tag: {}", tag),
            details(&[("name", namev), ("tag", tagv)]),
        );
    }

    let mut out = Value::map();
    out.set("name", Value::str(name));
    out.set("tag", Value::str(tag));
    Ok(out)
}

pub fn format_ref(name: &Value, tag: &Value) -> Result<String, PluginError> {
    let tag = if tag.is_null() { Value::str("") } else { tag.clone() };
    if !check_name(name) {
        return fail(
            "plugin_bad_name",
            &format!("invalid plugin name: {}", name.json()),
            details(&[("name", name.clone())]),
        );
    }
    if !check_tag(&tag) {
        return fail(
            "plugin_bad_tag",
            &format!("invalid plugin tag: {}", tag.json()),
            details(&[("name", name.clone()), ("tag", tag.clone())]),
        );
    }
    let name = name.as_str().unwrap();
    let tag = tag.as_str().unwrap();
    Ok(if tag.is_empty() {
        name.to_string()
    } else {
        format!("{}${}", name, tag)
    })
}

/// The canonical spelling of a ref. §4 rule 5: ports must canonicalize
/// before comparison.
pub fn canon_ref(value: &Value) -> Result<String, PluginError> {
    let parsed = parse_ref(value)?;
    format_ref(&parsed.get("name"), &parsed.get("tag"))
}

/// canon_ref for the internal callers that want the input back unchanged
/// when it is not well formed. NEVER use it where a bad ref must be
/// reported - the corpus pins plugin_bad_name at every public entry.
pub fn canon(text: &str) -> String {
    canon_ref(&Value::str(text)).unwrap_or_else(|_| text.to_string())
}

pub fn refname(text: &str) -> String {
    match parse_ref(&Value::str(text)) {
        Ok(r) => r.get("name").as_str().unwrap_or(text).to_string(),
        Err(_) => text.to_string(),
    }
}
