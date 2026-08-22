use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::setp;
use crate::core::result::SdkResult;
use crate::core::types::OutVal;
use crate::utility::voxgigstruct::Value;

pub fn make_result_util(
    ctx: &Rc<Context>,
) -> Result<Rc<RefCell<SdkResult>>, UnivecError> {
    if let Some(OutVal::Result(res)) = ctx.out_get("result") {
        return Ok(res);
    }

    let op = ctx.op.borrow().clone();
    let entity = ctx.entity.borrow().clone();
    let spec = ctx.spec.borrow().clone().ok_or_else(|| {
        ctx.make_error("result_no_spec", "Expected context spec property to be defined.")
    })?;
    let result = ctx.result.borrow().clone().ok_or_else(|| {
        ctx.make_error("result_no_result", "Expected context result property to be defined.")
    })?;

    spec.borrow_mut().step = "result".to_string();

    crate::utility::transform_response::transform_response_util(ctx);

    if op.name == "list" {
        let resdata = result.borrow().resdata.clone();
        result.borrow_mut().resdata = Value::empty_list();

        if let (Value::List(list), Some(ent)) = (&resdata, &entity) {
            if !list.borrow().is_empty() {
                // Wrap each entry through a made entity so entity hooks fire
                // per item (go stores the entity objects; rust keeps the
                // resdata as plain Value data — see the port notes).
                let mut entities: Vec<Value> = Vec::new();
                for entry in list.borrow().iter() {
                    let e = ent.make();
                    let out = if let Value::Map(_) = entry {
                        e.data(Some(entry))
                    } else {
                        e.data(None)
                    };
                    entities.push(out);
                }
                result.borrow_mut().resdata = Value::list(entities);
            }
        }
    }

    {
        let ctrl = ctx.ctrl.borrow().clone();
        let c = ctrl.borrow();
        if c.has_explain() {
            setp(&c.explain, "result", result.borrow().to_value());
        }
    }

    Ok(result)
}
