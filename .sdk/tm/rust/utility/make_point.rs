use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{allowed, getp, getpath, to_map};
use crate::core::types::OutVal;
use crate::utility::make_url::placeholders;
use crate::utility::param::param_value;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

// How many path segments a point has.
fn parts_len(point: &Value) -> usize {
    match getp(point, "parts") {
        Value::List(l) => l.borrow().len(),
        _ => 0,
    }
}

fn terminal_param(point: &Value) -> bool {
    match getp(point, "parts") {
        Value::List(l) => {
            let parts = l.borrow();
            match parts.last() {
                Some(Value::Str(s)) => s.starts_with('{'),
                _ => false,
            }
        }
        _ => false,
    }
}

fn own_point(points: &[Value]) -> Value {
    let mut best = points[0].clone();
    for cand in points {
        let cand_term = terminal_param(cand);
        let best_term = terminal_param(&best);
        if cand_term != best_term {
            if cand_term {
                best = cand.clone();
            }
        } else if parts_len(cand) < parts_len(&best) {
            best = cand.clone();
        }
    }
    best
}

// The path parameters of a point that neither the call nor the entity gives a
// value for, looked up as prepare_params_util looks them up.
fn unfilled(ctx: &Rc<Context>, point: &Value) -> Vec<String> {
    let mut missing = Vec::new();
    if let Value::List(pl) = getp(point, "parts") {
        for part in pl.borrow().iter() {
            let text = match part {
                Value::Str(s) => s,
                _ => continue,
            };
            let found = placeholders(text);
            if 1 != found.len() || found[0] != *text {
                continue;
            }
            let name = &text[1..text.len() - 1];
            let val = param_value(ctx, point, name);
            if val.is_noval() || val.is_null() {
                missing.push(name.to_string());
            }
        }
    }
    missing
}

pub fn make_point_util(ctx: &Rc<Context>) -> Result<Value, UnivecError> {
    match ctx.out_get("point") {
        // A PrePoint feature hook (e.g. rbac) may short-circuit the
        // operation by storing an error here; surface it before any
        // endpoint resolution or network activity.
        Some(OutVal::Err(err)) => return Err(err),
        Some(OutVal::Val(v)) => {
            if let Value::Map(_) = v {
                *ctx.point.borrow_mut() = v.clone();
                return Ok(v);
            }
        }
        _ => {}
    }

    let op = ctx.op.borrow().clone();
    let options = ctx.options.borrow().clone();

    let allow_op_val = getpath(&["allow", "op"], &options);
    let allow_op = match &allow_op_val {
        Value::Str(s) => s.clone(),
        _ => String::new(),
    };
    if !allowed(&allow_op_val, &op.name) {
        return Err(ctx.make_error(
            "point_op_allow",
            &format!(
                "Operation \"{}\" not allowed by SDK option allow.op value: \"{}\"",
                op.name, allow_op
            ),
        ));
    }

    let points = op.points.clone();
    let plen = vs::size(&points);

    if plen == 0 {
        return Err(ctx.make_error(
            "point_no_points",
            &format!("Operation \"{}\" has no endpoint definitions.", op.name),
        ));
    }

    if plen == 1 {
        let point = vs::get_elem(&points, &Value::Num(0.0), Value::Noval);
        *ctx.point.borrow_mut() = point;
    } else {
        let (reqselector, selector) = if op.input == "data" {
            (ctx.reqdata.borrow().clone(), ctx.data.borrow().clone())
        } else {
            (ctx.reqmatch.borrow().clone(), ctx.mtch.borrow().clone())
        };

        let mut point = Value::Noval;
        let mut matched = false;
        for i in 0..plen {
            let cand = vs::get_elem(&points, &Value::Num(i as f64), Value::Noval);
            let select_def = to_map(&getp(&cand, "select"));
            let mut found = true;

            if !selector.is_noval() && !select_def.is_noval() {
                if let Value::List(el) = getp(&select_def, "exist") {
                    for ek in el.borrow().iter() {
                        if let Value::Str(existkey) = ek {
                            let rv = getp(&reqselector, existkey);
                            let sv = getp(&selector, existkey);
                            if rv.is_noval() && sv.is_noval() {
                                found = false;
                                break;
                            }
                        }
                    }
                }
            }

            if found {
                let req_action = getp(&reqselector, "$action");
                let select_action = getp(&select_def, "$action");
                if req_action != select_action {
                    found = false;
                }
            }

            if found {
                point = cand;
                matched = true;
                break;
            }
        }

        // select.exist can list more than the params needed to pick a point,
        // so nothing matches — fall back to the entity's own route rather
        // than whichever point came last.
        if !matched {
            let unmatched_action = getp(&reqselector, "$action");
            if !unmatched_action.is_noval() {
                return Err(ctx.make_error(
                    "point_action_invalid",
                    &format!(
                        "Operation \"{}\" action \"{}\" is not valid.",
                        op.name,
                        vs::stringify(&unmatched_action, None, false)
                    ),
                ));
            }

            // A call without an action falls back to a point without one, as
            // generation does, and only to a route the call can fill.
            let all: Vec<Value> = (0..plen)
                .map(|i| vs::get_elem(&points, &Value::Num(i as f64), Value::Noval))
                .collect();
            let plain: Vec<Value> = all
                .iter()
                .filter(|cand| getp(&to_map(&getp(cand, "select")), "$action").is_noval())
                .cloned()
                .collect();
            if plain.is_empty() {
                return Err(ctx.make_error(
                    "point_action_required",
                    &format!(
                        "Operation \"{}\" has only action endpoints; pass $action to choose one.",
                        op.name
                    ),
                ));
            }
            let fillable: Vec<Value> =
                plain.iter().filter(|cand| unfilled(ctx, cand).is_empty()).cloned().collect();

            if fillable.is_empty() {
                return Err(ctx.make_error(
                    "point_no_match",
                    &format!(
                        "Operation \"{}\" has no endpoint whose path parameters are all given (missing: {}).",
                        op.name,
                        unfilled(ctx, &own_point(&plain)).join(", ")
                    ),
                ));
            }

            point = own_point(&fillable);
        }

        let req_action = getp(&reqselector, "$action");
        if !req_action.is_noval() && !point.is_noval() {
            let point_select = to_map(&getp(&point, "select"));
            let point_action = getp(&point_select, "$action");
            if req_action != point_action {
                return Err(ctx.make_error(
                    "point_action_invalid",
                    &format!(
                        "Operation \"{}\" action \"{}\" is not valid.",
                        op.name,
                        vs::stringify(&req_action, None, false)
                    ),
                ));
            }
        }

        *ctx.point.borrow_mut() = point;
    }

    Ok(ctx.point.borrow().clone())
}
