// Client-side role/permission enforcement (mirrors go
// feature/rbac_feature.go). Before an operation resolves its endpoint, the
// required permission for that entity+operation is checked against the
// permissions the client holds; a disallowed call is short-circuited with
// an `rbac_denied` error (via ctx.out["point"], which MakePoint surfaces)
// and never touches the network. Required permissions come from `rules`
// (keyed by `<entity>.<op>`, `<op>`, or `*`); the default when no rule
// matches is controlled by `deny` (default: allow when unspecified). Held
// permissions are the `permissions` list (a `*` grants everything).

use std::collections::HashMap;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{get_str, setp};
use crate::core::types::{Feature, OutVal};
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

pub struct RbacFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    granted: HashMap<String, bool>,

    // Activity tracking (mirrors the ts client._rbac record).
    pub allowed: i64,
    pub denied: i64,
    pub last: Value,
}

impl RbacFeature {
    pub fn new() -> RbacFeature {
        RbacFeature {
            name: "rbac".to_string(),
            active: true,
            add_opts: None,
            options: Value::Noval,
            granted: HashMap::new(),
            allowed: 0,
            denied: 0,
            last: Value::Noval,
        }
    }

    fn required(&self, ctx: &Rc<Context>) -> Option<String> {
        let rules = fopt_map(&self.options, "rules");
        if !matches!(rules, Value::Map(_)) {
            return None;
        }

        let entity = match ctx.entity.borrow().clone() {
            Some(e) => e.get_name(),
            None => ctx.op.borrow().entity.clone(),
        };
        let opname = ctx.op.borrow().name.clone();

        for key in [format!("{}.{}", entity, opname), opname, "*".to_string()] {
            if let Some(r) = get_str(&rules, &key) {
                return Some(r);
            }
        }
        None
    }

    fn track(&mut self, ctx: &Rc<Context>, required: &str, allowed: bool) {
        if allowed {
            self.allowed += 1;
        } else {
            self.denied += 1;
        }
        let opname = ctx.op.borrow().name.clone();
        let last = Value::empty_map();
        setp(&last, "required", Value::str(required));
        setp(&last, "allowed", Value::Bool(allowed));
        setp(&last, "op", Value::str(opname));
        self.last = last;
    }

    fn reject(&mut self, ctx: &Rc<Context>, required: &str) {
        self.track(ctx, required, false);

        let opname = {
            let n = ctx.op.borrow().name.clone();
            if n.is_empty() {
                "?".to_string()
            } else {
                n
            }
        };
        let err = ctx.make_error(
            "rbac_denied",
            &format!(
                "Permission \"{}\" required for operation \"{}\"",
                required, opname
            ),
        );

        // Short-circuit endpoint resolution; MakePoint surfaces this error
        // before any network activity.
        ctx.out_set("point", OutVal::Err(err));
    }
}

impl Feature for RbacFeature {
    fn name(&self) -> String {
        self.name.clone()
    }
    fn active(&self) -> bool {
        self.active
    }
    fn add_options(&self) -> Option<Value> {
        self.add_opts.clone()
    }

    fn init(&mut self, _ctx: &Rc<Context>, options: &Value) {
        self.options = options.clone();
        self.active = fopt_bool(options, "active", false);

        self.granted = HashMap::new();
        for p in fopt_str_list(options, "permissions").unwrap_or_default() {
            self.granted.insert(p, true);
        }
    }

    fn pre_point(&mut self, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }

        let required = match self.required(ctx) {
            None => {
                // No rule: honour the default policy.
                if fopt_bool(&self.options, "deny", false) {
                    self.reject(ctx, "<default-deny>");
                }
                return;
            }
            Some(r) => r,
        };

        if self.granted.get("*").copied().unwrap_or(false)
            || self.granted.get(&required).copied().unwrap_or(false)
        {
            self.track(ctx, &required, true);
            return;
        }

        self.reject(ctx, &required);
    }
}
