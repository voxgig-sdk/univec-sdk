// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/value.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The JSON value, and the only parser this port has.
//!
//! NO SERDE, AND NO CRATE GRAPH AT ALL (§16). The library is allowed
//! exactly one runtime dependency, `voxgig/struct`, which has no rust
//! port; everything else is the standard library. Parsing the corpus is a
//! hundred lines, and a hundred lines is cheaper than a supply chain.
//!
//! `Map` is a `BTreeMap`, which is not a convenience: every port has to
//! sort its keys before iterating - the canonical's status maps, export
//! lookups and registry walks all depend on it - and a sorted map makes
//! that the default rather than a discipline to remember.
//!
//! `Num` is `f64` because JSON HAS ONE NUMBER TYPE. The canonical is
//! javascript, `1` and `1.0` are the same value there, and a port that
//! split them would disagree with the corpus on which of two spellings a
//! document used.

use std::any::Any;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::rc::Rc;

#[derive(Clone)]
pub enum Value {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    List(Vec<Value>),
    Map(BTreeMap<String, Value>),
    /// A host object published through `exports` (§11). The design lets a
    /// plugin export "a client" - a thing the library never inspects - and
    /// in a statically typed port that needs an escape hatch. It is never
    /// produced by the parser and never compared as data.
    Opaque(Rc<dyn Any>),
}

impl Value {
    pub fn map() -> Value {
        Value::Map(BTreeMap::new())
    }

    pub fn str(s: &str) -> Value {
        Value::Str(s.to_string())
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    pub fn as_map(&self) -> Option<&BTreeMap<String, Value>> {
        match self {
            Value::Map(m) => Some(m),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&Vec<Value>> {
        match self {
            Value::List(l) => Some(l),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn as_num(&self) -> Option<f64> {
        match self {
            Value::Num(n) => Some(*n),
            _ => None,
        }
    }

    /// An INTEGER, and only when the value is one. `§7`'s band is an
    /// integer the document wrote as one; `true` and `"2"` are not bands,
    /// and a port that coerced them would accept documents the canonical
    /// rejects.
    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Num(n) if n.fract() == 0.0 => Some(*n as i64),
            _ => None,
        }
    }

    /// The value at a key, or `Null`. Absence and null read the same here
    /// ON PURPOSE at the call sites that want a default; the call sites
    /// that must tell them apart use `has` instead, and say so.
    pub fn get(&self, key: &str) -> Value {
        match self {
            Value::Map(m) => m.get(key).cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        }
    }

    pub fn has(&self, key: &str) -> bool {
        match self {
            Value::Map(m) => m.contains_key(key),
            _ => false,
        }
    }

    pub fn at(&self, i: usize) -> Value {
        match self {
            Value::List(l) => l.get(i).cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        }
    }

    pub fn set(&mut self, key: &str, value: Value) {
        if let Value::Map(m) = self {
            m.insert(key.to_string(), value);
        }
    }

    /// The keys of a map, sorted - which `BTreeMap` already is, so this is
    /// one call rather than a sort every caller has to remember.
    pub fn keys(&self) -> Vec<String> {
        match self {
            Value::Map(m) => m.keys().cloned().collect(),
            _ => Vec::new(),
        }
    }

    /// Ruby's truthiness, which is not rust's `if let`: present, and not
    /// `false`. `0`, `""` and `[]` are all values the corpus distinguishes
    /// from absence.
    pub fn truthy(&self) -> bool {
        !matches!(self, Value::Null | Value::Bool(false))
    }

    /// JSON equality: same type, then same value. `true` is not `1` and
    /// `1` is not `"1"` - `capability/match` has an entry for each
    /// direction, and the enum makes both fall out rather than needing a
    /// guard.
    pub fn same(&self, other: &Value) -> bool {
        match (self, other) {
            (Value::Null, Value::Null) => true,
            (Value::Bool(a), Value::Bool(b)) => a == b,
            (Value::Num(a), Value::Num(b)) => a == b,
            (Value::Str(a), Value::Str(b)) => a == b,
            (Value::List(a), Value::List(b)) => {
                a.len() == b.len() && a.iter().zip(b.iter()).all(|(x, y)| x.same(y))
            }
            (Value::Map(a), Value::Map(b)) => {
                a.len() == b.len()
                    && a.iter()
                        .all(|(k, v)| b.get(k).map(|o| v.same(o)).unwrap_or(false))
            }
            // Two opaque handles are the same only if they are the same
            // allocation. Nothing in the corpus compares one.
            (Value::Opaque(a), Value::Opaque(b)) => Rc::ptr_eq(a, b),
            _ => false,
        }
    }

    /// Compact JSON, with map keys in sorted order (which is what the map
    /// already gives). Used for §12's error details and for the runner's
    /// failure messages - never for parsing back.
    pub fn json(&self) -> String {
        let mut out = String::new();
        self.write_json(&mut out);
        out
    }

    fn write_json(&self, out: &mut String) {
        match self {
            Value::Null => out.push_str("null"),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Value::Num(n) => {
                // An integral f64 prints without a fractional part, so a
                // `pos` of 3 renders as `3` and not `3.0` - JSON has one
                // number type and the corpus writes them as it means them.
                if n.fract() == 0.0 && n.is_finite() && n.abs() < 1e15 {
                    let _ = write!(out, "{}", *n as i64);
                } else {
                    let _ = write!(out, "{}", n);
                }
            }
            Value::Str(s) => write_string(s, out),
            Value::List(l) => {
                out.push('[');
                for (i, v) in l.iter().enumerate() {
                    if 0 < i {
                        out.push(',');
                    }
                    v.write_json(out);
                }
                out.push(']');
            }
            Value::Map(m) => {
                out.push('{');
                for (i, (k, v)) in m.iter().enumerate() {
                    if 0 < i {
                        out.push(',');
                    }
                    write_string(k, out);
                    out.push(':');
                    v.write_json(out);
                }
                out.push('}');
            }
            Value::Opaque(_) => out.push_str("\"(opaque)\""),
        }
    }
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

// ---------------------------------------------------------------------
// the parser
// ---------------------------------------------------------------------

pub fn parse(text: &str) -> Result<Value, String> {
    let bytes: Vec<char> = text.chars().collect();
    let mut at = 0usize;
    skip_ws(&bytes, &mut at);
    let value = parse_value(&bytes, &mut at)?;
    skip_ws(&bytes, &mut at);
    if at < bytes.len() {
        return Err(format!("trailing input at {}", at));
    }
    Ok(value)
}

fn skip_ws(b: &[char], at: &mut usize) {
    while *at < b.len() && matches!(b[*at], ' ' | '\t' | '\n' | '\r') {
        *at += 1;
    }
}

fn parse_value(b: &[char], at: &mut usize) -> Result<Value, String> {
    if b.len() <= *at {
        return Err("unexpected end of input".to_string());
    }
    match b[*at] {
        '{' => parse_map(b, at),
        '[' => parse_list(b, at),
        '"' => Ok(Value::Str(parse_string(b, at)?)),
        't' => lit(b, at, "true", Value::Bool(true)),
        'f' => lit(b, at, "false", Value::Bool(false)),
        'n' => lit(b, at, "null", Value::Null),
        _ => parse_number(b, at),
    }
}

fn lit(b: &[char], at: &mut usize, word: &str, value: Value) -> Result<Value, String> {
    for (i, c) in word.chars().enumerate() {
        if b.len() <= *at + i || b[*at + i] != c {
            return Err(format!("bad literal at {}", at));
        }
    }
    *at += word.len();
    Ok(value)
}

fn parse_map(b: &[char], at: &mut usize) -> Result<Value, String> {
    let mut out = BTreeMap::new();
    *at += 1;
    skip_ws(b, at);
    if *at < b.len() && '}' == b[*at] {
        *at += 1;
        return Ok(Value::Map(out));
    }
    loop {
        skip_ws(b, at);
        let key = parse_string(b, at)?;
        skip_ws(b, at);
        if b.len() <= *at || ':' != b[*at] {
            return Err(format!("expected ':' at {}", at));
        }
        *at += 1;
        skip_ws(b, at);
        out.insert(key, parse_value(b, at)?);
        skip_ws(b, at);
        if b.len() <= *at {
            return Err("unexpected end in object".to_string());
        }
        match b[*at] {
            ',' => *at += 1,
            '}' => {
                *at += 1;
                return Ok(Value::Map(out));
            }
            _ => return Err(format!("expected ',' or '}}' at {}", at)),
        }
    }
}

fn parse_list(b: &[char], at: &mut usize) -> Result<Value, String> {
    let mut out = Vec::new();
    *at += 1;
    skip_ws(b, at);
    if *at < b.len() && ']' == b[*at] {
        *at += 1;
        return Ok(Value::List(out));
    }
    loop {
        skip_ws(b, at);
        out.push(parse_value(b, at)?);
        skip_ws(b, at);
        if b.len() <= *at {
            return Err("unexpected end in array".to_string());
        }
        match b[*at] {
            ',' => *at += 1,
            ']' => {
                *at += 1;
                return Ok(Value::List(out));
            }
            _ => return Err(format!("expected ',' or ']' at {}", at)),
        }
    }
}

fn parse_string(b: &[char], at: &mut usize) -> Result<String, String> {
    if b.len() <= *at || '"' != b[*at] {
        return Err(format!("expected a string at {}", at));
    }
    *at += 1;
    let mut out = String::new();
    while *at < b.len() {
        let c = b[*at];
        *at += 1;
        match c {
            '"' => return Ok(out),
            '\\' => {
                if b.len() <= *at {
                    return Err("unexpected end in string".to_string());
                }
                let e = b[*at];
                *at += 1;
                match e {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'b' => out.push('\u{8}'),
                    'f' => out.push('\u{c}'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'u' => {
                        let mut code = 0u32;
                        for _ in 0..4 {
                            if b.len() <= *at {
                                return Err("bad \\u escape".to_string());
                            }
                            let d = b[*at]
                                .to_digit(16)
                                .ok_or_else(|| "bad \\u escape".to_string())?;
                            code = code * 16 + d;
                            *at += 1;
                        }
                        // A surrogate PAIR is two escapes; a lone
                        // surrogate is left as the replacement character
                        // rather than failing the whole corpus.
                        if (0xD800..0xDC00).contains(&code)
                            && *at + 1 < b.len()
                            && '\\' == b[*at]
                            && 'u' == b[*at + 1]
                        {
                            let mut low = 0u32;
                            let save = *at;
                            *at += 2;
                            let mut ok = true;
                            for _ in 0..4 {
                                match b.get(*at).and_then(|c| c.to_digit(16)) {
                                    Some(d) => {
                                        low = low * 16 + d;
                                        *at += 1;
                                    }
                                    None => {
                                        ok = false;
                                        break;
                                    }
                                }
                            }
                            if ok && (0xDC00..0xE000).contains(&low) {
                                let joined =
                                    0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                                out.push(char::from_u32(joined).unwrap_or('\u{fffd}'));
                                continue;
                            }
                            *at = save;
                        }
                        out.push(char::from_u32(code).unwrap_or('\u{fffd}'));
                    }
                    _ => return Err(format!("bad escape at {}", at)),
                }
            }
            c => out.push(c),
        }
    }
    Err("unterminated string".to_string())
}

fn parse_number(b: &[char], at: &mut usize) -> Result<Value, String> {
    let start = *at;
    if *at < b.len() && '-' == b[*at] {
        *at += 1;
    }
    while *at < b.len() && (b[*at].is_ascii_digit() || matches!(b[*at], '.' | 'e' | 'E' | '+' | '-'))
    {
        *at += 1;
    }
    let text: String = b[start..*at].iter().collect();
    text.parse::<f64>()
        .map(Value::Num)
        .map_err(|_| format!("bad number {:?} at {}", text, start))
}
