// Per-call control state (mirrors go core/control.go).

use crate::core::error::UnivecError;
use crate::utility::voxgigstruct::Value;

pub struct Control {
    pub throw: Option<bool>,
    pub err: Option<UnivecError>,
    // explain / paging are Value maps when supplied (Noval otherwise). They
    // are the caller's own maps (reference-shared), so recorded entries are
    // visible to the caller after the operation completes.
    pub explain: Value,
    pub actor: String,
    pub paging: Value,
}

impl Control {
    pub fn new() -> Control {
        Control {
            throw: None,
            err: None,
            explain: Value::Noval,
            actor: String::new(),
            paging: Value::Noval,
        }
    }

    pub fn has_explain(&self) -> bool {
        matches!(self.explain, Value::Map(_))
    }
}

impl Default for Control {
    fn default() -> Control {
        Control::new()
    }
}
