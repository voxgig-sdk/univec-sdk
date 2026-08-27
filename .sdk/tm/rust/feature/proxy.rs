// Outbound HTTP(S) proxy support (mirrors go feature/proxy_feature.go).
// Wraps the active transport and annotates each request's fetch definition
// with the proxy target (`fetchdef.proxy`). The default ureq transport
// honours the annotation by routing the request through an agent
// configured with that proxy (see utility/fetcher.rs); custom transports
// can do the same. The proxy target comes from options (`url`) or, when
// `fromEnv` is set, the standard HTTPS_PROXY / HTTP_PROXY / NO_PROXY
// environment variables. Hosts matching `noProxy` bypass the proxy.

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
    pub url: String,
    pub no_proxy: Vec<String>,
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

        {
            let mut t = self.track.borrow_mut();
            t.url = url;
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
        (t.url.clone(), t.no_proxy.clone())
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
