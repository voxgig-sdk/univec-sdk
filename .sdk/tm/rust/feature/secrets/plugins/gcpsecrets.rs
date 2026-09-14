// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/gcpsecrets/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The GCP Secret Manager provider, as a voxgig/plugin definition.

use std::cell::RefCell;
use std::env;
use std::rc::Rc;
use std::time::Instant;

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{checkaddr, flatname, providerplugin, Answer, Provider, SekretoError};
use super::httpjson::json::Json;
use super::httpjson::{
    expiryseconds, fetchjson, firstof, http, renewdue, renewtime, textat, trimslash,
};

/// GCP Secret Manager.
///
/// `api.token` reads secret `api_token` (dots flattened to `_`; Secret
/// Manager ids have no hierarchy and reject dots), latest version. The
/// token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
/// GCE/GKE metadata server - so on Google's own platform no credential
/// configuration is needed at all.
///
/// The metadata call itself is plain http to a link-local host by
/// platform design; no credential rides on it, so `checkaddr` guards the
/// Secret Manager address instead.
#[derive(Default)]
pub struct GcpSecretsProvider {
    pub project: String,
    pub token: String,
    pub addr: String,
    pub metadataaddr: String,
    // A configured token is kept forever; a metadata-server token carries
    // expires_in and is renewed shortly before it runs out.
    livetoken: RefCell<Option<String>>,
    renewat: RefCell<Option<Instant>>,
}

impl GcpSecretsProvider {
    fn metadataaddr(&self) -> String {
        if !self.metadataaddr.is_empty() {
            return self.metadataaddr.clone();
        }
        match env::var("GCE_METADATA_HOST") {
            Ok(host) if !host.is_empty() => format!("http://{}", host),
            _ => "http://metadata.google.internal".to_string(),
        }
    }

    fn login(&self) -> Answer<String> {
        let configured = firstof(&self.token, &["GOOGLE_OAUTH_ACCESS_TOKEN"]);
        if !configured.is_empty() {
            return Ok(configured);
        }

        let url = format!(
            "{}/computeMetadata/v1/instance/service-accounts/default/token",
            trimslash(&self.metadataaddr())
        );

        let response = fetchjson("GET", &url, &[("Metadata-Flavor", "Google")], None)?;

        let got = textat(&response.body, &["access_token"]).unwrap_or_default();

        if 200 != response.status || got.is_empty() {
            return Err(SekretoError::new(
                "sekreto: gcp: no token and metadata server did not answer",
            ));
        }

        let expires = expiryseconds(&response.body, &["expires_in"]);
        *self.renewat.borrow_mut() = renewtime(expires);

        Ok(got)
    }
}

impl Provider for GcpSecretsProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        if self.project.is_empty() {
            return Err(SekretoError::new("sekreto: gcp: no project"));
        }

        let addr = if self.addr.is_empty() {
            "https://secretmanager.googleapis.com"
        } else {
            &self.addr
        };
        checkaddr(addr)?;

        if self.livetoken.borrow().is_none() || renewdue(&self.renewat) {
            *self.livetoken.borrow_mut() = Some(self.login()?);
        }
        let livetoken = self.livetoken.borrow().clone().unwrap_or_default();

        let url = format!(
            "{}/v1/projects/{}/secrets/{}/versions/latest:access",
            trimslash(addr),
            self.project,
            flatname(name, "_")?
        );

        let bearer = format!("Bearer {}", livetoken);
        let response = fetchjson("GET", &url, &[("authorization", bearer.as_str())], None)?;

        if 404 == response.status {
            return Ok(None);
        }

        if 200 != response.status {
            return Err(SekretoError::new(format!(
                "sekreto: gcp error: {}: {}",
                response.status, url
            )));
        }

        let data = match response
            .body
            .as_ref()
            .and_then(|body| body.get("payload"))
            .and_then(|payload| payload.get("data"))
        {
            Some(Json::Str(data)) => data.clone(),
            _ => return Ok(None),
        };

        // See the aws provider: an undecodable payload is an error, not a
        // miss.
        match http::unbase64(&data) {
            Some(bytes) => Ok(Some(String::from_utf8_lossy(&bytes).to_string())),
            None => Err(SekretoError::new("sekreto: gcp: undecodable secret".to_string())),
        }
    }

    fn describe(&self) -> String {
        format!("gcpsecrets:{}", self.project)
    }
}

/// The `gcpsecrets` kind, as a plugin definition.
pub fn plugin() -> Definition {
    providerplugin("gcpsecrets", |spec| {
        Ok(Rc::new(GcpSecretsProvider {
            project: spec.project.clone(),
            token: spec.token.clone(),
            addr: spec.addr.clone(),
            metadataaddr: spec.metadataaddr.clone(),
            ..Default::default()
        }) as Rc<dyn Provider>)
    })
}
