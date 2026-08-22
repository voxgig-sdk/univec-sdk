// The Utility bundle (mirrors go core/utility_type.go). Go carries the
// utilities as swappable function pointers; rust binds them statically and
// keeps the two members that genuinely vary per client swappable: the
// transport (`fetcher`, wrapped by features like retry/cache/netsim) and
// the `custom` map of caller-supplied utility callables.

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::context::{Context, CtxSpec};
use crate::core::error::UnivecError;
use crate::core::response::Response;
use crate::core::result::SdkResult;
use crate::core::spec::Spec;
use crate::core::types::{FeatureRef, FetcherFn};
use crate::utility as u;
use crate::utility::voxgigstruct::Value;

pub struct Utility {
    pub fetcher: RefCell<FetcherFn>,
    pub custom: RefCell<Value>,
}

impl Utility {
    pub fn new() -> Rc<Utility> {
        Rc::new(Utility {
            fetcher: RefCell::new(Rc::new(|ctx, url, fetchdef| {
                u::fetcher::fetcher_util(ctx, url, fetchdef)
            })),
            custom: RefCell::new(Value::empty_map()),
        })
    }

    /// CopyUtility: a fresh view sharing the (possibly feature-wrapped)
    /// fetcher, with a shallow copy of the custom map.
    pub fn copy(src: &Utility) -> Rc<Utility> {
        let custom = Value::empty_map();
        if let Value::Map(m) = &*src.custom.borrow() {
            for (k, v) in m.borrow().iter() {
                crate::core::helpers::setp(&custom, k, v.clone());
            }
        }
        Rc::new(Utility {
            fetcher: RefCell::new(src.fetcher.borrow().clone()),
            custom: RefCell::new(custom),
        })
    }

    /// Invoke the active transport.
    pub fn fetch(
        &self,
        ctx: &Rc<Context>,
        url: &str,
        fetchdef: &Value,
    ) -> Result<Value, UnivecError> {
        let f = self.fetcher.borrow().clone();
        f(ctx, url, fetchdef)
    }

    pub fn clean(&self, ctx: &Rc<Context>, val: &Value) -> Value {
        u::clean::clean_util(ctx, val)
    }

    pub fn done(&self, ctx: &Rc<Context>) -> Result<Value, UnivecError> {
        u::done::done_util(ctx)
    }

    pub fn make_error(
        &self,
        ctx: &Rc<Context>,
        err: Option<UnivecError>,
    ) -> Result<Value, UnivecError> {
        u::make_error::make_error_util(ctx, err)
    }

    pub fn feature_add(&self, ctx: &Rc<Context>, f: FeatureRef) {
        u::feature_add::feature_add_util(ctx, f)
    }

    pub fn feature_hook(&self, ctx: &Rc<Context>, name: &str) {
        u::feature_hook::feature_hook_util(ctx, name)
    }

    pub fn feature_init(&self, ctx: &Rc<Context>, f: &FeatureRef) {
        u::feature_init::feature_init_util(ctx, f)
    }

    pub fn make_fetch_def(&self, ctx: &Rc<Context>) -> Result<Value, UnivecError> {
        u::make_fetch_def::make_fetch_def_util(ctx)
    }

    pub fn make_context(&self, spec: CtxSpec, basectx: Option<&Rc<Context>>) -> Rc<Context> {
        u::make_context::make_context_util(spec, basectx)
    }

    pub fn make_options(&self, ctx: &Rc<Context>) -> Value {
        u::make_options::make_options_util(ctx)
    }

    pub fn make_request(
        &self,
        ctx: &Rc<Context>,
    ) -> Result<Rc<RefCell<Response>>, UnivecError> {
        u::make_request::make_request_util(ctx)
    }

    pub fn make_response(
        &self,
        ctx: &Rc<Context>,
    ) -> Result<Rc<RefCell<Response>>, UnivecError> {
        u::make_response::make_response_util(ctx)
    }

    pub fn make_result(
        &self,
        ctx: &Rc<Context>,
    ) -> Result<Rc<RefCell<SdkResult>>, UnivecError> {
        u::make_result::make_result_util(ctx)
    }

    pub fn make_point(&self, ctx: &Rc<Context>) -> Result<Value, UnivecError> {
        u::make_point::make_point_util(ctx)
    }

    pub fn make_spec(&self, ctx: &Rc<Context>) -> Result<Rc<RefCell<Spec>>, UnivecError> {
        u::make_spec::make_spec_util(ctx)
    }

    pub fn make_url(&self, ctx: &Rc<Context>) -> Result<String, UnivecError> {
        u::make_url::make_url_util(ctx)
    }

    pub fn param(&self, ctx: &Rc<Context>, paramdef: &Value) -> Value {
        u::param::param_util(ctx, paramdef)
    }

    pub fn prepare_auth(&self, ctx: &Rc<Context>) -> Result<Rc<RefCell<Spec>>, UnivecError> {
        u::prepare_auth::prepare_auth_util(ctx)
    }

    pub fn prepare_body(&self, ctx: &Rc<Context>) -> Value {
        u::prepare_body::prepare_body_util(ctx)
    }

    pub fn prepare_headers(&self, ctx: &Rc<Context>) -> Value {
        u::prepare_headers::prepare_headers_util(ctx)
    }

    pub fn prepare_method(&self, ctx: &Rc<Context>) -> String {
        u::prepare_method::prepare_method_util(ctx)
    }

    pub fn prepare_params(&self, ctx: &Rc<Context>) -> Value {
        u::prepare_params::prepare_params_util(ctx)
    }

    pub fn prepare_path(&self, ctx: &Rc<Context>) -> String {
        u::prepare_path::prepare_path_util(ctx)
    }

    pub fn prepare_query(&self, ctx: &Rc<Context>) -> Value {
        u::prepare_query::prepare_query_util(ctx)
    }

    pub fn result_basic(&self, ctx: &Rc<Context>) -> Option<Rc<RefCell<SdkResult>>> {
        u::result_basic::result_basic_util(ctx)
    }

    pub fn result_body(&self, ctx: &Rc<Context>) -> Option<Rc<RefCell<SdkResult>>> {
        u::result_body::result_body_util(ctx)
    }

    pub fn result_headers(&self, ctx: &Rc<Context>) -> Option<Rc<RefCell<SdkResult>>> {
        u::result_headers::result_headers_util(ctx)
    }

    pub fn transform_request(&self, ctx: &Rc<Context>) -> Value {
        u::transform_request::transform_request_util(ctx)
    }

    pub fn transform_response(&self, ctx: &Rc<Context>) -> Value {
        u::transform_response::transform_response_util(ctx)
    }
}
