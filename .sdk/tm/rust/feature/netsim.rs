// Network behaviour simulation (mirrors go feature/netsim_feature.go).
// Wraps the active transport (the live ureq fetch or the `test` feature's
// in-memory mock) and injects realistic network conditions so offline unit
// tests can exercise slowness, transient failures, rate limiting and
// outages deterministically.
//
// Every injection mode is counter-driven (per client instance) so tests
// are reproducible without mocking timers. `failRate` adds optional
// pseudo-random failures via a seeded LCG for coverage-style testing.

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, jo, json_thunk, setp};
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

#[derive(Default)]
pub struct NetsimTrack {
    pub seed: i64,

    // Activity tracking (mirrors the ts client._netsim record).
    pub calls: i64,
    pub applied: Vec<Value>,
}

pub struct NetsimFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    pub track: Rc<RefCell<NetsimTrack>>,
}

impl NetsimFeature {
    pub fn new() -> NetsimFeature {
        NetsimFeature {
            name: "netsim".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            track: Rc::new(RefCell::new(NetsimTrack::default())),
        }
    }
}

impl Feature for NetsimFeature {
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

        {
            let mut t = self.track.borrow_mut();
            t.seed = fopt_int(options, "seed", 0);
            if t.seed == 0 {
                t.seed = 1;
            }
        }

        if !self.active {
            return;
        }

        let util = ctx.util();
        let inner: FetcherFn = util.fetcher.borrow().clone();
        let track = self.track.clone();
        let options = options.clone();

        *util.fetcher.borrow_mut() = Rc::new(move |ctx2, url, fetchdef| {
            simulate(&track, &options, ctx2, url, fetchdef, &inner)
        });
    }
}

// A deterministic 0..1 pseudo-random via a linear congruential generator.
fn lcg_rand(track: &Rc<RefCell<NetsimTrack>>) -> f64 {
    let mut t = track.borrow_mut();
    t.seed = (t.seed.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7fffffff;
    t.seed as f64 / 0x7fffffff as f64
}

// pickLatency yields ms: a fixed number, or a uniform sample from {min,max}.
fn pick_latency(track: &Rc<RefCell<NetsimTrack>>, options: &Value) -> i64 {
    let l = getp(options, "latency");
    if l.is_noval() || l.is_null() {
        return 0;
    }
    if let Value::Map(_) = l {
        let min = fopt_int(&l, "min", 0);
        let max = fopt_int(&l, "max", min);
        if max <= min {
            return min;
        }
        return min + (lcg_rand(track) * (max - min) as f64) as i64;
    }
    fopt_int(options, "latency", 0).max(0)
}

fn track_applied(track: &Rc<RefCell<NetsimTrack>>, ctx: &Rc<Context>, applied: Value) {
    let (calls, applied_list) = {
        let mut t = track.borrow_mut();
        t.applied.push(applied);
        (t.calls, Value::list(t.applied.clone()))
    };
    let ctrl = ctx.ctrl.borrow().clone();
    let c = ctrl.borrow();
    if c.has_explain() {
        setp(
            &c.explain,
            "netsim",
            jo(vec![
                ("calls", Value::Num(calls as f64)),
                ("applied", applied_list),
            ]),
        );
    }
}

// respond builds a transport-shaped response (matching the test feature's
// mock) that the result pipeline understands.
fn respond(status: i64, data: Value, extra: Vec<(&str, Value)>) -> Value {
    let out = jo(vec![
        ("status", Value::Num(status as f64)),
        ("statusText", Value::str("OK")),
        ("json", json_thunk(data)),
        ("body", Value::str("not-used")),
        ("headers", Value::empty_map()),
    ]);
    for (k, v) in extra {
        setp(&out, k, v);
    }
    out
}

fn simulate(
    track: &Rc<RefCell<NetsimTrack>>,
    opts: &Value,
    ctx: &Rc<Context>,
    url: &str,
    fetchdef: &Value,
    inner: &FetcherFn,
) -> Result<Value, UnivecError> {
    let call = {
        let mut t = track.borrow_mut();
        t.calls += 1;
        t.calls
    };

    let sleep = fopt_sleep(opts);

    // Total outage: every call fails at the transport level.
    if fopt_bool(opts, "offline", false) {
        sleep(pick_latency(track, opts));
        track_applied(track, ctx, jo(vec![("offline", Value::Bool(true))]));
        return Err(ctx.make_error(
            "netsim_offline",
            &format!("Simulated network offline (URL was: \"{}\")", url),
        ));
    }

    // Connection-level errors for the first N calls (e.g. ECONNRESET).
    if call <= fopt_int(opts, "errorTimes", 0) {
        sleep(pick_latency(track, opts));
        track_applied(track, ctx, jo(vec![("error", Value::Bool(true))]));
        return Err(ctx.make_error(
            "netsim_conn",
            &format!("Simulated connection error (call {})", call),
        ));
    }

    // Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
    if call <= fopt_int(opts, "rateLimitTimes", 0) {
        sleep(pick_latency(track, opts));
        track_applied(track, ctx, jo(vec![("rateLimited", Value::Bool(true))]));
        let headers = jo(vec![(
            "retry-after",
            Value::str(format!("{}", fopt_int(opts, "retryAfter", 0))),
        )]);
        return Ok(respond(
            429,
            Value::Noval,
            vec![
                ("statusText", Value::str("Too Many Requests")),
                ("headers", headers),
            ],
        ));
    }

    // Retryable failure status for the first N calls, or every Nth call,
    // or pseudo-randomly at `failRate`.
    let fail_status = fopt_int(opts, "failStatus", 503);
    let fail_every = fopt_int(opts, "failEvery", 0);
    let fail_by_count = call <= fopt_int(opts, "failTimes", 0);
    let fail_by_every = fail_every > 0 && call % fail_every == 0;
    let fail_rate = fopt_num(opts, "failRate", 0.0);
    let fail_by_rate = fail_rate > 0.0 && lcg_rand(track) < fail_rate;
    if fail_by_count || fail_by_every || fail_by_rate {
        sleep(pick_latency(track, opts));
        track_applied(
            track,
            ctx,
            jo(vec![("failStatus", Value::Num(fail_status as f64))]),
        );
        return Ok(respond(
            fail_status,
            Value::Noval,
            vec![("statusText", Value::str("Simulated Failure"))],
        ));
    }

    // Otherwise: apply latency then delegate to the real transport.
    let latency = pick_latency(track, opts);
    track_applied(
        track,
        ctx,
        jo(vec![("latency", Value::Num(latency as f64))]),
    );
    sleep(latency);
    inner(ctx, url, fetchdef)
}
