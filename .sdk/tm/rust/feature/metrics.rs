// Statistics capture (mirrors go feature/metrics_feature.go). Records
// per-operation counters and latency for every call: totals plus a
// breakdown keyed by `<entity>.<op>`. Timing starts at endpoint resolution
// (PrePoint) and stops when the call returns (PreDone) or fails
// (PreUnexpected); each operation is recorded exactly once (the
// per-context start marker in ctx.out is consumed on record). The clock is
// injectable (`now`) for deterministic tests.

use std::collections::HashMap;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::to_int;
use crate::core::types::{Feature, OutVal};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

const METRICS_START_KEY: &str = "metrics_start";

#[derive(Default, Clone)]
pub struct MetricsBucket {
    pub count: i64,
    pub ok: i64,
    pub err: i64,
    pub total_ms: i64,
    pub max_ms: i64,
}

pub struct MetricsFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,

    // Aggregates (mirrors the ts client._metrics record).
    pub total: MetricsBucket,
    pub ops: HashMap<String, MetricsBucket>,
}

impl MetricsFeature {
    pub fn new() -> MetricsFeature {
        MetricsFeature {
            name: "metrics".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            total: MetricsBucket::default(),
            ops: HashMap::new(),
        }
    }

    fn record(&mut self, ctx: &Rc<Context>, ok: bool) {
        // Record once per operation: the missing start marker makes a second
        // call (PreDone followed by PreUnexpected on failure) a no-op.
        let start = match ctx.out_take(METRICS_START_KEY) {
            Some(OutVal::Val(v)) if matches!(v, Value::Num(_)) => to_int(&v),
            other => {
                // Put back anything unexpected (should not happen).
                if let Some(o) = other {
                    ctx.out_set(METRICS_START_KEY, o);
                }
                return;
            }
        };

        let dur = (fopt_now(&self.options)() - start).max(0);

        let (entity, opname) = {
            let op = ctx.op.borrow();
            (op.entity.clone(), op.name.clone())
        };
        let key = format!("{}.{}", entity, opname);

        bump(&mut self.total, ok, dur);
        bump(self.ops.entry(key).or_default(), ok, dur);
    }
}

fn bump(bucket: &mut MetricsBucket, ok: bool, dur: i64) {
    bucket.count += 1;
    if ok {
        bucket.ok += 1;
    } else {
        bucket.err += 1;
    }
    bucket.total_ms += dur;
    if dur > bucket.max_ms {
        bucket.max_ms = dur;
    }
}

impl Feature for MetricsFeature {
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
        self.total = MetricsBucket::default();
        self.ops = HashMap::new();
    }

    fn pre_point(&mut self, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }
        ctx.out_set(
            METRICS_START_KEY,
            OutVal::Val(Value::Num(fopt_now(&self.options)() as f64)),
        );
    }

    fn pre_done(&mut self, ctx: &Rc<Context>) {
        // Classify by the actual result: a 4xx/5xx that flows through still
        // reaches PreDone before the pipeline errors.
        let ok = match ctx.result.borrow().clone() {
            Some(r) => {
                let r = r.borrow();
                r.ok && r.err.is_none()
            }
            None => false,
        };
        self.record(ctx, ok);
    }

    fn pre_unexpected(&mut self, ctx: &Rc<Context>) {
        self.record(ctx, false);
    }
}
