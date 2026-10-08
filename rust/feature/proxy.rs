
use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::setp;
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

#[derive(Default)]
pub struct ProxyTrack {
    // Activity tracking (mirrors the ts client._proxy record).
    pub routed: i64,
    /// The proxy URL as it may be shown: userinfo masked.
    pub url: String,
    /// The proxy URL as it is used, kept off the tracking record.
    raw_url: String,
    pub no_proxy: Vec<String>,
}

// A proxy URL may carry credentials as userinfo, from the option or the
// environment, and neither is under a sensitive key name.
fn userinfo(url: &str) -> Vec<String> {
    let rest = match url.find("://") {
        Some(i) => &url[i + 3..],
        None => url,
    };
    let authority = &rest[..rest.find('/').unwrap_or(rest.len())];
    let at = match authority.rfind('@') {
        Some(i) => i,
        None => return Vec::new(),
    };
    authority[..at]
        .splitn(2, ':')
        .filter(|p| !p.is_empty())
        .map(|p| p.to_string())
        .collect()
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if b'%' == bytes[i] && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| s.to_string())
}

pub struct ProxyFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    pub track: Rc<RefCell<ProxyTrack>>,
}

impl ProxyFeature {
    pub fn new() -> ProxyFeature {
        ProxyFeature {
            name: "proxy".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            track: Rc::new(RefCell::new(ProxyTrack::default())),
        }
    }
}

fn first_env(names: &[&str]) -> String {
    for name in names {
        if let Ok(v) = std::env::var(name) {
            if !v.is_empty() {
                return v;
            }
        }
    }
    String::new()
}

fn host_of(url: &str) -> String {
    // <scheme>://<host>[:port][/...]
    let rest = match url.find("://") {
        Some(i) => &url[i + 3..],
        None => url,
    };
    let end = rest
        .find(|c| c == '/' || c == ':')
        .unwrap_or(rest.len());
    rest[..end].to_string()
}

fn bypass(no_proxy: &[String], url: &str) -> bool {
    if no_proxy.is_empty() {
        return false;
    }
    let host = host_of(url);
    for np in no_proxy {
        if np == "*" {
            return true;
        }
        let np_trim = np.trim_start_matches('.');
        if host == *np || host.ends_with(&format!(".{}", np_trim)) {
            return true;
        }
    }
    false
}

impl Feature for ProxyFeature {
    fn name(&self) -> String {
        self.name.clone()
    }
    fn active(&self) -> bool {
        self.active
    }
    fn add_options(&self) -> Option<Value> {
        self.add_opts.clone()
    }

    fn init(&mut self, ctx: &Rc<Context>, options: &Value) {
        self.options = options.clone();
        self.active = fopt_bool(options, "active", false);

        if !self.active {
            return;
        }

        let mut url = fopt_str(options, "url", "");
        let mut no_proxy = fopt_str_list(options, "noProxy");

        if fopt_bool(options, "fromEnv", false) {
            if url.is_empty() {
                url = first_env(&["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]);
            }
            if no_proxy.is_none() {
                let np = first_env(&["NO_PROXY", "no_proxy"]);
                if !np.is_empty() {
                    no_proxy = Some(np.split(',').map(|s| s.to_string()).collect());
                }
            }
        }

        let no_proxy: Vec<String> = no_proxy
            .unwrap_or_default()
            .into_iter()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();

        for part in userinfo(&url) {
            ctx.util().clean_add(ctx, &part);
            ctx.util().clean_add(ctx, &percent_decode(&part));
        }

        {
            let mut t = self.track.borrow_mut();
            t.url = ctx.util().clean_str(ctx, &url);
            t.raw_url = url;
            t.no_proxy = no_proxy;
        }

        let util = ctx.util();
        let inner: FetcherFn = util.fetcher.borrow().clone();
        let track = self.track.clone();

        *util.fetcher.borrow_mut() = Rc::new(move |ctx2, url2, fetchdef| {
            let fetchdef = route(&track, url2, fetchdef);
            inner(ctx2, url2, &fetchdef)
        });
    }
}

fn route(track: &Rc<RefCell<ProxyTrack>>, url: &str, fetchdef: &Value) -> Value {
    let (proxy_url, no_proxy) = {
        let t = track.borrow();
        (t.raw_url.clone(), t.no_proxy.clone())
    };

    if proxy_url.is_empty() || bypass(&no_proxy, url) {
        return fetchdef.clone();
    }

    let out = Value::empty_map();
    if let Value::Map(m) = fetchdef {
        for (k, v) in m.borrow().iter() {
            setp(&out, k, v.clone());
        }
    }
    setp(&out, "proxy", Value::str(proxy_url));

    track.borrow_mut().routed += 1;
    out
}
