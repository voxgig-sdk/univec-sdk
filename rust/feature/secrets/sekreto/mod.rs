// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! sekreto: one interface for secrets, wherever they live.
//!
//! An app asks a `Sekreto` for `api.token` and never learns whether the
//! value came from the environment, a `.env` file, HashiCorp Vault, AWS,
//! GCP, Azure or a boru vault. Swapping the chain is a config change, not
//! a code change.
//!
//! THIS IS THE CORE, AND ITS ONLY DEPENDENCY IS `voxgig_plugin`. Four
//! provider kinds are built in - `env`, `memory`, `dotenv` and `file` -
//! and what makes them built in is that they read at most a local file. No
//! TLS, no socket, no subprocess, no hash function: the manifest here
//! names no TLS crate at all, so a consumer whose chain is `[dotenv, env]`
//! compiles none of one.
//!
//! Every kind that opens a socket, signs a request or spawns a process is
//! a voxgig/plugin definition in its own crate under `plugins/`, and a
//! `Sekreto` can build exactly the ones its constructor was handed:
//!
//! ```ignore
//! use voxgig_sekreto::{Options, ProviderSpec, Sekreto};
//!
//! let secrets = Sekreto::new(Options {
//!     plugins: vec![voxgig_sekreto_hashicorp::plugin()],
//!     providers: vec![ProviderSpec::of("hashicorp")],
//!     ..Default::default()
//! })?;
//! ```
//!
//! See `docs/design/plugin-providers.md`.

pub mod addr;
pub mod providers;
pub mod sekreto;

pub use self::addr::{checkaddr, safeaddr};
pub use self::providers::{
    builtins, optionsof, providerplugin, specof, AuthSpec, DotenvProvider, EnvProvider,
    FileProvider, MemoryProvider, Provider, ProviderSpec, BUILTIN_KINDS, ERROR_CODE, PLUGIN_KINDS,
    PROVIDER_EXPORT,
};
pub use self::sekreto::{
    awsparam, checkname, envkey, flatname, parsedotenv, redact, storename, validname, vaultref,
    Answer, ChainError, Options, Sekreto, SekretoError, VaultRef,
};

/// voxgig/plugin, re-exported: a consumer builds a custom kind with
/// `providerplugin` and never needs to name the dependency itself.
pub use super::plugin as voxgig_plugin;
