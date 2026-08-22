use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::result::SdkResult;

pub fn result_basic_util(ctx: &Rc<Context>) -> Option<Rc<RefCell<SdkResult>>> {
    let response = ctx.response.borrow().clone();
    let result = ctx.result.borrow().clone();

    if let (Some(result), Some(response)) = (&result, &response) {
        let (status, status_text, resp_err) = {
            let r = response.borrow();
            (r.status, r.status_text.clone(), r.err.clone())
        };

        let mut res = result.borrow_mut();
        res.status = status;
        res.status_text = status_text.clone();

        if res.status >= 400 {
            let msg = format!("request: {}: {}", res.status, res.status_text);
            if let Some(prev) = &res.err {
                let prevmsg = prev.msg.clone();
                res.err = Some(ctx.make_error("request_status", &format!("{}: {}", prevmsg, msg)));
            } else {
                res.err = Some(ctx.make_error("request_status", &msg));
            }
        } else if let Some(rerr) = resp_err {
            res.err = Some(rerr);
        }
    }

    result
}
