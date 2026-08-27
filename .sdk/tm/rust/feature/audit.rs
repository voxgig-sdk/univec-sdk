// Audit trail (mirrors go feature/audit_feature.go). Emits a structured
// record for every operation — who (actor), what (entity + op), the
// outcome, and a correlation id — suitable for compliance logging. Records
// accumulate on the feature (bounded by `max`, default 1000) and, when a
// `sink` callback is supplied, are also pushed to it. The actor is the
// per-call ctrl actor, falling back to the options `actor`, then
// "anonymous". Each operation is audited exactly once (the per-context
// marker in ctx.out prevents a PreDone + PreUnexpected double-log).
// Timestamps use the injectable `now` clock so tests stay deterministic.

use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{call_vfn, getp, setp};
use crate::core::types::{Feature, OutVal};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

const AUDIT_SEEN_KEY: &str = "audit_seen";

pub struct AuditFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    seq: i64,

    // Activity tracking (mirrors the ts client._audit record).
    pub records: Vec<Value>,
}

impl AuditFeature {
    pub fn new() -> AuditFeature {
        AuditFeature {
            name: "audit".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            seq: 0,
            records: Vec::new(),
        }
    }

    fn emit(&mut self, ctx: &Rc<Context>, outcome: &str) {
        if !self.active {
            return;
        }

        // One record per operation (PreDone + a following PreUnexpected on a
        // failure must not double-log).
        if let Some(OutVal::Val(Value::Bool(true))) = ctx.out_get(AUDIT_SEEN_KEY) {
            return;
        }
        ctx.out_set(AUDIT_SEEN_KEY, OutVal::Val(Value::Bool(true)));

        self.seq += 1;

        let mut actor = "anonymous".to_string();
        let opt_actor = fopt_str(&self.options, "actor", "");
        if !opt_actor.is_empty() {
            actor = opt_actor;
        }
        {
            let ctrl = ctx.ctrl.borrow().clone();
            let c = ctrl.borrow();
            if !c.actor.is_empty() {
                actor = c.actor.clone();
            }
        }

        let (entity, opname) = {
            let op = ctx.op.borrow();
            (op.entity.clone(), op.name.clone())
        };

        let record = Value::empty_map();
        setp(&record, "seq", Value::Num(self.seq as f64));
        setp(
            &record,
            "ts",
            Value::Num(fopt_now(&self.options)() as f64),
        );
        setp(&record, "actor", Value::str(actor));
        setp(&record, "entity", Value::str(entity));
        setp(&record, "op", Value::str(opname));
        setp(&record, "outcome", Value::str(outcome));
        setp(&record, "correlationId", Value::str(ctx.id.clone()));
        if let Some(r) = ctx.result.borrow().clone() {
            setp(&record, "status", Value::Num(r.borrow().status as f64));
        }

        self.records.push(record.clone());
        let max = fopt_int(&self.options, "max", 1000) as usize;
        while self.records.len() > max {
            self.records.remove(0);
        }

        let sink = getp(&self.options, "sink");
        if let Value::Func(_) = sink {
            call_vfn(&sink, &record);
        }
    }
}

impl Feature for AuditFeature {
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

    fn pre_done(&mut self, ctx: &Rc<Context>) {
        // Outcome reflects the actual result; a non-2xx reaches PreDone
        // before the pipeline errors.
        let ok = match ctx.result.borrow().clone() {
            Some(r) => {
                let r = r.borrow();
                r.ok && r.err.is_none()
            }
            None => false,
        };
        self.emit(ctx, if ok { "ok" } else { "error" });
    }

    fn pre_unexpected(&mut self, ctx: &Rc<Context>) {
        self.emit(ctx, "error");
    }
}
