use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, getpath, to_map};
use crate::core::types::OutVal;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

// How many path segments a point has.
fn parts_len(point: &Value) -> usize {
    match getp(point, "parts") {
        Value::List(l) => l.borrow().len(),
        _ => 0,
    }
}

// Does this point's path end in a parameter? A record route ends in the
// record's identifier (/boards/{id}); a cross-reference that also returns
// the entity ends in the relationship's name (/posts/{id}/author). That,
// then fewest segments, is what tells the entity's own route from a
// cross-reference. The same rule runs at generation time, in
// helpers/opShape.ts — both sides must move together.
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

    let allow_op = match getpath(&["allow", "op"], &options) {
        Value::Str(s) => s,
        _ => String::new(),
    };
    if !allow_op.contains(&op.name) {
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
            // A request naming an action reaches here only because that
            // action's own point failed its exist test, so it is unbuildable
            // whatever we pick. Refuse it BEFORE choosing a fallback: the
            // guard below compares the chosen point's $action and would wave
            // the request through whenever the fallback lands on the action
            // point itself.
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

            point = vs::get_elem(&points, &Value::Num(0.0), Value::Noval);
            for i in 0..plen {
                let cand = vs::get_elem(&points, &Value::Num(i as f64), Value::Noval);
                let cand_term = terminal_param(&cand);
                let best_term = terminal_param(&point);
                if cand_term != best_term {
                    if cand_term {
                        point = cand;
                    }
                } else if parts_len(&cand) < parts_len(&point) {
                    point = cand;
                }
            }
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
