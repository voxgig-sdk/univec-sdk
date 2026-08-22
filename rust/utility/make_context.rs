use std::rc::Rc;

use crate::core::context::{Context, CtxSpec};

pub fn make_context_util(ctxspec: CtxSpec, basectx: Option<&Rc<Context>>) -> Rc<Context> {
    Context::new(ctxspec, basectx)
}
