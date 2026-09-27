// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (rust/plugins/minivault/src/format.rs)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use std::num::NonZeroU32;

use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use ring::hmac;
use ring::pbkdf2;
use ring::rand::{SecureRandom, SystemRandom};

use crate::feature::secrets::sekreto::{Answer, SekretoError};

pub const MAGIC: &[u8; 4] = b"SKMV";
pub const FORMAT: u8 = 1;

pub const KDF_PBKDF2: u8 = 1;
pub const CIPHER_AESGCM: u8 = 1;

/// AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
pub const KEYLEN: usize = 32;
pub const IVLEN: usize = 12;
pub const TAGLEN: usize = 16;
pub const SALTLEN: usize = 16;

/// The PBKDF2-HMAC-SHA256 round count when a caller names none.
pub const ITERATIONS: u32 = 210000;

/// The key id a vault gets when a caller names none.
pub const MASTERKEY: &str = "master";

/// Additional authenticated data. Every blob is bound to its PLACE in the
/// file, so no ciphertext can be moved: a restricted key's ring cannot be
/// relabelled as the master's, and one secret's value cannot be served
/// under a name it was never written for.
pub const AAD_RING: &str = "skmv1:ring:";
pub const AAD_META: &str = "skmv1:meta:";
pub const AAD_NAME: &str = "skmv1:name";
pub const AAD_SECRET: &str = "skmv1:secret:";

/// Everything a master reaches is derived from the root key, so rotating
/// is one new random value rather than a re-wrap of each part.
pub const LABEL_NAMES: &str = "skmv1:names";
pub const LABEL_META: &str = "skmv1:meta";
pub const LABEL_ID: &str = "skmv1:id";

pub fn fail<T>(text: &str) -> Answer<T> {
    Err(SekretoError::new(format!("sekreto: minivault: {}", text)))
}

pub const IDMAX: usize = 255;

pub fn checkid(id: &str, what: &str) -> Answer<()> {
    if id.is_empty() {
        return fail(what);
    }
    if IDMAX < id.len() {
        let cut: String = id.chars().take(32).collect();
        return fail(&format!(
            "key id is longer than {} bytes: {}...",
            IDMAX, cut
        ));
    }
    Ok(())
}

// --- keys ------------------------------------------------------------

pub fn mac(key: &[u8], text: &str) -> Vec<u8> {
    let one = hmac::Key::new(hmac::HMAC_SHA256, key);
    hmac::sign(&one, text.as_bytes()).as_ref().to_vec()
}

/// The key-encryption key a passphrase unwraps a ring with.
pub fn kek(passphrase: &str, salt: &[u8], iters: u32) -> Answer<Vec<u8>> {
    let rounds = match NonZeroU32::new(iters) {
        Some(held) => held,
        None => return fail(&format!("unusable round count: {}", iters)),
    };

    let mut out = vec![0u8; KEYLEN];
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA256,
        rounds,
        salt,
        passphrase.as_bytes(),
        &mut out,
    );

    Ok(out)
}

pub fn secretkey(root: &[u8], name: &str) -> Vec<u8> {
    mac(root, &format!("{}{}", AAD_SECRET, name))
}

/// Where a secret lives in the file, derived from its own key so that
/// finding it needs no plaintext name. One-way: an id yields nothing
/// about the key that produced it.
pub fn entryid(key: &[u8]) -> Vec<u8> {
    mac(key, LABEL_ID)
}

pub fn random(length: usize) -> Answer<Vec<u8>> {
    let mut out = vec![0u8; length];
    match SystemRandom::new().fill(&mut out) {
        Ok(()) => Ok(out),
        Err(_) => fail("no randomness available"),
    }
}

// --- sealing ---------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub struct Sealed {
    pub iv: Vec<u8>,
    pub blob: Vec<u8>,
}

fn aeadof(key: &[u8]) -> Answer<LessSafeKey> {
    match UnboundKey::new(&AES_256_GCM, key) {
        Ok(unbound) => Ok(LessSafeKey::new(unbound)),
        Err(_) => fail("bad key"),
    }
}

fn nonceof(iv: &[u8]) -> Answer<Nonce> {
    match Nonce::try_assume_unique_for_key(iv) {
        Ok(one) => Ok(one),
        Err(_) => fail("bad nonce"),
    }
}

/// The tag rides at the END of the blob, which is where every other port's
/// AEAD leaves it and therefore what the format records.
/// `seal_in_place_append_tag` puts it there, so nothing is repacked.
pub fn seal(key: &[u8], plain: &[u8], aad: &str) -> Answer<Sealed> {
    let iv = random(IVLEN)?;
    let one = aeadof(key)?;

    let mut held = plain.to_vec();
    if one
        .seal_in_place_append_tag(nonceof(&iv)?, Aad::from(aad.as_bytes()), &mut held)
        .is_err()
    {
        return fail("cannot seal");
    }

    Ok(Sealed { iv, blob: held })
}

/// The plaintext, or a refusal. A GCM tag that fails to verify is the only
/// evidence there is, and it cannot tell a wrong passphrase from a damaged
/// file, so `what` names the attempt and the message admits both.
pub fn unseal(key: &[u8], box_: &Sealed, aad: &str, what: &str) -> Answer<Vec<u8>> {
    if box_.blob.len() < TAGLEN || IVLEN != box_.iv.len() {
        return fail(&format!("{}: truncated", what));
    }

    let one = aeadof(key)?;
    let mut held = box_.blob.clone();

    match one.open_in_place(nonceof(&box_.iv)?, Aad::from(aad.as_bytes()), &mut held) {
        Ok(plain) => Ok(plain.to_vec()),
        Err(_) => fail(what),
    }
}

// --- the file --------------------------------------------------------

#[derive(Clone, Debug)]
pub struct KeyRecord {
    pub id: String,
    pub salt: Vec<u8>,
    pub iters: u32,
    pub ring: Sealed,
    pub meta: Sealed,
}

#[derive(Clone, Debug)]
pub struct EntryRecord {
    pub id: Vec<u8>,
    pub name: Sealed,
    pub value: Sealed,
}

#[derive(Clone, Debug, Default)]
pub struct VaultFile {
    pub keys: Vec<KeyRecord>,
    pub entries: Vec<EntryRecord>,
}

impl VaultFile {
    pub fn key(&self, id: &str) -> Option<&KeyRecord> {
        self.keys.iter().find(|record| id == record.id)
    }

    pub fn entry(&self, id: &[u8]) -> Option<&EntryRecord> {
        self.entries.iter().find(|record| id == record.id.as_slice())
    }
}

/// A cursor, so that every length check is in one place: a truncated vault
/// is refused rather than read as a short one.
struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, length: u64) -> Answer<&'a [u8]> {
        if ((self.bytes.len() - self.at) as u64) < length {
            return fail("the vault file is truncated");
        }
        let out = &self.bytes[self.at..self.at + length as usize];
        self.at += length as usize;
        Ok(out)
    }

    fn u8(&mut self) -> Answer<u8> {
        Ok(self.take(1)?[0])
    }

    fn u32(&mut self) -> Answer<u32> {
        let four = self.take(4)?;
        Ok(u32::from_be_bytes([four[0], four[1], four[2], four[3]]))
    }

    fn small(&mut self) -> Answer<Vec<u8>> {
        let length = self.u8()? as u64;
        Ok(self.take(length)?.to_vec())
    }

    fn large(&mut self) -> Answer<Vec<u8>> {
        let length = self.u32()? as u64;
        Ok(self.take(length)?.to_vec())
    }

    fn sealed(&mut self) -> Answer<Sealed> {
        let iv = self.small()?;
        let blob = self.large()?;
        Ok(Sealed { iv, blob })
    }
}

pub fn readfile(raw: &[u8]) -> Answer<VaultFile> {
    let mut read = Reader { bytes: raw, at: 0 };

    if MAGIC != read.take(4)? {
        return fail("not a vault file");
    }

    let version = read.u8()?;
    if FORMAT != version {
        return fail(&format!("unsupported format version: {}", version));
    }

    let kdf = read.u8()?;
    let cipher = read.u8()?;
    if KDF_PBKDF2 != kdf || CIPHER_AESGCM != cipher {
        return fail(&format!("unsupported kdf or cipher: {}/{}", kdf, cipher));
    }
    read.u8()?;

    let mut file = VaultFile::default();

    // A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a
    // few bytes, so a file claiming four billion of them is damaged; the
    // loop would find that out one truncation at a time, and a caller that
    // preallocated would not.
    let keycount = read.u32()? as u64;
    if ((raw.len() - read.at) as u64) < keycount {
        return fail("the vault file is truncated");
    }
    for _ in 0..keycount {
        let id = read.small()?;
        let salt = read.small()?;
        let iters = read.u32()?;
        let ring = read.sealed()?;
        let meta = read.sealed()?;
        file.keys.push(KeyRecord {
            id: String::from_utf8_lossy(&id).into_owned(),
            salt,
            iters,
            ring,
            meta,
        });
    }

    let entrycount = read.u32()? as u64;
    if ((raw.len() - read.at) as u64) < entrycount {
        return fail("the vault file is truncated");
    }
    for _ in 0..entrycount {
        let id = read.small()?;
        let name = read.sealed()?;
        let value = read.sealed()?;
        file.entries.push(EntryRecord { id, name, value });
    }

    if read.at != raw.len() {
        return fail("the vault file has trailing bytes");
    }

    Ok(file)
}

struct Writer {
    out: Vec<u8>,
}

impl Writer {
    fn u8(&mut self, value: u8) {
        self.out.push(value);
    }

    fn u32(&mut self, value: u32) {
        self.out.extend_from_slice(&value.to_be_bytes());
    }

    fn small(&mut self, value: &[u8]) {
        self.u8(value.len() as u8);
        self.out.extend_from_slice(value);
    }

    fn large(&mut self, value: &[u8]) {
        self.u32(value.len() as u32);
        self.out.extend_from_slice(value);
    }

    fn sealed(&mut self, value: &Sealed) {
        self.small(&value.iv);
        self.large(&value.blob);
    }
}

pub fn writefile(file: &VaultFile) -> Vec<u8> {
    let mut write = Writer {
        out: MAGIC.to_vec(),
    };

    write.u8(FORMAT);
    write.u8(KDF_PBKDF2);
    write.u8(CIPHER_AESGCM);
    write.u8(0);

    write.u32(file.keys.len() as u32);
    for record in &file.keys {
        write.small(record.id.as_bytes());
        write.small(&record.salt);
        write.u32(record.iters);
        write.sealed(&record.ring);
        write.sealed(&record.meta);
    }

    // SORTED BY ID, which is a blinded value: the file therefore records
    // nothing about the order secrets were written in.
    let mut entries: Vec<&EntryRecord> = file.entries.iter().collect();
    entries.sort_by(|left, right| left.id.cmp(&right.id));

    write.u32(entries.len() as u32);
    for record in entries {
        write.small(&record.id);
        write.sealed(&record.name);
        write.sealed(&record.value);
    }

    write.out
}
