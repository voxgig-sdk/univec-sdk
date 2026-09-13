// VENDORED: @voxgig/omni sdk-20260908-1556-0 (rust/src/lib.rs)
// Source: https://github.com/voxgig/omni @ 274708cc2d12b21707d975543953f845f8444be0  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! voxgig_omni - the shared multi-language test runner.
//!
//! A test spec is plain JSON. The same spec file drives the same tests in
//! every language that ships an omni port, so behaviour is defined once and
//! verified everywhere.
//!
//! ```no_run
//! use std::rc::Rc;
//! use voxgig_omni::{make_runner, Json, Provider, Subject};
//!
//! let runner = make_runner("../spec/fib.json", Provider::default()).unwrap();
//! let pack = runner.runner("fib", None).unwrap();
//! let double: Subject = Rc::new(|args: &[Json]| {
//!     Ok(Json::Num(args[0].asnum().unwrap_or(0.0) * 2.0))
//! });
//! pack.runset(&pack.set("basic"), Some(&double)).unwrap();
//! ```

pub mod json;
pub mod regex;
pub mod runner;
pub mod util;

pub use json::{parse, Json};
pub use regex::Regex;
pub use runner::{
    errify, fixjson, loadspec, make_runner, matchcheck, matchval, nullmodifier, numtext,
    resolvespec, Flags, OmniError, Provider, RunPack, Runner, SpecRef, Subject, SubjectArgs,
    CAPABILITIES,
    SPECVERSION,
};
pub use util::{
    clone, deepequal, getpath, jsonstr, numstr, pathify, stringify, walk, EXISTSMARK, NULLMARK,
    UNDEFMARK,
};
