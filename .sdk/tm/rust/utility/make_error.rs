use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{jo, setp};
use crate::core::result::SdkResult;
use crate::utility::voxgigstruct::Value;

pub fn make_error_util(
    ctx: &Rc<Context>,
    err: Option<UnivecError>,
) -> Result<Value, UnivecError> {
    let op = ctx.op.borrow().clone();
    let mut opname = op.name.clone();
    if opname.is_empty() || opname == "_" {
        opname = "unknown operation".to_string();
    }

    // Bind the clone to a local first: a `match` scrutinee keeps its
    // temporary `Ref` alive for the whole match, which would collide with the
    // `borrow_mut()` in the None arm ("RefCell already borrowed").
    let cur_result = ctx.result.borrow().clone();
    let result = match cur_result {
        Some(r) => r,
        None => {
            let r = Rc::new(RefCell::new(SdkResult::new(&Value::empty_map())));
            *ctx.result.borrow_mut() = Some(r.clone());
            r
        }
    };
    result.borrow_mut().ok = false;

    let err = err
        .or_else(|| result.borrow().err.clone())
        .unwrap_or_else(|| ctx.make_error("unknown", "unknown error"));

    let errmsg = err.msg.clone();
    let msg = format!("UnivecSDK: {}: {}", opname, errmsg);
    let msg = crate::utility::clean::clean_str(ctx, &msg);

    result.borrow_mut().err = None;

    let spec_val = match ctx.spec.borrow().clone() {
        Some(s) => s.borrow().to_value(),
        None => Value::Noval,
    };

    let ctrl = ctx.ctrl.borrow().clone();
    {
        let c = ctrl.borrow();
        if c.has_explain() {
            setp(
                &c.explain,
                "err",
                jo(vec![("message", Value::str(msg.clone()))]),
            );
        }
    }

    let mut sdk_err = UnivecError::new("", &msg);
    sdk_err.code = err.code.clone();
    sdk_err.result = crate::utility::clean::clean_util(ctx, &result.borrow().to_value());
    sdk_err.spec = crate::utility::clean::clean_util(ctx, &spec_val);

    // Promote the HTTP status to the top level, so a consumer can branch on
    // `err.status` / `err.not_found()` rather than reaching into `err.result`.
    sdk_err.status = result.borrow().status;

    ctrl.borrow_mut().err = Some(sdk_err.clone());

    // Fire PreUnexpected so observability features (metrics, telemetry, audit,
    // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
    // rbac short-circuit). Fires after ctx.ctrl.err is set so hooks can read the
    // error; features guard against double-recording when PreDone already fired.
    crate::utility::feature_hook::feature_hook_util(ctx, "PreUnexpected");

    if ctrl.borrow().throw == Some(false) {
        return Ok(result.borrow().resdata.clone());
    }

    Err(sdk_err)
}
