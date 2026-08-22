// ProjectNameSDK client (generated — mirrors the go Main fragment).

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::config::{make_feature, shared_config};
use crate::core::context::{Context, CtxSpec};
use crate::core::error::ProjectNameError;
use crate::core::helpers::{call_json, get_bool, get_str, getp, getpath, jo, setp, to_int, to_map};
use crate::core::spec::Spec;
use crate::core::types::FeatureRef;
use crate::core::utility_type::Utility;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub struct ProjectNameSDK {
    pub mode: RefCell<String>,
    options: RefCell<Value>,
    utility: Rc<Utility>,
    pub features: RefCell<Vec<FeatureRef>>,
    rootctx: RefCell<Option<Rc<Context>>>,
}

impl ProjectNameSDK {
    pub fn new(options: Value) -> Rc<ProjectNameSDK> {
        let sdk = Rc::new(ProjectNameSDK {
            mode: RefCell::new("live".to_string()),
            options: RefCell::new(Value::Noval),
            utility: Utility::new(),
            features: RefCell::new(Vec::new()),
            rootctx: RefCell::new(None),
        });

        // The per-thread config (sdkgen rung L2): read-only on the request
        // path, so every client shares one rather than rebuilding it.
        let config = shared_config();

        let rootctx = sdk.utility.make_context(
            CtxSpec {
                client: Some(sdk.clone()),
                utility: Some(sdk.utility.clone()),
                config: Some(config),
                options: Some(options),
                shared: Some(Value::empty_map()),
                ..Default::default()
            },
            None,
        );

        let opts = sdk.utility.make_options(&rootctx);
        *sdk.options.borrow_mut() = opts.clone();

        if getpath(&["feature", "test", "active"], &opts) == Value::Bool(true) {
            *sdk.mode.borrow_mut() = "test".to_string();
        }

        *rootctx.options.borrow_mut() = opts.clone();
        *sdk.rootctx.borrow_mut() = Some(rootctx.clone());

        // Add features in the resolved order (make_options puts an explicit
        // List order first, else defaults to test-first). Ordering matters:
        // the `test` feature installs the base mock transport and the
        // transport features (retry/cache/netsim/proxy/ratelimit) wrap
        // whatever is current, so `test` must be added before them to sit at
        // the base of the transport wrapper chain.
        let feature_opts = to_map(&getp(&opts, "feature"));
        if let Value::List(order) = getpath(&["__derived__", "featureorder"], &opts) {
            let names: Vec<String> = order
                .borrow()
                .iter()
                .filter_map(|v| match v {
                    Value::Str(s) => Some(s.clone()),
                    _ => None,
                })
                .collect();
            for fname in names {
                let fopts = getp(&feature_opts, &fname);
                if let Value::Map(_) = fopts {
                    if get_bool(&fopts, "active") == Some(true) {
                        sdk.utility.feature_add(&rootctx, make_feature(&fname));
                    }
                }
            }
        }

        // NOTE: go/ts also accept live Feature objects via an `extend`
        // option; rust options are pure data (Value), so extension features
        // are added with utility.feature_add directly instead.

        // Initialize features.
        let features: Vec<FeatureRef> = sdk.features.borrow().iter().cloned().collect();
        for f in features {
            sdk.utility.feature_init(&rootctx, &f);
        }

        sdk.utility.feature_hook(&rootctx, "PostConstruct");

        sdk
    }

    pub fn options_map(&self) -> Value {
        vs::clone(&self.options.borrow())
    }

    pub fn get_utility(&self) -> Rc<Utility> {
        Utility::copy(&self.utility)
    }

    pub fn get_root_ctx(&self) -> Rc<Context> {
        self.rootctx
            .borrow()
            .clone()
            .expect("SDK root context not initialised")
    }

    pub fn prepare(&self, fetchargs: Value) -> Result<Value, ProjectNameError> {
        let utility = &self.utility;

        let fetchargs = match fetchargs {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        let ctrl = match to_map(&getp(&fetchargs, "ctrl")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        let ctx = utility.make_context(
            CtxSpec {
                opname: Some("prepare".to_string()),
                ctrl: Some(ctrl),
                ..Default::default()
            },
            Some(&self.get_root_ctx()),
        );

        let options = self.options.borrow().clone();

        let path = get_str(&fetchargs, "path").unwrap_or_default();
        let method = get_str(&fetchargs, "method")
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| "GET".to_string());

        let params = match to_map(&getp(&fetchargs, "params")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };
        let query = match to_map(&getp(&fetchargs, "query")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        let headers = utility.prepare_headers(&ctx);

        let specmap = jo(vec![
            ("base", getp(&options, "base")),
            ("prefix", getp(&options, "prefix")),
            ("suffix", getp(&options, "suffix")),
            ("path", Value::str(path)),
            ("method", Value::str(method)),
            ("params", params),
            ("query", query),
            ("headers", headers),
            ("body", getp(&fetchargs, "body")),
            ("step", Value::str("start")),
        ]);
        let spec = Rc::new(RefCell::new(Spec::new(&specmap)));
        *ctx.spec.borrow_mut() = Some(spec.clone());

        // Merge user-provided headers.
        if let Value::Map(uh) = getp(&fetchargs, "headers") {
            let spec_headers = spec.borrow().headers.clone();
            for (k, v) in uh.borrow().iter() {
                setp(&spec_headers, k, v.clone());
            }
        }

        utility.prepare_auth(&ctx)?;

        utility.make_fetch_def(&ctx)
    }

    // Raw endpoint access is operator-controllable, like every entity op.
    // Blocking it means denying BOTH the 'direct' and 'graphql' tokens,
    // since either one reaches the same endpoint.
    pub fn direct(&self, fetchargs: Value) -> Result<Value, ProjectNameError> {
        if !self.op_allowed("direct") {
            return Ok(self.op_denied("direct"));
        }

        self.raw_request(fetchargs)
    }

    // Is this raw-access op permitted by the SDK's allow.op option?
    fn op_allowed(&self, op: &str) -> bool {
        match getpath(&["allow", "op"], &self.options_map()) {
            Value::Str(s) => s.contains(op),
            _ => false,
        }
    }

    fn op_denied(&self, op: &str) -> Value {
        let allow = match getpath(&["allow", "op"], &self.options_map()) {
            Value::Str(s) => s,
            _ => String::new(),
        };
        jo(vec![
            ("ok", Value::Bool(false)),
            ("err", Value::str(format!(
                "ProjectNameSDK: {}: operation not allowed by SDK option \
                 allow.op value: \"{}\"", op, allow))),
        ])
    }

    // Ungated request path shared by direct and graphql, each of which checks
    // its own allow.op token first. Private, rather than a flag on fetchargs:
    // a caller-supplied marker would let anyone opt straight back out of the
    // gate by passing it.
    fn raw_request(&self, fetchargs: Value) -> Result<Value, ProjectNameError> {
        let utility = &self.utility;

        let fetchdef = match self.prepare(fetchargs.clone()) {
            Ok(fd) => fd,
            Err(err) => {
                return Ok(jo(vec![
                    ("ok", Value::Bool(false)),
                    ("err", Value::str(err.msg.clone())),
                ]));
            }
        };

        let ctrl = match to_map(&getp(&fetchargs, "ctrl")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        let ctx = utility.make_context(
            CtxSpec {
                opname: Some("direct".to_string()),
                ctrl: Some(ctrl),
                ..Default::default()
            },
            Some(&self.get_root_ctx()),
        );

        let url = get_str(&fetchdef, "url").unwrap_or_default();
        let fetched = utility.fetch(&ctx, &url, &fetchdef);

        let fetched = match fetched {
            Err(err) => {
                return Ok(jo(vec![
                    ("ok", Value::Bool(false)),
                    ("err", Value::str(err.msg.clone())),
                ]));
            }
            Ok(f) => f,
        };

        if fetched.is_noval() || fetched.is_null() {
            return Ok(jo(vec![
                ("ok", Value::Bool(false)),
                ("err", Value::str("response: undefined")),
            ]));
        }

        if let Value::Map(_) = &fetched {
            let status = to_int(&getp(&fetched, "status"));
            let headers = getp(&fetched, "headers");

            // No-body responses (204, 304) and explicit zero content-length
            // must skip JSON parsing.
            let content_length = match getp(&headers, "content-length") {
                Value::Str(s) => s,
                Value::Num(n) => format!("{}", n as i64),
                _ => String::new(),
            };
            let no_body = status == 204 || status == 304 || content_length == "0";

            let json_data = if no_body {
                Value::Noval
            } else {
                let jf = getp(&fetched, "json");
                if let Value::Func(_) = jf {
                    call_json(&jf)
                } else {
                    Value::Noval
                }
            };

            return Ok(jo(vec![
                ("ok", Value::Bool((200..300).contains(&status))),
                ("status", Value::Num(status as f64)),
                ("headers", headers),
                ("data", json_data),
            ]));
        }

        Ok(jo(vec![
            ("ok", Value::Bool(false)),
            ("err", Value::str("invalid response type")),
        ]))
    }

    // Raw GraphQL access: the pressure valve that makes the generated
    // surface's deliberate omissions (per-call selection sets, typed filter
    // builders, batching, subscriptions) livable — the whole schema stays
    // reachable.
    //
    // Thin wrapper over the same prepare/fetch path direct uses, with the one
    // thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP
    // 200 as a top-level `errors` array, so status alone would report a
    // failed query as ok.
    //
    // NOTE: like direct, this bypasses the feature pipeline — no retry,
    // ratelimit or paging features apply.
    pub fn graphql(
        &self, query: &str, variables: Value, ctrl: Value,
    ) -> Result<Value, ProjectNameError> {
        if !self.op_allowed("graphql") {
            return Ok(self.op_denied("graphql"));
        }

        let vars = match &variables {
            Value::Map(_) => variables,
            _ => Value::empty_map(),
        };
        let ctl = match &ctrl {
            Value::Map(_) => ctrl,
            _ => Value::empty_map(),
        };

        let res = self.raw_request(jo(vec![
            ("method", Value::str("POST")),
            ("headers", jo(vec![("content-type", Value::str("application/json"))])),
            ("body", jo(vec![("query", Value::str(query)), ("variables", vars)])),
            ("ctrl", ctl),
        ]))?;

        // Errors are read BEFORE any status check: a GraphQL parse or
        // validation failure comes back as HTTP 400 carrying the standard
        // { errors: [...] } body, and the raw path represents a non-2xx as
        // ok:false with no err — so returning early on status would discard
        // the server's own diagnostics, which are the only useful part of
        // that response.
        let errors = getpath(&["data", "errors"], &res);

        if let Value::List(items) = &errors {
            let first = items.borrow().first().cloned();
            if let Some(first) = first {
                let msg = get_str(&first, "message")
                    .filter(|m| !m.is_empty())
                    .unwrap_or_else(|| "graphql error".to_string());
                setp(&res, "ok", Value::Bool(false));
                setp(&res, "err",
                     Value::str(format!("ProjectNameSDK: graphql: {}", msg)));
                setp(&res, "graphql", errors.clone());
            }
        }

        Ok(res)
    }

    // <[SLOT]>
}

pub fn test_sdk(testopts: Value, sdkopts: Value) -> Rc<ProjectNameSDK> {
    let sdkopts = match sdkopts {
        Value::Map(_) => vs::clone(&sdkopts),
        _ => Value::empty_map(),
    };

    let testopts = match testopts {
        Value::Map(_) => vs::clone(&testopts),
        _ => Value::empty_map(),
    };
    setp(&testopts, "active", Value::Bool(true));

    // set_path mutates `sdkopts` in place and returns the inner parent node;
    // discard the return so we pass the full options root (mirrors go's
    // vs.SetPath(sdkopts, ...) which does not rebind).
    vs::set_path(
        &sdkopts,
        &Value::list(vec![Value::str("feature"), Value::str("test")]),
        testopts,
        None,
    );

    let sdk = ProjectNameSDK::new(sdkopts);
    *sdk.mode.borrow_mut() = "test".to_string();

    sdk
}
