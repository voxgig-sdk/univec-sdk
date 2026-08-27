// Per-request timeout (mirrors go feature/timeout_feature.go, adapted to a
// synchronous single-threaded transport like the ruby port). The active
// transport is wrapped with a deadline of `ms` milliseconds (default
// 30000; <= 0 disables). The transport is synchronous, so the elapsed
// (injectable `now`) clock is checked around the inner call: when the call
// took longer than the deadline its result is discarded and a `timeout`
// error is returned instead.

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

#[derive(Default)]
pub struct TimeoutTrack {
    // Activity tracking (mirrors the ts client._timeout record).
    pub count: i64,
    pub ms: i64,
}

pub struct TimeoutFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    pub track: Rc<RefCell<TimeoutTrack>>,
}

impl TimeoutFeature {
    pub fn new() -> TimeoutFeature {
        TimeoutFeature {
            name: "timeout".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            track: Rc::new(RefCell::new(TimeoutTrack::default())),
        }
    }
}

impl Feature for TimeoutFeature {
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

        let util = ctx.util();
        let inner: FetcherFn = util.fetcher.borrow().clone();
        let track = self.track.clone();
        let options = options.clone();

        *util.fetcher.borrow_mut() = Rc::new(move |ctx2, url, fetchdef| {
            with_timeout(&track, &options, ctx2, url, fetchdef, &inner)
        });
    }
}

fn with_timeout(
    track: &Rc<RefCell<TimeoutTrack>>,
    options: &Value,
    ctx: &Rc<Context>,
    url: &str,
    fetchdef: &Value,
    inner: &FetcherFn,
) -> Result<Value, UnivecError> {
    let ms = fopt_int(options, "ms", 30000);
    if ms <= 0 {
        return inner(ctx, url, fetchdef);
    }

    let now = fopt_now(options);
    let start = now();
    let out = inner(ctx, url, fetchdef);

    if now() - start > ms {
        let mut t = track.borrow_mut();
        t.count += 1;
        t.ms = ms;
        return Err(ctx.make_error(
            "timeout",
            &format!("Request exceeded timeout of {}ms", ms),
        ));
    }

    out
}
