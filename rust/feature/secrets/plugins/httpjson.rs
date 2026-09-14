// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/httpjson/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The HTTP-JSON client the vault plugins share, and the helpers that go
//! with it.
//!
//! It lives under `plugins/` because a chain of BUILT-IN kinds must never
//! link it: `http.rs` is a TCP socket and a rustls session, and the core
//! reads at most a local file. `voxgig_sekreto` does not depend on this
//! crate; this crate depends on it.
//!
//! `json.rs` travels with it rather than staying in the core for the same
//! reason it was written at all: the only things that parse JSON here are
//! the vault clients and the CLI that calls a JSON API.

pub mod http;
pub mod json;

use std::cell::RefCell;
use std::env;
use std::time::{Duration, Instant};

use super::super::sekreto::{Answer, SekretoError};

pub use self::json::Json;

/// A base URL with one trailing slash removed, so paths join cleanly.
pub fn trimslash(addr: &str) -> &str {
    addr.strip_suffix('/').unwrap_or(addr)
}

/// The first non-empty answer: the configured value, then each named
/// environment variable in turn.
pub fn firstof(config: &str, envnames: &[&str]) -> String {
    if !config.is_empty() {
        return config.to_string();
    }

    for name in envnames {
        if let Ok(value) = env::var(name) {
            if !value.is_empty() {
                return value;
            }
        }
    }

    String::new()
}

/// Owned headers as the borrowed pairs the http client takes.
pub fn headerrefs(headers: &[(String, String)]) -> Vec<(&str, &str)> {
    headers
        .iter()
        .map(|(name, value)| (name.as_str(), value.as_str()))
        .collect()
}

/// What a store answered: the status, and the body when it parsed as JSON.
pub struct JsonResponse {
    pub status: u16,
    pub body: Option<Json>,
}

/// One JSON round-trip. Network failure is always an error - an
/// unreachable store is a store that could not answer.
pub fn fetchjson(
    method: &str,
    url: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Answer<JsonResponse> {
    let response = self::http::request(method, url, headers, body)?;

    let parsed = self::json::parse(&response.body);

    // A success status promised JSON; a body that does not parse means
    // the store could not answer coherently, and treating it as a miss
    // would fall through to a weaker store. Error statuses may carry
    // any body - they are decided on status alone.
    if 200 == response.status && parsed.is_none() {
        return Err(SekretoError::new(format!(
            "sekreto: malformed response from {}",
            url.split('?').next().unwrap_or(url)
        )));
    }

    Ok(JsonResponse {
        status: response.status,
        body: parsed,
    })
}

/// When a token obtained by a login should be renewed: shortly before
/// the expiry the login response named, or never (None) when it named
/// none - a store that does not say when a token dies cannot have it
/// renewed on a guess.
pub fn renewtime(seconds: f64) -> Option<Instant> {
    if 0.0 < seconds && seconds.is_finite() {
        // Clamp before constructing the Duration: from_secs_f64 panics on a
        // non-finite or too-large value, and a token expiry comes from the
        // (untrusted) auth response. A century is more than any real lease.
        let bounded = (seconds - 60.0).max(1.0).min(3_153_600_000.0);
        Some(Instant::now() + Duration::from_secs_f64(bounded))
    } else {
        None
    }
}

/// The expiry a login response named, in seconds - zero when it named
/// none (or named it unreadably). Some stores send the number as a JSON
/// string, so the text form is parsed rather than the number taken.
pub fn expiryseconds(body: &Option<Json>, path: &[&str]) -> f64 {
    textat(body, path)
        .and_then(|text| text.parse::<f64>().ok())
        .unwrap_or(0.0)
}

/// Is a cached login token due for renewal? A token that never expires
/// (a configured one, or one whose login named no expiry) never is.
pub fn renewdue(renewat: &RefCell<Option<Instant>>) -> bool {
    renewat.borrow().map_or(false, |at| Instant::now() >= at)
}

/// The value at a path of map keys, as text - or None when absent or null.
pub fn textat(body: &Option<Json>, path: &[&str]) -> Option<String> {
    let mut at = body.as_ref()?;

    for key in path {
        at = at.get(key)?;
    }

    if matches!(at, Json::Null) {
        return None;
    }

    Some(at.text())
}
