// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/boru/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The boru vault provider, as a voxgig/plugin definition.
//!
//! It is a plugin because it spawns a process and, in wire mode, opens a
//! socket: the core does neither.

use std::process::Command;
use std::rc::Rc;

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{checkaddr, checkname, providerplugin, Answer, Provider, SekretoError};
use super::httpjson::{fetchjson, textat, trimslash};

/// A boru vault (https://github.com/boru-lang/boru).
///
/// Two ways in, both boru's own.
///
/// With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
/// secret on stdout and nothing else. The passphrase is read by boru
/// itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as
/// config and never puts it on a command line, where it would show up in
/// the process table.
///
/// With an `addr`, boru's wire protocol: `boru vault serve` publishes a
/// read-only, HashiCorp-shaped provision API (boru's
/// design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
/// from `boru vault grant`. A sekreto name is already a valid boru
/// alias, and boru aliases keep their dots, so `api.token` is the single
/// path segment `api.token` - not the `api`/`token` split a HashiCorp KV
/// gets. The value is the `value` field. A 404 is a miss; anything else
/// the server refuses (a revoked capability, a sealed vault) is an
/// error.
///
/// boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
/// credential *broker*, built precisely so the caller never receives the
/// credential. `vault serve` is the provision endpoint, built to hand
/// the value back - that is the one sekreto uses.
pub struct BoruProvider {
    pub command: String,
    pub namespace: String,
    pub home: String,
    /// The wire-protocol address; empty means the CLI is used instead.
    pub addr: String,
    pub token: String,
    pub mount: String,
}

impl Provider for BoruProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        checkname(name)?;

        if !self.addr.is_empty() {
            checkaddr(&self.addr)?;

            let mount = if self.mount.is_empty() {
                "secret"
            } else {
                &self.mount
            };
            let alias = if self.namespace.is_empty() {
                name.to_string()
            } else {
                format!("{}/{}", self.namespace, name)
            };
            let url = format!("{}/v1/{}/data/{}", trimslash(&self.addr), mount, alias);

            let response = fetchjson(
                "GET",
                &url,
                &[("X-Vault-Token", self.token.as_str())],
                None,
            )?;

            if 404 == response.status {
                return Ok(None);
            }

            if 200 != response.status {
                return Err(SekretoError::new(format!(
                    "sekreto: boru serve error: {}: {}",
                    response.status, url
                )));
            }

            return Ok(textat(&response.body, &["data", "data", "value"]));
        }

        let alias = if self.namespace.is_empty() {
            name.to_string()
        } else {
            format!("{}:{}", self.namespace, name)
        };

        let mut run = Command::new(&self.command);
        run.args(["vault", "get", "--reveal", &alias]);

        if !self.home.is_empty() {
            run.env("BORU_HOME", &self.home);
        }

        let done = run.output().map_err(|err| {
            SekretoError::new(format!("sekreto: cannot run {}: {}", self.command, err))
        })?;

        if done.status.success() {
            // boru prints the value and one newline, and nothing else.
            let out = String::from_utf8_lossy(&done.stdout).to_string();
            return Ok(Some(
                out.strip_suffix('\n').map(str::to_string).unwrap_or(out),
            ));
        }

        let why = String::from_utf8_lossy(&done.stderr).trim().to_string();

        // "no alias named" is boru saying it does not hold this secret, which
        // is a miss: the chain carries on to the next provider. A locked vault
        // or a wrong passphrase is not a miss - treating it as one would fall
        // through to a weaker store without saying so.
        if borumiss(&why) {
            return Ok(None);
        }

        let reason = if why.is_empty() {
            format!("exit {}", done.status.code().unwrap_or(-1))
        } else {
            why
        };

        Err(SekretoError::new(format!(
            "sekreto: boru vault error: {}",
            reason
        )))
    }

    fn describe(&self) -> String {
        if !self.addr.is_empty() {
            return format!("boru:{}", trimslash(&self.addr));
        }

        if self.namespace.is_empty() {
            "boru".to_string()
        } else {
            format!("boru:{}", self.namespace)
        }
    }
}

/// Does this boru failure mean "no such secret" rather than "I could not
/// answer"? Matched on boru's own wording for a missing alias.
fn borumiss(why: &str) -> bool {
    why.contains("no alias named")
}

/// The `boru` kind, as a plugin definition.
pub fn plugin() -> Definition {
    providerplugin("boru", |spec| {
        Ok(Rc::new(BoruProvider {
            command: if spec.command.is_empty() {
                "boru".to_string()
            } else {
                spec.command.clone()
            },
            namespace: spec.namespace.clone(),
            home: spec.home.clone(),
            addr: spec.addr.clone(),
            token: spec.token.clone(),
            mount: spec.mount.clone(),
        }) as Rc<dyn Provider>)
    })
}
