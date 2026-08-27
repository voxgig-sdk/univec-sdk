// Client tracking (mirrors go feature/clienttrack_feature.go). Establishes
// a stable per-client session id at construction and stamps identifying
// headers on every request: a `User-Agent` (`<clientName>/<clientVersion>`),
// an `X-Client-Id` (session), and a fresh per-request `X-Request-Id`.
// Header names, client name/version and the id generator (`idgen`) are
// configurable; caller-provided User-Agent / X-Client-Id values are never
// clobbered.

use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{call_vfn, getp, rand_int, setp};
use crate::core::types::Feature;
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

pub struct ClienttrackFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,

    // Activity tracking (mirrors the ts client._clienttrack record).
    pub session: String,
    pub requests: i64,
    pub last_request_id: String,
    pub client_name: String,
}

impl ClienttrackFeature {
    pub fn new() -> ClienttrackFeature {
        ClienttrackFeature {
            name: "clienttrack".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            session: String::new(),
            requests: 0,
            last_request_id: String::new(),
            client_name: String::new(),
        }
    }

    fn full_name(&self) -> String {
        let name = fopt_str(&self.options, "clientName", "Univec-SDK");
        let version = fopt_str(&self.options, "clientVersion", "0.0.1");
        format!("{}/{}", name, version)
    }

    fn genid(&self, kind: &str) -> String {
        let idgen = getp(&self.options, "idgen");
        if let Value::Func(_) = idgen {
            if let Value::Str(s) = call_vfn(&idgen, &Value::str(kind)) {
                return s;
            }
        }
        let mut id = format!(
            "{}-{:06x}{:06x}{:06x}",
            &kind[..1],
            rand_int(0x1000000),
            rand_int(0x1000000),
            rand_int(0x1000000)
        );
        if id.len() > 20 {
            id.truncate(20);
        }
        id
    }
}

impl Feature for ClienttrackFeature {
    fn name(&self) -> String {
        self.name.clone()
    }
    fn active(&self) -> bool {
        self.active
    }
    fn add_options(&self) -> Option<Value> {
        self.add_opts.clone()
    }

    fn init(&mut self, _ctx: &Rc<Context>, options: &Value) {
        self.options = options.clone();
        self.active = fopt_bool(options, "active", false);
        self.requests = 0;
    }

    fn post_construct(&mut self, _ctx: &Rc<Context>) {
        if !self.active {
            return;
        }
        let sid = fopt_str(&self.options, "sessionId", "");
        self.session = if sid.is_empty() {
            self.genid("session")
        } else {
            sid
        };
        self.client_name = self.full_name();
    }

    fn pre_request(&mut self, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }

        let spec = match ctx.spec.borrow().clone() {
            Some(s) => s,
            None => return,
        };
        let headers = {
            let h = spec.borrow().headers.clone();
            if matches!(h, Value::Map(_)) {
                h
            } else {
                let nh = Value::empty_map();
                spec.borrow_mut().headers = nh.clone();
                nh
            }
        };

        // Lazily establish the session when PostConstruct never fired.
        if self.session.is_empty() {
            let sid = fopt_str(&self.options, "sessionId", "");
            self.session = if sid.is_empty() {
                self.genid("session")
            } else {
                sid
            };
        }

        let h = fopt_map(&self.options, "headers");
        self.requests += 1;
        let request_id = self.genid("request");

        fheader_set_default(
            &headers,
            &fopt_str(&h, "agent", "User-Agent"),
            &self.full_name(),
        );
        fheader_set_default(
            &headers,
            &fopt_str(&h, "client", "X-Client-Id"),
            &self.session,
        );
        setp(
            &headers,
            &fopt_str(&h, "request", "X-Request-Id"),
            Value::str(request_id.clone()),
        );

        self.last_request_id = request_id;
        self.client_name = self.full_name();
    }
}
