// Operation result (mirrors go core/result.go).

use std::rc::Rc;

use crate::core::error::UnivecError;
use crate::core::helpers::{get_bool, get_str, getp, setp, to_int};
use crate::utility::voxgigstruct::Value;

/// Stream producer attached by the streaming feature: yields the result
/// items (or chunked batches) with configured pacing applied.
pub type StreamFn = Rc<dyn Fn() -> Vec<Value>>;

pub struct SdkResult {
    pub ok: bool,
    pub status: i64,
    pub status_text: String,
    pub headers: Value,
    pub body: Value,
    pub err: Option<UnivecError>,
    pub resdata: Value,
    pub resmatch: Value,

    // Feature extensions: pagination signals (paging feature) and the
    // incremental item iterator (streaming feature).
    pub paging: Value,
    pub streaming: bool,
    pub stream: Option<StreamFn>,
}

impl SdkResult {
    pub fn new(resmap: &Value) -> SdkResult {
        let ok = get_bool(resmap, "ok").unwrap_or(false);
        let status = match getp(resmap, "status") {
            Value::Noval => -1,
            s => to_int(&s),
        };
        let status_text = get_str(resmap, "statusText").unwrap_or_default();
        let headers = match getp(resmap, "headers") {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };
        let body = getp(resmap, "body");
        let resdata = getp(resmap, "resdata");
        let resmatch = match getp(resmap, "resmatch") {
            Value::Map(m) => Value::Map(m),
            _ => Value::Noval,
        };

        SdkResult {
            ok,
            status,
            status_text,
            headers,
            body,
            err: None,
            resdata,
            resmatch,
            paging: Value::Noval,
            streaming: false,
            stream: None,
        }
    }

    /// Match-map view for tests and explain records.
    pub fn to_value(&self) -> Value {
        let out = Value::empty_map();
        setp(&out, "ok", Value::Bool(self.ok));
        setp(&out, "status", Value::Num(self.status as f64));
        setp(&out, "statusText", Value::str(self.status_text.clone()));
        setp(&out, "headers", self.headers.clone());
        if !self.body.is_noval() {
            setp(&out, "body", self.body.clone());
        }
        if let Some(e) = &self.err {
            let em = Value::empty_map();
            setp(&em, "message", Value::str(e.msg.clone()));
            setp(&out, "err", em);
        }
        if !self.resdata.is_noval() {
            setp(&out, "resdata", self.resdata.clone());
        }
        if !self.resmatch.is_noval() {
            setp(&out, "resmatch", self.resmatch.clone());
        }
        if !self.paging.is_noval() {
            setp(&out, "paging", self.paging.clone());
        }
        out
    }
}
