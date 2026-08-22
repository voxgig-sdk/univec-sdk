// EntityName entity client (generated — mirrors the go Entity fragment).

// Ops present vary per entity, so some shared imports may go unused.
#![allow(unused_imports)]

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::{Context, CtxSpec};
use crate::core::error::ProjectNameError;
use crate::core::helpers::{get_bool, getp, setp, to_map};
use crate::core::sdk::ProjectNameSDK;
use crate::core::types::{Entity, ProjectNameEntity};
use crate::core::utility_type::Utility;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub struct EntyClass {
    name: String,
    #[allow(dead_code)]
    client: Rc<ProjectNameSDK>,
    utility: Rc<Utility>,
    entopts: Value,
    data: RefCell<Value>,
    mtch: RefCell<Value>,
    entctx: RefCell<Option<Rc<Context>>>,
    // Set once a successful `remove` resolves on this instance.
    deleted: RefCell<bool>,
}

impl EntyClass {
    pub fn new(client: &Rc<ProjectNameSDK>, entopts: Value) -> Rc<EntyClass> {
        let entopts = match entopts {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };
        if get_bool(&entopts, "active").is_none() {
            setp(&entopts, "active", Value::Bool(true));
        } else if get_bool(&entopts, "active") != Some(false) {
            setp(&entopts, "active", Value::Bool(true));
        }

        let e = Rc::new(EntyClass {
            name: "entityname".to_string(),
            client: client.clone(),
            utility: client.get_utility(),
            entopts: entopts.clone(),
            data: RefCell::new(Value::empty_map()),
            mtch: RefCell::new(Value::empty_map()),
            entctx: RefCell::new(None),
            deleted: RefCell::new(false),
        });

        let entctx = e.utility.make_context(
            CtxSpec {
                entity: Some(e.clone() as Rc<dyn Entity>),
                entopts: Some(entopts),
                ..Default::default()
            },
            Some(&client.get_root_ctx()),
        );

        e.utility.feature_hook(&entctx, "PostConstructEntity");

        *e.entctx.borrow_mut() = Some(entctx);

        e
    }

    fn ent_ctx(&self) -> Rc<Context> {
        self.entctx
            .borrow()
            .clone()
            .expect("entity context not initialised")
    }

    // Runs the pipeline and returns the terminal result VALUE. The entity
    // contract lives one level up, in the op methods below: they call this,
    // then hand back the entity (see AGENTS.md). It is split that way because
    // `Value` is a closed data union that cannot carry an entity.
    fn run_op(
        &self,
        ctx: &Rc<Context>,
        post_done: &dyn Fn(&Rc<Context>),
    ) -> Result<Value, ProjectNameError> {
        let utility = &self.utility;

        // #PrePoint-Hook

        let point = match utility.make_point(ctx) {
            Ok(p) => p,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("point", crate::core::types::OutVal::Val(point));

        // #PreSpec-Hook

        let spec = match utility.make_spec(ctx) {
            Ok(s) => s,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("spec", crate::core::types::OutVal::Spec(spec));

        // #PreRequest-Hook

        let resp = match utility.make_request(ctx) {
            Ok(r) => r,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("request", crate::core::types::OutVal::Response(resp));

        // #PreResponse-Hook

        let resp2 = match utility.make_response(ctx) {
            Ok(r) => r,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("response", crate::core::types::OutVal::Response(resp2));

        // #PreResult-Hook

        let result = match utility.make_result(ctx) {
            Ok(r) => r,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("result", crate::core::types::OutVal::Result(result));

        // #PreDone-Hook

        post_done(ctx);

        utility.done(ctx)
    }

    /// Streaming operation. Runs `action` through the full pipeline and
    /// returns an iterator over the result items, so the `streaming`
    /// feature's incremental output is reachable from a generated entity (a
    /// normal op call materialises the whole result). This runtime is
    /// synchronous, so the returned iterator is a lazy cursor over items the
    /// pipeline produced. `callopts` parameterises the call:
    ///   - inbound (download): iterate items/chunks from the streaming
    ///     feature when active, else the materialised items;
    ///   - outbound (upload): a `body` in `callopts` is attached to the
    ///     request (reqdata `body$`) so the transport can stream a payload;
    ///   - `ctrl` (pipeline control) threads pipeline options.
    pub fn stream(
        &self,
        action: &str,
        args: Value,
        callopts: Value,
    ) -> Result<std::vec::IntoIter<Value>, ProjectNameError> {
        let stream_opts = match &callopts {
            Value::Map(_) => callopts.clone(),
            _ => Value::empty_map(),
        };

        let ctrl = match to_map(&getp(&stream_opts, "ctrl")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };
        setp(&ctrl, "stream", stream_opts.clone());

        // `args` carries the op's request match (list/load); pass it through
        // as reqmatch so the same pipeline the op methods run is exercised.
        let reqmatch = match to_map(&args) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };

        let ctx = self.utility.make_context(
            CtxSpec {
                opname: Some(action.to_string()),
                ctrl: Some(ctrl),
                mtch: Some(self.mtch.borrow().clone()),
                data: Some(self.data.borrow().clone()),
                reqmatch: Some(reqmatch),
                ..Default::default()
            },
            Some(&self.ent_ctx()),
        );

        // Outbound: attach a caller `body` so the transport can stream a
        // request payload (reqdata `body$`).
        let body = getp(&stream_opts, "body");
        if !body.is_noval() && !body.is_null() {
            let reqdata = match ctx.reqdata.borrow().clone() {
                Value::Map(m) => Value::Map(m),
                _ => Value::empty_map(),
            };
            setp(&reqdata, "body$", body);
            *ctx.reqdata.borrow_mut() = reqdata;
        }

        // Run the same pipeline as run_op.
        self.utility.feature_hook(&ctx, "PrePoint");
        let point = self.utility.make_point(&ctx)?;
        ctx.out_set("point", crate::core::types::OutVal::Val(point));

        self.utility.feature_hook(&ctx, "PreSpec");
        let spec = self.utility.make_spec(&ctx)?;
        ctx.out_set("spec", crate::core::types::OutVal::Spec(spec));

        self.utility.feature_hook(&ctx, "PreRequest");
        let resp = self.utility.make_request(&ctx)?;
        ctx.out_set("request", crate::core::types::OutVal::Response(resp));

        self.utility.feature_hook(&ctx, "PreResponse");
        let resp2 = self.utility.make_response(&ctx)?;
        ctx.out_set("response", crate::core::types::OutVal::Response(resp2));

        self.utility.feature_hook(&ctx, "PreResult");
        let result = self.utility.make_result(&ctx)?;
        ctx.out_set("result", crate::core::types::OutVal::Result(result));

        self.utility.feature_hook(&ctx, "PreDone");

        // Inbound: prefer the streaming feature's incremental producer; else
        // fall back to the materialised items so `stream` always yields.
        let cur = ctx.result.borrow().clone();
        if let Some(res) = &cur {
            let streamfn = res.borrow().stream.clone();
            if let Some(sf) = streamfn {
                return Ok(sf().into_iter());
            }
        }

        let data = self.utility.done(&ctx)?;
        let items: Vec<Value> = match data {
            Value::List(l) => l.borrow().iter().cloned().collect(),
            Value::Noval | Value::Null => Vec::new(),
            other => vec![other],
        };
        Ok(items.into_iter())
    }
}

impl Entity for EntyClass {
    fn get_name(&self) -> String {
        self.name.clone()
    }

    // `remove` resolves to the entity, marked. The instance KEEPS the data
    // it held — a caller can still read what was deleted — but it is no
    // longer a live record.
    fn mark_deleted(&self) {
        *self.deleted.borrow_mut() = true;
    }

    fn deleted(&self) -> bool {
        *self.deleted.borrow()
    }

    fn make(&self) -> Rc<dyn Entity> {
        let opts = Value::empty_map();
        if let Value::Map(m) = &self.entopts {
            for (k, v) in m.borrow().iter() {
                setp(&opts, k, v.clone());
            }
        }
        EntyClass::new(&self.client, opts) as Rc<dyn Entity>
    }

    fn data(&self, args: Option<&Value>) -> Value {
        if let Some(arg) = args {
            if !arg.is_noval() && !arg.is_null() {
                let cloned = to_map(&vs::clone(arg));
                *self.data.borrow_mut() = match cloned {
                    Value::Map(m) => Value::Map(m),
                    _ => Value::empty_map(),
                };
                self.utility.feature_hook(&self.ent_ctx(), "SetData");
            }
        }

        self.utility.feature_hook(&self.ent_ctx(), "GetData");
        vs::clone(&self.data.borrow())
    }

    fn matchv(&self, args: Option<&Value>) -> Value {
        if let Some(arg) = args {
            if !arg.is_noval() && !arg.is_null() {
                let cloned = to_map(&vs::clone(arg));
                *self.mtch.borrow_mut() = match cloned {
                    Value::Map(m) => Value::Map(m),
                    _ => Value::empty_map(),
                };
                self.utility.feature_hook(&self.ent_ctx(), "SetMatch");
            }
        }

        self.utility.feature_hook(&self.ent_ctx(), "GetMatch");
        vs::clone(&self.mtch.borrow())
    }
}

impl ProjectNameEntity for EntyClass {
    // #LoadOp

    // #ListOp

    // #CreateOp

    // #UpdateOp

    // #RemoveOp
}
