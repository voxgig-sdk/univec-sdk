// Cost tracking and spend budget (mirrors ts
// src/feature/cost/CostFeature.ts). Uses BOTH seams, which is the point of
// the feature: money is spent per HTTP ATTEMPT (a retried call is charged
// again, because the upstream API charges it again), but it is owed by an
// OPERATION. So the transport wrap prices each attempt, and pre_done
// attributes the running total to `<entity>.<op>` and to the caller (the
// per-call ctrl actor, the same actor the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// `<entity>.<op>` / `<op>` / `*`), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. "usage.total_tokens") is read at pre_done
// instead, from the already-parsed result, and describes the whole call, so
// it REPLACES the per-attempt estimate rather than adding to it.
//
// `budget` caps total spend. With `onBudget: "deny"` a further operation is
// refused at pre_point (via ctx.out["point"], which MakePoint surfaces),
// before an endpoint is resolved and before anything reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent. The default (map) order
// puts cache innermost and cost outside it, so activate them in list form
// with cost first.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{call_vfn, get_f64, getp, getpath, jo, setp};
use crate::core::types::{Feature, FetcherFn, OutVal};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

const COST_PENDING_KEY: &str = "cost_pending";

#[derive(Default, Clone)]
pub struct CostBucket {
    pub calls: i64,
    pub amount: f64,
}

#[derive(Default)]
pub struct CostTrack {
    // Aggregates (mirrors the ts client._cost record).
    pub currency: String,
    pub calls: i64,
    pub attempts: i64,
    pub amount: f64,
    pub reported: f64,
    pub estimated: f64,
    pub ops: HashMap<String, CostBucket>,
    pub actors: HashMap<String, CostBucket>,
    pub limit: f64,
    pub spent: f64,
    pub remaining: f64,
    pub exceeded: bool,
    pub last: Value,
    pub seq: i64,
}

pub struct CostFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    pub track: Rc<RefCell<CostTrack>>,
}

impl CostFeature {
    pub fn new() -> CostFeature {
        CostFeature {
            name: "cost".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            track: Rc::new(RefCell::new(CostTrack::default())),
        }
    }
}

// Price one attempt: a reported header figure, else the rate table, else the
// flat unit.
fn price(options: &Value, ctx: &Rc<Context>, res: &Value) -> (f64, String) {
    let header = fopt_str(options, "header", "");
    if !header.is_empty() {
        if let Some(s) = fres_header(res, &header) {
            if let Ok(n) = s.trim().parse::<f64>() {
                return (n * fopt_num(options, "perUnit", 0.0), "header".to_string());
            }
        }
    }

    if let Some(rate) = rate(options, ctx) {
        return (rate, "table".to_string());
    }

    let unit = fopt_num(options, "unit", 0.0);
    if unit != 0.0 {
        return (unit, "unit".to_string());
    }

    (0.0, "none".to_string())
}

// The rate table uses the same lookup grammar as rbac's rules:
// `<entity>.<op>`, then `<op>`, then `*`.
fn rate(options: &Value, ctx: &Rc<Context>) -> Option<f64> {
    let rates = fopt_map(options, "rates");
    if !matches!(rates, Value::Map(_)) {
        return None;
    }

    let (entity, opname) = {
        let op = ctx.op.borrow();
        (op.entity.clone(), op.name.clone())
    };

    for key in [format!("{}.{}", entity, opname), opname, "*".to_string()] {
        if let Some(n) = get_f64(&rates, &key) {
            return Some(n);
        }
    }
    None
}

// A usage figure from the parsed result body, priced by perUnit. Read here,
// not at the transport seam, because the body is one-shot.
fn body_amount(options: &Value, ctx: &Rc<Context>) -> Option<f64> {
    let path = fopt_str(options, "path", "");
    if path.is_empty() {
        return None;
    }

    let body = match ctx.result.borrow().clone() {
        Some(r) => r.borrow().body.clone(),
        None => return None,
    };

    let segs: Vec<&str> = path.split('.').collect();
    let val = getpath(&segs, &body);

    let n = match &val {
        Value::Num(n) => *n,
        Value::Str(s) => match s.trim().parse::<f64>() {
            Ok(v) => v,
            Err(_) => return None,
        },
        _ => return None,
    };

    Some(n * fopt_num(options, "perUnit", 0.0))
}

fn spend(t: &mut CostTrack, amount: f64, reported: f64, estimated: f64) {
    t.amount += amount;
    t.reported += reported;
    t.estimated += estimated;

    t.spent = t.amount;
    if t.limit > 0.0 {
        t.remaining = (t.limit - t.amount).max(0.0);
        if t.amount >= t.limit {
            t.exceeded = true;
        }
    } else {
        t.remaining = 0.0;
    }
}

fn bump(bucket: &mut HashMap<String, CostBucket>, key: String, amount: f64) {
    let entry = bucket.entry(key).or_default();
    entry.calls += 1;
    entry.amount += amount;
}

fn charge(
    track: &Rc<RefCell<CostTrack>>,
    options: &Value,
    ctx: &Rc<Context>,
    url: &str,
    fetchdef: &Value,
    inner: &FetcherFn,
) -> Result<Value, UnivecError> {
    let out = inner(ctx, url, fetchdef);

    let res = match &out {
        Ok(r) => r.clone(),
        Err(_) => Value::Noval,
    };

    let (amount, source) = price(options, ctx, &res);

    // Accumulated on the context, committed once at pre_done. Adding each
    // attempt to the running total and then subtracting it again when a body
    // figure supersedes it loses precision to catastrophic cancellation.
    let pending = match ctx.out_take(COST_PENDING_KEY) {
        Some(OutVal::Val(v)) if matches!(v, Value::Map(_)) => v,
        other => {
            if let Some(o) = other {
                ctx.out_set(COST_PENDING_KEY, o);
            }
            new_pending()
        }
    };

    let attempts = get_f64(&pending, "attempts").unwrap_or(0.0) + 1.0;
    let total = get_f64(&pending, "amount").unwrap_or(0.0) + amount;

    // Reported and estimated are kept apart per ATTEMPT: a 503 priced from the
    // rate table followed by a 200 carrying the cost header is part estimate,
    // part reported, and collapsing both into the final attempt's category
    // would corrupt the split.
    //
    // A failed transport is an Err VALUE here, not a panic, so it already
    // reaches this point and is priced from the table or unit - no separate
    // catch is needed, unlike the ts/js ports.
    let bucket = if "header" == source || "body" == source { "reported" } else { "estimated" };
    let prev = get_f64(&pending, bucket).unwrap_or(0.0);
    setp(&pending, bucket, Value::Num(prev + amount));

    setp(&pending, "attempts", Value::Num(attempts));
    setp(&pending, "amount", Value::Num(total));
    setp(&pending, "source", Value::str(source));

    let piped = matches!(getp(&pending, "piped"), Value::Bool(true));

    track.borrow_mut().attempts += 1;

    // direct() and graphql() reach the transport without dispatching any
    // pipeline hooks, so there is no pre_point to gate on and no pre_done to
    // commit. Their spend is committed here, or it would never be counted.
    if !piped {
        commit(track, options, ctx, &pending, "_", "direct");
        ctx.out_take(COST_PENDING_KEY);
    } else {
        ctx.out_set(COST_PENDING_KEY, OutVal::Val(pending));
    }

    out
}


fn new_pending() -> Value {
    jo(vec![
        ("attempts", Value::Num(0.0)),
        ("amount", Value::Num(0.0)),
        ("reported", Value::Num(0.0)),
        ("estimated", Value::Num(0.0)),
        ("source", Value::str("none".to_string())),
        ("piped", Value::Bool(false)),
    ])
}


// Commit one operation's spend: totals, budget, per-op and per-actor
// attribution, and the record. Shared by finish and the raw-request path in
// charge, which has no pre_done to reach.
fn commit(
    track: &Rc<RefCell<CostTrack>>,
    options: &Value,
    ctx: &Rc<Context>,
    pending: &Value,
    entity: &str,
    opname: &str,
) {
    let attempts = get_f64(pending, "attempts").unwrap_or(0.0);
    let mut amount = get_f64(pending, "amount").unwrap_or(0.0);
    let mut reported = get_f64(pending, "reported").unwrap_or(0.0);
    let mut estimated = get_f64(pending, "estimated").unwrap_or(0.0);
    let mut source = match getp(pending, "source") {
        Value::Str(s) => s,
        _ => "none".to_string(),
    };

    // A body figure prices the whole call, so it replaces the per-attempt
    // estimate rather than adding to it, and being server-stated the whole
    // amount counts as reported.
    if let Some(b) = body_amount(options, ctx) {
        amount = b;
        reported = b;
        estimated = 0.0;
        source = "body".to_string();
    }

    let mut actor = "anonymous".to_string();
    let opt_actor = fopt_str(options, "actor", "");
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

    let record = jo(vec![]);
    {
        let mut t = track.borrow_mut();
        spend(&mut t, amount, reported, estimated);
        t.calls += 1;
        t.seq += 1;

        bump(&mut t.ops, format!("{}.{}", entity, opname), amount);
        bump(&mut t.actors, actor.clone(), amount);

        setp(&record, "seq", Value::Num(t.seq as f64));
        setp(&record, "entity", Value::str(entity.to_string()));
        setp(&record, "op", Value::str(opname.to_string()));
        setp(&record, "actor", Value::str(actor));
        setp(&record, "amount", Value::Num(amount));
        setp(&record, "currency", Value::str(t.currency.clone()));
        setp(&record, "source", Value::str(source));
        setp(&record, "attempts", Value::Num(attempts));

        t.last = record.clone();
    }

    let sink = getp(options, "sink");
    if let Value::Func(_) = sink {
        call_vfn(&sink, &record);
    }
}

impl Feature for CostFeature {
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

        let limit = fopt_num(options, "budget", 0.0);
        {
            let mut t = self.track.borrow_mut();
            *t = CostTrack::default();
            t.currency = fopt_str(options, "currency", "USD");
            t.limit = limit;
            t.remaining = limit;
            t.last = Value::Noval;
        }

        if !self.active {
            return;
        }

        let util = ctx.util();
        let inner: FetcherFn = util.fetcher.borrow().clone();
        let track = self.track.clone();
        let options = options.clone();

        *util.fetcher.borrow_mut() = Rc::new(move |ctx2, url, fetchdef| {
            charge(&track, &options, ctx2, url, fetchdef, &inner)
        });
    }

    // The budget gate. Runs before endpoint resolution, so a refused call
    // costs nothing at all.
    fn pre_point(&mut self, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }

        let (limit, amount, currency) = {
            let t = self.track.borrow();
            (t.limit, t.amount, t.currency.clone())
        };

        // Mark the context as running through the pipeline, so charge knows a
        // pre_done is coming and does not commit the spend itself.
        let pending = match ctx.out_take(COST_PENDING_KEY) {
            Some(OutVal::Val(v)) if matches!(v, Value::Map(_)) => v,
            other => {
                if let Some(o) = other {
                    ctx.out_set(COST_PENDING_KEY, o);
                }
                new_pending()
            }
        };
        setp(&pending, "piped", Value::Bool(true));
        ctx.out_set(COST_PENDING_KEY, OutVal::Val(pending));

        if limit <= 0.0 || amount < limit {
            return;
        }

        self.track.borrow_mut().exceeded = true;

        if "deny" != fopt_str(&self.options, "onBudget", "warn") {
            return;
        }

        let err = ctx.make_error(
            "cost_budget",
            &format!(
                "Cost budget of {} {} is spent ({} {} used)",
                limit, currency, amount, currency
            ),
        );

        // Short-circuit endpoint resolution; MakePoint surfaces this error
        // before any network activity.
        ctx.out_set("point", OutVal::Err(err));
    }

    // Attribute the operation's spend once the call is finished.
    fn pre_done(&mut self, ctx: &Rc<Context>) {
        self.finish(ctx, true);
    }

    // A failed operation still spent the money. When the pipeline errors,
    // pre_done never runs, so without this the attempts are counted and the
    // spend is not, and a budget could never see the cost of a failed call.
    // Whichever hook fires first consumes the pending entry, so it commits
    // exactly once.
    fn pre_unexpected(&mut self, ctx: &Rc<Context>) {
        self.finish(ctx, false);
    }
}

impl CostFeature {
    fn finish(&mut self, ctx: &Rc<Context>, done: bool) {
        if !self.active {
            return;
        }

        let pending = match ctx.out_take(COST_PENDING_KEY) {
            Some(OutVal::Val(v)) if matches!(v, Value::Map(_)) => v,
            other => {
                if let Some(o) = other {
                    ctx.out_set(COST_PENDING_KEY, o);
                }
                return;
            }
        };

        // A FAILED operation that made no attempt never reached the network:
        // PrePoint creates the pending entry to mark the context as piped, and
        // then the budget gate refuses the call (rbac, or an unresolvable
        // endpoint, short-circuits just as early). Committing it would count a
        // call that never happened and file a zero-amount record as `last`.
        //
        // A SUCCEEDED operation that made no attempt is the opposite case: it was
        // served from the cache. That is a real call, and the fact that it cost
        // nothing is the whole point of ordering cost inside the cache.
        if !done && 0.0 == get_f64(&pending, "attempts").unwrap_or(0.0) {
            return;
        }

        let (entity, opname) = {
            let op = ctx.op.borrow();
            (op.entity.clone(), op.name.clone())
        };

        commit(&self.track, &self.options, ctx, &pending, &entity, &opname);
    }
}
