// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (rust/src/addr.rs)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use super::sekreto::{Answer, SekretoError};

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

