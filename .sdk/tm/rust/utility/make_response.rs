use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::setp;
use crate::core::response::Response;
use crate::core::types::OutVal;

pub fn make_response_util(
    ctx: &Rc<Context>,
) -> Result<Rc<RefCell<Response>>, UnivecError> {
    if let Some(OutVal::Response(resp)) = ctx.out_get("response") {
        return Ok(resp);
    }

    let spec = ctx.spec.borrow().clone().ok_or_else(|| {
        ctx.make_error("response_no_spec", "Expected context spec property to be defined.")
    })?;
    let response = ctx.response.borrow().clone().ok_or_else(|| {
        ctx.make_error(
            "response_no_response",
            "Expected context response property to be defined.",
        )
    })?;
    let result = ctx.result.borrow().clone().ok_or_else(|| {
        ctx.make_error(
            "response_no_result",
            "Expected context result property to be defined.",
        )
    })?;

    spec.borrow_mut().step = "response".to_string();

    crate::utility::result_basic::result_basic_util(ctx);
    crate::utility::result_headers::result_headers_util(ctx);
    crate::utility::result_body::result_body_util(ctx);

    // GraphQL reports failures as a top-level `errors` array under HTTP
    // 200, so result_basic's status check never sees them. Lift them here,
    // before the response transform tries to unwrap data that is not there.
    crate::utility::graphql::graphql_errors_util(ctx);

    crate::utility::transform_response::transform_response_util(ctx);

    {
        let mut res = result.borrow_mut();
        if res.err.is_none() {
            res.ok = true;
        }
    }

    {
        let ctrl = ctx.ctrl.borrow().clone();
        let c = ctrl.borrow();
        if c.has_explain() {
            setp(&c.explain, "result", result.borrow().to_value());
        }
    }

    Ok(response)
}
