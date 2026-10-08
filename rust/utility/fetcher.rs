use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Mutex, OnceLock};

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{call_vfn, get_str, getp, getpath, ja, jo, json_thunk, setp};
use crate::utility::voxgigstruct::Value;

// One agent per process: ureq pools keep-alive connections per agent, so
// an agent per request reused nothing. Cloning shares the pool.
pub(crate) fn default_agent() -> ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| ureq::AgentBuilder::new().build()).clone()
}

// Agents keyed by the `proxy` annotation (set by the proxy feature) and
// manual redirects, for requests the default agent cannot serve.
fn agent_for(fetchdef: &Value) -> ureq::Agent {
    let proxy = get_str(fetchdef, "proxy").filter(|p| !p.is_empty());
    let manual = get_str(fetchdef, "redirect").as_deref() == Some("manual");
    if proxy.is_none() && !manual {
        return default_agent();
    }

    static AGENTS: OnceLock<Mutex<HashMap<(Option<String>, bool), ureq::Agent>>> =
        OnceLock::new();
    let mut agents = AGENTS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    agents
        .entry((proxy.clone(), manual))
        .or_insert_with(|| {
            let mut builder = ureq::AgentBuilder::new();
            if let Some(p) = proxy.as_deref().and_then(|p| ureq::Proxy::new(p).ok()) {
                builder = builder.proxy(p);
            }
            if manual {
                builder = builder.redirects(0);
            }
            builder.build()
        })
        .clone()
}

// Default live transport: ureq (blocking, minimal).
fn default_http_fetch(fullurl: &str, fetchdef: &Value) -> Result<Value, UnivecError> {
    let method = get_str(fetchdef, "method")
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| "GET".to_string());

    let agent = agent_for(fetchdef);
    let mut req = agent.request(&method, fullurl);

    let mut has_ua = false;
    let sent_headers = getp(fetchdef, "headers");
    if let Value::Map(m) = &sent_headers {
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
    // Mozilla-shaped UA unless the caller already set one, and record it with
    // the headers the request sent.
    if !has_ua {
        let agent = "Mozilla/5.0 (compatible; UnivecSDK/1.0)";
        req = req.set("User-Agent", agent);
        if let Value::Map(_) = &sent_headers {
            setp(&sent_headers, "user-agent", Value::str(agent));
        }
    }

    let body = getp(fetchdef, "body");
    let sent = match crate::utility::media::body_bytes(&body) {
        Some(bytes) if !bytes.is_empty() => req.send_bytes(&bytes),
        _ => req.call(),
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

    let parsed = if body_txt.trim().is_empty() {
        Ok(Value::Noval)
    } else {
        crate::utility::jsonparse::json_parse(&body_txt)
    };
    let unreadable = parsed.is_err();
    let json_body = parsed.unwrap_or(Value::Noval);

    Ok(jo(vec![
        ("status", Value::Num(status as f64)),
        ("statusText", Value::str(status_text)),
        ("headers", headers),
        ("json", json_thunk(json_body)),
        ("body", Value::str(body_txt)),
        ("unreadable", Value::Bool(unreadable)),
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
