// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/minivault.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */


import { PluginError } from '../../plugin'

import {
  Definition, ERROR_CODE, PROVIDER_EXPORT, Provider, ProviderSpec, SekretoError,
  checkname, nodemod,
} from '../provider/support'

type Crypto = typeof import('node:crypto')
type Fs = typeof import('node:fs')

function crypto(): Crypto {
  return nodemod<Crypto>('node:crypto')
}

function fs(): Fs {
  return nodemod<Fs>('node:fs')
}



const MAGIC = 'SKMV'
const FORMAT = 1
const KDF_PBKDF2 = 1
const CIPHER_AESGCM = 1

const KEYLEN = 32
const IVLEN = 12
const TAGLEN = 16
const SALTLEN = 16

export const ITERATIONS = 210000

export const MASTERKEY = 'master'

// Additional authenticated data. Every blob is bound to its PLACE in the
// file, so no ciphertext can be moved: a restricted key's ring cannot be
// relabelled as the master's, and one secret's value cannot be served
// under a name it was never written for.
const AAD_RING = 'skmv1:ring:'
const AAD_META = 'skmv1:meta:'
const AAD_NAME = 'skmv1:name'
const AAD_SECRET = 'skmv1:secret:'

// Everything a master can reach is derived from the root key, so a
// rotation is one new random value rather than a re-wrap of each part.
const LABEL_NAMES = 'skmv1:names'
const LABEL_META = 'skmv1:meta'
const LABEL_ID = 'skmv1:id'


function fail(text: string): never {
  throw new SekretoError('sekreto: minivault: ' + text)
}

const IDMAX = 255

function checkid(id: string, what: string): string {
  if ('string' !== typeof id || '' === id) {
    fail(what)
  }
  if (IDMAX < Buffer.byteLength(id, 'utf8')) {
    fail('key id is longer than ' + IDMAX + ' bytes: ' + id.substring(0, 32) + '...')
  }
  return id
}



function hmac(key: Buffer, text: string): Buffer {
  return crypto().createHmac('sha256', key).update(text, 'utf8').digest()
}

function kek(passphrase: string, salt: Buffer, iters: number): Buffer {
  return crypto().pbkdf2Sync(passphrase, salt, iters, KEYLEN, 'sha256')
}

function secretkey(root: Buffer, name: string): Buffer {
  return hmac(root, AAD_SECRET + name)
}

/** Where a secret lives in the file, derived from its own key so that
 * finding it needs no plaintext name. One-way: an id yields nothing
 * about the key that produced it. */
function entryid(key: Buffer): Buffer {
  return hmac(key, LABEL_ID)
}

function random(len: number): Buffer {
  return crypto().randomBytes(len)
}



type Sealed = { iv: Buffer, blob: Buffer }

function seal(key: Buffer, plain: Buffer, aad: string): Sealed {
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
function unseal(key: Buffer, sealed: Sealed, aad: string, what: string): Buffer {
  if (sealed.blob.length < TAGLEN || IVLEN !== sealed.iv.length) {
    fail(what + ': truncated')
  }

  // The WHOLE round-trip is guarded, not only `final()`. A nonce or tag
  // of the wrong length makes the constructor itself raise, and a
  // damaged file reaching a caller as a raw RangeError is a refusal
  // nobody can act on.
  try {
    const decipher = crypto().createDecipheriv('aes-256-gcm', key, sealed.iv)
    decipher.setAAD(Buffer.from(aad, 'utf8'))
    decipher.setAuthTag(sealed.blob.subarray(sealed.blob.length - TAGLEN))

    return Buffer.concat([
      decipher.update(sealed.blob.subarray(0, sealed.blob.length - TAGLEN)),
      decipher.final(),
    ])
  } catch {
    fail(what)
  }
}

function jsonof(plain: Buffer, what: string): any {
  try {
    return JSON.parse(plain.toString('utf8'))
  } catch {
    return fail('unreadable ' + what)
  }
}

function b64(bytes: Buffer): string {
  return bytes.toString('base64')
}

function unb64(text: any, what: string): Buffer {
  if ('string' !== typeof text) {
    fail('missing ' + what)
  }
  return Buffer.from(text, 'base64')
}



type KeyRecord = { id: string, salt: Buffer, iters: number, ring: Sealed, meta: Sealed }
type EntryRecord = { id: Buffer, name: Sealed, value: Sealed }
type VaultFile = { keys: KeyRecord[], entries: EntryRecord[] }

function reader(bytes: Buffer) {
  let at = 0

  const take = (len: number): Buffer => {
    if (bytes.length < at + len) {
      fail('the vault file is truncated')
    }
    const out = Buffer.from(bytes.subarray(at, at + len))
    at += len
    return out
  }

  const u8 = (): number => take(1)[0]
  const u32 = (): number => take(4).readUInt32BE(0)
  const small = (): Buffer => take(u8())
  const large = (): Buffer => take(u32())

  return {
    u8, u32, small, large,
    magic: (): string => take(4).toString('latin1'),
    sealed: (): Sealed => ({ iv: small(), blob: large() }),
    done: (): boolean => at === bytes.length,
  }
}

function readfile(bytes: Buffer): VaultFile {
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

  const keys: KeyRecord[] = []
  const keycount = read.u32()
  for (let index = 0; index < keycount; index++) {
    const id = read.small().toString('utf8')
    const salt = read.small()
    const iters = read.u32()
    keys.push({ id, salt, iters, ring: read.sealed(), meta: read.sealed() })
  }

  const entries: EntryRecord[] = []
  const entrycount = read.u32()
  for (let index = 0; index < entrycount; index++) {
    entries.push({ id: read.small(), name: read.sealed(), value: read.sealed() })
  }

  if (!read.done()) {
    fail('the vault file has trailing bytes')
  }

  return { keys, entries }
}

function writefile(vault: VaultFile): Buffer {
  const parts: Buffer[] = []

  const u8 = (value: number) => parts.push(Buffer.from([value]))
  const u32 = (value: number) => {
    const four = Buffer.alloc(4)
    four.writeUInt32BE(value, 0)
    parts.push(four)
  }
  const small = (bytes: Buffer) => { u8(bytes.length); parts.push(bytes) }
  const large = (bytes: Buffer) => { u32(bytes.length); parts.push(bytes) }
  const sealed = (value: Sealed) => { small(value.iv); large(value.blob) }

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

  const entries = [...vault.entries].sort((left, right) => Buffer.compare(left.id, right.id))

  u32(entries.length)
  for (const entry of entries) {
    small(entry.id)
    sealed(entry.name)
    sealed(entry.value)
  }

  return Buffer.concat(parts)
}



/** A detached copy, so that what a caller is handed cannot become what
 * this vault believes. */
function copyinfo(info: VaultKeyInfo): VaultKeyInfo {
  return {
    key: info.key,
    master: info.master,
    write: info.write,
    grants: [...info.grants],
  }
}

export type VaultKeyInfo = {
  key: string
  master: boolean
  write: boolean
  grants: string[]
}

export type GrantSpec = {
  key: string
  /** Its passphrase. Nothing else unwraps it, and no master can recover
   * it - a lost restricted passphrase is re-granted, never read back. */
  passphrase: string
  /** The names it may read. A name that does not exist yet is allowed
   * and means what it says: the key reads it once a master writes it. */
  names: string[]
  write?: boolean
  iterations?: number
}

export type VaultOptions = {
  file: string
  key?: string
  passphrase: string
  iterations?: number
  /** Make the file, with this key as its master, if it is not there.
   *
   * Off by default. A missing vault is far more often a broken
   * deployment than a new one, and a store that invents itself where a
   * real vault was meant to be answers every read with a miss. */
  create?: boolean
}

export type MiniVault = {
  file: () => string
  key: () => string
  open: () => VaultKeyInfo
  close: () => void
  list: () => string[]
  has: (name: string) => boolean
  get: (name: string) => string | undefined
  set: (name: string, value: string) => void
  remove: (name: string) => void
  keys: () => VaultKeyInfo[]
  grant: (spec: GrantSpec) => void
  /** Drop a key. Master only.
   *
   * Anyone who already copied the file keeps whatever that key could
   * read, so revoking bars future reads of the LIVE file and `rotate` is
   * what takes a secret back. */
  revoke: (key: string) => void
  rotate: () => void
}



function newvault(keyid: string, passphrase: string, iterations: number): VaultFile {
  const root = random(KEYLEN)
  const salt = random(SALTLEN)

  const ring: Ring = { v: FORMAT, write: true, root: b64(root) }
  const meta: Meta = { v: FORMAT, master: true, write: true, grants: [] }

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

function putnew(file: string, vault: VaultFile): void {
  try {
    fs().writeFileSync(file, writefile(vault), { mode: 0o600, flag: 'wx' })
  } catch (err: any) {
    if ('EEXIST' === err.code) {
      fail('vault file already exists: ' + file)
    }
    fail('cannot write ' + file + ': ' + err.message)
  }
}



type Ring = { v: number, write: boolean, root?: string, grants?: Record<string, string> }

/** What a master recorded about a key when it minted it, sealed under
 * the vault's meta key so that `keys()` can answer without holding any
 * other key's passphrase. */
type Meta = { v: number, master: boolean, write: boolean, grants: string[] }

type Opened = {
  info: VaultKeyInfo
  root?: Buffer
  /** The per-name keys this key was granted. Empty for a master, which
   * derives them from the root key instead. */
  grants: Record<string, Buffer>
  /** THE SEALED RING THIS WAS DERIVED FROM, kept so that every later
   * call can check the file still says the same thing. A handle that
   * cached its keys and never looked again kept reading a vault after
   * its key was revoked, which is the one thing `revoke` promises. */
  ring: Sealed
}

function sameseal(left: Sealed, right: Sealed): boolean {
  return 0 === Buffer.compare(left.iv, right.iv) && 0 === Buffer.compare(left.blob, right.blob)
}

export function openvault(options: VaultOptions): MiniVault {
  const opts = options || ({} as VaultOptions)
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

  let opened: Opened | undefined

  const bytes = (): Buffer => {
    try {
      return fs().readFileSync(file)
    } catch (err: any) {
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

  const load = (): { vault: VaultFile, open: Opened } => {
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

    const ring: Ring = jsonof(plain, 'key ring for ' + keyid)

    const grants: Record<string, Buffer> = {}
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

  const rootof = (open: Opened, what: string): Buffer => {
    if (undefined === open.root) {
      fail(what + ' needs a master key, and ' + open.info.key + ' is restricted')
    }
    return open.root
  }

  /** The key for one name, or undefined when this key cannot reach it. */
  const keyfor = (open: Opened, name: string): Buffer | undefined => {
    if (undefined !== open.root) {
      return secretkey(open.root, name)
    }
    return open.grants[name]
  }

  const findentry = (vault: VaultFile, key: Buffer): EntryRecord | undefined => {
    const id = entryid(key)
    return vault.entries.find((entry) => 0 === Buffer.compare(entry.id, id))
  }

  const metaof = (open: Opened, record: KeyRecord): Meta | undefined => {
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

  const sealkey = (
    root: Buffer, id: string, phrase: string, iters: number, ring: Ring, meta: Meta,
  ): KeyRecord => {
    const salt = random(SALTLEN)
    return {
      id,
      salt,
      iters,
      ring: seal(kek(phrase, salt, iters), Buffer.from(JSON.stringify(ring), 'utf8'), AAD_RING + id),
      meta: seal(hmac(root, LABEL_META), Buffer.from(JSON.stringify(meta), 'utf8'), AAD_META + id),
    }
  }

  const save = (vault: VaultFile): void => {
    const node = fs()
    const temp = file + '.' + random(8).toString('hex') + '.tmp'

    try {
      node.writeFileSync(temp, writefile(vault), { mode: 0o600, flag: 'wx' })
      node.renameSync(temp, file)
    } catch (err: any) {
      try {
        node.unlinkSync(temp)
      } catch {
      }
      fail('cannot write ' + file + ': ' + err.message)
    }
  }

  const self: MiniVault = {
    file: () => file,
    key: () => keyid,

    // A COPY. `set` reads `info.write` to decide whether this key may
    // write, so handing the caller the object itself let it flip its own
    // permission: `vault.open().write = true` turned a read-only key
    // into a writing one. Authorization state does not leave this
    // closure.
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

      return open.info.grants
        .filter((name) => undefined !== findentry(vault, open.grants[name]))
        .sort()
    },

    has: (name: string) => undefined !== self.get(name),

    get: (name: string) => {
      checkname(name)
      const { vault, open } = load()

      const key = keyfor(open, name)
      if (undefined === key) {
        return undefined
      }

      const entry = findentry(vault, key)
      if (undefined === entry) {
        return undefined
      }

      return unseal(key, entry.value, AAD_SECRET + name,
        'the value of ' + name + ' is damaged').toString('utf8')
    },

    set: (name: string, value: string) => {
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
        vault.entries[at] = { id: vault.entries[at].id, name: vault.entries[at].name, value: sealedvalue }
      } else {
        // A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
        // restricted key with `write` updates what it was granted and
        // cannot grow the vault, which is what "restricted" has to mean
        // for the grant list to stay the whole story.
        const root = rootof(open, 'creating the secret ' + name)
        vault.entries.push({
          id,
          name: seal(hmac(root, LABEL_NAMES), Buffer.from(name, 'utf8'), AAD_NAME),
          value: sealedvalue,
        })
      }

      save(vault)
    },

    remove: (name: string) => {
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

    grant: (spec: GrantSpec) => {
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
      const grants: Record<string, string> = {}
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

    revoke: (key: string) => {
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

      const plain = self.list().map((name) => ({ name, value: self.get(name) as string }))

      const root = random(KEYLEN)
      const namekey = hmac(root, LABEL_NAMES)

      const entries: EntryRecord[] = plain.map((secret) => {
        const key = secretkey(root, secret.name)
        return {
          id: entryid(key),
          name: seal(namekey, Buffer.from(secret.name, 'utf8'), AAD_NAME),
          value: seal(key, Buffer.from(secret.value, 'utf8'), AAD_SECRET + secret.name),
        }
      })

      const record = vault.keys.find((k) => k.id === keyid) as KeyRecord

      const fresh = sealkey(root, keyid, passphrase, record.iters,
        { v: FORMAT, write: true, root: b64(root) },
        { v: FORMAT, master: true, write: true, grants: [] })

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
 * overwriting one discards every secret in it along with every key that
 * could read them. */
export function createvault(options: VaultOptions): MiniVault {
  const opts = options || ({} as VaultOptions)

  if ('string' !== typeof opts.file || '' === opts.file) {
    fail('a vault needs a file')
  }
  if ('string' !== typeof opts.passphrase || '' === opts.passphrase) {
    fail('a vault needs a passphrase')
  }
  checkid(opts.key || MASTERKEY, 'a vault needs a key id')

  putnew(opts.file, newvault(opts.key || MASTERKEY, opts.passphrase, opts.iterations || ITERATIONS))

  return openvault(opts)
}



export function providerof(vault: MiniVault): Provider {
  return {
    lookup: (name: string) => vault.get(name),
    describe: () => 'minivault:' + vault.file(),
  }
}

export function minivaultprovider(options: VaultOptions): Provider {
  return providerof(openvault(options))
}

function vaultoptions(spec: ProviderSpec): VaultOptions {
  return {
    file: spec.file || '',
    key: spec.vaultkey,
    passphrase: spec.passphrase || '',
    iterations: spec.iterations,
    create: true === spec.create,
  }
}



export const VAULT_EXPORT = 'vault'

export const minivault: Definition = {
  name: 'minivault',
  define: (inst: any) => {
    const options = vaultoptions(inst.options as ProviderSpec)

    try {
      // `openvault` refuses bad configuration HERE, so a mistyped chain
      // fails at construction. Reaching the FILE is not configuration:
      // the handle is lazy, and nothing is read or stretched until a
      // lookup.
      const vault = openvault(options)

      inst.export(PROVIDER_EXPORT, providerof(vault))
      inst.export(VAULT_EXPORT, vault)
    } catch (err: any) {
      if (err instanceof SekretoError) {
        throw new PluginError(ERROR_CODE, err.message, { ref: inst.ref, cause: err.message })
      }
      throw err
    }
  },
}

export function vaultof(secrets: { host: any }, store?: string): MiniVault {
  if (undefined === store) {
    const found = secrets.host.exports('minivault/' + VAULT_EXPORT)
    if (undefined === found) {
      fail('no minivault store in this chain')
    }
    return found as MiniVault
  }

  const ref = 'minivault' === store ? 'minivault' : 'minivault$' + store

  if (undefined === secrets.host.instance(ref)) {
    fail('no minivault store named ' + store + ' in this chain')
  }

  return secrets.host.exports(ref + '/' + VAULT_EXPORT) as MiniVault
}
