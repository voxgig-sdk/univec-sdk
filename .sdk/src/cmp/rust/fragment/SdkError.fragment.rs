use crate::core::helpers::jo;
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

#[derive(Clone)]
pub struct ProjectNameError {
    pub sdk: String,
    pub code: String,
    pub msg: String,
    // Cleaned snapshots attached by makeError (Noval until then).
    pub result: Value,
    pub spec: Value,
    pub status: i64,
}

impl ProjectNameError {
    pub fn new(code: &str, msg: &str) -> ProjectNameError {
        ProjectNameError {
            sdk: "ProjectName".to_string(),
            code: code.to_string(),
            msg: msg.to_string(),
            result: Value::Noval,
            spec: Value::Noval,
            status: -1,
        }
    }

    pub fn not_found(&self) -> bool {
        404 == self.status
    }

    /// The error as a record. What makeError attached is already cleaned;
    /// the error carries no context.
    pub fn to_value(&self) -> Value {
        jo(vec![
            ("sdk", Value::str(self.sdk.clone())),
            ("code", Value::str(self.code.clone())),
            ("message", Value::str(self.msg.clone())),
            ("status", Value::Num(self.status as f64)),
            ("result", self.result.clone()),
            ("spec", self.spec.clone()),
        ])
    }

    pub fn to_json(&self) -> String {
        vs::jsonify(&self.to_value(), Some(&vs::JsonFlags { indent: 0, offset: 0 }))
    }
}

// Hand-written rather than derived so the printed form is decided here: the
// message and the cleaned snapshots, nothing the pipeline holds live.
impl std::fmt::Debug for ProjectNameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProjectNameError")
            .field("code", &self.code)
            .field("msg", &self.msg)
            .field("status", &self.status)
            .field("result", &self.result)
            .field("spec", &self.spec)
            .finish()
    }
}

impl std::fmt::Display for ProjectNameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.msg)
    }
}

impl std::error::Error for ProjectNameError {}
