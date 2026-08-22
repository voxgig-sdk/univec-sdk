// EphemeralKey entity client (generated — mirrors the go Entity fragment).

// Ops present vary per entity, so some shared imports may go unused.
#![allow(unused_imports)]

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::{Context, CtxSpec};
use crate::core::error::UnivecError;
use crate::core::helpers::{get_bool, getp, setp, to_map};
use crate::core::sdk::UnivecSDK;
use crate::core::types::{Entity, UnivecEntity};
use crate::core::utility_type::Utility;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub struct EphemeralKeyEntity {
    name: String,
    #[allow(dead_code)]
    client: Rc<UnivecSDK>,
    utility: Rc<Utility>,
    entopts: Value,
    data: RefCell<Value>,
    mtch: RefCell<Value>,
    entctx: RefCell<Option<Rc<Context>>>,
    // Set once a successful `remove` resolves on this instance.
    deleted: RefCell<bool>,
}

impl EphemeralKeyEntity {
    pub fn new(client: &Rc<UnivecSDK>, entopts: Value) -> Rc<EphemeralKeyEntity> {
        let entopts = match entopts {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };
        if get_bool(&entopts, "active").is_none() {
            setp(&entopts, "active", Value::Bool(true));
        } else if get_bool(&entopts, "active") != Some(false) {
            setp(&entopts, "active", Value::Bool(true));
        }

        let e = Rc::new(EphemeralKeyEntity {
            name: "ephemeral_key".to_string(),
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
    ) -> Result<Value, UnivecError> {
        let utility = &self.utility;

        self.utility.feature_hook(ctx, "PrePoint");
        let point = match utility.make_point(ctx) {
            Ok(p) => p,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("point", crate::core::types::OutVal::Val(point));

        self.utility.feature_hook(ctx, "PreSpec");
        let spec = match utility.make_spec(ctx) {
            Ok(s) => s,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("spec", crate::core::types::OutVal::Spec(spec));

        self.utility.feature_hook(ctx, "PreRequest");
        let resp = match utility.make_request(ctx) {
            Ok(r) => r,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("request", crate::core::types::OutVal::Response(resp));

        self.utility.feature_hook(ctx, "PreResponse");
        let resp2 = match utility.make_response(ctx) {
            Ok(r) => r,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("response", crate::core::types::OutVal::Response(resp2));

        self.utility.feature_hook(ctx, "PreResult");
        let result = match utility.make_result(ctx) {
            Ok(r) => r,
            Err(err) => return utility.make_error(ctx, Some(err)),
        };
        ctx.out_set("result", crate::core::types::OutVal::Result(result));

        self.utility.feature_hook(ctx, "PreDone");
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
    ) -> Result<std::vec::IntoIter<Value>, UnivecError> {
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

impl Entity for EphemeralKeyEntity {
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
        EphemeralKeyEntity::new(&self.client, opts) as Rc<dyn Entity>
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

impl UnivecEntity for EphemeralKeyEntity {
    fn load(self: &Rc<Self>, _reqmatch: Value, _ctrl: Value) -> Result<Rc<Self>, UnivecError> {
        Err(crate::core::helpers::unsupported_op("load", &self.name))
    }

    fn list(self: &Rc<Self>, _reqmatch: Value, _ctrl: Value) -> Result<Vec<Rc<Self>>, UnivecError> {
        Err(crate::core::helpers::unsupported_op("list", &self.name))
    }


    fn create(self: &Rc<Self>, reqdata: Value, ctrl: Value) -> Result<Rc<Self>, UnivecError> {
        let ctx = self.utility.make_context(
            CtxSpec {
                opname: Some("create".to_string()),
                ctrl: Some(ctrl),
                mtch: Some(self.mtch.borrow().clone()),
                data: Some(self.data.borrow().clone()),
                reqdata: Some(reqdata),
                ..Default::default()
            },
            Some(&self.ent_ctx()),
        );
    
        self.run_op(&ctx, &|ctx| {
            if let Some(result) = ctx.result.borrow().clone() {
                let resdata = result.borrow().resdata.clone();
                if !resdata.is_noval() && !resdata.is_null() {
                    *self.data.borrow_mut() = match to_map(&vs::clone(&resdata)) {
                        Value::Map(m) => Value::Map(m),
                        _ => Value::empty_map(),
                    };
                }
            }
        })?;
    
        // The operation resolves to THIS entity: `run_op` has just absorbed the
        // result into it, and the caller reaches the record through `.data(None)`.
        // See AGENTS.md "Entity operations return ENTITIES".
    
        Ok(self.clone())
    }
    

    fn update(self: &Rc<Self>, _reqdata: Value, _ctrl: Value) -> Result<Rc<Self>, UnivecError> {
        Err(crate::core::helpers::unsupported_op("update", &self.name))
    }

    fn remove(self: &Rc<Self>, _reqmatch: Value, _ctrl: Value) -> Result<Rc<Self>, UnivecError> {
        Err(crate::core::helpers::unsupported_op("remove", &self.name))
    }
}
