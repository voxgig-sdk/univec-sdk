// Idempotency keys for mutating operations (mirrors go
// feature/idempotency_feature.go). Adds an `Idempotency-Key` header (name
// configurable via `header`) to unsafe requests so a server can
// de-duplicate retried writes. The key is set once, at PreRequest, before
// the request is built — so it is stable across transport-level retries of
// the same call. A caller-supplied header is never overwritten
// (case-insensitive). The key generator is injectable (`keygen`).

use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{call_vfn, getp, rand_int, setp};
use crate::core::types::Feature;
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

pub struct IdempotencyFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,

    // Activity tracking (mirrors the ts client._idempotency record).
    pub issued: i64,
    pub last: String,
}

impl IdempotencyFeature {
    pub fn new() -> IdempotencyFeature {
        IdempotencyFeature {
            name: "idempotency".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            issued: 0,
            last: String::new(),
        }
    }

    fn mutating(&self, ctx: &Rc<Context>) -> bool {
        let methods = fopt_str_list(&self.options, "methods").unwrap_or_else(|| {
            vec![
                "POST".to_string(),
                "PUT".to_string(),
                "PATCH".to_string(),
                "DELETE".to_string(),
            ]
        });
        let method = match ctx.spec.borrow().clone() {
            Some(sp) => sp.borrow().method.to_uppercase(),
            None => String::new(),
        };
        if !method.is_empty() && methods.iter().any(|m| m.to_uppercase() == method) {
            return true;
        }

        let opname = ctx.op.borrow().name.clone();
        let ops = fopt_str_list(&self.options, "ops").unwrap_or_else(|| {
            vec![
                "create".to_string(),
                "update".to_string(),
                "remove".to_string(),
            ]
        });
        ops.iter().any(|o| *o == opname)
    }

    fn genkey(&self) -> String {
        let keygen = getp(&self.options, "keygen");
        if let Value::Func(_) = keygen {
            if let Value::Str(s) = call_vfn(&keygen, &Value::Noval) {
                return s;
            }
        }
        let key = format!(
            "{:06x}{:06x}{:06x}{:06x}",
            rand_int(0x1000000),
            rand_int(0x1000000),
            rand_int(0x1000000),
            rand_int(0x1000000)
        );
        key[..24].to_string()
    }
}

impl Feature for IdempotencyFeature {
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
    }

    fn pre_request(&mut self, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }

        let spec = match ctx.spec.borrow().clone() {
            Some(s) => s,
            None => return,
        };

        if !self.mutating(ctx) {
            return;
        }

        let header = fopt_str(&self.options, "header", "Idempotency-Key");
        {
            let headers = spec.borrow().headers.clone();
            let headers = if matches!(headers, Value::Map(_)) {
                headers
            } else {
                let h = Value::empty_map();
                spec.borrow_mut().headers = h.clone();
                h
            };

            // Respect a key the caller already provided.
            if fheader_get(&headers, &header).is_some() {
                return;
            }

            let key = self.genkey();
            setp(&headers, &header, Value::str(key.clone()));

            self.issued += 1;
            self.last = key;
        }
    }
}
