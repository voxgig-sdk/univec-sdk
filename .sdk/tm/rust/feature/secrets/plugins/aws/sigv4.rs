// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (rust/plugins/aws/src/sigv4.rs)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use std::collections::BTreeMap;

use super::crypto;
use crate::feature::secrets::sekreto::{Answer, SekretoError};

/// One request to sign. Absent optional fields are empty strings.
#[derive(Clone, Debug, Default)]
pub struct Sigv4Input {
    pub method: String,
    /// Full request URL; the host, path and query are signed.
    pub url: String,
    /// Extra headers to sign, e.g. content-type and x-amz-target.
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub service: String,
    pub region: String,
    pub keyid: String,
    pub secret: String,
    /// STS session token; signed as x-amz-security-token when non-empty.
    pub session: String,
    pub datetime: String,
}

/// The headers to attach to the request: authorization, x-amz-date, and
/// x-amz-security-token when a session token was given.
pub type Sigv4Output = BTreeMap<String, String>;

/// RFC 3986 escaping, which is stricter than the usual form-encoding: AWS
/// wants `!`, `'`, `(`, `)` and `*` escaped too, so only the unreserved
/// characters survive.
fn uriescape(bytes: &[u8]) -> String {
    let mut out = String::new();

    for byte in bytes {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{:02X}", byte)),
        }
    }

    out
}

/// Undo percent-encoding, to bytes: the canonical form re-escapes from a
/// clean slate, so what arrived encoded must not be encoded twice.
fn percentdecode(text: &str) -> Vec<u8> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut at = 0;

    while at < bytes.len() {
        if b'%' == bytes[at] && at + 2 < bytes.len() {
            let high = (bytes[at + 1] as char).to_digit(16);
            let low = (bytes[at + 2] as char).to_digit(16);
            if let (Some(high), Some(low)) = (high, low) {
                out.push((16 * high + low) as u8);
                at += 3;
                continue;
            }
        }
        out.push(bytes[at]);
        at += 1;
    }

    out
}

/// The canonical query string: each pair RFC 3986-escaped, sorted by
/// escaped key then escaped value.
fn canonicalquery(query: &str) -> String {
    if query.is_empty() {
        return String::new();
    }

    let mut pairs: Vec<(String, String)> = query
        .split('&')
        .map(|pair| {
            let (key, value) = match pair.find('=') {
                Some(at) => (&pair[..at], &pair[at + 1..]),
                None => (pair, ""),
            };
            (
                uriescape(&percentdecode(key)),
                uriescape(&percentdecode(value)),
            )
        })
        .collect();

    pairs.sort();

    pairs
        .iter()
        .map(|(key, value)| format!("{}={}", key, value))
        .collect::<Vec<String>>()
        .join("&")
}

/// Split a url into the signed host (a default port stays implicit, the
/// way a URL normalises it), the path and the raw query.
fn parseurl(url: &str) -> Answer<(String, String, String)> {
    let (rest, defaultport) = match url.strip_prefix("http://") {
        Some(rest) => (rest, "80"),
        None => match url.strip_prefix("https://") {
            Some(rest) => (rest, "443"),
            None => {
                return Err(SekretoError::new(format!(
                    "sekreto: not an http url: {}",
                    url
                )))
            }
        },
    };

    let cut = rest
        .find(|head| '/' == head || '?' == head)
        .unwrap_or(rest.len());
    let authority = &rest[..cut];
    let pathquery = &rest[cut..];

    let (path, query) = match pathquery.find('?') {
        Some(at) => (&pathquery[..at], &pathquery[at + 1..]),
        None => (pathquery, ""),
    };

    let mut host = authority.to_ascii_lowercase();
    let implicit = format!(":{}", defaultport);
    if host.ends_with(&implicit) {
        host.truncate(host.len() - implicit.len());
    }

    let path = if path.is_empty() { "/" } else { path };

    Ok((host, path.to_string(), query.to_string()))
}

/// Sign one request. Returns the headers to attach.
pub fn sigv4(input: &Sigv4Input) -> Answer<Sigv4Output> {
    let (host, path, query) = parseurl(&input.url)?;

    let date = input.datetime.get(..8).unwrap_or(&input.datetime);

    let mut headers: BTreeMap<String, String> = BTreeMap::new();
    for (key, value) in &input.headers {
        headers.insert(
            key.to_lowercase(),
            value.split_whitespace().collect::<Vec<&str>>().join(" "),
        );
    }
    headers.insert("host".to_string(), host);
    headers.insert("x-amz-date".to_string(), input.datetime.clone());
    if !input.session.is_empty() {
        headers.insert("x-amz-security-token".to_string(), input.session.clone());
    }

    let canonicalheaders: String = headers
        .iter()
        .map(|(name, value)| format!("{}:{}\n", name, value))
        .collect();
    let signedheaders = headers.keys().cloned().collect::<Vec<String>>().join(";");

    let canonicalrequest = [
        input.method.to_uppercase(),
        path,
        canonicalquery(&query),
        canonicalheaders,
        signedheaders.clone(),
        crypto::sha256hex(input.body.as_bytes()),
    ]
    .join("\n");

    let scope = format!("{}/{}/{}/aws4_request", date, input.region, input.service);

    let stringtosign = [
        "AWS4-HMAC-SHA256".to_string(),
        input.datetime.clone(),
        scope.clone(),
        crypto::sha256hex(canonicalrequest.as_bytes()),
    ]
    .join("\n");

    let kdate = crypto::hmac(format!("AWS4{}", input.secret).as_bytes(), date.as_bytes());
    let kregion = crypto::hmac(&kdate, input.region.as_bytes());
    let kservice = crypto::hmac(&kregion, input.service.as_bytes());
    let ksigning = crypto::hmac(&kservice, b"aws4_request");
    let signature = crypto::hex(&crypto::hmac(&ksigning, stringtosign.as_bytes()));

    let mut out = Sigv4Output::new();
    out.insert(
        "authorization".to_string(),
        format!(
            "AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}",
            input.keyid, scope, signedheaders, signature
        ),
    );
    out.insert("x-amz-date".to_string(), input.datetime.clone());

    if !input.session.is_empty() {
        out.insert("x-amz-security-token".to_string(), input.session.clone());
    }

    Ok(out)
}
