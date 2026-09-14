// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/infisical/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The Infisical provider, as a voxgig/plugin definition.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Instant;

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{checkaddr, envkey, providerplugin, Answer, Provider, SekretoError};
use super::httpjson::json::{self, Json};
use super::httpjson::{
    expiryseconds, fetchjson, http, renewdue, renewtime, textat, trimslash,
};

/// Infisical.
///
/// `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
/// convention is environment-style keys) at a secret path in one
/// environment of a project. Auth is a token, or a universal-auth
/// (machine identity) login with clientid/clientsecret.
#[derive(Default)]
pub struct InfisicalProvider {
    pub addr: String,
    pub token: String,
    pub clientid: String,
    pub clientsecret: String,
    pub project: String,
    pub environment: String,
    pub path: String,
    // A configured token is kept forever; a universal-auth token carries
    // expiresIn and is renewed shortly before it runs out.
    livetoken: RefCell<Option<String>>,
    renewat: RefCell<Option<Instant>>,
}

impl InfisicalProvider {
    fn login(&self, addr: &str) -> Answer<String> {
        if !self.token.is_empty() {
            return Ok(self.token.clone());
        }

        if self.clientid.is_empty() || self.clientsecret.is_empty() {
            return Err(SekretoError::new(
                "sekreto: infisical: no token and no client credentials",
            ));
        }

        let body = json::stringify(&Json::Map(BTreeMap::from([
            ("clientId".to_string(), Json::Str(self.clientid.clone())),
            (
                "clientSecret".to_string(),
                Json::Str(self.clientsecret.clone()),
            ),
        ])));

        let response = fetchjson(
            "POST",
            &format!("{}/api/v1/auth/universal-auth/login", addr),
            &[("content-type", "application/json")],
            Some(&body),
        )?;

        let got = textat(&response.body, &["accessToken"]).unwrap_or_default();

        if 200 != response.status || got.is_empty() {
            return Err(SekretoError::new(format!(
                "sekreto: infisical login failed: {}",
                response.status
            )));
        }

        let expires = expiryseconds(&response.body, &["expiresIn"]);
        *self.renewat.borrow_mut() = renewtime(expires);

        Ok(got)
    }
}

impl Provider for InfisicalProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        let addr = if self.addr.is_empty() {
            "https://app.infisical.com"
        } else {
            &self.addr
        };
        let addr = trimslash(addr).to_string();
        checkaddr(&addr)?;

        if self.project.is_empty() || self.environment.is_empty() {
            return Err(SekretoError::new(
                "sekreto: infisical: no project/environment",
            ));
        }

        if self.livetoken.borrow().is_none() || renewdue(&self.renewat) {
            *self.livetoken.borrow_mut() = Some(self.login(&addr)?);
        }
        let livetoken = self.livetoken.borrow().clone().unwrap_or_default();

        let url = format!(
            "{}/api/v3/secrets/raw/{}?workspaceId={}&environment={}&secretPath={}",
            addr,
            envkey(name, "")?,
            http::urlencode(&self.project),
            http::urlencode(&self.environment),
            http::urlencode(if self.path.is_empty() { "/" } else { &self.path })
        );

        let bearer = format!("Bearer {}", livetoken);
        let response = fetchjson("GET", &url, &[("authorization", bearer.as_str())], None)?;

        if 404 == response.status {
            return Ok(None);
        }

        if 200 != response.status {
            return Err(SekretoError::new(format!(
                "sekreto: infisical error: {}",
                response.status
            )));
        }

        Ok(textat(&response.body, &["secret", "secretValue"]))
    }

    fn describe(&self) -> String {
        format!("infisical:{}/{}", self.project, self.environment)
    }
}

/// The `infisical` kind, as a plugin definition.
pub fn plugin() -> Definition {
    providerplugin("infisical", |spec| {
        Ok(Rc::new(InfisicalProvider {
            addr: spec.addr.clone(),
            token: spec.token.clone(),
            clientid: spec.clientid.clone(),
            clientsecret: spec.clientsecret.clone(),
            project: spec.project.clone(),
            environment: spec.environment.clone(),
            path: spec.path.clone(),
            ..Default::default()
        }) as Rc<dyn Provider>)
    })
}
