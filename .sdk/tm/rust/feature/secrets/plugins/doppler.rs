// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/doppler/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The Doppler provider, as a voxgig/plugin definition.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{checkaddr, envkey, providerplugin, Answer, Provider, SekretoError};
use super::httpjson::json::Json;
use super::httpjson::{fetchjson, http, trimslash};

/// Doppler.
///
/// The whole config is downloaded once - Doppler's own bulk endpoint -
/// and answered from memory, like a remote .env: `api.token` is the
/// `API_TOKEN` entry. A service token is config-scoped, so project and
/// config are only needed with broader tokens.
#[derive(Default)]
pub struct DopplerProvider {
    pub token: String,
    pub project: String,
    pub config: String,
    pub addr: String,
    values: RefCell<Option<BTreeMap<String, String>>>,
}

impl DopplerProvider {
    fn load(&self) -> Answer<BTreeMap<String, String>> {
        if let Some(values) = self.values.borrow().as_ref() {
            return Ok(values.clone());
        }

        let addr = if self.addr.is_empty() {
            "https://api.doppler.com"
        } else {
            &self.addr
        };
        let addr = trimslash(addr);
        checkaddr(addr)?;

        let mut url = format!("{}/v3/configs/config/secrets/download?format=json", addr);
        if !self.project.is_empty() {
            url.push_str(&format!("&project={}", http::urlencode(&self.project)));
        }
        if !self.config.is_empty() {
            url.push_str(&format!("&config={}", http::urlencode(&self.config)));
        }

        let bearer = format!("Bearer {}", self.token);
        let response = fetchjson("GET", &url, &[("authorization", bearer.as_str())], None)?;

        let entries = match (response.status, &response.body) {
            (200, Some(Json::Map(entries))) => entries.clone(),
            _ => {
                return Err(SekretoError::new(format!(
                    "sekreto: doppler error: {}",
                    response.status
                )))
            }
        };

        let mut values = BTreeMap::new();
        for (key, value) in entries {
            if !matches!(value, Json::Null) {
                values.insert(key, value.text());
            }
        }

        *self.values.borrow_mut() = Some(values.clone());
        Ok(values)
    }
}

impl Provider for DopplerProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        Ok(self.load()?.get(&envkey(name, "")?).cloned())
    }

    fn describe(&self) -> String {
        if self.project.is_empty() {
            "doppler".to_string()
        } else {
            format!("doppler:{}/{}", self.project, self.config)
        }
    }
}

/// The `doppler` kind, as a plugin definition.
pub fn plugin() -> Definition {
    providerplugin("doppler", |spec| {
        Ok(Rc::new(DopplerProvider {
            token: spec.token.clone(),
            project: spec.project.clone(),
            config: spec.config.clone(),
            addr: spec.addr.clone(),
            ..Default::default()
        }) as Rc<dyn Provider>)
    })
}
