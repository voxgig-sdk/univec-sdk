use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{getp, setp};
use crate::utility::voxgigstruct::Value;

// GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
// produces uses this file unchanged. The API-specific part — which
// operations exist and what each one's document is — is model data,
// computed once by apidef and emitted into Config.
//
// Two jobs:
//
//   graphql_body_util   — build { query, variables } for a point, binding
//                         the op's arguments to the document's declared
//                         variables.
//
//   graphql_errors_util — lift a GraphQL failure into an SDK error.
//                         GraphQL reports failures as a top-level `errors`
//                         array under HTTP 200, so the status-driven path
//                         in result_basic never sees them.

/// Content type every GraphQL-over-HTTP request uses.
pub const GRAPHQL_CONTENT_TYPE: &str = "application/json";

fn as_str(v: &Value) -> String {
    match v {
        Value::Str(s) => s.clone(),
        _ => String::new(),
    }
}

/// Map a GraphQL error to the same error codes the HTTP path produces, so
/// a caller handles auth or rate limiting identically on both transports.
/// Servers put the machine-readable code in `extensions.code`;
/// Linear-style APIs use `extensions.type`.
pub fn graphql_error_code(gqlerr: &Value) -> &'static str {
    let ext = getp(gqlerr, "extensions");

    let mut raw = as_str(&getp(&ext, "code"));
    if raw.is_empty() {
        raw = as_str(&getp(&ext, "type"));
    }
    let raw = raw.to_uppercase();

    if raw.contains("AUTH") || raw.contains("FORBIDDEN")
        || raw.contains("UNAUTHENTICATED")
    {
        return "request_auth";
    }
    if raw.contains("RATELIMIT") || raw.contains("RATE_LIMIT")
        || raw.contains("TOO_MANY")
    {
        return "request_ratelimit";
    }
    if raw.contains("BAD_USER_INPUT") || raw.contains("VALIDATION")
        || raw.contains("INVALID")
    {
        return "request_invalid";
    }

    "request_graphql"
}

/// Build the request body for a GraphQL point.
///
/// Variables come from the op's own arguments: a named variable binds to
/// the like-named argument (`from`), and the input-object variable (empty
/// `from`) takes the request data as a whole — which is what makes a
/// generated create/update call look exactly like its REST equivalent.
pub fn graphql_body_util(ctx: &Rc<Context>) -> Value {
    let point = ctx.point.borrow().clone();
    let gql = getp(&point, "graphql");

    if !matches!(gql, Value::Map(_)) {
        return Value::Noval;
    }

    // reqmatch/reqdata hold the caller's arguments for THIS call; data/match
    // hold the entity's current state. Which pair depends on whether the op
    // takes match or data input. A named variable falls back to the current
    // state, so updating a loaded entity with just {title} still binds the
    // stored id the mutation requires.
    let op = ctx.op.borrow().clone();
    let (reqsrc, datasrc) = if op.input == "data" {
        (ctx.reqdata.borrow().clone(), ctx.data.borrow().clone())
    } else {
        (ctx.reqmatch.borrow().clone(), ctx.mtch.borrow().clone())
    };
    let reqsrc = match reqsrc {
        Value::Map(m) => Value::Map(m),
        _ => Value::empty_map(),
    };
    let datasrc = match datasrc {
        Value::Map(m) => Value::Map(m),
        _ => Value::empty_map(),
    };

    let variables = Value::empty_map();

    if let Value::List(varlist) = getp(&gql, "vars") {
        let specs: Vec<Value> = varlist.borrow().iter().cloned().collect();

        for spec in specs {
            let name = as_str(&getp(&spec, "name"));
            let from = as_str(&getp(&spec, "from"));

            if from.is_empty() {
                // The input object IS the request body. Strip the action
                // selector, which is an SDK-side point discriminator, not
                // an API field.
                let body = Value::empty_map();
                if let Value::Map(src) = &reqsrc {
                    let entries: Vec<(String, Value)> = src
                        .borrow()
                        .iter()
                        .map(|(k, v)| (k.clone(), v.clone()))
                        .collect();
                    for (k, v) in entries {
                        if "$action" != k {
                            setp(&body, &k, v);
                        }
                    }
                }
                setp(&variables, &name, body);
                continue;
            }

            // Only send variables the caller actually supplied: sending an
            // explicit null would clear a field on many APIs.
            let mut val = getp(&reqsrc, &from);
            if val.is_noval() || val.is_null() {
                val = getp(&datasrc, &from);
            }
            if !val.is_noval() && !val.is_null() {
                setp(&variables, &name, val);
            }
        }
    }

    let out = Value::empty_map();
    setp(&out, "query", getp(&gql, "doc"));
    setp(&out, "variables", variables);

    out
}

/// Inspect a decoded GraphQL response body and record a failure when the
/// server reported one. Returns true when an error was recorded.
///
/// Partial data (`data` alongside `errors`) is treated as failure: the
/// REST surface has no partial-success concept, and silently returning
/// half an object would be worse than failing. The raw envelope stays
/// available on the result for callers that need it.
pub fn graphql_errors_util(ctx: &Rc<Context>) -> bool {
    let point = ctx.point.borrow().clone();

    if as_str(&getp(&point, "kind")) != "graphql" {
        return false;
    }

    let result = match ctx.result.borrow().clone() {
        Some(r) => r,
        None => return false,
    };

    let body = result.borrow().body.clone();
    let errors: Vec<Value> = match getp(&body, "errors") {
        Value::List(l) => l.borrow().iter().cloned().collect(),
        _ => return false,
    };

    if errors.is_empty() {
        return false;
    }

    let first = errors[0].clone();
    let mut msg = as_str(&getp(&first, "message"));
    if msg.is_empty() {
        msg = "graphql error".to_string();
    }
    if 1 < errors.len() {
        msg = format!("{} (+{} more)", msg, errors.len() - 1);
    }

    let err = ctx.make_error(graphql_error_code(&first), &format!("graphql: {}", msg));

    let mut r = result.borrow_mut();
    r.err = Some(err);
    r.ok = false;

    true
}
