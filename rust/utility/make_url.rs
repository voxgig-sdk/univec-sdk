use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{getp, setp};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

// The {name} placeholders in a text, in order.
pub(crate) fn placeholders(text: &str) -> Vec<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if b'{' == bytes[i] {
            let mut j = i + 1;
            while j < bytes.len() && !b"{}/".contains(&bytes[j]) {
                j += 1;
            }
            if j < bytes.len() && b'}' == bytes[j] && j > i + 1 {
                out.push(text[i..=j].to_string());
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    out
}

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

    let suffixless = suffix.is_empty();
    let mut url = vs::join(
        &Value::list(vec![
            Value::str(base.clone()),
            Value::str(prefix),
            Value::str(path),
            Value::str(suffix),
        ]),
        Some("/"),
        true,
    );

    // A route the definition ends with a slash keeps it: a server such as a
    // Django REST one redirects or refuses the route without it.
    if let Value::Str(orig) = getp(&ctx.point.borrow().clone(), "orig") {
        if orig.ends_with('/') && suffixless && !url.ends_with('/') {
            url.push('/');
        }
    }

    let resmatch = Value::empty_map();

    // Sent with the request, never recorded as the entity's match.
    let authquery = spec.borrow().authquery.clone();

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

    // A placeholder left in the route would send the request to the wrong route.
    // The base's own placeholders are server variables, resolved with the options.
    let unfilled = placeholders(url.strip_prefix(base.trim_end_matches('/')).unwrap_or(url.as_str()));
    if !unfilled.is_empty() {
        return Err(ctx.make_error(
            "url_param_missing",
            &format!("URL path has no value for {}.", unfilled.join(", ")),
        ));
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
                if !authquery.contains(&key) {
                    setp(&resmatch, &key, val);
                }
            }
        }
    }

    result.borrow_mut().resmatch = resmatch;

    Ok(url)
}
