// Request specification (mirrors go core/spec.go).

use crate::core::helpers::{get_str, getp};
use crate::utility::voxgigstruct::Value;

pub struct Spec {
    pub parts: Value,
    pub headers: Value,
    pub alias: Value,
    pub base: String,
    pub prefix: String,
    pub suffix: String,
    pub params: Value,
    pub query: Value,
    pub step: String,
    pub method: String,
    pub body: Value,
    pub url: String,
    pub path: String,
}

impl Spec {
    pub fn new(specmap: &Value) -> Spec {
        let mut s = Spec {
            parts: Value::Noval,
            headers: Value::empty_map(),
            alias: Value::empty_map(),
            base: String::new(),
            prefix: String::new(),
            suffix: String::new(),
            params: Value::empty_map(),
            query: Value::empty_map(),
            step: String::new(),
            method: "GET".to_string(),
            body: Value::Noval,
            url: String::new(),
            path: String::new(),
        };

        if !matches!(specmap, Value::Map(_)) {
            return s;
        }

        if let Value::List(_) = getp(specmap, "parts") {
            s.parts = getp(specmap, "parts");
        }
        if let Value::Map(_) = getp(specmap, "headers") {
            s.headers = getp(specmap, "headers");
        }
        if let Value::Map(_) = getp(specmap, "alias") {
            s.alias = getp(specmap, "alias");
        }
        if let Some(b) = get_str(specmap, "base") {
            s.base = b;
        }
        if let Some(p) = get_str(specmap, "prefix") {
            s.prefix = p;
        }
        if let Some(sf) = get_str(specmap, "suffix") {
            s.suffix = sf;
        }
        if let Value::Map(_) = getp(specmap, "params") {
            s.params = getp(specmap, "params");
        }
        if let Value::Map(_) = getp(specmap, "query") {
            s.query = getp(specmap, "query");
        }
        if let Some(st) = get_str(specmap, "step") {
            s.step = st;
        }
        if let Some(m) = get_str(specmap, "method") {
            s.method = m;
        }
        let body = getp(specmap, "body");
        if !body.is_noval() {
            s.body = body;
        }
        if let Some(u) = get_str(specmap, "url") {
            s.url = u;
        }
        if let Some(p) = get_str(specmap, "path") {
            s.path = p;
        }

        s
    }

    /// Match-map view for tests and explain records.
    pub fn to_value(&self) -> Value {
        let out = Value::empty_map();
        crate::core::helpers::setp(&out, "base", Value::str(self.base.clone()));
        crate::core::helpers::setp(&out, "prefix", Value::str(self.prefix.clone()));
        crate::core::helpers::setp(&out, "suffix", Value::str(self.suffix.clone()));
        crate::core::helpers::setp(&out, "path", Value::str(self.path.clone()));
        crate::core::helpers::setp(&out, "method", Value::str(self.method.clone()));
        crate::core::helpers::setp(&out, "params", self.params.clone());
        crate::core::helpers::setp(&out, "query", self.query.clone());
        crate::core::helpers::setp(&out, "headers", self.headers.clone());
        crate::core::helpers::setp(&out, "step", Value::str(self.step.clone()));
        crate::core::helpers::setp(&out, "alias", self.alias.clone());
        if !self.body.is_noval() {
            crate::core::helpers::setp(&out, "body", self.body.clone());
        }
        if !self.url.is_empty() {
            crate::core::helpers::setp(&out, "url", Value::str(self.url.clone()));
        }
        out
    }
}
