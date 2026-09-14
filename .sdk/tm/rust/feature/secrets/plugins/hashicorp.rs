// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/hashicorp/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The HashiCorp Vault provider, as a voxgig/plugin definition.
//!
//! It is a plugin because it opens a socket: the core reads at most a
//! local file. Depend on this crate to put `hashicorp` in a chain, and on
//! nothing else you do not configure.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs;
use std::rc::Rc;
use std::time::Instant;

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{checkaddr, providerplugin, vaultref, Answer, AuthSpec, Provider, SekretoError};
use super::httpjson::json::{self, Json};
use super::httpjson::{
    expiryseconds, fetchjson, headerrefs, renewdue, renewtime, textat, trimslash,
};

/// HashiCorp Vault.
///
/// KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api`
/// and takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
/// `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means
/// "not here" - a miss - so a vault can sit in a chain with fallbacks.
///
/// A Vault Enterprise namespace rides the X-Vault-Namespace header, on
/// logins as well as reads.
///
/// Instead of being handed a token, the provider can log in: Kubernetes
/// auth (the pod's service-account JWT, from its conventional path) or
/// AppRole. A failed login is an error, never a miss - it means this
/// store could not answer at all.
#[derive(Default)]
pub struct HashicorpProvider {
    pub addr: String,
    pub token: String,
    pub mount: String,
    /// KV engine version, 1 or 2.
    pub kv: u32,
    pub vaultnamespace: String,
    pub auth: Option<AuthSpec>,
    // The working token: a configured token is kept forever, a logged-in
    // token is renewed shortly before its lease runs out - a long-running
    // process must not keep presenting a token the vault already expired.
    livetoken: RefCell<Option<String>>,
    renewat: RefCell<Option<Instant>>,
}

impl HashicorpProvider {
    fn baseheaders(&self) -> Vec<(String, String)> {
        let mut headers = Vec::new();
        if !self.vaultnamespace.is_empty() {
            headers.push((
                "X-Vault-Namespace".to_string(),
                self.vaultnamespace.clone(),
            ));
        }
        headers
    }

    fn login(&self) -> Answer<String> {
        let auth = match &self.auth {
            Some(auth) => auth,
            None => {
                return Err(SekretoError::new(
                    "sekreto: hashicorp: no token and no auth method",
                ))
            }
        };

        let mount = if auth.mount.is_empty() {
            &auth.method
        } else {
            &auth.mount
        };
        let url = format!(
            "{}/v1/auth/{}/login",
            trimslash(&self.addr),
            mount
        );

        let body = match auth.method.as_str() {
            "kubernetes" => {
                let jwt = match &auth.jwt {
                    Some(jwt) => jwt.clone(),
                    None => {
                        let file = if auth.jwtfile.is_empty() {
                            "/var/run/secrets/kubernetes.io/serviceaccount/token"
                        } else {
                            &auth.jwtfile
                        };
                        fs::read_to_string(file)
                            .map(|text| text.trim().to_string())
                            .map_err(|_| {
                                SekretoError::new(format!(
                                    "sekreto: hashicorp: cannot read jwt file {}",
                                    file
                                ))
                            })?
                    }
                };
                Json::Map(BTreeMap::from([
                    ("role".to_string(), Json::Str(auth.role.clone())),
                    ("jwt".to_string(), Json::Str(jwt)),
                ]))
            }
            "approle" => Json::Map(BTreeMap::from([
                ("role_id".to_string(), Json::Str(auth.roleid.clone())),
                ("secret_id".to_string(), Json::Str(auth.secretid.clone())),
            ])),
            _ => {
                return Err(SekretoError::new(format!(
                    "sekreto: hashicorp: unknown auth method: {}",
                    auth.method
                )))
            }
        };

        let headers = self.baseheaders();
        let response = fetchjson(
            "POST",
            &url,
            &headerrefs(&headers),
            Some(&json::stringify(&body)),
        )?;

        let got = textat(&response.body, &["auth", "client_token"]).unwrap_or_default();

        if 200 != response.status || got.is_empty() {
            return Err(SekretoError::new(format!(
                "sekreto: hashicorp login failed: {}: {}",
                response.status, url
            )));
        }

        let lease = expiryseconds(&response.body, &["auth", "lease_duration"]);
        *self.renewat.borrow_mut() = renewtime(lease);

        Ok(got)
    }
}

impl Provider for HashicorpProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        checkaddr(&self.addr)?;

        if self.livetoken.borrow().is_none() || renewdue(&self.renewat) {
            let token = if self.token.is_empty() {
                self.login()?
            } else {
                self.token.clone()
            };
            *self.livetoken.borrow_mut() = Some(token);
        }
        let livetoken = self.livetoken.borrow().clone().unwrap_or_default();

        let reference = vaultref(name)?;
        let base = format!("{}/v1/{}", trimslash(&self.addr), self.mount);
        let url = if 1 == self.kv {
            format!("{}/{}", base, reference.path)
        } else {
            format!("{}/data/{}", base, reference.path)
        };

        let mut headers = self.baseheaders();
        headers.push(("X-Vault-Token".to_string(), livetoken));

        let response = fetchjson("GET", &url, &headerrefs(&headers), None)?;

        if 404 == response.status {
            return Ok(None);
        }

        if 200 != response.status {
            return Err(SekretoError::new(format!(
                "sekreto: hashicorp error: {}: {}",
                response.status, url
            )));
        }

        if 1 == self.kv {
            return Ok(textat(&response.body, &["data", reference.field.as_str()]));
        }
        Ok(textat(
            &response.body,
            &["data", "data", reference.field.as_str()],
        ))
    }

    fn describe(&self) -> String {
        format!("hashicorp:{}/{}", self.addr, self.mount)
    }
}

/// The `hashicorp` kind, as a plugin definition.
pub fn plugin() -> Definition {
    providerplugin("hashicorp", |spec| {
        let kv = if 0 == spec.kv { 2 } else { spec.kv };

        // A version typo like kv: 3 must not quietly behave as v2 and
        // turn its 404s into misses; there is nothing safe to assume
        // it meant.
        if 1 != kv && 2 != kv {
            return Err(SekretoError::new(format!(
                "sekreto: hashicorp: unsupported kv version: {}",
                kv
            )));
        }

        Ok(Rc::new(HashicorpProvider {
            addr: spec.addr.clone(),
            token: spec.token.clone(),
            mount: if spec.mount.is_empty() {
                "secret".to_string()
            } else {
                spec.mount.clone()
            },
            kv,
            vaultnamespace: spec.vaultnamespace.clone(),
            auth: spec.auth.clone(),
            ..Default::default()
        }) as Rc<dyn Provider>)
    })
}
