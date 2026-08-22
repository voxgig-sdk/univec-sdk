// Operation context (mirrors go core/context.go). Fields use interior
// mutability (RefCell) since the pipeline mutates the context in place;
// contexts are shared as Rc<Context>.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::core::control::Control;
use crate::core::error::UnivecError;
use crate::core::helpers::{get_bool, get_str, getp, getpath, jo, rand_int, to_map};
use crate::core::operation::Operation;
use crate::core::response::Response;
use crate::core::result::SdkResult;
use crate::core::sdk::UnivecSDK;
use crate::core::spec::Spec;
use crate::core::types::{Entity, OutVal};
use crate::core::utility_type::Utility;
use crate::utility::voxgigstruct::Value;

pub type OpMap = Rc<RefCell<HashMap<String, Rc<Operation>>>>;

/// Construction spec for a Context (go passes an untyped ctxmap; rust uses
/// this typed builder with `..Default::default()` at call sites).
#[derive(Default)]
pub struct CtxSpec {
    pub opname: Option<String>,
    pub client: Option<Rc<UnivecSDK>>,
    pub utility: Option<Rc<Utility>>,
    /// ctrl as a caller-supplied Value map ({throw, explain, actor, paging}).
    pub ctrl: Option<Value>,
    /// ctrl as an existing Control object.
    pub ctrl_obj: Option<Rc<RefCell<Control>>>,
    pub meta: Option<Value>,
    pub config: Option<Value>,
    pub entopts: Option<Value>,
    pub options: Option<Value>,
    pub entity: Option<Rc<dyn Entity>>,
    pub shared: Option<Value>,
    pub opmap: Option<OpMap>,
    pub data: Option<Value>,
    pub reqdata: Option<Value>,
    pub mtch: Option<Value>,
    pub reqmatch: Option<Value>,
    pub point: Option<Value>,
    pub spec: Option<Rc<RefCell<Spec>>>,
    pub result: Option<Rc<RefCell<SdkResult>>>,
    pub response: Option<Rc<RefCell<Response>>>,
}

pub struct Context {
    pub id: String,
    pub out: RefCell<HashMap<String, OutVal>>,
    pub ctrl: RefCell<Rc<RefCell<Control>>>,
    pub meta: RefCell<Value>,
    pub client: RefCell<Option<Rc<UnivecSDK>>>,
    pub utility: RefCell<Option<Rc<Utility>>>,
    pub op: RefCell<Rc<Operation>>,
    pub point: RefCell<Value>,
    pub config: RefCell<Value>,
    pub entopts: RefCell<Value>,
    pub options: RefCell<Value>,
    pub opmap: RefCell<OpMap>,
    pub response: RefCell<Option<Rc<RefCell<Response>>>>,
    pub result: RefCell<Option<Rc<RefCell<SdkResult>>>>,
    pub spec: RefCell<Option<Rc<RefCell<Spec>>>>,
    pub data: RefCell<Value>,
    pub reqdata: RefCell<Value>,
    pub mtch: RefCell<Value>,
    pub reqmatch: RefCell<Value>,
    pub entity: RefCell<Option<Rc<dyn Entity>>>,
    pub shared: RefCell<Value>,
}

impl Context {
    pub fn new(ctxspec: CtxSpec, basectx: Option<&Rc<Context>>) -> Rc<Context> {
        let id = format!("C{}", rand_int(90000000) + 10000000);

        // Client
        let client = ctxspec
            .client
            .or_else(|| basectx.and_then(|b| b.client.borrow().clone()));

        // Utility
        let utility = ctxspec
            .utility
            .or_else(|| basectx.and_then(|b| b.utility.borrow().clone()));

        // Ctrl
        let ctrl: Rc<RefCell<Control>> = if let Some(cm) = &ctxspec.ctrl {
            let mut c = Control::new();
            if let Some(t) = get_bool(cm, "throw") {
                c.throw = Some(t);
            }
            if let Value::Map(_) = getp(cm, "explain") {
                c.explain = getp(cm, "explain");
            }
            if let Some(a) = get_str(cm, "actor") {
                c.actor = a;
            }
            if let Value::Map(_) = getp(cm, "paging") {
                c.paging = getp(cm, "paging");
            }
            Rc::new(RefCell::new(c))
        } else if let Some(co) = ctxspec.ctrl_obj {
            co
        } else if let Some(b) = basectx {
            b.ctrl.borrow().clone()
        } else {
            Rc::new(RefCell::new(Control::new()))
        };

        // Meta
        let meta = ctxspec
            .meta
            .or_else(|| {
                basectx.and_then(|b| {
                    let m = b.meta.borrow();
                    if matches!(&*m, Value::Map(_)) {
                        Some(m.clone())
                    } else {
                        None
                    }
                })
            })
            .unwrap_or_else(Value::empty_map);

        // Config / Entopts / Options / Entity / Shared: fall back to base.
        let config = ctxspec
            .config
            .or_else(|| basectx.map(|b| b.config.borrow().clone()))
            .unwrap_or(Value::Noval);
        let entopts = ctxspec
            .entopts
            .or_else(|| basectx.map(|b| b.entopts.borrow().clone()))
            .unwrap_or(Value::Noval);
        let options = ctxspec
            .options
            .or_else(|| basectx.map(|b| b.options.borrow().clone()))
            .unwrap_or(Value::Noval);
        let entity = ctxspec
            .entity
            .or_else(|| basectx.and_then(|b| b.entity.borrow().clone()));
        let shared = ctxspec
            .shared
            .or_else(|| {
                basectx.and_then(|b| {
                    let s = b.shared.borrow();
                    if matches!(&*s, Value::Map(_)) {
                        Some(s.clone())
                    } else {
                        None
                    }
                })
            })
            .unwrap_or(Value::Noval);

        // Opmap (shared with the base context, like go).
        let opmap: OpMap = ctxspec
            .opmap
            .or_else(|| basectx.map(|b| b.opmap.borrow().clone()))
            .unwrap_or_else(|| Rc::new(RefCell::new(HashMap::new())));

        // Data maps (never inherited).
        let data = match ctxspec.data.map(|d| to_map(&d)) {
            Some(Value::Map(m)) => Value::Map(m),
            _ => Value::empty_map(),
        };
        let reqdata = match ctxspec.reqdata.map(|d| to_map(&d)) {
            Some(Value::Map(m)) => Value::Map(m),
            _ => Value::empty_map(),
        };
        let mtch = match ctxspec.mtch.map(|d| to_map(&d)) {
            Some(Value::Map(m)) => Value::Map(m),
            _ => Value::empty_map(),
        };
        let reqmatch = match ctxspec.reqmatch.map(|d| to_map(&d)) {
            Some(Value::Map(m)) => Value::Map(m),
            _ => Value::empty_map(),
        };

        // Point / Spec / Result / Response: fall back to base.
        let point = ctxspec
            .point
            .or_else(|| {
                basectx.and_then(|b| {
                    let p = b.point.borrow();
                    if matches!(&*p, Value::Map(_)) {
                        Some(p.clone())
                    } else {
                        None
                    }
                })
            })
            .unwrap_or(Value::Noval);
        let spec = ctxspec
            .spec
            .or_else(|| basectx.and_then(|b| b.spec.borrow().clone()));
        let result = ctxspec
            .result
            .or_else(|| basectx.and_then(|b| b.result.borrow().clone()));
        let response = ctxspec
            .response
            .or_else(|| basectx.and_then(|b| b.response.borrow().clone()));

        let ctx = Rc::new(Context {
            id,
            out: RefCell::new(HashMap::new()),
            ctrl: RefCell::new(ctrl),
            meta: RefCell::new(meta),
            client: RefCell::new(client),
            utility: RefCell::new(utility),
            op: RefCell::new(Rc::new(Operation::new(&Value::empty_map()))),
            point: RefCell::new(point),
            config: RefCell::new(config),
            entopts: RefCell::new(entopts),
            options: RefCell::new(options),
            opmap: RefCell::new(opmap),
            response: RefCell::new(response),
            result: RefCell::new(result),
            spec: RefCell::new(spec),
            data: RefCell::new(data),
            reqdata: RefCell::new(reqdata),
            mtch: RefCell::new(mtch),
            reqmatch: RefCell::new(reqmatch),
            entity: RefCell::new(entity),
            shared: RefCell::new(shared),
        });

        // Resolve operation.
        let opname = ctxspec.opname.unwrap_or_default();
        let op = ctx.resolve_op(&opname);
        *ctx.op.borrow_mut() = op;

        ctx
    }

    fn resolve_op(&self, opname: &str) -> Rc<Operation> {
        // Cache key is `<entity>:<opname>` so two entities with the same op
        // (e.g. both have a "list") get distinct cached Operations.
        let entname = self
            .entity
            .borrow()
            .as_ref()
            .map(|e| e.get_name())
            .unwrap_or_default();
        let cache_key = format!("{}:{}", entname, opname);

        if let Some(op) = self.opmap.borrow().borrow().get(&cache_key) {
            return op.clone();
        }

        if opname.is_empty() {
            return Rc::new(Operation::new(&Value::empty_map()));
        }

        let opcfg = getpath(
            &["entity", &entname, "op", opname],
            &self.config.borrow(),
        );

        let input = if opname == "update" || opname == "create" {
            "data"
        } else {
            "match"
        };

        let targets = match getp(&opcfg, "points") {
            Value::List(l) => Value::List(l),
            _ => Value::empty_list(),
        };

        let op = Rc::new(Operation::new(&jo(vec![
            ("entity", Value::str(entname)),
            ("name", Value::str(opname)),
            ("input", Value::str(input)),
            ("points", targets),
        ])));

        self.opmap
            .borrow()
            .borrow_mut()
            .insert(cache_key, op.clone());
        op
    }

    pub fn make_error(&self, code: &str, msg: &str) -> UnivecError {
        UnivecError::new(code, msg)
    }

    /// The context utility (set on every pipeline context).
    pub fn util(&self) -> Rc<Utility> {
        self.utility
            .borrow()
            .clone()
            .expect("context utility not set")
    }

    // --- ctx.out staging helpers -----------------------------------------

    pub fn out_get(&self, key: &str) -> Option<OutVal> {
        self.out.borrow().get(key).cloned()
    }

    pub fn out_set(&self, key: &str, val: OutVal) {
        self.out.borrow_mut().insert(key.to_string(), val);
    }

    pub fn out_take(&self, key: &str) -> Option<OutVal> {
        self.out.borrow_mut().remove(key)
    }

    /// A ctx.out entry as a Value (Noval when absent or not a Value).
    pub fn out_val(&self, key: &str) -> Value {
        match self.out_get(key) {
            Some(OutVal::Val(v)) => v,
            _ => Value::Noval,
        }
    }
}
