// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/azuresecrets/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The Azure Key Vault provider, as a voxgig/plugin definition.

use std::cell::RefCell;
use std::rc::Rc;
use std::time::Instant;

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{checkaddr, flatname, providerplugin, Answer, Provider, SekretoError};
use super::httpjson::{
    expiryseconds, fetchjson, http, renewdue, renewtime, textat, trimslash,
};

/// Azure Key Vault.
///
/// `api.token` reads secret `api-token` (dots flattened to `-`; Key
/// Vault names allow nothing else), current version. The token comes
/// from config, then a client-credentials login when tenant/clientid/
/// clientsecret are given, then the IMDS managed-identity endpoint - so
/// on Azure's own platform no credential configuration is needed.
///
/// As with GCP, the IMDS call is plain http to a link-local host by
/// platform design and carries no credential; the login and vault
/// addresses are `checkaddr`-guarded.
#[derive(Default)]
pub struct AzureSecretsProvider {
    pub vault: String,
    pub token: String,
    pub tenant: String,
    pub clientid: String,
    pub clientsecret: String,
    pub loginaddr: String,
    pub imdsaddr: String,
    pub apiversion: String,
    // A configured token is kept forever; logged-in and IMDS tokens carry
    // expires_in and are renewed shortly before they run out.
    livetoken: RefCell<Option<String>>,
    renewat: RefCell<Option<Instant>>,
}

/// The OAuth resource a Key Vault token is scoped to.
const AZURERESOURCE: &str = "https://vault.azure.net";

impl AzureSecretsProvider {
    fn login(&self) -> Answer<String> {
        if !self.token.is_empty() {
            return Ok(self.token.clone());
        }

        if !self.tenant.is_empty() && !self.clientid.is_empty() && !self.clientsecret.is_empty() {
            let loginaddr = if self.loginaddr.is_empty() {
                "https://login.microsoftonline.com"
            } else {
                &self.loginaddr
            };
            checkaddr(loginaddr)?;

            let url = format!("{}/{}/oauth2/v2.0/token", trimslash(loginaddr), self.tenant);
            let form = format!(
                "grant_type=client_credentials&client_id={}&client_secret={}&scope={}",
                http::urlencode(&self.clientid),
                http::urlencode(&self.clientsecret),
                http::urlencode(&format!("{}/.default", AZURERESOURCE))
            );

            let response = fetchjson(
                "POST",
                &url,
                &[("content-type", "application/x-www-form-urlencoded")],
                Some(&form),
            )?;

            let got = textat(&response.body, &["access_token"]).unwrap_or_default();

            if 200 != response.status || got.is_empty() {
                return Err(SekretoError::new(format!(
                    "sekreto: azure login failed: {}",
                    response.status
                )));
            }

            // expires_in may arrive as a string; expiryseconds reads both.
            *self.renewat.borrow_mut() =
                renewtime(expiryseconds(&response.body, &["expires_in"]));
            return Ok(got);
        }

        let imds = format!(
            "{}/metadata/identity/oauth2/token?api-version=2018-02-01&resource={}",
            trimslash(if self.imdsaddr.is_empty() {
                "http://169.254.169.254"
            } else {
                &self.imdsaddr
            }),
            http::urlencode(AZURERESOURCE)
        );

        let response = fetchjson("GET", &imds, &[("Metadata", "true")], None)?;

        let got = textat(&response.body, &["access_token"]).unwrap_or_default();

        if 200 != response.status || got.is_empty() {
            return Err(SekretoError::new(
                "sekreto: azure: no token, no client credentials, and IMDS did not answer",
            ));
        }

        *self.renewat.borrow_mut() = renewtime(expiryseconds(&response.body, &["expires_in"]));
        Ok(got)
    }
}

impl Provider for AzureSecretsProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        if self.vault.is_empty() {
            return Err(SekretoError::new("sekreto: azure: no vault"));
        }

        // Only an explicit scheme is a URL; a vault NAMED httpvault must
        // still become https://httpvault.vault.azure.net.
        let vaulturl = if self.vault.starts_with("http://") || self.vault.starts_with("https://") {
            self.vault.clone()
        } else {
            format!("https://{}.vault.azure.net", self.vault)
        };
        checkaddr(&vaulturl)?;

        if self.livetoken.borrow().is_none() || renewdue(&self.renewat) {
            *self.livetoken.borrow_mut() = Some(self.login()?);
        }
        let livetoken = self.livetoken.borrow().clone().unwrap_or_default();

        let url = format!(
            "{}/secrets/{}?api-version={}",
            trimslash(&vaulturl),
            flatname(name, "-")?,
            if self.apiversion.is_empty() {
                "7.4"
            } else {
                &self.apiversion
            }
        );

        let bearer = format!("Bearer {}", livetoken);
        let response = fetchjson("GET", &url, &[("authorization", bearer.as_str())], None)?;

        if 404 == response.status {
            return Ok(None);
        }

        if 200 != response.status {
            return Err(SekretoError::new(format!(
                "sekreto: azure error: {}: {}",
                response.status,
                url.split('?').next().unwrap_or(&url)
            )));
        }

        Ok(textat(&response.body, &["value"]))
    }

    fn describe(&self) -> String {
        format!("azuresecrets:{}", self.vault)
    }
}

/// The `azuresecrets` kind, as a plugin definition.
pub fn plugin() -> Definition {
    providerplugin("azuresecrets", |spec| {
        Ok(Rc::new(AzureSecretsProvider {
            vault: spec.vault.clone(),
            token: spec.token.clone(),
            tenant: spec.tenant.clone(),
            clientid: spec.clientid.clone(),
            clientsecret: spec.clientsecret.clone(),
            loginaddr: spec.loginaddr.clone(),
            imdsaddr: spec.imdsaddr.clone(),
            apiversion: spec.apiversion.clone(),
            ..Default::default()
        }) as Rc<dyn Provider>)
    })
}
