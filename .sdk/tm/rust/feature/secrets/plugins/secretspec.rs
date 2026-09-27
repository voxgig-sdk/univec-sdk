// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (rust/plugins/secretspec/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
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
