// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/src/addr.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The plaintext-address guard, in the core because it is pure - a
//! handful of string steps, no socket - and because it is on the spec:
//! every port answers the same for every address in spec/def/store.aon.
//! The plugins that dial an address call `checkaddr` before they do.
//!
//! A port of typescript/src/provider/addr.ts.

use super::sekreto::{Answer, SekretoError};

/// An address with any userinfo replaced by `[redacted]`, for messages.
///
/// Every refusal below names the address it refused, and one of them fires
/// precisely because the address carries a credential - so printing it
/// verbatim wrote the password to stderr and into the logs. It cannot be
/// cleaned up afterwards either: that password was never resolved as a
/// secret, so `redact` has never seen it and never will. The host is what a
/// reader needs to identify which chain entry is at fault; the userinfo is
/// not.
pub fn safeaddr(addr: &str) -> String {
    let mark = match addr.find("://") {
        Some(at) => at,
        None => return addr.to_string(),
    };

    let rest = &addr[mark + 3..];
    let authority = match rest.find(['/', '?', '#']) {
        Some(at) => &rest[..at],
        None => rest,
    };

    match authority.rfind('@') {
        Some(at) => format!("{}[redacted]{}", &addr[..mark + 3], &addr[mark + 3 + at..]),
        None => addr.to_string(),
    }
}


/// Refuse to send a secret-bearing credential in the clear.
///
/// A vault API is HTTPS in any real deployment; plaintext is a dev-mode
/// convenience. Sending a token over http to anything but the local
/// machine puts both the token and the secret it fetches on the wire for
/// anyone on the path, so sekreto will not do it. Loopback stays allowed:
/// that is `vault server -dev`, `boru vault serve`, and this repo's own
/// test harness.
///
/// https is dialled by whichever plugin needs it, with the server
/// certificate and the host name both verified and `SEKRETO_CA_BUNDLE`
/// adding trust roots for an internal CA. See
/// `plugins/httpjson/src/http.rs` - the transport is a plugin's business,
/// while this check is pure string work and therefore the core's.
///
/// The address is read by hand, in the same handful of steps in every port,
/// rather than by each platform's URL parser. That is deliberate. Twelve
/// parsers disagree about malformed input - where userinfo ends, whether
/// `0177.0.0.1` is loopback, what an unclosed bracket means - and a check
/// that answers differently in different ports is not a check. (Rust has no
/// URL parser in std in any case, and a crate for one is exactly what this
/// library does not take.)
///
/// The rule this parse obeys, and the reason it can be trusted: it is never
/// more permissive than the HTTP client that will dial the address. It ends
/// the authority at `/`, `?` or `#` only, so a client that also breaks on
/// `\` (WHATWG does) can only ever see a SHORTER host than this does. It
/// refuses userinfo outright rather than locating its end. It compares the
/// host literally, so a numeric form no parser here agrees on is refused
/// rather than guessed at.
pub fn checkaddr(addr: &str) -> Answer<()> {
    let scheme = if addr.starts_with("https://") {
        "https://"
    } else if addr.starts_with("http://") {
        "http://"
    } else {
        return Err(SekretoError::new(format!(
            "sekreto: not an http(s) address: {}",
            safeaddr(addr)
        )));
    };

    let rest = &addr[scheme.len()..];
    let authority = match rest.find(['/', '?', '#']) {
        Some(at) => &rest[..at],
        None => rest,
    };

    // Userinfo is refused outright rather than parsed around, and on https
    // as well as http. No store this library speaks authenticates by
    // userinfo - they take a token or a signature - so an address carrying
    // one is a mistake at best. At worst it is the attack this whole
    // function exists to stop: `http://localhost:8200@evil.example.com/` is
    // a request to evil.example.com that reads, to anything that splits the
    // authority on ':', as loopback.
    if authority.contains('@') {
        return Err(SekretoError::new(format!(
            "sekreto: refusing an address with embedded credentials: {}",
            safeaddr(addr)
        )));
    }

    // An opening bracket with no closing one is not an address at all.
    if authority.starts_with('[') && !authority.contains(']') {
        return Err(SekretoError::new(format!(
            "sekreto: not a valid http(s) address: {}",
            safeaddr(addr)
        )));
    }

    if "https://" == scheme {
        return Ok(());
    }

    // A bracketed IPv6 literal keeps its brackets. Splitting the authority
    // on the first colon yields `[`, so `http://[::1]:8200` could never
    // match - which made the `[::1]` entry below unreachable, and refused a
    // legitimate local vault.
    let host = if authority.starts_with('[') {
        // The closing bracket is known to be there: the check above returned
        // for an authority that opens one without closing it.
        match authority.find(']') {
            Some(close) => &authority[..close + 1],
            None => authority,
        }
    } else {
        match authority.find(':') {
            Some(colon) => &authority[..colon],
            None => authority,
        }
    };

    let host = host.to_ascii_lowercase();

    if matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1" | "[::1]") {
        return Ok(());
    }

    Err(SekretoError::new(format!(
        "sekreto: refusing to send a token in plaintext to {} (use https)",
        safeaddr(addr)
    )))
}

