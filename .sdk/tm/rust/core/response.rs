
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{get_str, getp, to_int};
use crate::utility::clean::clean_str;
use crate::utility::voxgigstruct::{stringify, Value};

const PREVIEW_LENGTH: usize = 160;

pub struct Response {
    pub status: i64,
    pub status_text: String,
    pub headers: Value,
    pub json: Value,
    pub body: Value,
    pub err: Option<UnivecError>,
    // Set by a transport that could not read a non-blank body as JSON.
    pub unreadable: bool,
}

impl Response {
    pub fn new(resmap: &Value) -> Response {
        let status = match getp(resmap, "status") {
            Value::Noval => -1,
            s => to_int(&s),
        };

        let status_text = get_str(resmap, "statusText").unwrap_or_default();
        let headers = getp(resmap, "headers");
        let json = getp(resmap, "json");
        let body = getp(resmap, "body");
        let unreadable = getp(resmap, "unreadable") == Value::Bool(true);

        Response {
            status,
            status_text,
            headers,
            json,
            body,
            err: None,
            unreadable,
        }
    }
}

/// A body that is not JSON. An HTTP failure keeps its own error, with the
/// response described; otherwise the code tells a wrong content type from
/// malformed JSON.
pub fn unreadable_body(
    ctx: &Rc<Context>,
    status: i64,
    headers: &Value,
    text: &Value,
    sent: &Value,
    failed: Option<UnivecError>,
) -> UnivecError {
    let ctype = header_value(headers, "content-type");
    let agent = clean_str(ctx, &header_value(sent, "user-agent"));
    let detail = format!(
        "HTTP {}, content-type {}, user-agent {}{}",
        status,
        if ctype.is_empty() { "none" } else { &ctype },
        if agent.is_empty() { "transport default" } else { &agent },
        match text {
            Value::Noval | Value::Null => String::new(),
            t => format!(", body: {}", preview(ctx, t)),
        }
    );

    if let Some(mut err) = failed {
        err.msg = format!("{} ({})", err.msg, detail);
        return err;
    }

    if ctype.is_empty() || ctype.to_lowercase().contains("json") {
        ctx.make_error(
            "response_json_invalid",
            &format!("response: body is not valid JSON ({})", detail),
        )
    } else {
        ctx.make_error(
            "response_content_type",
            &format!("response: expected JSON, got {} ({})", ctype, detail),
        )
    }
}

fn header_value(headers: &Value, name: &str) -> String {
    if let Value::Map(m) = headers {
        for (k, v) in m.borrow().iter() {
            if k.eq_ignore_ascii_case(name) {
                return text_of(v);
            }
        }
    }
    String::new()
}

fn text_of(v: &Value) -> String {
    match v {
        Value::Str(s) => s.clone(),
        other => stringify(other, None, false),
    }
}

// Cleaned whole: a secret the bound would split could leave its prefix.
fn preview(ctx: &Rc<Context>, text: &Value) -> String {
    let flat = clean_str(ctx, &text_of(text).split_whitespace().collect::<Vec<_>>().join(" "));
    match flat.char_indices().nth(PREVIEW_LENGTH) {
        Some((end, _)) => format!("{}...", &flat[..end]),
        None => flat,
    }
}
