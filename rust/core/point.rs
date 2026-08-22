// Endpoint point description (mirrors go core/target.go NewPoint). Points
// stay Value maps in the pipeline; this typed view is a convenience for
// callers that want field access.

use crate::core::helpers::{get_bool, get_str, getp, jo, to_map};
use crate::utility::voxgigstruct::Value;

pub struct Point {
    pub args: Value,
    pub rename: Value,
    pub method: String,
    pub orig: String,
    pub parts: Value,
    pub params: Value,
    pub select: Value,
    pub active: bool,
    pub relations: Value,
    pub alias: Value,
    pub transform: Value,
}

impl Point {
    pub fn new(altmap: &Value) -> Point {
        let args = match to_map(&getp(altmap, "args")) {
            Value::Map(m) => Value::Map(m),
            _ => jo(vec![("params", Value::empty_list())]),
        };

        let rename = match to_map(&getp(altmap, "rename")) {
            Value::Map(m) => Value::Map(m),
            _ => jo(vec![("params", Value::empty_map())]),
        };

        let parts = match getp(altmap, "parts") {
            Value::List(l) => Value::List(l),
            _ => Value::empty_list(),
        };

        let params = match getp(altmap, "params") {
            Value::List(l) => Value::List(l),
            _ => Value::Noval,
        };

        let alias = match to_map(&getp(altmap, "alias")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        let transform = match to_map(&getp(altmap, "transform")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        Point {
            args,
            rename,
            method: get_str(altmap, "method").unwrap_or_default(),
            orig: get_str(altmap, "orig").unwrap_or_default(),
            parts,
            params,
            select: to_map(&getp(altmap, "select")),
            active: get_bool(altmap, "active").unwrap_or(false),
            relations: getp(altmap, "relations"),
            alias,
            transform,
        }
    }
}
