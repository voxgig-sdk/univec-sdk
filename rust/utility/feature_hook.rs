use std::rc::Rc;

use crate::core::context::Context;

pub fn feature_hook_util(ctx: &Rc<Context>, name: &str) {
    let client = match ctx.client.borrow().clone() {
        Some(c) => c,
        None => return,
    };

    // Snapshot the list so a hook that mutates the feature set does not
    // invalidate iteration.
    let features: Vec<_> = client.features.borrow().iter().cloned().collect();

    for f in features {
        f.borrow_mut().dispatch(name, ctx);
    }
}
