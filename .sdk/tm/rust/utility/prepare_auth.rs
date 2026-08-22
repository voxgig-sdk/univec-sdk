use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, getpath, setp};
use crate::core::spec::Spec;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

const HEADER_AUTH: &str = "authorization";
const OPTION_APIKEY: &str = "apikey";
const NOT_FOUND: &str = "__NOTFOUND__";

pub fn prepare_auth_util(ctx: &Rc<Context>) -> Result<Rc<RefCell<Spec>>, UnivecError> {
    let spec = ctx.spec.borrow().clone().ok_or_else(|| {
        ctx.make_error("auth_no_spec", "Expected context spec property to be defined.")
    })?;

    let headers = spec.borrow().headers.clone();
    let options = match ctx.client.borrow().clone() {
        Some(client) => client.options_map(),
        None => ctx.options.borrow().clone(),
    };

    // Public APIs that need no auth omit the options.auth block entirely.
    let auth = getp(&options, "auth");
    if auth.is_noval() || auth.is_null() {
        vs::del_prop(headers, &Value::str(HEADER_AUTH));
        return Ok(spec);
    }

    let apikey = vs::get_prop(&options, &Value::str(OPTION_APIKEY), Value::str(NOT_FOUND));

    let skip = match &apikey {
        Value::Noval | Value::Null => true,
        Value::Str(s) => s == NOT_FOUND || s.is_empty(),
        _ => false,
    };

    if skip {
        vs::del_prop(headers, &Value::str(HEADER_AUTH));
    } else {
        let auth_prefix = match getpath(&["auth", "prefix"], &options) {
            Value::Str(s) => s,
            _ => String::new(),
        };
        let apikey_val = match &apikey {
            Value::Str(s) => s.clone(),
            _ => String::new(),
        };
        // Empty prefix (raw apiKey credential) must not add a leading space.
        if auth_prefix.is_empty() {
            setp(&headers, HEADER_AUTH, Value::str(apikey_val));
        } else {
            setp(
                &headers,
                HEADER_AUTH,
                Value::str(format!("{} {}", auth_prefix, apikey_val)),
            );
        }
    }

    Ok(spec)
}
