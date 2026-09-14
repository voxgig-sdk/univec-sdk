// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/secretspec/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The SecretSpec provider, as a voxgig/plugin definition.
//!
//! It is a plugin because it spawns a process. It reaches no network at
//! all, and its dependency list says so: no `httpjson`, and therefore no
//! TLS anywhere in its closure.

use std::process::Command;
use std::rc::Rc;

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{envkey, providerplugin, Answer, Provider, SekretoError};

/// SecretSpec (https://secretspec.dev).
///
/// SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
/// project needs - plus a chain of its own backends to satisfy them from.
/// That makes it the same shape as sekreto one level down, and the reason
/// to support it is the same reason sekreto exists: a project that has
/// already declared its secrets there should not have to declare them
/// again here.
///
/// Read through its CLI, as boru is, because that is the interface it
/// offers a program in another language: `secretspec get API_TOKEN`
/// prints the value on stdout and nothing else. A sekreto name maps to a
/// SecretSpec key exactly as it maps to an environment variable -
/// `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
/// examples use.
///
/// `backend` selects one of SecretSpec's backends (`--provider`, e.g.
/// `keyring` or `dotenv://.env`) and is called `backend` here only
/// because `provider` already means something else in this library.
///
/// A reason is required, not optional: SecretSpec records every read in
/// an audit log and refuses to read at all without one. sekreto sends
/// `sekreto` unless told otherwise, so the audit trail says which tool
/// asked.
pub struct SecretSpecProvider {
    pub command: String,
    pub file: String,
    pub profile: String,
    pub backend: String,
    pub reason: String,
    pub prefix: String,
}

impl Provider for SecretSpecProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        let key = envkey(name, &self.prefix)?;

        let mut args: Vec<&str> = Vec::new();
        if !self.file.is_empty() {
            args.push("--file");
            args.push(&self.file);
        }
        args.push("get");
        args.push(&key);
        if !self.backend.is_empty() {
            args.push("--provider");
            args.push(&self.backend);
        }
        if !self.profile.is_empty() {
            args.push("--profile");
            args.push(&self.profile);
        }
        args.push("--reason");
        args.push(if self.reason.is_empty() {
            "sekreto"
        } else {
            &self.reason
        });

        let mut run = Command::new(&self.command);
        run.args(&args);

        let done = run.output().map_err(|err| {
            SekretoError::new(format!("sekreto: cannot run {}: {}", self.command, err))
        })?;

        if done.status.success() {
            // The value and one newline, and nothing else.
            let out = String::from_utf8_lossy(&done.stdout).to_string();
            return Ok(Some(
                out.strip_suffix('\n').map(str::to_string).unwrap_or(out),
            ));
        }

        let why = String::from_utf8_lossy(&done.stderr).trim().to_string();

        if secretspecmiss(&why, &key) {
            return Ok(None);
        }

        let reason = if why.is_empty() {
            format!("exit {}", done.status.code().unwrap_or(-1))
        } else {
            why
        };

        Err(SekretoError::new(format!(
            "sekreto: secretspec error: {}",
            reason
        )))
    }

    fn describe(&self) -> String {
        if self.backend.is_empty() {
            "secretspec".to_string()
        } else {
            format!("secretspec:{}", self.backend)
        }
    }
}

/// Does this SecretSpec failure mean "no such secret" rather than "I
/// could not answer"?
///
/// SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
/// not declare and one declared with no value, and both are misses: this
/// store does not hold it, so the chain carries on.
///
/// MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
/// `Provider backend 'keyring' not found`, which is a store that could
/// not answer at all - and reading that as a miss is the worst failure
/// this library has, because the chain then falls through to a weaker
/// store without saying so. The key is required to appear, so the two
/// cannot be confused.
fn secretspecmiss(why: &str, key: &str) -> bool {
    why.contains(&format!("Secret '{}' not found", key))
}

/// The `secretspec` kind, as a plugin definition.
pub fn plugin() -> Definition {
    providerplugin("secretspec", |spec| {
        Ok(Rc::new(SecretSpecProvider {
            command: if spec.command.is_empty() {
                "secretspec".to_string()
            } else {
                spec.command.clone()
            },
            file: spec.file.clone(),
            profile: spec.profile.clone(),
            backend: spec.backend.clone(),
            reason: spec.reason.clone(),
            prefix: spec.prefix.clone(),
        }) as Rc<dyn Provider>)
    })
}
