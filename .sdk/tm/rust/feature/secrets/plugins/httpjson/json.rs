// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/httpjson/src/json.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Minimal JSON support for sekreto.
//!
//! sekreto adds no third-party dependencies, so it carries just enough JSON
//! to read a vault's answer and write the CLI's own line of output. It is
//! deliberately not a general-purpose library.

use std::collections::BTreeMap;

/// A JSON value.
#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    List(Vec<Json>),
    Map(BTreeMap<String, Json>),
}

impl Json {
    /// The named entry of a map, if this is a map that has it.
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Map(entries) => entries.get(key),
            _ => None,
        }
    }

    /// This value as a string, the way the canonical port's String() renders
    /// it: strings verbatim, scalars as text, containers as JSON.
    pub fn text(&self) -> String {
        match self {
            Json::Null => "null".to_string(),
            Json::Bool(value) => value.to_string(),
            Json::Num(value) => numstr(*value),
            Json::Str(value) => value.clone(),
            _ => stringify(self),
        }
    }
}

/// Render a number without a trailing `.0`, so 5.0 prints as `5`.
pub fn numstr(value: f64) -> String {
    if value.is_finite() && value == value.trunc() && value.abs() < 1e15 {
        return format!("{}", value as i64);
    }
    format!("{}", value)
}

/// Render a value as compact JSON.
pub fn stringify(value: &Json) -> String {
    match value {
        Json::Null => "null".to_string(),
        Json::Bool(entry) => entry.to_string(),
        Json::Num(entry) => numstr(*entry),
        Json::Str(entry) => quote(entry),
        Json::List(entries) => {
            let parts: Vec<String> = entries.iter().map(stringify).collect();
            format!("[{}]", parts.join(","))
        }
        Json::Map(entries) => {
            let parts: Vec<String> = entries
                .iter()
                .map(|(key, entry)| format!("{}:{}", quote(key), stringify(entry)))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
    }
}

/// Quote a string as JSON.
pub fn quote(text: &str) -> String {
    let mut out = String::from("\"");

    for head in text.chars() {
        match head {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ if (head as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", head as u32)),
            _ => out.push(head),
        }
    }

    out.push('"');
    out
}

/// The deepest nesting the parser will follow. A response is trusted only
/// as far as its status; the body arrives before any check, so a hostile
/// or buggy upstream must not be able to overflow the stack with `[[[...`.
const MAX_DEPTH: usize = 128;

/// Parse JSON text, answering None for anything unreadable.
pub fn parse(text: &str) -> Option<Json> {
    let chars: Vec<char> = text.chars().collect();
    let mut at = 0usize;
    let value = value(&chars, &mut at, 0)?;
    Some(value)
}

fn skip(chars: &[char], at: &mut usize) {
    while *at < chars.len() && chars[*at].is_whitespace() {
        *at += 1;
    }
}

fn value(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
    if depth > MAX_DEPTH {
        return None;
    }

    skip(chars, at);

    if *at >= chars.len() {
        return None;
    }

    match chars[*at] {
        '{' => map(chars, at, depth),
        '[' => list(chars, at, depth),
        '"' => string(chars, at).map(Json::Str),
        't' => literal(chars, at, "true", Json::Bool(true)),
        'f' => literal(chars, at, "false", Json::Bool(false)),
        'n' => literal(chars, at, "null", Json::Null),
        _ => number(chars, at),
    }
}

fn literal(chars: &[char], at: &mut usize, word: &str, value: Json) -> Option<Json> {
    for (offset, head) in word.chars().enumerate() {
        if *at + offset >= chars.len() || chars[*at + offset] != head {
            return None;
        }
    }
    *at += word.len();
    Some(value)
}

fn map(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
    let mut out = BTreeMap::new();
    *at += 1; // {
    skip(chars, at);

    if *at < chars.len() && '}' == chars[*at] {
        *at += 1;
        return Some(Json::Map(out));
    }

    loop {
        skip(chars, at);
        let key = string(chars, at)?;
        skip(chars, at);

        if *at >= chars.len() || ':' != chars[*at] {
            return None;
        }
        *at += 1;

        out.insert(key, value(chars, at, depth + 1)?);
        skip(chars, at);

        if *at >= chars.len() {
            return None;
        }

        if ',' == chars[*at] {
            *at += 1;
            continue;
        }

        *at += 1; // }
        break;
    }

    Some(Json::Map(out))
}

fn list(chars: &[char], at: &mut usize, depth: usize) -> Option<Json> {
    let mut out = Vec::new();
    *at += 1; // [
    skip(chars, at);

    if *at < chars.len() && ']' == chars[*at] {
        *at += 1;
        return Some(Json::List(out));
    }

    loop {
        out.push(value(chars, at, depth + 1)?);
        skip(chars, at);

        if *at >= chars.len() {
            return None;
        }

        if ',' == chars[*at] {
            *at += 1;
            continue;
        }

        *at += 1; // ]
        break;
    }

    Some(Json::List(out))
}

fn string(chars: &[char], at: &mut usize) -> Option<String> {
    if *at >= chars.len() || '"' != chars[*at] {
        return None;
    }

    let mut out = String::new();
    *at += 1;

    while *at < chars.len() {
        let head = chars[*at];
        *at += 1;

        if '"' == head {
            return Some(out);
        }

        if '\\' != head {
            out.push(head);
            continue;
        }

        if *at >= chars.len() {
            return None;
        }

        let next = chars[*at];
        *at += 1;

        match next {
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'b' => out.push('\u{0008}'),
            'f' => out.push('\u{000c}'),
            'u' => {
                if *at + 4 > chars.len() {
                    return None;
                }
                let hex: String = chars[*at..*at + 4].iter().collect();
                *at += 4;
                let code = u32::from_str_radix(&hex, 16).ok()?;
                out.push(char::from_u32(code)?);
            }
            _ => out.push(next),
        }
    }

    None
}

fn number(chars: &[char], at: &mut usize) -> Option<Json> {
    let start = *at;

    while *at < chars.len() && !",]}\r\n\t ".contains(chars[*at]) {
        *at += 1;
    }

    let text: String = chars[start..*at].iter().collect();

    // Reject non-finite results: `1e999` parses to f64::INFINITY, which
    // later panics Duration::from_secs_f64 when it lands in a token-expiry
    // field. JSON has no infinity, so this is also stricter-correct.
    match text.parse::<f64>() {
        Ok(value) if value.is_finite() => Some(Json::Num(value)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn deep_nesting_does_not_overflow() {
        // A hostile/buggy upstream must not crash the client with `[[[...`.
        let deep = "[".repeat(100_000) + &"]".repeat(100_000);
        assert!(parse(&deep).is_none());
    }

    #[test]
    fn non_finite_numbers_are_rejected() {
        // 1e999 -> f64::INFINITY would later panic Duration::from_secs_f64.
        assert!(parse("1e999").is_none());
        assert!(parse("[1e999]").is_none());
        assert!(parse("5").is_some());
    }
}
