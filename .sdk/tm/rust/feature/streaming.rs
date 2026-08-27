// Streaming result support (mirrors go feature/streaming_feature.go,
// adapted to a synchronous runtime). For list-style operations it attaches
// a `result.stream` producer so callers can consume items incrementally
// with `for item in (result.stream)()` instead of materialising the whole
// list themselves. A `chunkSize` groups items into list batches when set;
// a `chunkDelay` (ms) paces delivery via the injectable `sleep` for
// offline tests.

use std::rc::Rc;

use crate::core::context::Context;
use crate::core::types::Feature;
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

pub struct StreamingFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,

    // Activity tracking (mirrors the ts client._streaming record).
    pub opened: i64,
}

impl StreamingFeature {
    pub fn new() -> StreamingFeature {
        StreamingFeature {
            name: "streaming".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            opened: 0,
        }
    }

    fn streamable(&self, ctx: &Rc<Context>) -> bool {
        let opname = ctx.op.borrow().name.clone();
        let ops =
            fopt_str_list(&self.options, "ops").unwrap_or_else(|| vec!["list".to_string()]);
        ops.iter().any(|o| *o == opname)
    }
}

impl Feature for StreamingFeature {
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

    fn pre_result(&mut self, ctx: &Rc<Context>) {
        if !self.active || !self.streamable(ctx) {
            return;
        }
        let result = match ctx.result.borrow().clone() {
            Some(r) => r,
            None => return,
        };

        let options = self.options.clone();
        // Weak reference: the stream closure lives on the result itself, so
        // a strong capture would leak the result via an Rc cycle.
        let weak = Rc::downgrade(&result);

        {
            let mut r = result.borrow_mut();
            r.streaming = true;
            r.stream = Some(Rc::new(move || {
                let result = match weak.upgrade() {
                    Some(r) => r,
                    None => return Vec::new(),
                };
                let resdata = result.borrow().resdata.clone();
                iterate(&options, &resdata)
            }));
        }

        self.opened += 1;
    }
}

fn iterate(options: &Value, resdata: &Value) -> Vec<Value> {
    let chunk_delay = fopt_int(options, "chunkDelay", 0);
    let chunk_size = fopt_int(options, "chunkSize", 0);
    let sleep = fopt_sleep(options);

    let items: Vec<Value> = match resdata {
        Value::List(l) => l.borrow().iter().cloned().collect(),
        _ => Vec::new(),
    };

    let mut out: Vec<Value> = Vec::new();

    if chunk_size > 0 {
        let mut i = 0usize;
        while i < items.len() {
            if chunk_delay > 0 {
                sleep(chunk_delay);
            }
            let end = (i + chunk_size as usize).min(items.len());
            out.push(Value::list(items[i..end].to_vec()));
            i = end;
        }
        return out;
    }

    for item in items {
        if chunk_delay > 0 {
            sleep(chunk_delay);
        }
        out.push(item);
    }
    out
}
