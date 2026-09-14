// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/aws/src/lib.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The two AWS providers - Secrets Manager and SSM Parameter Store -
//! and the request signing they need, as voxgig/plugin definitions.
//!
//! SIGV4 TRAVELS WITH THEM, which is the sharpest instance of the split:
//! the core of no port imports a hash function, and `crypto.rs` here is
//! the only SHA-256 in this repository's Rust. A chain of built-in kinds
//! links neither it nor the HTTP client it signs for.

pub mod crypto;
pub mod sigv4;

use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::feature::secrets::plugin::catalog::Definition;
use crate::feature::secrets::sekreto::{awsparam, checkaddr, providerplugin, vaultref, Answer, Provider, SekretoError};
use super::httpjson::json::{self, Json};
use super::httpjson::{fetchjson, firstof, headerrefs, http, textat, trimslash, JsonResponse};

pub use self::sigv4::{sigv4, Sigv4Input, Sigv4Output};

/// The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now.
fn awsnow() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let (year, month, day) = civildate((seconds / 86400) as i64);
    let clock = seconds % 86400;

    format!(
        "{:04}{:02}{:02}T{:02}{:02}{:02}Z",
        year,
        month,
        day,
        clock / 3600,
        clock % 3600 / 60,
        clock % 60
    )
}

/// Days since the epoch as a civil date - the classic era-based
/// conversion (Howard Hinnant's `civil_from_days`), exact for any date
/// the epoch can name.
fn civildate(days: i64) -> (i64, u32, u32) {
    let z = days + 719468;
    let era = if 0 <= z { z } else { z - 146096 } / 146097;
    let dayofera = z - era * 146097;
    let yearofera = (dayofera - dayofera / 1460 + dayofera / 36524 - dayofera / 146096) / 365;
    let year = yearofera + era * 400;
    let dayofyear = dayofera - (365 * yearofera + yearofera / 4 - yearofera / 100);
    let monthish = (5 * dayofyear + 2) / 153;
    let day = (dayofyear - (153 * monthish + 2) / 5 + 1) as u32;
    let month = (if monthish < 10 {
        monthish + 3
    } else {
        monthish - 9
    }) as u32;

    (if month <= 2 { year + 1 } else { year }, month, day)
}

/// Region and credentials, resolved for one AWS call.
struct AwsAuth {
    region: String,
    keyid: String,
    secret: String,
    session: String,
}

/// Region and credentials, from config first and the standard AWS_*
/// environment variables second - those are AWS's own convention, and a
/// pod or CI job that has them set should just work. Missing either is
/// an error: an AWS store with no credentials could not answer.
fn awsauth(region: &str, keyid: &str, secret: &str, session: &str) -> Answer<AwsAuth> {
    let region = firstof(region, &["AWS_REGION", "AWS_DEFAULT_REGION"]);
    let keyid = firstof(keyid, &["AWS_ACCESS_KEY_ID"]);
    let secret = firstof(secret, &["AWS_SECRET_ACCESS_KEY"]);
    let session = firstof(session, &["AWS_SESSION_TOKEN"]);

    if region.is_empty() {
        return Err(SekretoError::new(
            "sekreto: aws: no region (set region or AWS_REGION)",
        ));
    }
    if keyid.is_empty() || secret.is_empty() {
        return Err(SekretoError::new(
            "sekreto: aws: no credentials (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)",
        ));
    }

    Ok(AwsAuth {
        region,
        keyid,
        secret,
        session,
    })
}

/// One signed call to an AWS JSON-1.1 API.
fn awscall(
    addr: &str,
    auth: &AwsAuth,
    service: &str,
    target: &str,
    payload: &Json,
) -> Answer<JsonResponse> {
    let addr = if addr.is_empty() {
        // The China partition lives under its own suffix; every other
        // commercial region is plain amazonaws.com.
        let suffix = if auth.region.starts_with("cn-") {
            ".amazonaws.com.cn"
        } else {
            ".amazonaws.com"
        };
        format!("https://{}.{}{}", service, auth.region, suffix)
    } else {
        addr.to_string()
    };
    checkaddr(&addr)?;

    let url = format!("{}/", trimslash(&addr));
    let body = json::stringify(payload);

    let mut headers = vec![
        (
            "content-type".to_string(),
            "application/x-amz-json-1.1".to_string(),
        ),
        ("x-amz-target".to_string(), target.to_string()),
    ];

    let signed = sigv4(&Sigv4Input {
        method: "POST".to_string(),
        url: url.clone(),
        headers: headers.clone(),
        body: body.clone(),
        service: service.to_string(),
        region: auth.region.clone(),
        keyid: auth.keyid.clone(),
        secret: auth.secret.clone(),
        session: auth.session.clone(),
        datetime: awsnow(),
    })?;

    for (name, value) in signed {
        headers.push((name, value));
    }

    fetchjson("POST", &url, &headerrefs(&headers), Some(&body))
}

/// Does this AWS error body name one of the not-found types? Those are
/// a miss; every other failure is a store that could not answer.
fn awsmiss(body: &Option<Json>, types: &[&str]) -> bool {
    let errtype = match body.as_ref().and_then(|body| body.get("__type")) {
        Some(Json::Str(errtype)) => errtype.clone(),
        _ => String::new(),
    };

    types.iter().any(|name| errtype.contains(name))
}

/// AWS Secrets Manager.
///
/// `api.token` reads the secret named `api` (the vaultref path, so
/// `db.pass.main` reads `db/pass`) and takes the `token` field of its
/// JSON SecretString - the AWS idiom of one JSON map per secret. A
/// SecretString that is not JSON is the value itself, under the
/// conventional field `value`. Requests are SigV4-signed in-tree; see
/// src/sigv4.rs.
pub struct AwsSecretsProvider {
    pub region: String,
    pub keyid: String,
    pub secret: String,
    pub session: String,
    pub addr: String,
}

impl Provider for AwsSecretsProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        let reference = vaultref(name)?;
        let auth = awsauth(&self.region, &self.keyid, &self.secret, &self.session)?;

        let payload = Json::Map(BTreeMap::from([(
            "SecretId".to_string(),
            Json::Str(reference.path.clone()),
        )]));

        let response = awscall(
            &self.addr,
            &auth,
            "secretsmanager",
            "secretsmanager.GetSecretValue",
            &payload,
        )?;

        if 400 == response.status && awsmiss(&response.body, &["ResourceNotFoundException"]) {
            return Ok(None);
        }

        if 200 != response.status {
            return Err(SekretoError::new(format!(
                "sekreto: aws secretsmanager error: {}",
                response.status
            )));
        }

        let text = match response.body.as_ref().and_then(|body| body.get("SecretString")) {
            Some(Json::Str(text)) => text.clone(),
            _ => {
                // A binary secret has no fields to address; only the
                // conventional `value` field can mean "the bytes
                // themselves".
                if "value" != reference.field {
                    return Ok(None);
                }
                let bin = match response.body.as_ref().and_then(|body| body.get("SecretBinary")) {
                    Some(Json::Str(bin)) => bin.clone(),
                    _ => return Ok(None),
                };
                // A payload that will not decode was reported as None -
                // a MISS - so the chain carried on to a weaker store. A
                // store that answered incoherently could not answer.
                return match http::unbase64(&bin) {
                    Some(bytes) => Ok(Some(String::from_utf8_lossy(&bytes).to_string())),
                    None => Err(SekretoError::new("sekreto: aws secretsmanager: undecodable secret".to_string())),
                };
            }
        };

        if let Some(Json::Map(fields)) = json::parse(&text) {
            return Ok(fields
                .get(&reference.field)
                .filter(|value| !matches!(value, Json::Null))
                .map(|value| value.text()));
        }

        // A plain-string secret is the whole value; it has no named fields.
        if "value" == reference.field {
            return Ok(Some(text));
        }
        Ok(None)
    }

    // Config only, never the environment: describe() feeds the spec's
    // sources group, which must answer the same everywhere.
    fn describe(&self) -> String {
        format!("awssecrets:{}", self.region)
    }
}

/// AWS SSM Parameter Store.
///
/// `db.pass.main` reads the parameter `/db/pass/main` (under an optional
/// prefix path), decrypted. Parameter Store carries flat strings, so
/// there is no field indirection.
pub struct AwsParamsProvider {
    pub region: String,
    pub keyid: String,
    pub secret: String,
    pub session: String,
    pub addr: String,
    pub prefix: String,
}

impl Provider for AwsParamsProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        let paramname = awsparam(name, &self.prefix)?;
        let auth = awsauth(&self.region, &self.keyid, &self.secret, &self.session)?;

        let payload = Json::Map(BTreeMap::from([
            ("Name".to_string(), Json::Str(paramname)),
            ("WithDecryption".to_string(), Json::Bool(true)),
        ]));

        let response = awscall(&self.addr, &auth, "ssm", "AmazonSSM.GetParameter", &payload)?;

        if 400 == response.status && awsmiss(&response.body, &["ParameterNotFound"]) {
            return Ok(None);
        }

        if 200 != response.status {
            return Err(SekretoError::new(format!(
                "sekreto: aws ssm error: {}",
                response.status
            )));
        }

        Ok(textat(&response.body, &["Parameter", "Value"]))
    }

    fn describe(&self) -> String {
        format!("awsparams:{}{}", self.region, self.prefix)
    }
}

/// The `awssecrets` kind, as a plugin definition.
pub fn secrets() -> Definition {
    providerplugin("awssecrets", |spec| {
        Ok(Rc::new(AwsSecretsProvider {
            region: spec.region.clone(),
            keyid: spec.keyid.clone(),
            secret: spec.secret.clone(),
            session: spec.session.clone(),
            addr: spec.addr.clone(),
        }) as Rc<dyn Provider>)
    })
}

/// The `awsparams` kind, as a plugin definition.
pub fn params() -> Definition {
    providerplugin("awsparams", |spec| {
        Ok(Rc::new(AwsParamsProvider {
            region: spec.region.clone(),
            keyid: spec.keyid.clone(),
            secret: spec.secret.clone(),
            session: spec.session.clone(),
            addr: spec.addr.clone(),
            prefix: spec.prefix.clone(),
        }) as Rc<dyn Provider>)
    })
}
