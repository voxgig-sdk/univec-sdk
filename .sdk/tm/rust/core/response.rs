// Transport response wrapper (mirrors go core/response.go). The `json`
// entry stays a Value::Func thunk so bodies can be re-read repeatedly.

use crate::core::error::UnivecError;
use crate::core::helpers::{get_str, getp, to_int};
use crate::utility::voxgigstruct::Value;

pub struct Response {
    pub status: i64,
    pub status_text: String,
    pub headers: Value,
    pub json: Value,
    pub body: Value,
    pub err: Option<UnivecError>,
}

impl Response {
    pub fn new(resmap: &Value) -> Response {
        let status = match getp(resmap, "status") {
            Value::Noval => -1,
            s => to_int(&s),
        };

        let status_text = get_str(resmap, "statusText").unwrap_or_default();
        let headers = getp(resmap, "headers");
        let json = getp(resmap, "json");
        let body = getp(resmap, "body");

        Response {
            status,
            status_text,
            headers,
            json,
            body,
            err: None,
        }
    }
}
