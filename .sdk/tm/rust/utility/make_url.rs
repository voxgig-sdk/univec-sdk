use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::setp;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn make_url_util(ctx: &Rc<Context>) -> Result<String, UnivecError> {
    let spec = ctx.spec.borrow().clone().ok_or_else(|| {
        ctx.make_error("url_no_spec", "Expected context spec property to be defined.")
    })?;
    let result = ctx.result.borrow().clone().ok_or_else(|| {
        ctx.make_error("url_no_result", "Expected context result property to be defined.")
    })?;

    let (base, prefix, path, suffix, params, query) = {
        let s = spec.borrow();
        (
            s.base.clone(),
            s.prefix.clone(),
            s.path.clone(),
            s.suffix.clone(),
            s.params.clone(),
            s.query.clone(),
        )
    };

    let mut url = vs::join(
        &Value::list(vec![
            Value::str(base),
            Value::str(prefix),
            Value::str(path),
            Value::str(suffix),
        ]),
        Some("/"),
        true,
    );

    let resmatch = Value::empty_map();

    if let Value::Map(pm) = &params {
        let entries: Vec<(String, Value)> = pm
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        for (key, val) in entries {
            if !val.is_noval() && !val.is_null() {
                let pat = format!("\\{{{}\\}}", vs::esc_re(&Value::str(key.clone())));
                let sub = vs::esc_url(&Value::str(vs::stringify(&val, None, false)));
                url = vs::re_replace(&pat, &url, &sub);
                setp(&resmatch, &key, val);
            }
        }
    }

    // Append query string from spec.query.
    let mut qsep = "?";
    if let Value::Map(qm) = &query {
        let entries: Vec<(String, Value)> = qm
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        for (key, val) in entries {
            if !val.is_noval() && !val.is_null() {
                url.push_str(&format!(
                    "{}{}={}",
                    qsep,
                    vs::esc_url(&Value::str(key.clone())),
                    vs::esc_url(&Value::str(vs::stringify(&val, None, false)))
                ));
                qsep = "&";
                setp(&resmatch, &key, val);
            }
        }
    }

    result.borrow_mut().resmatch = resmatch;

    Ok(url)
}
