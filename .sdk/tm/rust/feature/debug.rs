// Request/response capture for debugging (mirrors go
// feature/debug_feature.go). Records a bounded ring buffer of
// per-operation traces — method, URL, redacted headers, response status
// and timing — on the feature's entries. Sensitive header values (matching
// `redact`, default authorization/cookie/api-key style names) are masked.
// An optional `onEntry` callback receives each finished entry. `max` caps
// the buffer (default 100).

use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{call_vfn, get_i64, get_str, getp, setp};
use crate::core::types::{Feature, OutVal};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

const DEBUG_ENTRY_KEY: &str = "debug_entry";

const DEBUG_DEFAULT_REDACT: [&str; 7] = [
    "authorization",
    "cookie",
    "set-cookie",
    "api-key",
    "apikey",
    "x-api-key",
    "idempotency-key",
];

pub struct DebugFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,

    // Activity tracking (mirrors the ts client._debug record).
    pub entries: Vec<Value>,
}

impl DebugFeature {
    pub fn new() -> DebugFeature {
        DebugFeature {
            name: "debug".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            entries: Vec::new(),
        }
    }

    fn redact(&self, headers: &Value) -> Value {
        let out = Value::empty_map();
        let patterns = fopt_str_list(&self.options, "redact")
            .unwrap_or_else(|| DEBUG_DEFAULT_REDACT.iter().map(|s| s.to_string()).collect());
        if let Value::Map(m) = headers {
            for (k, v) in m.borrow().iter() {
                let masked = patterns.iter().any(|p| k.to_lowercase() == *p);
                if masked {
                    setp(&out, k, Value::str("<redacted>"));
                } else {
                    setp(&out, k, v.clone());
                }
            }
        }
        out
    }

    fn finish(&mut self, ctx: &Rc<Context>, ok: bool) {
        // Finish once per operation: the marker in ctx.out is consumed here.
        let entry = match ctx.out_take(DEBUG_ENTRY_KEY) {
            Some(OutVal::Val(v)) if matches!(v, Value::Map(_)) => v,
            _ => return,
        };

        let result_ok = match ctx.result.borrow().clone() {
            Some(r) => r.borrow().ok,
            None => true,
        };
        setp(&entry, "ok", Value::Bool(ok && result_ok));
        let start = get_i64(&entry, "start").unwrap_or(0);
        let dur = (fopt_now(&self.options)() - start).max(0);
        setp(&entry, "durationMs", Value::Num(dur as f64));
        if getp(&entry, "status").is_noval() {
            if let Some(r) = ctx.result.borrow().clone() {
                setp(&entry, "status", Value::Num(r.borrow().status as f64));
            }
        }

        self.entries.push(entry.clone());
        let max = fopt_int(&self.options, "max", 100) as usize;
        while self.entries.len() > max {
            self.entries.remove(0);
        }

        let on_entry = getp(&self.options, "onEntry");
        if let Value::Func(_) = on_entry {
            call_vfn(&on_entry, &entry);
        }
    }
}

impl Feature for DebugFeature {
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

        let (entity, opname) = {
            let op = ctx.op.borrow();
            (op.entity.clone(), op.name.clone())
        };

        let entry = Value::empty_map();
        setp(&entry, "op", Value::str(format!("{}.{}", entity, opname)));
        setp(
            &entry,
            "start",
            Value::Num(fopt_now(&self.options)() as f64),
        );
        if let Some(spec) = ctx.spec.borrow().clone() {
            let s = spec.borrow();
            setp(&entry, "method", Value::str(s.method.clone()));
            if !s.url.is_empty() {
                setp(&entry, "url", Value::str(s.url.clone()));
            } else {
                setp(&entry, "url", Value::str(s.path.clone()));
            }
            setp(&entry, "headers", self.redact(&s.headers));
        }
        ctx.out_set(DEBUG_ENTRY_KEY, OutVal::Val(entry));
    }

    fn pre_response(&mut self, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }

        let entry = ctx.out_val(DEBUG_ENTRY_KEY);
        if !matches!(entry, Value::Map(_)) {
            return;
        }
        if let Some(response) = ctx.response.borrow().clone() {
            setp(
                &entry,
                "status",
                Value::Num(response.borrow().status as f64),
            );
            let url = get_str(&entry, "url").unwrap_or_default();
            if url.is_empty() {
                if let Some(spec) = ctx.spec.borrow().clone() {
                    setp(&entry, "url", Value::str(spec.borrow().url.clone()));
                }
            }
        }
    }

    fn pre_done(&mut self, ctx: &Rc<Context>) {
        self.finish(ctx, true);
    }

    fn pre_unexpected(&mut self, ctx: &Rc<Context>) {
        {
            let entry = ctx.out_val(DEBUG_ENTRY_KEY);
            if matches!(entry, Value::Map(_)) {
                let ctrl = ctx.ctrl.borrow().clone();
                let c = ctrl.borrow();
                if let Some(err) = &c.err {
                    setp(&entry, "error", Value::str(err.msg.clone()));
                }
            }
        }
        self.finish(ctx, false);
    }
}
