# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/minivault.py)
# Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""The mini vault: every secret a project owns, encrypted, in one file.

A store this library owns outright rather than a client for a server
somebody else runs. It has a master key and restricted keys, and it is the
port's worked example of a definition publishing an API beside its
provider: a chain READS, and writing is a deliberate act with an interface
of its own.

    from voxgig_sekreto import Sekreto
    from voxgig_sekreto.plugins.minivault import createvault, minivault, vaultof

    vault = createvault({'file': 'app.skmv', 'passphrase': MASTER})
    vault.set('api.token', 'tok01')
    vault.grant({'key': 'ci', 'passphrase': CI, 'names': ['api.token']})

    secrets = Sekreto({
        'plugins': [minivault],
        'providers': [{'kind': 'minivault', 'file': 'app.skmv',
                       'vaultkey': 'ci', 'passphrase': CI}],
    })

    secrets.get('api.token')            # the chain reads
    vaultof(secrets).list()             # the API writes

THE FILE FORMAT IS THE CONTRACT, and the vaults committed under
test/fixture/ pin it: a vault written by any port is read by every other.

    magic       4   'SKMV'
    version     1   FORMAT
    kdf         1   1 = PBKDF2-HMAC-SHA256
    cipher      1   1 = AES-256-GCM
    reserved    1   0
    keycount    4   uint32
    per key:
      id        1 + bytes            the key id, PLAINTEXT
      salt      1 + bytes
      iters     4                    PBKDF2 rounds for this key
      ring      1 + iv, 4 + bytes    sealed under the passphrase
      meta      1 + iv, 4 + bytes    sealed under the vault's meta key
    entrycount  4   uint32
    per entry:
      id        1 + bytes            the blinded lookup id
      name      1 + iv, 4 + bytes    sealed under the vault's name key
      value     1 + iv, 4 + bytes    sealed under that secret's own key

Integers are big-endian and every length precedes its bytes, so the file
is written with the same two primitives it is read with.

NOTHING OUTSIDE A KEY RECORD IS PLAINTEXT. Secret names are sealed, and an
entry is addressed by a blinded id derived from its own key, so a
restricted key finds what it was granted without the file ever naming the
rest. What the file does show anyone is the key ids and how many secrets
there are.

A port of typescript/plugins/minivault.ts, which is canonical.
"""

import ctypes
import ctypes.util
import hashlib
import hmac as hmaclib
import json
import os
import struct
import sys
import threading

from ...voxgig_plugin import PluginError

from ..sekreto import SekretoError, checkname
from ..providers import ERROR_CODE, PROVIDER_EXPORT, Provider

MAGIC = b'SKMV'
FORMAT = 1

KDF_PBKDF2 = 1
CIPHER_AESGCM = 1

# AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
KEYLEN = 32
IVLEN = 12
TAGLEN = 16
SALTLEN = 16

#: The PBKDF2-HMAC-SHA256 round count when a caller names none.
ITERATIONS = 210000

#: The key id a vault gets when a caller names none.
MASTERKEY = 'master'

#: The export key the vault API is published under, beside the provider.
VAULT_EXPORT = 'vault'

# Additional authenticated data. Every blob is bound to its PLACE in the
# file, so no ciphertext can be moved: a restricted key's ring cannot be
# relabelled as the master's, and one secret's value cannot be served under
# a name it was never written for.
AAD_RING = 'skmv1:ring:'
AAD_META = 'skmv1:meta:'
AAD_NAME = 'skmv1:name'
AAD_SECRET = 'skmv1:secret:'

# Everything a master reaches is derived from the root key, so rotating is
# one new random value rather than a re-wrap of each part.
LABEL_NAMES = 'skmv1:names'
LABEL_META = 'skmv1:meta'
LABEL_ID = 'skmv1:id'


def _fail(text):
    raise SekretoError('sekreto: minivault: ' + text)


#: The largest key id the format can record.
#:
#: A length is written in ONE byte. A longer id wraps that byte and the
#: writer then appends the whole thing, so every field after it shifts: a
#: grant with a 300-character id would replace a working vault with an
#: unreadable one, and say nothing. Checked where an id is ACCEPTED, so the
#: refusal names the id rather than the file.
IDMAX = 255


def _checkid(held, what):
    if not held:
        _fail(what)
    if IDMAX < len(held.encode('utf-8')):
        _fail('key id is longer than %d bytes: %s...' % (IDMAX, held[:32]))
    return held


# --- the primitives --------------------------------------------------
#
# THREE OF THE FOUR ARE IN THE STANDARD LIBRARY. `hashlib.pbkdf2_hmac`,
# `hmac` over `hashlib.sha256` and `os.urandom` are all stdlib, so the
# whole of the binding below exists for the fourth: AES-256-GCM, which
# python has no interface to at all.
#
# IT COMES FROM THE LIBCRYPTO CPYTHON ALREADY LOADS. `import ssl` links
# OpenSSL into this process - it is what `urllib` speaks HTTPS through, and
# what the HTTP plugins in this same folder already depend on - so calling
# its AEAD is the audited-library half of the dependency rule rather than a
# new package. The alternative was a pure-python AES, which is exactly what
# the rule exists to forbid: a table-driven cipher passes every
# known-answer test in the world and still hands its key to anyone who can
# time a cache.
#
# The whole surface is five EVP calls. This module NEVER hand-rolls a
# primitive and never falls back to one: where libcrypto cannot be found,
# the vault refuses and says so.

_CRYPTO = None
_CRYPTOLOCK = threading.Lock()

_SET_IVLEN = 0x9
_GET_TAG = 0x10
_SET_TAG = 0x11


def _libcrypto():
    """The OpenSSL `ssl` is already using, or a refusal.

    Looked up in three places because one is not enough anywhere but
    Linux. `find_library` reads the loader's own search path and answers
    for a distribution install; CPython on Windows ships `libcrypto-3.dll`
    beside `_ssl`, and a macOS build from python.org bundles its
    `libcrypto.*.dylib` in the same directory. Importing `ssl` first is
    what makes the second two true: the library is in the process either
    way, and this only has to name the file it came from.
    """
    global _CRYPTO

    with _CRYPTOLOCK:
        if None is not _CRYPTO:
            return _CRYPTO

        import ssl  # noqa: F401  (loads libcrypto into this process)

        tried = []

        # APPLE'S /usr/lib/libcrypto.dylib IS A TRAP, AND IT MUST NOT BE
        # TRIED. It is a compatibility stub: loading it directly prints
        # "loading libcrypto in an unsafe way" and calls abort(). That is a
        # SIGABRT, not an exception, so the `except OSError: continue`
        # below never runs and the whole process dies — `make test` here
        # ended at `Abort trap: 6` on the first vault case.
        #
        # `find_library('crypto')` returns exactly that path on macOS, so
        # it cannot be the first thing attempted, and on Darwin it cannot
        # be attempted at all. Homebrew's openssl@3 is the real library a
        # mac usually has, and it is named explicitly because it is not on
        # the loader's default search path.
        darwin = 'darwin' == sys.platform

        found = ctypes.util.find_library('crypto')
        if found and not (darwin and found.startswith('/usr/lib/')):
            tried.append(found)

        # A statically linked CPython (uv's, python.org's recent builds)
        # has no `_ssl.__file__` at all, so this finds nothing and the list
        # below is the only thing standing between a mac and a refusal.
        try:
            import _ssl
            beside = os.path.dirname(getattr(_ssl, '__file__', '') or '')
            if beside:
                for name in sorted(os.listdir(beside)):
                    low = name.lower()
                    if low.startswith(('libcrypto', 'crypto')) and (
                        low.endswith(('.so', '.dylib', '.dll')) or '.so.' in low
                    ):
                        tried.append(os.path.join(beside, name))
        except Exception:
            pass

        if darwin:
            # Homebrew on both architectures, then MacPorts. A bare
            # `libcrypto.dylib` is deliberately NOT in this list: the
            # loader would resolve it to /usr/lib and abort.
            tried.extend([
                '/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib',
                '/opt/homebrew/opt/openssl@1.1/lib/libcrypto.dylib',
                '/usr/local/opt/openssl@3/lib/libcrypto.dylib',
                '/usr/local/opt/openssl@1.1/lib/libcrypto.dylib',
                '/opt/local/lib/libcrypto.dylib',
            ])
        else:
            tried.extend(['libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so',
                          'libcrypto.dylib', 'libcrypto-3-x64.dll',
                          'libcrypto-3.dll'])

        for name in tried:
            try:
                lib = ctypes.CDLL(name)
                if not hasattr(lib, 'EVP_aes_256_gcm'):
                    continue
            except OSError:
                continue

            lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
            lib.EVP_aes_256_gcm.restype = ctypes.c_void_p
            lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]

            _CRYPTO = lib
            return _CRYPTO

        _fail('no AES-256-GCM available: this python cannot reach a libcrypto')


def _context():
    made = _libcrypto().EVP_CIPHER_CTX_new()
    if not made:
        _fail('cannot seal')
    return ctypes.c_void_p(made)


def _mac(key, text):
    return hmaclib.new(key, text.encode('utf-8'), hashlib.sha256).digest()


def _kek(passphrase, salt, iters):
    """The key-encryption key a passphrase unwraps a ring with."""
    if 1 > iters:
        _fail('unusable round count: %d' % iters)
    return hashlib.pbkdf2_hmac('sha256', passphrase.encode('utf-8'), salt, iters, KEYLEN)


def _secretkey(root, name):
    """The key one named secret's value is encrypted with.

    DERIVED, never stored, for a master: it holds the root key and so
    reaches every name, including ones written after it was made. A
    restricted key holds the derived keys it was granted and nothing that
    produces another, so every other name is ciphertext to it in exactly
    the way it is to a stranger.
    """
    return _mac(root, AAD_SECRET + name)


def _entryid(key):
    """Where a secret lives in the file, derived from its own key so that
    finding it needs no plaintext name. One-way: an id yields nothing about
    the key that produced it."""
    return _mac(key, LABEL_ID)


def _random(length):
    return os.urandom(length)


def _seal(key, plain, aad):
    """Ciphertext followed by the 16-byte tag, which is where every other
    port's AEAD leaves it and therefore what the format records."""
    if KEYLEN != len(key):
        _fail('bad key')

    lib = _libcrypto()
    iv = _random(IVLEN)
    ctx = _context()
    aad = aad.encode('utf-8')

    try:
        out = ctypes.create_string_buffer(len(plain) + TAGLEN)
        moved = ctypes.c_int()

        lib.EVP_EncryptInit_ex(ctx, ctypes.c_void_p(lib.EVP_aes_256_gcm()), None, None, None)
        lib.EVP_CIPHER_CTX_ctrl(ctx, _SET_IVLEN, IVLEN, None)
        lib.EVP_EncryptInit_ex(ctx, None, None, key, iv)
        lib.EVP_EncryptUpdate(ctx, None, ctypes.byref(moved), aad, len(aad))

        if 1 != lib.EVP_EncryptUpdate(ctx, out, ctypes.byref(moved), plain, len(plain)):
            _fail('cannot seal')
        body = out.raw[:moved.value]

        if 1 != lib.EVP_EncryptFinal_ex(ctx, out, ctypes.byref(moved)):
            _fail('cannot seal')
        body += out.raw[:moved.value]

        tag = ctypes.create_string_buffer(TAGLEN)
        if 1 != lib.EVP_CIPHER_CTX_ctrl(ctx, _GET_TAG, TAGLEN, tag):
            _fail('cannot seal')

        return {'iv': iv, 'blob': body + tag.raw[:TAGLEN]}
    finally:
        lib.EVP_CIPHER_CTX_free(ctx)


def _unseal(key, box, aad, what):
    """The plaintext, or a refusal.

    A GCM tag that fails to verify is the only evidence there is, and it
    cannot tell a wrong passphrase from a damaged file, so `what` names the
    attempt and the message admits both.
    """
    if len(box['blob']) < TAGLEN or IVLEN != len(box['iv']):
        _fail(what + ': truncated')
    if KEYLEN != len(key):
        _fail('bad key')

    lib = _libcrypto()
    body, tag = box['blob'][:-TAGLEN], box['blob'][-TAGLEN:]
    ctx = _context()
    aad = aad.encode('utf-8')

    try:
        out = ctypes.create_string_buffer(len(body) + TAGLEN)
        moved = ctypes.c_int()

        lib.EVP_DecryptInit_ex(ctx, ctypes.c_void_p(lib.EVP_aes_256_gcm()), None, None, None)
        lib.EVP_CIPHER_CTX_ctrl(ctx, _SET_IVLEN, IVLEN, None)
        lib.EVP_DecryptInit_ex(ctx, None, None, key, box['iv'])
        lib.EVP_DecryptUpdate(ctx, None, ctypes.byref(moved), aad, len(aad))

        lib.EVP_DecryptUpdate(ctx, out, ctypes.byref(moved), body, len(body))
        plain = out.raw[:moved.value]

        lib.EVP_CIPHER_CTX_ctrl(ctx, _SET_TAG, TAGLEN, tag)
        if 0 >= lib.EVP_DecryptFinal_ex(ctx, out, ctypes.byref(moved)):
            _fail(what)

        return plain
    finally:
        lib.EVP_CIPHER_CTX_free(ctx)


def _b64(raw):
    import base64
    return base64.b64encode(raw).decode('ascii')


def _unb64(text, what):
    """STRICT. A lenient decoder hands back plausible bytes for a corrupted
    payload, and those bytes are then used AS A KEY."""
    import base64
    import binascii

    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError, TypeError):
        _fail('missing ' + what)


def _dumps(value):
    """The compact JSON every port writes.

    SEPARATORS, EXPLICITLY. `json.dumps` puts a space after each comma and
    colon by default, where every other port's encoder writes none - and a
    ring is SEALED, so the difference is not cosmetic: it changes the
    ciphertext length, and a vault written here would be a different size
    from the same vault written anywhere else. The fixtures under
    test/fixture are all the same length, which is what catches this.
    """
    return json.dumps(value, separators=(',', ':'))


def _jsonof(plain, what):
    try:
        return json.loads(plain.decode('utf-8'))
    except (ValueError, UnicodeDecodeError):
        _fail('unreadable ' + what)


# --- the file --------------------------------------------------------


class _Reader:
    """A cursor, so that every length check is in one place: a truncated
    vault is refused rather than read as a short one."""

    def __init__(self, raw):
        self.raw = raw
        self.at = 0

    def take(self, length):
        """Reads `length` bytes, or refuses.

        The bound is checked AGAINST WHAT IS LEFT, never by adding the
        length to the cursor: python's integers cannot wrap, but the check
        reads the same in every port and is the one that is right
        everywhere.
        """
        if len(self.raw) - self.at < length:
            _fail('the vault file is truncated')
        out = self.raw[self.at:self.at + length]
        self.at += length
        return out

    def u8(self):
        return self.take(1)[0]

    def u32(self):
        return struct.unpack('>I', self.take(4))[0]

    def small(self):
        return self.take(self.u8())

    def large(self):
        return self.take(self.u32())

    def sealed(self):
        return {'iv': self.small(), 'blob': self.large()}


def readfile(raw):
    read = _Reader(raw)

    if MAGIC != read.take(4):
        _fail('not a vault file')

    version = read.u8()
    if FORMAT != version:
        _fail('unsupported format version: %d' % version)

    kdf = read.u8()
    cipher = read.u8()
    if KDF_PBKDF2 != kdf or CIPHER_AESGCM != cipher:
        _fail('unsupported kdf or cipher: %d/%d' % (kdf, cipher))
    read.u8()

    out = {'keys': [], 'entries': []}

    # A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a
    # few bytes, so a file claiming four billion of them is damaged; the
    # loop would find that out one truncation at a time, and a caller that
    # preallocated would not.
    keycount = read.u32()
    if len(raw) - read.at < keycount:
        _fail('the vault file is truncated')

    for _ in range(keycount):
        out['keys'].append({
            'id': read.small().decode('utf-8', 'replace'),
            'salt': read.small(),
            'iters': read.u32(),
            'ring': read.sealed(),
            'meta': read.sealed(),
        })

    entrycount = read.u32()
    if len(raw) - read.at < entrycount:
        _fail('the vault file is truncated')

    for _ in range(entrycount):
        out['entries'].append({
            'id': read.small(),
            'name': read.sealed(),
            'value': read.sealed(),
        })

    if read.at != len(raw):
        _fail('the vault file has trailing bytes')

    return out


def writefile(vault):
    out = bytearray(MAGIC)
    out.append(FORMAT)
    out.append(KDF_PBKDF2)
    out.append(CIPHER_AESGCM)
    out.append(0)

    def small(value):
        out.append(len(value))
        out.extend(value)

    def large(value):
        out.extend(struct.pack('>I', len(value)))
        out.extend(value)

    def sealed(value):
        small(value['iv'])
        large(value['blob'])

    out.extend(struct.pack('>I', len(vault['keys'])))
    for record in vault['keys']:
        small(record['id'].encode('utf-8'))
        small(record['salt'])
        out.extend(struct.pack('>I', record['iters']))
        sealed(record['ring'])
        sealed(record['meta'])

    # SORTED BY ID, which is a blinded value: the file therefore records
    # nothing about the order secrets were written in.
    entries = sorted(vault['entries'], key=lambda record: record['id'])

    out.extend(struct.pack('>I', len(entries)))
    for record in entries:
        small(record['id'])
        sealed(record['name'])
        sealed(record['value'])

    return bytes(out)


def _keyrecord(vault, held):
    for record in vault['keys']:
        if held == record['id']:
            return record
    return None


def _entryrecord(vault, held):
    for record in vault['entries']:
        if held == record['id']:
            return record
    return None


def _sameseal(left, right):
    return left['iv'] == right['iv'] and left['blob'] == right['blob']


# --- the file on disk ------------------------------------------------


def _spill(path, raw):
    """Writes bytes to a path that is not there yet, and REFUSES one that
    is.

    `O_EXCL` refuses an existing path in ONE syscall and will not follow a
    symlink to make one, and the mode goes on AT CREATION rather than
    after: a chmod once the bytes are written leaves the file readable for
    as long as it takes to write them.

    Raises OSError. Both callers turn that into a refusal naming the VAULT
    file, which is the path a caller configured - not the temporary this
    one happens to be writing.
    """
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, 'O_BINARY'):
        flags |= os.O_BINARY

    with os.fdopen(os.open(path, flags, 0o600), 'wb') as out:
        out.write(raw)


def _putnew(path, made):
    """Writes a vault file that is not there yet, and REFUSES one that is."""
    try:
        _spill(path, writefile(made))
    except FileExistsError:
        _fail('vault file already exists: ' + path)
    except OSError as err:
        _fail('cannot write ' + path + ': ' + str(err))


def _readmaybe(path):
    try:
        with open(path, 'rb') as held:
            return held.read()
    except FileNotFoundError:
        return None
    except OSError as err:
        _fail('cannot read ' + path + ': ' + str(err))


# --- the lock every handle on one file shares ------------------------
#
# Each MiniVault is its own object, so two handles on one path did not
# coordinate: both could finish `_load` before either saved, and the second
# rename then discarded the first one's change while reporting success.
# Keyed by the ABSOLUTE path, so two handles spelled differently still
# meet.
#
# THE GIL DOES NOT MAKE THIS SAFE. It is released around every file read
# and write, which is exactly where the two handles interleave. A
# guarantee WITHIN one process, which is what DOCS.md promises and what the
# go port arranges the same way; two processes still race, and the format's
# answer to that is the exclusive create and the atomic rename.

_LOCKS = {}
_LOCKSLOCK = threading.Lock()


def _lockfor(path):
    try:
        key = os.path.abspath(path)
    except OSError:
        key = path

    with _LOCKSLOCK:
        one = _LOCKS.get(key)
        if None is one:
            one = threading.RLock()
            _LOCKS[key] = one
        return one


# --- creating --------------------------------------------------------


def _newvault(keyid, passphrase, iterations):
    """A new vault: one master key, no secrets."""
    root = _random(KEYLEN)
    salt = _random(SALTLEN)

    ring = {'v': FORMAT, 'write': True, 'root': _b64(root)}
    meta = {'v': FORMAT, 'master': True, 'write': True, 'grants': []}

    return {
        'keys': [{
            'id': keyid,
            'salt': salt,
            'iters': iterations,
            'ring': _seal(_kek(passphrase, salt, iterations),
                          _dumps(ring).encode('utf-8'), AAD_RING + keyid),
            'meta': _seal(_mac(root, LABEL_META),
                          _dumps(meta).encode('utf-8'), AAD_META + keyid),
        }],
        'entries': [],
    }


def _sealkey(root, keyid, passphrase, iters, ring, meta):
    """One key record: the ring sealed under the passphrase, the metadata
    sealed under the vault's meta key."""
    salt = _random(SALTLEN)

    return {
        'id': keyid,
        'salt': salt,
        'iters': iters,
        'ring': _seal(_kek(passphrase, salt, iters),
                      _dumps(ring).encode('utf-8'), AAD_RING + keyid),
        'meta': _seal(_mac(root, LABEL_META),
                      _dumps(meta).encode('utf-8'), AAD_META + keyid),
    }


def _wantkey(held):
    """AN EMPTY KEY IS NO KEY, so it means `master`.

    `held or MASTERKEY` would do it, and says less about why: a CLI
    reaches here with SEKRETO_VAULT_KEY set and empty, which is what an
    unset shell variable expands to, and an empty id is not a key anyone
    could have granted.
    """
    return MASTERKEY if not held else held


def _copyinfo(info):
    """A detached copy, so that what a caller is handed cannot become what
    this vault believes."""
    return {
        'key': info['key'],
        'master': info['master'],
        'write': info['write'],
        'grants': list(info['grants']),
    }


# --- the vault -------------------------------------------------------


class MiniVault:
    """A handle on one vault file, opened as ONE key.

    Every method answers as that key: `list` shows the names it may read,
    `get` answers for those and misses on the rest, and the master-only
    methods refuse for any other key. Nothing is read or derived until the
    first call that needs the file.
    """

    def __init__(self, options=None):
        opts = options or {}

        self._file = opts.get('file')
        self._keyid = _wantkey(opts.get('key'))
        self._passphrase = opts.get('passphrase')
        self._iterations = opts.get('iterations') or ITERATIONS
        self._create = True is opts.get('create')

        if not isinstance(self._file, str) or not self._file:
            _fail('a vault needs a file')
        if not isinstance(self._passphrase, str) or not self._passphrase:
            _fail('a vault needs a passphrase')
        _checkid(self._keyid, 'a vault needs a key id')

        self._opened = None

    @property
    def file(self):
        """The file this handle reads."""
        return self._file

    @property
    def key(self):
        """The key id this handle opens with."""
        return self._keyid

    def open(self):
        """Derive the key and read the file NOW rather than at first use."""
        return _copyinfo(self._load()[1]['info'])

    def close(self):
        """Forget the derived keys. The next call opens again."""
        self._opened = None

    def list(self):
        """The names this key can read, sorted."""
        vault, opened = self._load()

        if None is not opened['root']:
            namekey = _mac(opened['root'], LABEL_NAMES)
            return sorted(
                _unseal(namekey, record['name'], AAD_NAME,
                        'a secret name is damaged').decode('utf-8')
                for record in vault['entries']
            )

        # A restricted key has no name key, so it reports the grants it can
        # actually find: the vault never tells it what else is in there.
        return sorted(
            name for name in opened['info']['grants']
            if None is not self._findentry(vault, opened['grants'].get(name))
        )

    def has(self, name):
        return None is not self.get(name)

    def get(self, name):
        """The value, or None when the vault does not hold that name or
        this key was not granted it."""
        checkname(name)
        vault, opened = self._load()

        key = self._keyfor(opened, name)
        # OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as
        # the key that opened it, so a name this key cannot read is a name
        # this store does not hold for this caller.
        if None is key:
            return None

        entry = self._findentry(vault, key)
        if None is entry:
            return None

        return _unseal(key, entry['value'], AAD_SECRET + name,
                       'the value of ' + name + ' is damaged').decode('utf-8')

    def set(self, name, value):
        """Write a value. A master writes any name; a restricted key
        holding `write` overwrites the names it was granted, and creates
        none."""
        # Every write on this file, from any handle in this process,
        # serializes here; see _lockfor.
        with _lockfor(self._file):
            checkname(name)
            if not isinstance(value, str):
                _fail('a secret value must be text: ' + name)

            vault, opened = self._load()

            if not opened['info']['write']:
                _fail('key ' + opened['info']['key'] + ' is read-only')

            key = self._keyfor(opened, name)
            if None is key:
                _fail('key ' + opened['info']['key'] + ' was not granted ' + name)

            sealedvalue = _seal(key, value.encode('utf-8'), AAD_SECRET + name)
            entry = _entryrecord(vault, _entryid(key))

            if None is not entry:
                entry['value'] = sealedvalue
            else:
                # A NEW NAME NEEDS THE NAME KEY, which only a master holds.
                # So a restricted key with `write` updates what it was
                # granted and cannot grow the vault.
                root = self._rootof(opened, 'creating the secret ' + name)
                vault['entries'].append({
                    'id': _entryid(key),
                    'name': _seal(_mac(root, LABEL_NAMES),
                                  name.encode('utf-8'), AAD_NAME),
                    'value': sealedvalue,
                })

            self._save(vault)

    def remove(self, name):
        """Drop a name. Master only."""
        # Every write on this file, from any handle in this process,
        # serializes here; see _lockfor.
        with _lockfor(self._file):
            checkname(name)
            vault, opened = self._load()
            root = self._rootof(opened, 'removing a secret')

            wanted = _entryid(_secretkey(root, name))
            entry = _entryrecord(vault, wanted)
            if None is entry:
                _fail('no such secret: ' + name)

            vault['entries'] = [one for one in vault['entries'] if wanted != one['id']]
            self._save(vault)

    def keys(self):
        """Every key in the file, with what it may do. Master only."""
        vault, opened = self._load()
        self._rootof(opened, 'listing the keys')

        out = []
        for record in vault['keys']:
            meta = self._metaof(opened, record)
            if None is meta:
                out.append({'key': record['id'], 'master': False,
                            'write': False, 'grants': []})
            else:
                out.append({
                    'key': record['id'],
                    'master': True is meta.get('master'),
                    'write': True is meta.get('write'),
                    'grants': sorted(meta.get('grants') or []),
                })
        return out

    def grant(self, spec=None):
        """Mint a restricted key. Master only."""
        # Every write on this file, from any handle in this process,
        # serializes here; see _lockfor.
        with _lockfor(self._file):
            vault, opened = self._load()
            root = self._rootof(opened, 'granting a key')

            spec = spec or {}
            _checkid(spec.get('key'), 'a grant needs a key id')
            if not isinstance(spec.get('passphrase'), str) or not spec['passphrase']:
                _fail('a grant needs a passphrase')
            if None is not _keyrecord(vault, spec['key']):
                _fail('key already exists: ' + spec['key'])

            names = sorted(spec.get('names') or [])
            grants = {}
            for name in names:
                checkname(name)
                grants[name] = _b64(_secretkey(root, name))

            write = True is spec.get('write')
            vault['keys'].append(_sealkey(
                root, spec['key'], spec['passphrase'],
                spec.get('iterations') or self._iterations,
                # GRANTS IS ALWAYS THERE, even granted nothing. A ring
                # without it is a MASTER's ring in every port's reader, so
                # dropping the empty map would be a key that reads the
                # whole vault.
                {'v': FORMAT, 'write': write, 'grants': grants},
                {'v': FORMAT, 'master': False, 'write': write, 'grants': names}))

            self._save(vault)

    def revoke(self, key):
        """Drop a key. Master only.

        Anyone who already copied the file keeps whatever that key could
        read, so revoking bars future reads of the LIVE file and `rotate`
        is what takes a secret back.
        """
        # Every write on this file, from any handle in this process,
        # serializes here; see _lockfor.
        with _lockfor(self._file):
            vault, opened = self._load()
            self._rootof(opened, 'revoking a key')

            if key == opened['info']['key']:
                _fail('a key cannot revoke itself: ' + key)
            if None is _keyrecord(vault, key):
                _fail('no such key: ' + key)

            vault['keys'] = [one for one in vault['keys'] if key != one['id']]
            self._save(vault)

    def rotate(self):
        """A new root key, every value re-encrypted under it, and EVERY
        OTHER KEY DROPPED. Master only.

        The other keys go because they must: their rings are sealed under
        passphrases this process does not have. Re-grant afterwards.
        """
        # Every write on this file, from any handle in this process,
        # serializes here; see _lockfor.
        with _lockfor(self._file):
            vault, opened = self._load()
            self._rootof(opened, 'rotating the vault')

            # Read everything out under the old root before anything
            # changes: once the root is replaced the old derived keys are
            # unreachable.
            plain = [(name, self.get(name)) for name in self.list()]

            root = _random(KEYLEN)
            namekey = _mac(root, LABEL_NAMES)

            entries = []
            for name, value in plain:
                key = _secretkey(root, name)
                entries.append({
                    'id': _entryid(key),
                    'name': _seal(namekey, name.encode('utf-8'), AAD_NAME),
                    'value': _seal(key, value.encode('utf-8'), AAD_SECRET + name),
                })

            record = _keyrecord(vault, self._keyid)
            fresh = _sealkey(root, self._keyid, self._passphrase, record['iters'],
                             {'v': FORMAT, 'write': True, 'root': _b64(root)},
                             {'v': FORMAT, 'master': True, 'write': True, 'grants': []})

            # SAVE FIRST, adopt second. A handle holding the new root over
            # a file that still holds the old one reads nothing and says
            # the vault is damaged, which is the wrong story about a failed
            # write.
            self._save({'keys': [fresh], 'entries': entries})

            self._opened = {
                'info': {'key': self._keyid, 'master': True, 'write': True, 'grants': []},
                'root': root,
                'grants': {},
                'ring': fresh['ring'],
            }

    # --- inside ------------------------------------------------------

    def _bytes(self):
        raw = _readmaybe(self._file)
        if None is not raw:
            return raw

        # A vault is configured deliberately, with a key. Its absence is a
        # broken deployment and never "no secrets here": answering a miss
        # would send the chain on to a weaker store.
        if not self._create:
            _fail('no vault file: ' + self._file)

        _putnew(self._file, _newvault(self._keyid, self._passphrase, self._iterations))

        raw = _readmaybe(self._file)
        if None is raw:
            _fail('cannot read ' + self._file)
        return raw

    def _load(self):
        vault = readfile(self._bytes())
        record = _keyrecord(vault, self._keyid)

        if None is record:
            # REVOKED, or never there. Either way this handle is finished,
            # and dropping what it derived is what stops the next call
            # answering from memory.
            self._opened = None
            _fail('no such key: ' + self._keyid)

        # The file still holds this key, and holds the SAME ring: a key
        # revoked and re-granted under another passphrase is a different
        # key wearing the id, and re-deriving is what refuses it.
        if None is not self._opened and _sameseal(self._opened['ring'], record['ring']):
            return vault, self._opened

        self._opened = None

        plain = _unseal(
            _kek(self._passphrase, record['salt'], record['iters']),
            record['ring'], AAD_RING + self._keyid,
            'wrong passphrase for key ' + self._keyid + ', or a damaged vault')

        ring = _jsonof(plain, 'key ring for ' + self._keyid)

        grants = {}
        for name, key in (ring.get('grants') or {}).items():
            grants[name] = _unb64(key, 'a granted key')

        root = ring.get('root')
        self._opened = {
            'info': {
                'key': self._keyid,
                'master': None is not root,
                'write': None is not root or True is ring.get('write'),
                'grants': sorted(grants.keys()),
            },
            'root': None if None is root else _unb64(root, 'the root key'),
            'grants': grants,
            'ring': record['ring'],
        }

        return vault, self._opened

    def _rootof(self, opened, what):
        if None is opened['root']:
            _fail(what + ' needs a master key, and ' + opened['info']['key'] +
                  ' is restricted')
        return opened['root']

    def _keyfor(self, opened, name):
        """The key for one name, or None when this key cannot reach it."""
        if None is not opened['root']:
            return _secretkey(opened['root'], name)
        return opened['grants'].get(name)

    def _findentry(self, vault, key):
        if None is key:
            return None
        return _entryrecord(vault, _entryid(key))

    def _metaof(self, opened, record):
        root = self._rootof(opened, 'reading key metadata')
        what = 'metadata for key ' + record['id']

        try:
            return _jsonof(
                _unseal(_mac(root, LABEL_META), record['meta'],
                        AAD_META + record['id'], what),
                what)
        except SekretoError:
            # A record written under a root key this one has replaced. The
            # key is still in the file and still opens with its own
            # passphrase, so it is reported rather than hidden - with what
            # it can do unknown.
            return None

    def _save(self, vault):
        """Read, change, and REPLACE - never edit in place.

        THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a
        name anyone can predict, so anyone who can write the vault's
        directory could put a symlink there and have the next save
        truncate whatever it pointed at.
        """
        temp = self._file + '.' + _random(8).hex() + '.tmp'

        try:
            _spill(temp, writefile(vault))
            os.replace(temp, self._file)
        except OSError as err:
            try:
                os.unlink(temp)
            except OSError:
                # The vault is unchanged either way, and the write error is
                # what the caller needs to be told about.
                pass
            _fail('cannot write ' + self._file + ': ' + str(err))


def openvault(options):
    """Open a vault file as one key.

    The handle is lazy. Nothing is read, and no passphrase is stretched,
    until a method needs the file.
    """
    return MiniVault(options)


def createvault(options):
    """Make a vault file and return a handle on its master key.

    Refuses a file that is already there: a vault is created once, and
    overwriting one discards every secret in it.
    """
    opts = options or {}

    file = opts.get('file')
    passphrase = opts.get('passphrase')

    if not isinstance(file, str) or not file:
        _fail('a vault needs a file')
    if not isinstance(passphrase, str) or not passphrase:
        _fail('a vault needs a passphrase')

    keyid = _checkid(_wantkey(opts.get('key')), 'a vault needs a key id')

    # No existence check first: the check and the write would be two steps,
    # and `_putnew` refuses an existing file in ONE.
    _putnew(file, _newvault(keyid, passphrase, opts.get('iterations') or ITERATIONS))

    return openvault(opts)


# --- the provider ----------------------------------------------------


class MiniVaultProvider(Provider):
    """Read a vault as one store in a chain.

    The provider is the READ half and nothing more: a chain resolves
    secrets, and writing one is a deliberate act with an API of its own.
    """

    def __init__(self, vault):
        self.vault = vault

    def lookup(self, name):
        return self.vault.get(name)

    def describe(self):
        return 'minivault:' + self.vault.file


def minivaultprovider(options):
    """A vault provider from options, for a chain built by hand."""
    return MiniVaultProvider(openvault(options))


def minivaultoptions(spec):
    """The vault options a provider spec describes."""
    return {
        'file': spec.get('file') or '',
        'key': spec.get('vaultkey'),
        'passphrase': spec.get('passphrase') or '',
        'iterations': spec.get('iterations'),
        'create': True is spec.get('create'),
    }


def vaultof(secrets, store=None):
    """The vault behind a store in a chain, as its programmatic API.

    With no store named, the unqualified alias answers: one vault in the
    chain resolves whatever it is called, and two raise rather than
    picking one.
    """
    if None is store:
        found = secrets.host.exports('minivault/' + VAULT_EXPORT)
        if None is found:
            _fail('no minivault store in this chain')
        return found

    # A NAMED STORE MUST EXIST, and the alias must not stand in for it.
    # `host.exports` falls back to the alias when the exact ref misses, so
    # asking for `minivault` in a chain whose only vault is named `app`
    # used to hand back the `app` vault - and then write to it. Naming a
    # store that is not there raises, which is the rule the whole library
    # follows: `try` already means "may not have it", so it cannot also
    # mean "may not exist".
    ref = 'minivault' if 'minivault' == store else 'minivault$' + store

    if None is secrets.host.instance(ref):
        _fail('no minivault store named ' + store + ' in this chain')

    return secrets.host.exports(ref + '/' + VAULT_EXPORT)


def _define(inst):
    options = minivaultoptions(inst.options or {})

    try:
        # `openvault` refuses bad configuration HERE, so a mistyped chain
        # fails at construction. Reaching the FILE is not configuration:
        # the handle is lazy.
        vault = openvault(options)
    except SekretoError as err:
        raise PluginError(ERROR_CODE, str(err), {'ref': inst.ref, 'cause': str(err)})

    inst.export(PROVIDER_EXPORT, MiniVaultProvider(vault))
    inst.export(VAULT_EXPORT, vault)


# The plugin: the `minivault` provider kind, as a voxgig/plugin definition.
#
# Written out rather than built by `providerplugin`, because this
# definition publishes TWO exports: `provider`, the read half every kind
# publishes, and `vault`, the programmatic API.
minivault = {'name': 'minivault', 'define': _define}
