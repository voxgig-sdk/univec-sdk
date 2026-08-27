// Structured hook logging (mirrors go feature/log_feature.go, using stderr
// lines instead of slog). Logs every pipeline hook with the operation and
// spec summary when active; `level` filters (debug < info < warn < error).

use std::rc::Rc;

use crate::core::context::Context;
use crate::core::types::Feature;
use crate::feature::support::*;
use crate::utility::voxgigstruct::Value;

fn level_num(level: &str) -> i64 {
    match level {
        "debug" => 10,
        "warn" => 30,
        "error" => 40,
        _ => 20,
    }
}

pub struct LogFeature {
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,
    options: Value,
    level: i64,
}

impl LogFeature {
    pub fn new() -> LogFeature {
        LogFeature {
            name: "log".to_string(),
            active: false,
            add_opts: None,
            options: Value::Noval,
            level: level_num("info"),
        }
    }

    fn loghook(&self, hook: &str, ctx: &Rc<Context>) {
        if !self.active {
            return;
        }
        if level_num("info") < self.level {
            return;
        }

        let opname = ctx.op.borrow().name.clone();
        let specinfo = match ctx.spec.borrow().clone() {
            Some(sp) => {
                let s = sp.borrow();
                format!("{} {}", s.method, s.path)
            }
            None => String::new(),
        };

        eprintln!(
            "name=log hook={} op={} spec={}",
            hook, opname, specinfo
        );
    }
}

impl Feature for LogFeature {
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
        self.level = level_num(&fopt_str(options, "level", "info"));
    }

    fn post_construct(&mut self, ctx: &Rc<Context>) {
        self.loghook("PostConstruct", ctx);
    }
    fn post_construct_entity(&mut self, ctx: &Rc<Context>) {
        self.loghook("PostConstructEntity", ctx);
    }
    fn set_data(&mut self, ctx: &Rc<Context>) {
        self.loghook("SetData", ctx);
    }
    fn get_data(&mut self, ctx: &Rc<Context>) {
        self.loghook("GetData", ctx);
    }
    fn set_match(&mut self, ctx: &Rc<Context>) {
        self.loghook("SetMatch", ctx);
    }
    fn get_match(&mut self, ctx: &Rc<Context>) {
        self.loghook("GetMatch", ctx);
    }
    fn pre_point(&mut self, ctx: &Rc<Context>) {
        self.loghook("PrePoint", ctx);
    }
    fn pre_spec(&mut self, ctx: &Rc<Context>) {
        self.loghook("PreSpec", ctx);
    }
    fn pre_request(&mut self, ctx: &Rc<Context>) {
        self.loghook("PreRequest", ctx);
    }
    fn pre_response(&mut self, ctx: &Rc<Context>) {
        self.loghook("PreResponse", ctx);
    }
    fn pre_result(&mut self, ctx: &Rc<Context>) {
        self.loghook("PreResult", ctx);
    }
}
