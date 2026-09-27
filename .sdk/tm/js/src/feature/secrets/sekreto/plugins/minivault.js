// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (javascript/plugins/minivault.js)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

// A port of typescript/plugins/minivault.ts, which is canonical.
//
// A mini vault: every secret a project owns, encrypted, in ONE FILE.
//
// THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
// every name and mints restricted keys. A restricted key reads the names
// it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
// cryptography rather than a check this code performs. What that does
// and does not protect is set out in DOCS.md under "What the mini vault
// protects".

const { PluginError } = require('@voxgig/plugin-js')

const {
  ERROR_CODE, PROVIDER_EXPORT, SekretoError, checkname, nodemod,
} = require('../provider/support')

function crypto() {
  return nodemod('node:crypto')
}

function fs() {
  return nodemod('node:fs')
}


// --- the format ------------------------------------------------------
//
//   magic       4   'SKMV'
//   version     1   FORMAT
//   kdf         1   1 = PBKDF2-HMAC-SHA256
//   cipher      1   1 = AES-256-GCM
//   reserved    1   0
//   keycount    4   uint32
//   per key:
//     id        1 + bytes      the key id, PLAINTEXT
//     salt      1 + bytes
//     iters     4              PBKDF2 rounds for this key
//     ring      1 + iv, 4 + bytes    sealed under the passphrase
//     meta      1 + iv, 4 + bytes    sealed under the vault's meta key
//   entrycount  4   uint32
//   per entry:
//     id        1 + bytes      the blinded lookup id
//     name      1 + iv, 4 + bytes    sealed under the vault's name key
//     value     1 + iv, 4 + bytes    sealed under that secret's own key
//
// Integers are big-endian, and every length precedes its bytes. A file
// one port writes is read by every other; `test/fixture` pins that with
// a committed vault rather than with agreement.

const MAGIC = 'SKMV'
const FORMAT = 1
const KDF_PBKDF2 = 1
const CIPHER_AESGCM = 1

/** AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags. */
const KEYLEN = 32
const IVLEN = 12
const TAGLEN = 16
const SALTLEN = 16

/** PBKDF2-HMAC-SHA256 rounds when a caller names none. */
const ITERATIONS = 210000

/** The key id a vault gets when a caller names none. */
const MASTERKEY = 'master'

// Additional authenticated data. Every blob is bound to its PLACE in the
// file, so no ciphertext can be moved.
const AAD_RING = 'skmv1:ring:'
const AAD_META = 'skmv1:meta:'
const AAD_NAME = 'skmv1:name'
const AAD_SECRET = 'skmv1:secret:'

// Everything a master can reach is derived from the root key, so a
// rotation is one new random value rather than a re-wrap of each part.
const LABEL_NAMES = 'skmv1:names'
const LABEL_META = 'skmv1:meta'
const LABEL_ID = 'skmv1:id'


function fail(text) {
  throw new SekretoError('sekreto: minivault: ' + text)
}

/** The largest key id the format can record.
 *
 * `small` writes a length in ONE byte. A longer id wrapped that byte and
 * the writer then appended the whole thing, so every field after it
 * shifted. Checked where an id is ACCEPTED, so the refusal names the id
 * rather than the file. */
const IDMAX = 255

function checkid(id, what) {
  if ('string' !== typeof id || '' === id) {
    fail(what)
  }
  if (IDMAX < Buffer.byteLength(id, 'utf8')) {
    fail('key id is longer than ' + IDMAX + ' bytes: ' + id.substring(0, 32) + '...')
  }
  return id
}


// --- keys ------------------------------------------------------------

function hmac(key, text) {
  return crypto().createHmac('sha256', key).update(text, 'utf8').digest()
}

/** The key-encryption key a passphrase unwraps a ring with. */
function kek(passphrase, salt, iters) {
  return crypto().pbkdf2Sync(passphrase, salt, iters, KEYLEN, 'sha256')
}

/** The key one named secret's value is encrypted with.
 *
 * DERIVED, never stored, for a master: it holds the root key and so
 * reaches every name, including ones written after it was made. A
 * restricted key holds the derived keys it was granted and nothing that
 * produces another. */
function secretkey(root, name) {
  return hmac(root, AAD_SECRET + name)
}

/** Where a secret lives in the file, derived from its own key so that
 * finding it needs no plaintext name. */
function entryid(key) {
  return hmac(key, LABEL_ID)
}

function random(len) {
  return crypto().randomBytes(len)
}


// --- sealing ---------------------------------------------------------

function seal(key, plain, aad) {
  const iv = random(IVLEN)
  const cipher = crypto().createCipheriv('aes-256-gcm', key, iv)
  cipher.setAAD(Buffer.from(aad, 'utf8'))
  const body = Buffer.concat([cipher.update(plain), cipher.final()])
  return { iv, blob: Buffer.concat([body, cipher.getAuthTag()]) }
}

/** The plaintext, or a refusal. A GCM tag that fails to verify is the
 * only evidence there is, and it cannot tell a wrong passphrase from a
 * damaged file, so `what` names the attempt and the message admits
 * both. */
function unseal(key, sealed, aad, what) {
  if (sealed.blob.length < TAGLEN || IVLEN !== sealed.iv.length) {
    fail(what + ': truncated')
  }

  // The WHOLE round-trip is guarded, not only `final()`. A nonce or tag
  // of the wrong length makes the constructor itself raise.
  try {
    const decipher = crypto().createDecipheriv('aes-256-gcm', key, sealed.iv)
    decipher.setAAD(Buffer.from(aad, 'utf8'))
    decipher.setAuthTag(sealed.blob.subarray(sealed.blob.length - TAGLEN))

    return Buffer.concat([
      decipher.update(sealed.blob.subarray(0, sealed.blob.length - TAGLEN)),
      decipher.final(),
    ])
  } catch {
    return fail(what)
  }
}

function jsonof(plain, what) {
  try {
    return JSON.parse(plain.toString('utf8'))
  } catch {
    return fail('unreadable ' + what)
  }
}

function b64(bytes) {
  return bytes.toString('base64')
}

function unb64(text, what) {
  if ('string' !== typeof text) {
    fail('missing ' + what)
  }
  return Buffer.from(text, 'base64')
}


// --- the file --------------------------------------------------------

/** A cursor, so that every length check is in one place: a truncated
 * vault is refused rather than read as a short one. */
function reader(bytes) {
  let at = 0

  const take = (len) => {
    if (bytes.length < at + len) {
      fail('the vault file is truncated')
    }
    const out = Buffer.from(bytes.subarray(at, at + len))
    at += len
    return out
  }

  const u8 = () => take(1)[0]
  const u32 = () => take(4).readUInt32BE(0)
  const small = () => take(u8())
  const large = () => take(u32())

  return {
    u8,
    u32,
    small,
    large,
    magic: () => take(4).toString('latin1'),
    sealed: () => ({ iv: small(), blob: large() }),
    done: () => at === bytes.length,
  }
}

function readfile(bytes) {
  const read = reader(bytes)

  if (MAGIC !== read.magic()) {
    fail('not a vault file')
  }

  const version = read.u8()
  if (FORMAT !== version) {
    fail('unsupported format version: ' + version)
  }

  const kdf = read.u8()
  const cipher = read.u8()
  if (KDF_PBKDF2 !== kdf || CIPHER_AESGCM !== cipher) {
    fail('unsupported kdf or cipher: ' + kdf + '/' + cipher)
  }
  read.u8()

  const keys = []
  const keycount = read.u32()
  for (let index = 0; index < keycount; index++) {
    const id = read.small().toString('utf8')
    const salt = read.small()
    const iters = read.u32()
    keys.push({ id, salt, iters, ring: read.sealed(), meta: read.sealed() })
  }

  const entries = []
  const entrycount = read.u32()
  for (let index = 0; index < entrycount; index++) {
    entries.push({ id: read.small(), name: read.sealed(), value: read.sealed() })
  }

  if (!read.done()) {
    fail('the vault file has trailing bytes')
  }

  return { keys, entries }
}

function writefile(vault) {
  const parts = []

  const u8 = (value) => parts.push(Buffer.from([value]))
  const u32 = (value) => {
    const four = Buffer.alloc(4)
    four.writeUInt32BE(value, 0)
    parts.push(four)
  }
  const small = (bytes) => { u8(bytes.length); parts.push(bytes) }
  const large = (bytes) => { u32(bytes.length); parts.push(bytes) }
  const sealed = (value) => { small(value.iv); large(value.blob) }

  parts.push(Buffer.from(MAGIC, 'latin1'))
  u8(FORMAT)
  u8(KDF_PBKDF2)
  u8(CIPHER_AESGCM)
  u8(0)

  u32(vault.keys.length)
  for (const key of vault.keys) {
    small(Buffer.from(key.id, 'utf8'))
    small(key.salt)
    u32(key.iters)
    sealed(key.ring)
    sealed(key.meta)
  }

  // SORTED BY ID, which is a blinded value: the file therefore records
  // nothing about the order secrets were written in.
  const entries = [...vault.entries].sort((left, right) => Buffer.compare(left.id, right.id))

  u32(entries.length)
  for (const entry of entries) {
    small(entry.id)
    sealed(entry.name)
    sealed(entry.value)
  }

  return Buffer.concat(parts)
}


// --- what a key is ---------------------------------------------------

/** A detached copy, so that what a caller is handed cannot become what
 * this vault believes. */
function copyinfo(info) {
  return {
    key: info.key,
    master: info.master,
    write: info.write,
    grants: [...info.grants],
  }
}


// --- creating --------------------------------------------------------

/** A new vault: one master key, no secrets. */
function newvault(keyid, passphrase, iterations) {
  const root = random(KEYLEN)
  const salt = random(SALTLEN)

  const ring = { v: FORMAT, write: true, root: b64(root) }
  const meta = { v: FORMAT, master: true, write: true, grants: [] }

  return {
    keys: [{
      id: keyid,
      salt,
      iters: iterations,
      ring: seal(kek(passphrase, salt, iterations),
        Buffer.from(JSON.stringify(ring), 'utf8'), AAD_RING + keyid),
      meta: seal(hmac(root, LABEL_META),
        Buffer.from(JSON.stringify(meta), 'utf8'), AAD_META + keyid),
    }],
    entries: [],
  }
}

/** Write a vault file that is not there yet, and REFUSE one that is.
 *
 * Straight to the target under `wx` — `O_CREAT|O_EXCL` — rather than
 * through a temporary and a rename. `rename` REPLACES its destination,
 * so two processes creating the same vault both succeeded and the
 * second discarded the first one's secrets. */
function putnew(file, vault) {
  try {
    fs().writeFileSync(file, writefile(vault), { mode: 0o600, flag: 'wx' })
  } catch (err) {
    if ('EEXIST' === err.code) {
      fail('vault file already exists: ' + file)
    }
    fail('cannot write ' + file + ': ' + err.message)
  }
}


// --- opening ---------------------------------------------------------

/** Is this the same sealed blob, byte for byte? */
function sameseal(left, right) {
  return 0 === Buffer.compare(left.iv, right.iv) && 0 === Buffer.compare(left.blob, right.blob)
}

/** Open a vault file as one key.
 *
 * The handle is lazy. Nothing is read, and no passphrase is stretched,
 * until a method needs the file. */
function openvault(options) {
  const opts = options || {}
  const file = opts.file
  const keyid = opts.key || MASTERKEY
  const passphrase = opts.passphrase
  const iterations = opts.iterations || ITERATIONS

  if ('string' !== typeof file || '' === file) {
    fail('a vault needs a file')
  }
  if ('string' !== typeof passphrase || '' === passphrase) {
    fail('a vault needs a passphrase')
  }
  checkid(keyid, 'a vault needs a key id')

  let opened

  const bytes = () => {
    try {
      return fs().readFileSync(file)
    } catch (err) {
      // A vault is configured deliberately, with a key. Its absence is a
      // broken deployment and never "no secrets here": answering a miss
      // would send the chain on to a weaker store.
      if ('ENOENT' === err.code) {
        if (true !== opts.create) {
          fail('no vault file: ' + file)
        }
        putnew(file, newvault(keyid, passphrase, iterations))
        return fs().readFileSync(file)
      }
      return fail('cannot read ' + file + ': ' + err.message)
    }
  }

  const load = () => {
    const vault = readfile(bytes())

    const record = vault.keys.find((k) => k.id === keyid)
    if (undefined === record) {
      // REVOKED, or never there. Either way this handle is finished, and
      // dropping what it derived is what stops the next call answering
      // from memory.
      opened = undefined
      fail('no such key: ' + keyid)
    }

    // The file still holds this key, and holds the SAME ring: a key
    // revoked and re-granted under another passphrase is a different key
    // wearing the id, and re-deriving is what refuses it.
    if (undefined !== opened && sameseal(opened.ring, record.ring)) {
      return { vault, open: opened }
    }
    opened = undefined

    const plain = unseal(kek(passphrase, record.salt, record.iters), record.ring,
      AAD_RING + keyid, 'wrong passphrase for key ' + keyid + ', or a damaged vault')

    const ring = jsonof(plain, 'key ring for ' + keyid)

    const grants = {}
    for (const [name, key] of Object.entries(ring.grants || {})) {
      grants[name] = unb64(key, 'a granted key')
    }

    opened = {
      info: {
        key: keyid,
        master: undefined !== ring.root,
        write: undefined !== ring.root || true === ring.write,
        grants: Object.keys(grants).sort(),
      },
      root: undefined === ring.root ? undefined : unb64(ring.root, 'the root key'),
      grants,
      ring: record.ring,
    }

    return { vault, open: opened }
  }

  const rootof = (open, what) => {
    if (undefined === open.root) {
      fail(what + ' needs a master key, and ' + open.info.key + ' is restricted')
    }
    return open.root
  }

  /** The key for one name, or undefined when this key cannot reach it. */
  const keyfor = (open, name) => {
    if (undefined !== open.root) {
      return secretkey(open.root, name)
    }
    return open.grants[name]
  }

  const findentry = (vault, key) => {
    const id = entryid(key)
    return vault.entries.find((entry) => 0 === Buffer.compare(entry.id, id))
  }

  const metaof = (open, record) => {
    const root = rootof(open, 'reading key metadata')
    try {
      return jsonof(unseal(hmac(root, LABEL_META), record.meta, AAD_META + record.id,
        'metadata for key ' + record.id), 'metadata for key ' + record.id)
    } catch {
      // A record written under a root key this one has replaced. The key
      // is still in the file and still opens with its own passphrase, so
      // it is reported rather than hidden - with what it can do unknown.
      return undefined
    }
  }

  const sealkey = (root, id, phrase, iters, ring, meta) => {
    const salt = random(SALTLEN)
    return {
      id,
      salt,
      iters,
      ring: seal(kek(phrase, salt, iters), Buffer.from(JSON.stringify(ring), 'utf8'), AAD_RING + id),
      meta: seal(hmac(root, LABEL_META), Buffer.from(JSON.stringify(meta), 'utf8'), AAD_META + id),
    }
  }

  /** Read, change, and REPLACE - never edit in place.
   *
   * THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
   * anyone can predict, so anyone who can write the vault's directory
   * could put a symlink there and have the next save truncate whatever
   * it pointed at. */
  const save = (vault) => {
    const node = fs()
    const temp = file + '.' + random(8).toString('hex') + '.tmp'

    try {
      node.writeFileSync(temp, writefile(vault), { mode: 0o600, flag: 'wx' })
      node.renameSync(temp, file)
    } catch (err) {
      try {
        node.unlinkSync(temp)
      } catch {
        // The vault is unchanged either way, and the write error is what
        // the caller needs to be told about.
      }
      fail('cannot write ' + file + ': ' + err.message)
    }
  }

  const self = {
    file: () => file,
    key: () => keyid,

    // A COPY. `set` reads `info.write` to decide whether this key may
    // write, so handing the caller the object itself let it flip its own
    // permission. Authorization state does not leave this closure.
    open: () => copyinfo(load().open.info),

    close: () => { opened = undefined },

    list: () => {
      const { vault, open } = load()

      if (undefined !== open.root) {
        const namekey = hmac(open.root, LABEL_NAMES)
        return vault.entries
          .map((entry) => unseal(namekey, entry.name, AAD_NAME, 'a secret name is damaged')
            .toString('utf8'))
          .sort()
      }

      // A restricted key has no name key, so it reports the grants it can
      // actually find: the vault never tells it what else is in there.
      return open.info.grants
        .filter((name) => undefined !== findentry(vault, open.grants[name]))
        .sort()
    },

    has: (name) => undefined !== self.get(name),

    get: (name) => {
      checkname(name)
      const { vault, open } = load()

      const key = keyfor(open, name)
      if (undefined === key) {
        // OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as
        // the key that opened it, so a name this key cannot read is a
        // name this store does not hold for this caller.
        return undefined
      }

      const entry = findentry(vault, key)
      if (undefined === entry) {
        return undefined
      }

      return unseal(key, entry.value, AAD_SECRET + name,
        'the value of ' + name + ' is damaged').toString('utf8')
    },

    set: (name, value) => {
      checkname(name)
      if ('string' !== typeof value) {
        fail('a secret value must be text: ' + name)
      }

      const { vault, open } = load()

      if (!open.info.write) {
        fail('key ' + open.info.key + ' is read-only')
      }

      const key = keyfor(open, name)
      if (undefined === key) {
        fail('key ' + open.info.key + ' was not granted ' + name)
      }

      const sealedvalue = seal(key, Buffer.from(value, 'utf8'), AAD_SECRET + name)
      const id = entryid(key)
      const at = vault.entries.findIndex((entry) => 0 === Buffer.compare(entry.id, id))

      if (-1 !== at) {
        vault.entries[at] = {
          id: vault.entries[at].id,
          name: vault.entries[at].name,
          value: sealedvalue,
        }
      } else {
        // A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
        // restricted key with `write` updates what it was granted and
        // cannot grow the vault.
        const root = rootof(open, 'creating the secret ' + name)
        vault.entries.push({
          id,
          name: seal(hmac(root, LABEL_NAMES), Buffer.from(name, 'utf8'), AAD_NAME),
          value: sealedvalue,
        })
      }

      save(vault)
    },

    remove: (name) => {
      checkname(name)
      const { vault, open } = load()
      const root = rootof(open, 'removing a secret')

      const at = vault.entries.findIndex(
        (entry) => 0 === Buffer.compare(entry.id, entryid(secretkey(root, name))))
      if (-1 === at) {
        fail('no such secret: ' + name)
      }

      vault.entries.splice(at, 1)
      save(vault)
    },

    keys: () => {
      const { vault, open } = load()
      rootof(open, 'listing the keys')

      return vault.keys.map((record) => {
        const meta = metaof(open, record)
        if (undefined === meta) {
          return { key: record.id, master: false, write: false, grants: [] }
        }
        return {
          key: record.id,
          master: true === meta.master,
          write: true === meta.write,
          grants: [...(meta.grants || [])].sort(),
        }
      })
    },

    grant: (spec) => {
      const { vault, open } = load()
      const root = rootof(open, 'granting a key')

      checkid(null == spec ? '' : spec.key, 'a grant needs a key id')
      if ('string' !== typeof spec.passphrase || '' === spec.passphrase) {
        fail('a grant needs a passphrase')
      }
      if (undefined !== vault.keys.find((k) => k.id === spec.key)) {
        fail('key already exists: ' + spec.key)
      }

      const names = [...(spec.names || [])].sort()
      const grants = {}
      for (const name of names) {
        checkname(name)
        grants[name] = b64(secretkey(root, name))
      }

      const write = true === spec.write
      vault.keys.push(sealkey(root, spec.key, spec.passphrase, spec.iterations || iterations,
        { v: FORMAT, write, grants },
        { v: FORMAT, master: false, write, grants: names }))

      save(vault)
    },

    revoke: (key) => {
      const { vault, open } = load()
      rootof(open, 'revoking a key')

      if (key === open.info.key) {
        fail('a key cannot revoke itself: ' + key)
      }

      const at = vault.keys.findIndex((k) => k.id === key)
      if (-1 === at) {
        fail('no such key: ' + key)
      }

      vault.keys.splice(at, 1)
      save(vault)
    },

    rotate: () => {
      const { vault, open } = load()
      rootof(open, 'rotating the vault')

      // Read everything out under the old root before anything changes:
      // once the root is replaced the old derived keys are unreachable.
      const plain = self.list().map((name) => ({ name, value: self.get(name) }))

      const root = random(KEYLEN)
      const namekey = hmac(root, LABEL_NAMES)

      const entries = plain.map((secret) => {
        const key = secretkey(root, secret.name)
        return {
          id: entryid(key),
          name: seal(namekey, Buffer.from(secret.name, 'utf8'), AAD_NAME),
          value: seal(key, Buffer.from(secret.value, 'utf8'), AAD_SECRET + secret.name),
        }
      })

      const record = vault.keys.find((k) => k.id === keyid)

      const fresh = sealkey(root, keyid, passphrase, record.iters,
        { v: FORMAT, write: true, root: b64(root) },
        { v: FORMAT, master: true, write: true, grants: [] })

      // SAVE FIRST, adopt second. A handle holding the new root over a
      // file that still holds the old one reads nothing and says the
      // vault is damaged.
      save({ keys: [fresh], entries })

      opened = {
        info: { key: keyid, master: true, write: true, grants: [] },
        root,
        grants: {},
        ring: fresh.ring,
      }
    },
  }

  return self
}

/** Make a vault file and return a handle on its master key.
 *
 * Refuses a file that is already there: a vault is created once, and
 * overwriting one discards every secret in it. */
function createvault(options) {
  const opts = options || {}

  if ('string' !== typeof opts.file || '' === opts.file) {
    fail('a vault needs a file')
  }
  if ('string' !== typeof opts.passphrase || '' === opts.passphrase) {
    fail('a vault needs a passphrase')
  }
  checkid(opts.key || MASTERKEY, 'a vault needs a key id')

  // No `existsSync` first: the check and the write would be two steps,
  // and `putnew` refuses an existing file in ONE.
  putnew(opts.file, newvault(opts.key || MASTERKEY, opts.passphrase, opts.iterations || ITERATIONS))

  return openvault(opts)
}


// --- the provider ----------------------------------------------------

/** Read a vault as one store in a chain.
 *
 * The provider is the READ half and nothing more: a chain resolves
 * secrets, and writing one is a deliberate act with an API of its own. */
function providerof(vault) {
  return {
    lookup: (name) => vault.get(name),
    describe: () => 'minivault:' + vault.file(),
  }
}

/** A vault provider from options, for a chain built by hand. */
function minivaultprovider(options) {
  return providerof(openvault(options))
}

/** The vault options a provider spec describes. */
function vaultoptions(spec) {
  return {
    file: spec.file || '',
    key: spec.vaultkey,
    passphrase: spec.passphrase || '',
    iterations: spec.iterations,
    create: true === spec.create,
  }
}


// --- the plugin ------------------------------------------------------

/** The export key the vault API is published under, beside the
 * `provider` key every kind publishes. */
const VAULT_EXPORT = 'vault'

/** The `minivault` provider kind.
 *
 * Written out rather than built by `providerplugin`, because this
 * definition publishes TWO exports: `provider`, the read half every kind
 * publishes, and `vault`, the programmatic API. */
const minivault = {
  name: 'minivault',
  define: (inst) => {
    const options = vaultoptions(inst.options)

    try {
      // `openvault` refuses bad configuration HERE, so a mistyped chain
      // fails at construction. Reaching the FILE is not configuration:
      // the handle is lazy.
      const vault = openvault(options)

      inst.export(PROVIDER_EXPORT, providerof(vault))
      inst.export(VAULT_EXPORT, vault)
    } catch (err) {
      if (err instanceof SekretoError) {
        throw new PluginError(ERROR_CODE, err.message, { ref: inst.ref, cause: err.message })
      }
      throw err
    }
  },
}

/** The vault behind a store in a chain, as its programmatic API.
 *
 * With no store named, the unqualified alias answers: one vault in the
 * chain resolves whatever it is called, and two raise rather than
 * picking one. */
function vaultof(secrets, store) {
  if (undefined === store) {
    const found = secrets.host.exports('minivault/' + VAULT_EXPORT)
    if (undefined === found) {
      fail('no minivault store in this chain')
    }
    return found
  }

  // A NAMED STORE MUST EXIST, and the alias must not stand in for it.
  // `host.exports` falls back to the alias when the exact ref misses, so
  // asking for `minivault` in a chain whose only vault is named `app`
  // used to hand back the `app` vault - and then write to it.
  const ref = 'minivault' === store ? 'minivault' : 'minivault$' + store

  if (undefined === secrets.host.instance(ref)) {
    fail('no minivault store named ' + store + ' in this chain')
  }

  return secrets.host.exports(ref + '/' + VAULT_EXPORT)
}


module.exports = {
  ITERATIONS,
  MASTERKEY,
  VAULT_EXPORT,
  createvault,
  minivault,
  minivaultprovider,
  openvault,
  providerof,
  vaultof,
}
