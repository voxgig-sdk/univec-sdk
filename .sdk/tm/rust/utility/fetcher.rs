use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{call_vfn, get_str, getp, getpath, ja, jo, json_thunk, setp};
use crate::utility::voxgigstruct::Value;

// Default live transport: ureq (blocking, minimal). Honours a `proxy`
// annotation on the fetch definition (set by the proxy feature) by routing
// the request through an agent configured with that proxy.
fn default_http_fetch(fullurl: &str, fetchdef: &Value) -> Result<Value, UnivecError> {
    let method = get_str(fetchdef, "method")
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| "GET".to_string());

    let mut builder = ureq::AgentBuilder::new();
    if let Some(proxy) = get_str(fetchdef, "proxy").filter(|p| !p.is_empty()) {
        if let Ok(p) = ureq::Proxy::new(&proxy) {
            builder = builder.proxy(p);
        }
    }
    // A `redirect: "manual"` annotation (set by the station feature when a
    // hosts policy is active - the same in-band channel as `proxy` above)
    // disables automatic redirect following, so a 3xx rides back as a normal
    // response: a Location pointing off an egress allowlist must never pull
    // an automatic credentialed follow-up request.
    if get_str(fetchdef, "redirect").as_deref() == Some("manual") {
        builder = builder.redirects(0);
    }
    let agent = builder.build();

    let mut req = agent.request(&method, fullurl);

    let mut has_ua = false;
    if let Value::Map(m) = getp(fetchdef, "headers") {
        for (k, v) in m.borrow().iter() {
            if let Value::Str(sv) = v {
                if k.eq_ignore_ascii_case("user-agent") {
                    has_ua = true;
                }
                req = req.set(k, sv);
            }
        }
    }
    // Default User-Agent — some CDNs block library defaults. Use a
    // Mozilla-shaped UA unless the caller already set one.
    if !has_ua {
        req = req.set("User-Agent", "Mozilla/5.0 (compatible; UnivecSDK/1.0)");
    }

    let body = get_str(fetchdef, "body").filter(|b| !b.is_empty());

    let sent = match body {
        Some(b) => req.send_string(&b),
        None => req.call(),
    };

    // ureq reports non-2xx as Err(Status) — unwrap those back into normal
    // responses so the result pipeline classifies them.
    let resp = match sent {
        Ok(r) => r,
        Err(ureq::Error::Status(_code, r)) => r,
        Err(e) => {
            return Err(UnivecError::new("fetch_transport", &format!("{}", e)));
        }
    };

    let status = resp.status() as i64;
    let status_text = resp.status_text().to_string();

    let headers = Value::empty_map();
    for name in resp.headers_names() {
        if let Some(val) = resp.header(&name) {
            setp(&headers, &name.to_lowercase(), Value::str(val));
        }
    }

    let body_txt = resp
        .into_string()
        .map_err(|e| UnivecError::new("fetch_body", &format!("{}", e)))?;

    let json_body = if body_txt.is_empty() {
        Value::Noval
    } else {
        crate::utility::jsonparse::json_parse(&body_txt).unwrap_or(Value::Noval)
    };

    Ok(jo(vec![
        ("status", Value::Num(status as f64)),
        ("statusText", Value::str(status_text)),
        ("headers", headers),
        ("json", json_thunk(json_body)),
        ("body", Value::str(body_txt)),
    ]))
}

pub fn fetcher_util(
    ctx: &Rc<Context>,
    fullurl: &str,
    fetchdef: &Value,
) -> Result<Value, UnivecError> {
    let client = ctx
        .client
        .borrow()
        .clone()
        .ok_or_else(|| ctx.make_error("fetch_no_client", "Expected context client."))?;

    let mode = client.mode.borrow().clone();
    if mode != "live" {
        return Err(ctx.make_error(
            "fetch_mode_block",
            &format!(
                "Request blocked by mode: \"{}\" (URL was: \"{}\")",
                mode, fullurl
            ),
        ));
    }

    let options = client.options_map();
    if getpath(&["feature", "test", "active"], &options) == Value::Bool(true) {
        return Err(ctx.make_error(
            "fetch_test_block",
            &format!(
                "Request blocked as test feature is active (URL was: \"{}\")",
                fullurl
            ),
        ));
    }

    let sys_fetch = getpath(&["system", "fetch"], &options);

    if sys_fetch.is_noval() || sys_fetch.is_null() {
        return default_http_fetch(fullurl, fetchdef);
    }

    if let Value::Func(_) = sys_fetch {
        // Caller-supplied transport: called with [url, fetchdef]; returns a
        // transport-shaped response map (an "__err__" entry signals failure).
        let out = call_vfn(
            &sys_fetch,
            &ja(vec![Value::str(fullurl), fetchdef.clone()]),
        );
        if let Some(msg) = get_str(&out, "__err__") {
            return Err(ctx.make_error("fetch_system", &msg));
        }
        return Ok(out);
    }

    Err(ctx.make_error("fetch_invalid", "system.fetch is not a valid function"))
}
