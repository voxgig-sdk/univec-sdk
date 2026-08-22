// Core traits and shared type aliases (mirrors go core/types.go).

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::response::Response;
use crate::core::result::SdkResult;
use crate::core::spec::Spec;
use crate::utility::voxgigstruct::Value;

/// Feature: every pipeline hook, with no-op defaults. Features are trait
/// objects (`FeatureRef`); `add_options` mirrors go's AddOptions so
/// featureAdd `__before__` / `__after__` / `__replace__` ordering works.
pub trait Feature {
    fn version(&self) -> String {
        "0.0.1".to_string()
    }
    fn name(&self) -> String;
    fn active(&self) -> bool;

    /// Ordering options consulted by the featureAdd utility. Default: None.
    fn add_options(&self) -> Option<Value> {
        None
    }

    fn init(&mut self, _ctx: &Rc<Context>, _options: &Value) {}

    fn post_construct(&mut self, _ctx: &Rc<Context>) {}
    fn post_construct_entity(&mut self, _ctx: &Rc<Context>) {}
    fn set_data(&mut self, _ctx: &Rc<Context>) {}
    fn get_data(&mut self, _ctx: &Rc<Context>) {}
    fn get_match(&mut self, _ctx: &Rc<Context>) {}
    fn set_match(&mut self, _ctx: &Rc<Context>) {}

    fn pre_point(&mut self, _ctx: &Rc<Context>) {}
    fn pre_spec(&mut self, _ctx: &Rc<Context>) {}
    fn pre_request(&mut self, _ctx: &Rc<Context>) {}
    fn pre_response(&mut self, _ctx: &Rc<Context>) {}
    fn pre_result(&mut self, _ctx: &Rc<Context>) {}
    fn pre_done(&mut self, _ctx: &Rc<Context>) {}
    fn pre_unexpected(&mut self, _ctx: &Rc<Context>) {}

    /// Non-standard hooks (go dispatches these reflectively; rust routes
    /// unknown hook names here).
    fn custom_hook(&mut self, _name: &str, _ctx: &Rc<Context>) {}

    /// Hook dispatch by name (called by the featureHook utility).
    fn dispatch(&mut self, name: &str, ctx: &Rc<Context>) {
        match name {
            "PostConstruct" => self.post_construct(ctx),
            "PostConstructEntity" => self.post_construct_entity(ctx),
            "SetData" => self.set_data(ctx),
            "GetData" => self.get_data(ctx),
            "GetMatch" => self.get_match(ctx),
            "SetMatch" => self.set_match(ctx),
            "PrePoint" => self.pre_point(ctx),
            "PreSpec" => self.pre_spec(ctx),
            "PreRequest" => self.pre_request(ctx),
            "PreResponse" => self.pre_response(ctx),
            "PreResult" => self.pre_result(ctx),
            "PreDone" => self.pre_done(ctx),
            "PreUnexpected" => self.pre_unexpected(ctx),
            _ => self.custom_hook(name, ctx),
        }
    }
}

pub type FeatureRef = Rc<RefCell<dyn Feature>>;

/// Entity: the dynamic entity contract (mirrors go core Entity interface).
/// `matchv` is go's Match (— `match` is a rust keyword).
pub trait Entity {
    fn get_name(&self) -> String;
    fn make(&self) -> Rc<dyn Entity>;
    fn data(&self, args: Option<&Value>) -> Value;
    fn matchv(&self, args: Option<&Value>) -> Value;

    /// `remove` resolves to the entity, marked. The instance KEEPS the data
    /// it held — a caller can still read what was deleted — but it is no
    /// longer a live record.
    fn mark_deleted(&self);
    fn deleted(&self) -> bool;
}

/// UnivecEntity: the full CRUD contract every generated entity
/// implements. Ops the API spec doesn't define are runtime-error stubs.
pub trait UnivecEntity: Entity + Sized {
    /// Every operation resolves to the ENTITY, not the raw data — `list` to a
    /// vector of them, one per record. The record is reached through
    /// `.data(None)`. See AGENTS.md "Entity operations return ENTITIES".
    ///
    /// The receivers are `&Rc<Self>` because the result IS this entity: the
    /// op absorbs `resdata`/`resmatch` into it and hands the handle back.
    /// `Value` cannot carry an entity — it is a closed data union
    /// (Noval|Null|Bool|Num|Str|List|Map|Func|Sentinel) and adding a variant
    /// to a general-purpose struct library to carry SDK objects would be
    /// wrong — so the CONTRACT lives in these signatures instead.
    fn load(self: &Rc<Self>, reqmatch: Value, ctrl: Value) -> Result<Rc<Self>, UnivecError>;
    fn list(self: &Rc<Self>, reqmatch: Value, ctrl: Value) -> Result<Vec<Rc<Self>>, UnivecError>;
    fn create(self: &Rc<Self>, reqdata: Value, ctrl: Value) -> Result<Rc<Self>, UnivecError>;
    fn update(self: &Rc<Self>, reqdata: Value, ctrl: Value) -> Result<Rc<Self>, UnivecError>;
    fn remove(self: &Rc<Self>, reqmatch: Value, ctrl: Value) -> Result<Rc<Self>, UnivecError>;
}

/// Transport: `(ctx, url, fetchdef) -> transport-shaped response map`.
/// An Ok(Value::Noval) mirrors go's (nil, nil) transport result.
pub type FetcherFn =
    Rc<dyn Fn(&Rc<Context>, &str, &Value) -> Result<Value, UnivecError>>;

/// Pipeline stage products staged on ctx.out (go stores these in the
/// untyped ctx.Out map; rust keeps them in one typed enum).
#[derive(Clone)]
pub enum OutVal {
    Val(Value),
    Err(UnivecError),
    Spec(Rc<RefCell<Spec>>),
    Response(Rc<RefCell<Response>>),
    Result(Rc<RefCell<SdkResult>>),
}
