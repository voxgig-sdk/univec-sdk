use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::get_str;
use crate::core::types::FeatureRef;

// feature_add_util appends a feature to the client's feature list. A
// feature whose add_options() names an already-added feature with
// "__before__", "__after__" or "__replace__" positions itself relative to
// it — mirroring the ts featureAdd. The first match wins; when no ordering
// option matches, the feature is appended.
pub fn feature_add_util(ctx: &Rc<Context>, f: FeatureRef) {
    let client = match ctx.client.borrow().clone() {
        Some(c) => c,
        None => return,
    };

    let fopts = f.borrow().add_options();

    if let Some(fopts) = fopts {
        let before = get_str(&fopts, "__before__").unwrap_or_default();
        let after = get_str(&fopts, "__after__").unwrap_or_default();
        let replace = get_str(&fopts, "__replace__").unwrap_or_default();

        if !before.is_empty() || !after.is_empty() || !replace.is_empty() {
            let mut features = client.features.borrow_mut();
            for i in 0..features.len() {
                let name = features[i].borrow().name();
                if before == name {
                    features.insert(i, f);
                    return;
                }
                if after == name {
                    features.insert(i + 1, f);
                    return;
                }
                if replace == name {
                    features[i] = f;
                    return;
                }
            }
        }
    }

    client.features.borrow_mut().push(f);
}
