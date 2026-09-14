// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/onepassword/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The 1Password Connect provider, as a voxgig/plugin definition.

use std::cell::RefCell;
use std::rc::Rc;

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{checkaddr, checkname, providerplugin, Answer, Provider, SekretoError};
use super::httpjson::json::Json;
use super::httpjson::{fetchjson, http, trimslash};

/// 1Password, through a Connect server.
///
/// The item titled `api.token` (titles keep their dots), in the named
/// vault. The value is the field with purpose PASSWORD, or the field
/// labelled `value`. A vault that cannot be found is an error - config
/// names it, so its absence is a broken store, not a missing secret.
#[derive(Default)]
pub struct OnePasswordProvider {
    pub addr: String,
    pub token: String,
    pub vault: String,
    vaultid: RefCell<Option<String>>,
}

impl OnePasswordProvider {
    fn resolvevault(&self, addr: &str, bearer: &str) -> Answer<String> {
        if self.vault.is_empty() {
            return Err(SekretoError::new("sekreto: onepassword: no vault"));
        }

        let response = fetchjson(
            "GET",
            &format!("{}/v1/vaults", addr),
            &[("authorization", bearer)],
            None,
        )?;

        let entries = match (&response.body, response.status) {
            (Some(Json::List(entries)), 200) => entries.clone(),
            _ => {
                return Err(SekretoError::new(format!(
                    "sekreto: onepassword error: {}: listing vaults",
                    response.status
                )))
            }
        };

        for entry in &entries {
            let id = entry.get("id").map(|value| value.text());
            let name = entry.get("name").map(|value| value.text());
            if Some(&self.vault) == id.as_ref() || Some(&self.vault) == name.as_ref() {
                return Ok(id.unwrap_or_default());
            }
        }

        Err(SekretoError::new(format!(
            "sekreto: onepassword: no vault named {}",
            self.vault
        )))
    }
}

impl Provider for OnePasswordProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        checkname(name)?;

        let addr = trimslash(&self.addr).to_string();
        if addr.is_empty() {
            return Err(SekretoError::new("sekreto: onepassword: no addr"));
        }
        checkaddr(&addr)?;

        let bearer = format!("Bearer {}", self.token);

        if self.vaultid.borrow().is_none() {
            *self.vaultid.borrow_mut() = Some(self.resolvevault(&addr, &bearer)?);
        }
        let vaultid = self.vaultid.borrow().clone().unwrap_or_default();

        let filter = http::urlencode(&format!("title eq \"{}\"", name));
        let found = fetchjson(
            "GET",
            &format!("{}/v1/vaults/{}/items?filter={}", addr, vaultid, filter),
            &[("authorization", bearer.as_str())],
            None,
        )?;

        let entries = match (&found.body, found.status) {
            (Some(Json::List(entries)), 200) => entries.clone(),
            _ => {
                return Err(SekretoError::new(format!(
                    "sekreto: onepassword error: {}: finding {}",
                    found.status, name
                )))
            }
        };

        if entries.is_empty() {
            return Ok(None);
        }

        let itemid = entries[0].get("id").map(|value| value.text()).unwrap_or_default();

        let item = fetchjson(
            "GET",
            &format!("{}/v1/vaults/{}/items/{}", addr, vaultid, itemid),
            &[("authorization", bearer.as_str())],
            None,
        )?;

        if 200 != item.status {
            return Err(SekretoError::new(format!(
                "sekreto: onepassword error: {}: reading {}",
                item.status, name
            )));
        }

        let fields = match item.body.as_ref().and_then(|body| body.get("fields")) {
            Some(Json::List(fields)) => fields.clone(),
            _ => Vec::new(),
        };

        for field in &fields {
            if let Some(Json::Str(purpose)) = field.get("purpose") {
                if "PASSWORD" == purpose {
                    return Ok(field
                        .get("value")
                        .filter(|value| !matches!(value, Json::Null))
                        .map(|value| value.text()));
                }
            }
        }
        for field in &fields {
            if let Some(Json::Str(label)) = field.get("label") {
                if "value" == label {
                    return Ok(field
                        .get("value")
                        .filter(|value| !matches!(value, Json::Null))
                        .map(|value| value.text()));
                }
            }
        }

        Ok(None)
    }

    fn describe(&self) -> String {
        format!("onepassword:{}", self.vault)
    }
}

/// The `onepassword` kind, as a plugin definition.
pub fn plugin() -> Definition {
    providerplugin("onepassword", |spec| {
        Ok(Rc::new(OnePasswordProvider {
            addr: spec.addr.clone(),
            token: spec.token.clone(),
            vault: spec.vault.clone(),
            ..Default::default()
        }) as Rc<dyn Provider>)
    })
}
