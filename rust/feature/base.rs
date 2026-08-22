// BaseFeature: the no-op feature every hook defaults to (mirrors go
// feature/base_feature.go). Custom features can embed it for name/active
// bookkeeping and add_options ordering support.

use crate::core::types::Feature;
use crate::utility::voxgigstruct::Value;

pub struct BaseFeature {
    pub version: String,
    pub name: String,
    pub active: bool,

    // add_opts positions this feature when added via the client `extend`
    // option: "__before__", "__after__" or "__replace__" name an
    // already-added feature (mirrors the ts feature `_options`).
    pub add_opts: Option<Value>,
}

impl BaseFeature {
    pub fn new() -> BaseFeature {
        BaseFeature {
            version: "0.0.1".to_string(),
            name: "base".to_string(),
            active: true,
            add_opts: None,
        }
    }
}

impl Default for BaseFeature {
    fn default() -> BaseFeature {
        BaseFeature::new()
    }
}

impl Feature for BaseFeature {
    fn version(&self) -> String {
        self.version.clone()
    }
    fn name(&self) -> String {
        self.name.clone()
    }
    fn active(&self) -> bool {
        self.active
    }
    fn add_options(&self) -> Option<Value> {
        self.add_opts.clone()
    }
}
