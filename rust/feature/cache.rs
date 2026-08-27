// Response caching for safe (read) requests (mirrors go
// feature/cache_feature.go). Wraps the active transport and serves a fresh
// cached snapshot instead of hitting the network when the same method+URL
// was fetched within `ttl` ms (default: 5000). Only successful (2xx)
// responses to cacheable methods (default: GET) are stored, keyed by
// method+URL. The cache is bounded (`max` entries, default 256, oldest
// evicted first) and every hit/miss/bypass is counted. Bodies are
// snapshotted on capture so both the current caller and later hits can
// re-read the JSON body repeatedly.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{call_json, get_str, getp, jo, json_thunk, setp};
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

pub struct CacheSnapshot {
    status: i64,
    status_text: String,
    data: Value,
    headers: Value,
}

pub struct CacheEntry {
    expiry: i64,
    snapshot: Rc<CacheSnapshot>,
}

#[derive(Default)]
pub struct CacheTrack {
    store: HashMap<String, CacheEntry>,
    order: Vec<String>,

    // Activity tracking (mirrors the ts client._cache record).
    pub hit: i64,
    pub miss: i64,
    pub bypass: i64,
}

pub struct CacheFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    pub track: Rc<RefCell<CacheTrack>>,
}

impl CacheFeature {
    pub fn new() -> CacheFeature {
        CacheFeature {
            name: "cache".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            track: Rc::new(RefCell::new(CacheTrack::default())),
        }
    }
}

impl Feature for CacheFeature {
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
            through(&track, &options, ctx2, url, fetchdef, &inner)
        });
    }
}

fn through(
    track: &Rc<RefCell<CacheTrack>>,
    options: &Value,
    ctx: &Rc<Context>,
    url: &str,
    fetchdef: &Value,
    inner: &FetcherFn,
) -> Result<Value, UnivecError> {
    let method = get_str(fetchdef, "method")
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| "GET".to_string())
        .to_uppercase();

    let methods = fopt_str_list(options, "methods").unwrap_or_else(|| vec!["GET".to_string()]);
    let cacheable = methods.iter().any(|m| m.to_uppercase() == method);
    if !cacheable {
        return inner(ctx, url, fetchdef);
    }

    let key = format!("{} {}", method, url);
    let now = fopt_now(options)();

    {
        let mut t = track.borrow_mut();
        if let Some(hit) = t.store.get(&key) {
            if hit.expiry > now {
                let snap = hit.snapshot.clone();
                t.hit += 1;
                return Ok(replay(&snap));
            }
        }
    }

    let out = inner(ctx, url, fetchdef);

    if let Ok(res) = &out {
        if storable(res) {
            let snap = Rc::new(snapshot(res));
            let ttl = fopt_int(options, "ttl", 5000);
            let mut t = track.borrow_mut();
            evict(&mut t, options);
            t.store.insert(
                key.clone(),
                CacheEntry {
                    expiry: now + ttl,
                    snapshot: snap.clone(),
                },
            );
            t.order.push(key);
            t.miss += 1;
            return Ok(replay(&snap));
        }
    }

    track.borrow_mut().bypass += 1;
    out
}

fn storable(res: &Value) -> bool {
    matches!(fres_status(res), Some(status) if (200..300).contains(&status))
}

fn snapshot(res: &Value) -> CacheSnapshot {
    let headers = Value::empty_map();
    if let Value::Map(hm) = getp(res, "headers") {
        for (k, v) in hm.borrow().iter() {
            setp(&headers, &k.to_lowercase(), v.clone());
        }
    }

    CacheSnapshot {
        status: fres_status(res).unwrap_or(0),
        status_text: get_str(res, "statusText").unwrap_or_default(),
        data: call_json(&getp(res, "json")),
        headers,
    }
}

// replay builds a fresh transport-shaped response so the body stays
// re-readable for every consumer.
fn replay(snap: &CacheSnapshot) -> Value {
    let headers = Value::empty_map();
    if let Value::Map(hm) = &snap.headers {
        for (k, v) in hm.borrow().iter() {
            setp(&headers, k, v.clone());
        }
    }
    jo(vec![
        ("status", Value::Num(snap.status as f64)),
        ("statusText", Value::str(snap.status_text.clone())),
        ("body", Value::str("not-used")),
        ("json", json_thunk(snap.data.clone())),
        ("headers", headers),
    ])
}

// evict drops oldest entries (FIFO) until the store is under `max`.
fn evict(t: &mut CacheTrack, options: &Value) {
    let max = fopt_int(options, "max", 256) as usize;
    while t.store.len() >= max && !t.order.is_empty() {
        let oldest = t.order.remove(0);
        t.store.remove(&oldest);
    }
}
