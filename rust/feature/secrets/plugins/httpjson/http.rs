// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (rust/plugins/httpjson/src/http.rs)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::{Duration, Instant};

use rustls::pki_types::{CertificateDer, ServerName};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};

pub const CABUNDLE: &str = "SEKRETO_CA_BUNDLE";

/// Anything the exchange can run over: a plain TcpStream, or a rustls
/// stream wrapping one.
trait ReadWrite: Read + Write {}
impl<T: Read + Write> ReadWrite for T {}

pub struct Response {
    pub status: u16,
    pub body: String,
}

struct Target {
    host: String,
    /// The authority as it goes in the `Host:` header. An IPv6 literal
    /// keeps its brackets, because `Host: 2001:db8::1:8200` is not a valid
    /// authority and an intermediary may reject or misroute it.
    authority: String,
    port: u16,
    path: String,
    tls: bool,
}

const MAXBODY: u64 = 8 * 1024 * 1024;

/// How long reaching a vault may take before it is treated as unreachable.
/// Ports carry the same bound.
const TIMEOUT: Duration = Duration::from_secs(10);

fn connect(host: &str, port: u16, url: &str) -> Result<TcpStream, String> {
    let unreachable =
        |why: String| format!("sekreto: cannot reach {}: {}", nakedurl(url), why);

    let addrs = (host, port)
        .to_socket_addrs()
        .map_err(|err| unreachable(err.to_string()))?;

    connectall(addrs, TIMEOUT).map_err(unreachable)
}

fn connectall(
    addrs: impl Iterator<Item = SocketAddr>,
    budget: Duration,
) -> Result<TcpStream, String> {
    let start = Instant::now();
    let mut last = None;

    for addr in addrs {
        let left = budget.saturating_sub(start.elapsed());
        if left.is_zero() {
            return Err(match last {
                Some(err) => format!("{}", err),
                None => "timed out".to_string(),
            });
        }

        match TcpStream::connect_timeout(&addr, left) {
            Ok(stream) => return Ok(stream),
            Err(err) => last = Some(err),
        }
    }

    // No address at all is not the same failure as every address refusing,
    // but both are "could not reach", which is what the caller acts on.
    Err(match last {
        Some(err) => err.to_string(),
        None => "no address".to_string(),
    })
}

fn nakedurl(url: &str) -> &str {
    match url.find('?') {
        Some(at) => &url[..at],
        None => url,
    }
}

fn split(url: &str) -> Result<Target, String> {
    let (rest, tls, defaultport) = match url.strip_prefix("http://") {
        Some(rest) => (rest, false, 80u16),
        None => match url.strip_prefix("https://") {
            Some(rest) => (rest, true, 443u16),
            None => return Err(format!("sekreto: not an http url: {}", nakedurl(url))),
        },
    };

    let (authority, path) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, "/"),
    };

    // rfind, so that an IPv6 literal's own colons are not mistaken for a
    // port separator when one is present.
    let (host, port) = match authority.rfind(':') {
        Some(at) if !authority[at + 1..].is_empty() && !authority.ends_with(']') => (
            &authority[..at],
            authority[at + 1..]
                .parse::<u16>()
                .map_err(|_| format!("sekreto: bad port: {}", nakedurl(url)))?,
        ),
        _ => (authority, defaultport),
    };

    let bare = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_string();

    // Re-bracketed only if it really is an IPv6 literal, because
    // `Host: 2001:db8::1:8200` is not a valid authority.
    let hostheader = if bare.contains(':') {
        format!("[{}]", bare)
    } else {
        bare.clone()
    };

    Ok(Target {
        host: bare,
        authority: hostheader,
        port,
        path: path.to_string(),
        tls,
    })
}

pub fn unbase64(text: &str) -> Option<Vec<u8>> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let mut out = Vec::new();
    let mut acc: u32 = 0;
    let mut bits = 0u32;

    for head in text.bytes() {
        if head.is_ascii_whitespace() || b'=' == head {
            continue;
        }

        let value = ALPHABET.iter().position(|entry| *entry == head)? as u32;

        acc = (acc << 6) | value;
        bits += 6;

        if 8 <= bits {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }

    Some(out)
}

fn pemcerts(text: &str) -> Vec<CertificateDer<'static>> {
    const OPEN: &str = "-----BEGIN CERTIFICATE-----";
    const CLOSE: &str = "-----END CERTIFICATE-----";

    let mut out = Vec::new();
    let mut rest = text;

    while let Some(start) = rest.find(OPEN) {
        let body = &rest[start + OPEN.len()..];

        let end = match body.find(CLOSE) {
            Some(end) => end,
            None => break,
        };

        if let Some(der) = unbase64(&body[..end]) {
            out.push(CertificateDer::from(der));
        }

        rest = &body[end + CLOSE.len()..];
    }

    out
}

/// The trust roots: the Mozilla set, plus anything in `SEKRETO_CA_BUNDLE`.
///
/// A private CA is how most internal Vault deployments are set up, so the
/// bundle is additive rather than a replacement - a wrong path weakens
/// nothing, it just adds no roots.
fn rootstore() -> RootCertStore {
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

    if let Ok(path) = std::env::var(CABUNDLE) {
        if !path.is_empty() {
            if let Ok(text) = std::fs::read_to_string(&path) {
                for cert in pemcerts(&text) {
                    let _ = roots.add(cert);
                }
            }
        }
    }

    roots
}

pub fn get(url: &str, header: &str, value: &str) -> Result<Response, String> {
    getwith(url, &[(header, value)])
}

pub fn getwith(url: &str, headers: &[(&str, &str)]) -> Result<Response, String> {
    request("GET", url, headers, None)
}

/// One HTTP exchange: any method, a set of headers, an optional body. A
/// non-2xx status is returned, not raised: a 404 from a vault means "no
/// such secret", which is a miss rather than a failure.
pub fn request(
    method: &str,
    url: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Result<Response, String> {
    let target = split(url)?;

    let mut stream = connect(&target.host, target.port, url)?;

    stream
        .set_read_timeout(Some(TIMEOUT))
        .map_err(|err| format!("sekreto: cannot reach {}: {}", nakedurl(url), err))?;

    // A write blocks too, once the peer's receive window fills and it stops
    // reading. Only the read side was bounded here.
    stream
        .set_write_timeout(Some(TIMEOUT))
        .map_err(|err| format!("sekreto: cannot reach {}: {}", nakedurl(url), err))?;

    if target.tls {
        let config = ClientConfig::builder()
            .with_root_certificates(rootstore())
            .with_no_client_auth();

        let servername = ServerName::try_from(target.host.clone())
            .map_err(|_| format!("sekreto: bad host name: {}", target.host))?;

        let connection = ClientConnection::new(Arc::new(config), servername)
            .map_err(|err| format!("sekreto: tls setup failed for {}: {}", nakedurl(url), err))?;

        // A handshake failure is a refusal to trust the server, so it must
        // surface as an error rather than as a missing secret.
        return exchange(
            &mut StreamOwned::new(connection, stream),
            method,
            &target,
            headers,
            body,
            url,
        );
    }

    exchange(&mut stream, method, &target, headers, body, url)
}

fn exchange(
    stream: &mut impl ReadWrite,
    method: &str,
    target: &Target,
    headers: &[(&str, &str)],
    body: Option<&str>,
    url: &str,
) -> Result<Response, String> {
    // A default port stays implicit in the Host header, the way a URL
    // normalises it: a SigV4 signature covers `host`, and `Host: x:443` is
    // not what was signed.
    let hostheader = if (target.tls && 443 == target.port) || (!target.tls && 80 == target.port) {
        target.authority.clone()
    } else {
        format!("{}:{}", target.authority, target.port)
    };

    let mut request = format!(
        "{} {} HTTP/1.1\r\nHost: {}\r\nAccept: application/json\r\nConnection: close\r\n",
        method, target.path, hostheader
    );

    for (name, value) in headers {
        request.push_str(&format!("{}: {}\r\n", name, value));
    }

    if let Some(text) = body {
        request.push_str(&format!("Content-Length: {}\r\n", text.len()));
    }

    request.push_str("\r\n");

    if let Some(text) = body {
        request.push_str(text);
    }

    stream
        .write_all(request.as_bytes())
        .map_err(|err| format!("sekreto: cannot reach {}: {}", nakedurl(url), err))?;

    // Bounded, not read_to_end: an endless body would otherwise be
    // accumulated in memory until the read timeout, which on a loopback or
    // datacentre link is gigabytes. One byte over the bound is enough to
    // know it was exceeded, and an endless body is a store that could not
    // answer - so this is an error, never a miss.
    let mut raw = Vec::new();
    Read::by_ref(stream)
        .take(MAXBODY + 1)
        .read_to_end(&mut raw)
        .map_err(|err| format!("sekreto: cannot read {}: {}", nakedurl(url), err))?;

    if MAXBODY < raw.len() as u64 {
        return Err(format!("sekreto: oversized response from {}", nakedurl(url)));
    }

    let split_at = findbytes(&raw, b"\r\n\r\n")
        .ok_or_else(|| format!("sekreto: malformed response from {}", nakedurl(url)))?;

    // Headers are ASCII; the body is not necessarily, so it stays bytes
    // until every length-counted slice has been taken.
    let head = String::from_utf8_lossy(&raw[..split_at]).to_string();
    let rawbody = &raw[split_at + 4..];

    let status = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| format!("sekreto: no status from {}", nakedurl(url)))?;

    // A server that does not know the body length up front sends it in
    // chunks - which is what a vault answering from a store usually does.
    let chunked = head
        .lines()
        .skip(1)
        .filter_map(|line| line.split_once(':'))
        .any(|(name, value)| {
            name.eq_ignore_ascii_case("transfer-encoding")
                && value.to_ascii_lowercase().contains("chunked")
        });

    let bodybytes = if chunked {
        dechunk(rawbody).ok_or_else(|| format!("sekreto: malformed chunks from {}", nakedurl(url)))?
    } else {
        rawbody.to_vec()
    };

    let body = String::from_utf8_lossy(&bodybytes).to_string();

    Ok(Response { status, body })
}

fn findbytes(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len())
        .position(|window| window == needle)
}

fn dechunk(raw: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut rest = raw;

    loop {
        let at = findbytes(rest, b"\r\n")?;

        let header = std::str::from_utf8(&rest[..at]).ok()?;
        let size = usize::from_str_radix(header.split(';').next()?.trim(), 16).ok()?;

        let body = rest.get(at + 2..)?;

        if 0 == size {
            return Some(out);
        }

        if body.len() < size {
            return None;
        }

        out.extend_from_slice(&body[..size]);

        rest = body.get(size + 2..)?;
    }
}

pub fn urlencode(text: &str) -> String {
    let mut out = String::new();

    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{:02X}", byte)),
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const BUDGET: Duration = Duration::from_millis(300);

    fn hole(last: u8) -> SocketAddr {
        format!("10.255.255.{}:8200", last).parse().unwrap()
    }

    #[test]
    fn addresses_share_one_deadline() {
        let start = Instant::now();
        let alone = connectall(std::iter::once(hole(1)), BUDGET);
        let one = start.elapsed();

        assert!(alone.is_err(), "10.255.255.1 must not connect");

        if one < BUDGET / 2 {
            eprintln!(
                "skipped: 10.255.255.1 answered in {:?}, so it is refused here \
                 rather than blackholed and there is no blocking to bound",
                one
            );
            return;
        }

        let start = Instant::now();
        let three = connectall([hole(1), hole(2), hole(3)].into_iter(), BUDGET);
        let took = start.elapsed();

        assert!(three.is_err(), "10.255.255.0/24 must not connect");

        assert!(
            took < BUDGET * 2,
            "three addresses took {:?} against a {:?} budget: \
             the deadline is being handed out per address, not shared",
            took,
            BUDGET
        );
    }
}
