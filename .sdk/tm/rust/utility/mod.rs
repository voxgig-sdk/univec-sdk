// Univec SDK utilities: the operation pipeline building blocks
// (mirrors tm/go/utility). The voxgig struct port is vendored as the
// `voxgigstruct` submodule — it is the SDK's uniform data model.

pub mod voxgigstruct;

pub mod clean;
pub mod done;
pub mod feature_add;
pub mod feature_hook;
pub mod feature_init;
pub mod fetcher;
pub mod jsonparse;
pub mod make_context;
pub mod make_error;
pub mod make_fetch_def;
pub mod make_options;
pub mod make_point;
pub mod make_request;
pub mod make_response;
pub mod make_result;
pub mod make_spec;
pub mod make_url;
pub mod param;
pub mod prepare_auth;
pub mod prepare_body;
pub mod prepare_headers;
pub mod prepare_method;
pub mod prepare_params;
pub mod prepare_path;
pub mod graphql;
pub mod prepare_query;
pub mod result_basic;
pub mod result_body;
pub mod result_headers;
pub mod transform_request;
pub mod transform_response;
