use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, getpath, setp};
use crate::core::spec::Spec;
use crate::core::types::OutVal;
use crate::utility::voxgigstruct::Value;

pub fn make_spec_util(ctx: &Rc<Context>) -> Result<Rc<RefCell<Spec>>, UnivecError> {
    match ctx.out_get("spec") {
        // A PreSpec feature hook (e.g. validate) may short-circuit the
        // operation by storing an error here; surface it before the request
        // is built, the same way make_point surfaces out["point"].
        Some(OutVal::Err(err)) => return Err(err),
        Some(OutVal::Spec(sp)) => {
            *ctx.spec.borrow_mut() = Some(sp.clone());
            return Ok(sp);
        }
        _ => {}
    }

    let point = ctx.point.borrow().clone();
    let options = ctx.options.borrow().clone();

    let specmap = Value::empty_map();
    setp(&specmap, "base", getp(&options, "base"));
    setp(&specmap, "prefix", getp(&options, "prefix"));
    setp(&specmap, "suffix", getp(&options, "suffix"));
    setp(&specmap, "parts", getp(&point, "parts"));
    setp(&specmap, "step", Value::str("start"));

    let spec = Rc::new(RefCell::new(Spec::new(&specmap)));
    *ctx.spec.borrow_mut() = Some(spec.clone());

    let method = crate::utility::prepare_method::prepare_method_util(ctx);
    spec.borrow_mut().method = method.clone();

    let allow_method = match getpath(&["allow", "method"], &options) {
        Value::Str(s) => s,
        _ => String::new(),
    };
    if !allow_method.contains(&method) {
        return Err(ctx.make_error(
            "spec_method_allow",
            &format!(
                "Method \"{}\" not allowed by SDK option allow.method value: \"{}\"",
                method, allow_method
            ),
        ));
    }

    let params = crate::utility::prepare_params::prepare_params_util(ctx);
    spec.borrow_mut().params = params;
    let query = crate::utility::prepare_query::prepare_query_util(ctx);
    spec.borrow_mut().query = query;
    let headers = crate::utility::prepare_headers::prepare_headers_util(ctx);
    spec.borrow_mut().headers = headers;

    let point = ctx.point.borrow().clone();
    let kind = match getp(&point, "kind") {
        Value::Str(s) => s,
        _ => String::new(),
    };

    if "graphql" == kind {
        let body = crate::utility::graphql::graphql_body_util(ctx);
        spec.borrow_mut().body = body;
        spec.borrow_mut().path = String::new();
        // prepare_query already copied the op's match arguments into the
        // query string. Those same values are bound as operation
        // variables, so leaving them would send /graphql?id=i1.
        spec.borrow_mut().query = Value::empty_map();
        let headers = spec.borrow().headers.clone();
        setp(
            &headers,
            "content-type",
            Value::Str(crate::utility::graphql::GRAPHQL_CONTENT_TYPE.to_string()),
        );
        spec.borrow_mut().headers = headers;
    } else {
        let body = crate::utility::prepare_body::prepare_body_util(ctx);
        spec.borrow_mut().body = body;
        let path = crate::utility::prepare_path::prepare_path_util(ctx);
        spec.borrow_mut().path = path;
    }

    {
        let ctrl = ctx.ctrl.borrow().clone();
        let c = ctrl.borrow();
        if c.has_explain() {
            setp(&c.explain, "spec", spec.borrow().to_value());
        }
    }

    let spec = crate::utility::prepare_auth::prepare_auth_util(ctx)?;

    *ctx.spec.borrow_mut() = Some(spec.clone());
    Ok(spec)
}
