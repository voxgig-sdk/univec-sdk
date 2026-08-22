// Operation description (mirrors go core/operation.go).

use crate::core::helpers::{get_str, getp, to_map};
use crate::utility::voxgigstruct::Value;

pub struct Operation {
    pub entity: String,
    pub name: String,
    pub input: String,
    pub points: Value,
    pub alias: Value,
}

impl Operation {
    pub fn new(opmap: &Value) -> Operation {
        let entity = get_str(opmap, "entity").filter(|s| !s.is_empty());
        let name = get_str(opmap, "name").filter(|s| !s.is_empty());
        let input = get_str(opmap, "input").filter(|s| !s.is_empty());

        let points = match getp(opmap, "points") {
            Value::List(l) => Value::List(l),
            _ => Value::empty_list(),
        };

        let alias = to_map(&getp(opmap, "alias"));

        Operation {
            entity: entity.unwrap_or_else(|| "_".to_string()),
            name: name.unwrap_or_else(|| "_".to_string()),
            input: input.unwrap_or_else(|| "_".to_string()),
            points,
            alias,
        }
    }
}
