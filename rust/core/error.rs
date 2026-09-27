
use crate::utility::voxgigstruct::Value;

#[derive(Clone, Debug)]
pub struct UnivecError {
    pub sdk: String,
    pub code: String,
    pub msg: String,
    // Cleaned snapshots attached by makeError (Noval until then).
    pub result: Value,
    pub spec: Value,
    pub status: i64,
}

impl UnivecError {
    pub fn new(code: &str, msg: &str) -> UnivecError {
        UnivecError {
            sdk: "Univec".to_string(),
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
}

impl std::fmt::Display for UnivecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.msg)
    }
}

impl std::error::Error for UnivecError {}
