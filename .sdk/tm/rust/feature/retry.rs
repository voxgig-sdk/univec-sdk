// Automatic retry of transient failures with exponential backoff and
// jitter (mirrors go feature/retry_feature.go). Wraps the active transport
// so a single operation call may make several HTTP attempts. A failure is
// retryable when the transport returns an error, or responds with a status
// in `statuses` (default: 408, 425, 429, 500, 502, 503, 504). An HTTP
// 429/503 with a `Retry-After` header overrides the computed backoff.

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::rand_int;
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

#[derive(Default)]
pub struct RetryTrack {
    // Activity tracking (mirrors the ts client._retry record).
    pub attempts: i64,
    pub retries: Vec<Value>,
}

pub struct RetryFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    pub track: Rc<RefCell<RetryTrack>>,
}

impl RetryFeature {
    pub fn new() -> RetryFeature {
        RetryFeature {
            name: "retry".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            track: Rc::new(RefCell::new(RetryTrack::default())),
        }
    }
}

impl Feature for RetryFeature {
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
            with_retry(&track, &options, ctx2, url, fetchdef, &inner)
        });
    }
}

fn with_retry(
    track: &Rc<RefCell<RetryTrack>>,
    options: &Value,
    ctx: &Rc<Context>,
    url: &str,
    fetchdef: &Value,
    inner: &FetcherFn,
) -> Result<Value, UnivecError> {
    let max = fopt_int(options, "retries", 2);
    let min_delay = fopt_int(options, "minDelay", 50);
    let max_delay = fopt_int(options, "maxDelay", 2000);
    let factor = fopt_num(options, "factor", 2.0);

    let mut attempt: i64 = 0;

    loop {
        let out = inner(ctx, url, fetchdef);

        if !retryable(options, &out) || attempt >= max {
            // Out of attempts (or not retryable): return the last
            // response/error as-is to preserve pipeline semantics.
            return out;
        }

        let wait = backoff(options, &out, attempt, min_delay, max_delay, factor);
        track_attempt(track, attempt + 1, &out, wait);
        if wait > 0 {
            fopt_sleep(options)(wait);
        }
        attempt += 1;
    }
}

fn retryable(options: &Value, out: &Result<Value, UnivecError>) -> bool {
    let res = match out {
        Err(_) => return true,
        Ok(r) => r,
    };
    if res.is_noval() || res.is_null() {
        return true;
    }
    let status = match fres_status(res) {
        Some(s) => s,
        None => return false,
    };
    let statuses: Vec<i64> = match fopt_list(options, "statuses") {
        Value::List(l) => l
            .borrow()
            .iter()
            .filter_map(|v| match v {
                Value::Num(n) => Some(*n as i64),
                _ => None,
            })
            .collect(),
        _ => vec![408, 425, 429, 500, 502, 503, 504],
    };
    statuses.contains(&status)
}

fn backoff(
    options: &Value,
    out: &Result<Value, UnivecError>,
    attempt: i64,
    min_delay: i64,
    max_delay: i64,
    factor: f64,
) -> i64 {
    // Honour a server-provided Retry-After (seconds) when present.
    if let Ok(res) = out {
        if let Some(ra) = retry_after(res) {
            return ra.min(max_delay);
        }
    }
    let base = (min_delay as f64) * factor.powf(attempt as f64);
    let jitter = if fopt_bool(options, "jitter", true) && min_delay > 0 {
        rand_int(min_delay)
    } else {
        0
    };
    let wait = base as i64 + jitter;
    wait.min(max_delay)
}

fn retry_after(res: &Value) -> Option<i64> {
    let v = fres_header(res, "retry-after")?;
    let seconds = fparse_int(&v, -1);
    if seconds < 0 {
        return None;
    }
    Some(seconds * 1000)
}

fn track_attempt(
    track: &Rc<RefCell<RetryTrack>>,
    attempt: i64,
    out: &Result<Value, UnivecError>,
    wait: i64,
) {
    let mut t = track.borrow_mut();
    t.attempts += 1;

    let entry = Value::empty_map();
    crate::core::helpers::setp(&entry, "attempt", Value::Num(attempt as f64));
    crate::core::helpers::setp(&entry, "wait", Value::Num(wait as f64));
    match out {
        Ok(res) => {
            if let Some(status) = fres_status(res) {
                crate::core::helpers::setp(&entry, "status", Value::Num(status as f64));
            }
        }
        Err(e) => {
            crate::core::helpers::setp(&entry, "error", Value::str(e.msg.clone()));
        }
    }
    t.retries.push(entry);
}
