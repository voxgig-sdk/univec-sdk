// Univec SDK feature modules (mirrors tm/go/feature).
// Each feature is a Feature trait object registered on the client;
// `support` carries the shared option readers (go feature_options.go).

pub mod support;

pub mod base;
pub mod audit;
pub mod cache;
pub mod clienttrack;
pub mod cost;
pub mod debug;
pub mod idempotency;
pub mod log;
pub mod metrics;
pub mod netsim;
pub mod paging;
pub mod proxy;
pub mod ratelimit;
pub mod rbac;
pub mod retry;
pub mod secrets;
pub mod streaming;
pub mod telemetry;
pub mod test;
pub mod timeout;
