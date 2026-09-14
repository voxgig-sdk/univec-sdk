// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/plugins/aws/src/crypto.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! SHA-256 and HMAC-SHA256, hand-rolled.
//!
//! The Rust standard library ships no hash functions, and SigV4 signing
//! needs exactly these two. Taking a crate for them would break the
//! no-dependency rule that keeps ten ports honest, so - like JSON, HTTP,
//! PEM and base64 before them - they live in-tree.
//!
//! SHA-256 is FIPS 180-4, implemented straight from the standard; HMAC is
//! RFC 2104 over it. Both are proven against the spec's sigv4 known-answer
//! cases, which include AWS's own published test vector - a signature is a
//! chain of these primitives, so a single wrong bit anywhere fails there.

/// The FIPS 180-4 round constants: the fractional parts of the cube roots
/// of the first 64 primes.
const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// The SHA-256 digest of a byte string.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    // The initial hash: the fractional parts of the square roots of the
    // first 8 primes.
    let mut hash: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    // Pad to a whole number of 64-byte blocks: 0x80, zeros, then the
    // message length in bits, big-endian.
    let mut message = data.to_vec();
    message.push(0x80);
    while 56 != message.len() % 64 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());

    for block in message.chunks(64) {
        let mut schedule = [0u32; 64];

        for slot in 0..16 {
            schedule[slot] = u32::from_be_bytes([
                block[4 * slot],
                block[4 * slot + 1],
                block[4 * slot + 2],
                block[4 * slot + 3],
            ]);
        }

        for slot in 16..64 {
            let small0 = schedule[slot - 15].rotate_right(7)
                ^ schedule[slot - 15].rotate_right(18)
                ^ (schedule[slot - 15] >> 3);
            let small1 = schedule[slot - 2].rotate_right(17)
                ^ schedule[slot - 2].rotate_right(19)
                ^ (schedule[slot - 2] >> 10);
            schedule[slot] = schedule[slot - 16]
                .wrapping_add(small0)
                .wrapping_add(schedule[slot - 7])
                .wrapping_add(small1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = hash;

        for slot in 0..64 {
            let big1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choose = (e & f) ^ (!e & g);
            let temp1 = h
                .wrapping_add(big1)
                .wrapping_add(choose)
                .wrapping_add(K[slot])
                .wrapping_add(schedule[slot]);
            let big0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = big0.wrapping_add(majority);

            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        hash[0] = hash[0].wrapping_add(a);
        hash[1] = hash[1].wrapping_add(b);
        hash[2] = hash[2].wrapping_add(c);
        hash[3] = hash[3].wrapping_add(d);
        hash[4] = hash[4].wrapping_add(e);
        hash[5] = hash[5].wrapping_add(f);
        hash[6] = hash[6].wrapping_add(g);
        hash[7] = hash[7].wrapping_add(h);
    }

    let mut out = [0u8; 32];
    for (slot, word) in hash.iter().enumerate() {
        out[4 * slot..4 * slot + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

/// The SHA-256 digest as lowercase hex, the form SigV4 embeds.
pub fn sha256hex(data: &[u8]) -> String {
    hex(&sha256(data))
}

/// HMAC-SHA256 (RFC 2104): a keyed digest, the primitive SigV4's key
/// derivation chains.
pub fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    // A key longer than the 64-byte block is hashed down; a shorter one is
    // zero-padded up.
    let mut padded = if 64 < key.len() {
        sha256(key).to_vec()
    } else {
        key.to_vec()
    };
    padded.resize(64, 0);

    let mut inner: Vec<u8> = padded.iter().map(|byte| byte ^ 0x36).collect();
    inner.extend_from_slice(data);
    let innerhash = sha256(&inner);

    let mut outer: Vec<u8> = padded.iter().map(|byte| byte ^ 0x5c).collect();
    outer.extend_from_slice(&innerhash);
    sha256(&outer)
}

/// Bytes as lowercase hex.
pub fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(2 * bytes.len());
    for byte in bytes {
        out.push_str(&format!("{:02x}", byte));
    }
    out
}
