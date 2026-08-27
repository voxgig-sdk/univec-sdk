// Client-side rate limiting via a token bucket (mirrors go
// feature/ratelimit_feature.go). Each request consumes a token; when the
// bucket is empty the request waits until the bucket refills at `rate`
// tokens per second (with capacity `burst`, default: rate). The clock
// (`now`) and the wait (`sleep`) are injectable so the accounting can be
// tested deterministically.

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

#[derive(Default)]
pub struct RatelimitTrack {
    pub tokens: f64,
    pub last: i64,

    // Activity tracking (mirrors the ts client._ratelimit record).
    pub throttled: i64,
    pub wait_ms: i64,
}

pub struct RatelimitFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    pub track: Rc<RefCell<RatelimitTrack>>,
}

impl RatelimitFeature {
    pub fn new() -> RatelimitFeature {
        RatelimitFeature {
            name: "ratelimit".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            track: Rc::new(RefCell::new(RatelimitTrack::default())),
        }
    }
}

impl Feature for RatelimitFeature {
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

        let rate = fopt_num(options, "rate", 5.0);
        let burst = fopt_num(options, "burst", rate);
        {
            let mut t = self.track.borrow_mut();
            t.tokens = burst;
            t.last = fopt_now(options)();
        }

        let util = ctx.util();
        let inner: FetcherFn = util.fetcher.borrow().clone();
        let track = self.track.clone();
        let options = options.clone();

        *util.fetcher.borrow_mut() = Rc::new(move |ctx2, url, fetchdef| {
            acquire(&track, &options);
            inner(ctx2, url, fetchdef)
        });
    }
}

fn acquire(track: &Rc<RefCell<RatelimitTrack>>, options: &Value) {
    let rate = fopt_num(options, "rate", 5.0);
    let burst = fopt_num(options, "burst", rate);
    let now_fn = fopt_now(options);

    // Refill according to elapsed time.
    let now = now_fn();
    let wait_ms;
    {
        let mut t = track.borrow_mut();
        let elapsed = now - t.last;
        t.last = now;
        t.tokens = burst.min(t.tokens + (elapsed as f64 / 1000.0) * rate);

        if t.tokens >= 1.0 {
            t.tokens -= 1.0;
            return;
        }

        // Not enough tokens: wait for one to accrue, then consume it.
        let needed = 1.0 - t.tokens;
        wait_ms = ((needed / rate) * 1000.0).ceil() as i64;
        t.throttled += 1;
        t.wait_ms += wait_ms;
    }
    if wait_ms > 0 {
        fopt_sleep(options)(wait_ms);
    }
    let mut t = track.borrow_mut();
    t.last = now_fn();
    t.tokens = 0.0;
}
