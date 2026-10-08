// The media types a point declares: `response` (the model's `rs`) for the
// Accept header, and `body` (the model's `rb`) for the request body.

use crate::core::helpers::{getp, setp};
use crate::utility::voxgigstruct::Value;

// The data key holding a raw request body. Like `$action`, it can never be a
// declared argument name.
pub const RAW_BODY: &str = "$body";

pub fn is_json_media(media: &str) -> bool {
    let m = media.split(';').next().unwrap_or("").trim().to_lowercase();
    m == "application/json" || m == "text/json" || m.ends_with("+json")
}

fn text_of(v: &Value) -> Option<String> {
    match v {
        Value::Str(s) if !s.is_empty() => Some(s.clone()),
        _ => None,
    }
}

// The declared JSON type alone, else every declared type in the model's
// order; None when no success response declares a body.
pub fn accept_of(point: &Value) -> Option<String> {
    let res = getp(point, "response");
    let media = text_of(&getp(&res, "media"))?;
    if text_of(&getp(&res, "kind")).as_deref() == Some("json") {
        return Some(media);
    }
    let mut types = vec![media];
    if let Value::List(alts) = getp(&res, "alternatives") {
        for alt in alts.borrow().iter() {
            if let Some(m) = text_of(&getp(alt, "media")) {
                types.push(m);
            }
        }
    }
    Some(types.join(", "))
}

pub fn is_raw_request(point: &Value) -> bool {
    text_of(&getp(&getp(point, "body"), "kind")).as_deref() == Some("raw")
}

pub fn is_json_request(point: &Value) -> bool {
    text_of(&getp(&getp(point, "body"), "kind")).as_deref() == Some("json")
}

fn has_header(headers: &Value, name: &str) -> bool {
    match headers {
        Value::Map(m) => m.borrow().keys().any(|k| k.to_lowercase() == name),
        _ => false,
    }
}

// A caller's accept wins. A declared request type replaces each JSON
// content-type, the SDK default, and leaves any other the caller set.
pub fn media_headers(point: &Value, headers: Value) -> Value {
    if let Some(accept) = accept_of(point) {
        if !has_header(&headers, "accept") {
            setp(&headers, "accept", Value::Str(accept));
        }
    }

    let body = getp(point, "body");
    let kind = text_of(&getp(&body, "kind"));
    if let (Some(kind), Some(media)) = (kind, text_of(&getp(&body, "media"))) {
        if kind == "raw" || kind == "json" {
            if let Value::Map(m) = &headers {
                let json: Vec<String> = m
                    .borrow()
                    .iter()
                    .filter(|(k, v)| {
                        k.to_lowercase() == "content-type"
                            && matches!(v, Value::Str(s) if is_json_media(s))
                    })
                    .map(|(k, _)| k.clone())
                    .collect();
                for k in json {
                    m.borrow_mut().shift_remove(&k);
                }
            }
            if !has_header(&headers, "content-type") {
                setp(&headers, "content-type", Value::Str(media));
            }
        }
    }

    headers
}

pub fn raw_body(reqdata: &Value) -> Value {
    getp(reqdata, RAW_BODY)
}

// A struct string must be UTF-8, so a binary body is a list of byte values.
pub fn bytes_value(bytes: &[u8]) -> Value {
    Value::list(bytes.iter().map(|b| Value::Num(*b as f64)).collect())
}

// The bytes a raw body sends: a string's UTF-8, or a list of byte values.
pub fn body_bytes(body: &Value) -> Option<Vec<u8>> {
    match body {
        Value::Str(s) => Some(s.as_bytes().to_vec()),
        Value::List(items) => items
            .borrow()
            .iter()
            .map(|v| match v {
                Value::Num(n) if (0.0..=255.0).contains(n) && 0.0 == n.fract() => Some(*n as u8),
                _ => None,
            })
            .collect(),
        _ => None,
    }
}
