// Distributed-tracing telemetry (mirrors go feature/telemetry_feature.go).
// Opens a span per operation (PrePoint), propagates trace context to the
// server as W3C `traceparent` plus `X-Trace-Id` / `X-Span-Id` headers
// (PreRequest), and closes the span on completion (PreDone) or failure
// (PreUnexpected). Each span closes exactly once (the per-context marker
// in ctx.out is consumed on close). Finished spans accumulate on the
// feature; an `exporter` callback, when provided, is invoked with each
// finished span. Trace/span id generation (`idgen`) and the clock (`now`)
// are injectable for deterministic tests.

use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{call_vfn, get_i64, get_str, getp, setp};
use crate::core::types::{Feature, OutVal};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

const TELEMETRY_SPAN_KEY: &str = "telemetry_span";

pub struct TelemetryFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    seq: i64,

    // Activity tracking (mirrors the ts client._telemetry record).
    pub spans: Vec<Value>,
    pub active_spans: i64,
}

impl TelemetryFeature {
    pub fn new() -> TelemetryFeature {
        TelemetryFeature {
            name: "telemetry".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            seq: 0,
            spans: Vec::new(),
            active_spans: 0,
        }
    }

    fn id(&mut self, kind: &str) -> String {
        let idgen = getp(&self.options, "idgen");
        if let Value::Func(_) = idgen {
            if let Value::Str(s) = call_vfn(&idgen, &Value::str(kind)) {
                return s;
            }
        }
        // Deterministic-ish sequential id; unique within a client instance.
        self.seq += 1;
        let mut n = format!("{:04x}", self.seq);
        let prefix = if kind == "trace" { "t" } else { "s" };
        while n.len() < 16 {
            n.push('0');
        }
        format!("{}{}", prefix, n)
    }

    fn close(&mut self, ctx: &Rc<Context>, ok: bool) {
        // Close once per operation; a PreDone followed by a pipeline failure
        // (non-2xx) fires PreUnexpected too, which then finds no open span.
        let span = match ctx.out_take(TELEMETRY_SPAN_KEY) {
            Some(OutVal::Val(v)) if matches!(v, Value::Map(_)) => v,
            _ => return,
        };

        let end = fopt_now(&self.options)();
        let start = get_i64(&span, "start").unwrap_or(0);
        let dur = (end - start).max(0);
        setp(&span, "end", Value::Num(end as f64));
        setp(&span, "durationMs", Value::Num(dur as f64));
        setp(&span, "ok", Value::Bool(ok));

        self.active_spans -= 1;
        self.spans.push(span.clone());

        let exporter = getp(&self.options, "exporter");
        if let Value::Func(_) = exporter {
            call_vfn(&exporter, &span);
        }
    }
}

impl Feature for TelemetryFeature {
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
        self.seq = 0;
    }

    fn pre_point(&mut self, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }

        let (entity, opname) = {
            let op = ctx.op.borrow();
            (op.entity.clone(), op.name.clone())
        };

        let span = Value::empty_map();
        setp(&span, "traceId", Value::str(self.id("trace")));
        setp(&span, "spanId", Value::str(self.id("span")));
        setp(&span, "name", Value::str(format!("{}.{}", entity, opname)));
        setp(
            &span,
            "start",
            Value::Num(fopt_now(&self.options)() as f64),
        );
        ctx.out_set(TELEMETRY_SPAN_KEY, OutVal::Val(span));
        self.active_spans += 1;
    }

    fn pre_request(&mut self, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }

        let span = ctx.out_val(TELEMETRY_SPAN_KEY);
        let spec = ctx.spec.borrow().clone();
        let spec = match (matches!(span, Value::Map(_)), spec) {
            (true, Some(s)) => s,
            _ => return,
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

        let h = fopt_map(&self.options, "headers");
        let trace_id = get_str(&span, "traceId").unwrap_or_default();
        let span_id = get_str(&span, "spanId").unwrap_or_default();
        setp(
            &headers,
            &fopt_str(&h, "trace", "X-Trace-Id"),
            Value::str(trace_id.clone()),
        );
        setp(
            &headers,
            &fopt_str(&h, "span", "X-Span-Id"),
            Value::str(span_id.clone()),
        );
        setp(
            &headers,
            &fopt_str(&h, "parent", "traceparent"),
            Value::str(format!("00-{}-{}-01", trace_id, span_id)),
        );
    }

    fn pre_done(&mut self, ctx: &Rc<Context>) {
        let ok = match ctx.result.borrow().clone() {
            Some(r) => {
                let r = r.borrow();
                r.ok && r.err.is_none()
            }
            None => false,
        };
        self.close(ctx, ok);
    }

    fn pre_unexpected(&mut self, ctx: &Rc<Context>) {
        self.close(ctx, false);
    }
}
