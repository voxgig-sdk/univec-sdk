<?php
// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (php/plugins/minivault.php)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * The mini vault, as a voxgig/plugin definition.
 *
 * A port of typescript/plugins/minivault.ts, which is canonical.
 *
 * A PLUGIN, not a built-in: it needs crypto, which is the line the four
 * built-ins stay behind.
 *
 * THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
 * every name and mints restricted keys. A restricted key reads the names
 * it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
 * cryptography rather than a check this code performs. What that does and
 * does not protect is set out in DOCS.md under "What the mini vault
 * protects".
 *
 * ext-openssl and ext-hash carry all four primitives, so nothing here is
 * hand-rolled (AGENTS.md rule 3).
 */

declare(strict_types=1);

namespace Voxgig\Sekreto\Plugins;

require_once __DIR__ . '/../src/Providers.php';

use Voxgig\Plugin\PluginError;
use Voxgig\Plugin\Inst;
use Voxgig\Sekreto\Name;
use Voxgig\Sekreto\Provider;
use Voxgig\Sekreto\SekretoError;

use const Voxgig\Sekreto\ERROR_CODE;
use const Voxgig\Sekreto\PROVIDER_EXPORT;

/*
 * --- the format ------------------------------------------------------
 *
 *   magic       4   'SKMV'
 *   version     1   FORMAT
 *   kdf         1   1 = PBKDF2-HMAC-SHA256
 *   cipher      1   1 = AES-256-GCM
 *   reserved    1   0
 *   keycount    4   uint32
 *   per key:
 *     id        1 + bytes      the key id, PLAINTEXT
 *     salt      1 + bytes
 *     iters     4              PBKDF2 rounds for this key
 *     ring      1 + iv, 4 + bytes    sealed under the passphrase
 *     meta      1 + iv, 4 + bytes    sealed under the vault's meta key
 *   entrycount  4   uint32
 *   per entry:
 *     id        1 + bytes      the blinded lookup id
 *     name      1 + iv, 4 + bytes    sealed under the vault's name key
 *     value     1 + iv, 4 + bytes    sealed under that secret's own key
 *
 * Integers are big-endian, and every length precedes its bytes. A file
 * one port writes is read by every other; `test/fixture` pins that with a
 * committed vault rather than with agreement.
 */

const MV_MAGIC = 'SKMV';
const MV_FORMAT = 1;
const MV_KDF_PBKDF2 = 1;
const MV_CIPHER_AESGCM = 1;

/** AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags. */
const MV_KEYLEN = 32;
const MV_IVLEN = 12;
const MV_TAGLEN = 16;
const MV_SALTLEN = 16;

/** PBKDF2-HMAC-SHA256 rounds when a caller names none. */
const MV_ITERATIONS = 210000;

/** The key id a vault gets when a caller names none. */
const MV_MASTERKEY = 'master';

/*
 * Additional authenticated data. Every blob is bound to its PLACE in the
 * file, so no ciphertext can be moved.
 */
const MV_AAD_RING = 'skmv1:ring:';
const MV_AAD_META = 'skmv1:meta:';
const MV_AAD_NAME = 'skmv1:name';
const MV_AAD_SECRET = 'skmv1:secret:';

/*
 * Everything a master can reach is derived from the root key, so a
 * rotation is one new random value rather than a re-wrap of each part.
 */
const MV_LABEL_NAMES = 'skmv1:names';
const MV_LABEL_META = 'skmv1:meta';
const MV_LABEL_ID = 'skmv1:id';

/**
 * The largest key id the format can record.
 *
 * `small` writes a length in ONE byte. A longer id wrapped that byte and
 * the writer then appended the whole thing, so every field after it
 * shifted. Checked where an id is ACCEPTED, so the refusal names the id
 * rather than the file.
 */
const MV_IDMAX = 255;

/**
 * The export key the vault API is published under, beside the `provider`
 * key every kind publishes.
 */
const VAULT_EXPORT = 'vault';

/** @return never */
function mvfail(string $text): void
{
    throw new SekretoError('sekreto: minivault: ' . $text);
}

function mvcheckid(mixed $id, string $what): string
{
    if (!is_string($id) || '' === $id) {
        mvfail($what);
    }
    if (strlen($id) > MV_IDMAX) {
        mvfail('key id is longer than ' . MV_IDMAX . ' bytes: ' . substr($id, 0, 32) . '...');
    }

    return $id;
}

// --- keys ------------------------------------------------------------

function mvhmac(string $key, string $text): string
{
    return hash_hmac('sha256', $text, $key, true);
}

/** The key-encryption key a passphrase unwraps a ring with. */
function mvkek(string $passphrase, string $salt, int $iters): string
{
    return hash_pbkdf2('sha256', $passphrase, $salt, $iters, MV_KEYLEN, true);
}

/**
 * The key one named secret's value is encrypted with.
 *
 * DERIVED, never stored, for a master: it holds the root key and so
 * reaches every name, including ones written after it was made. A
 * restricted key holds the derived keys it was granted and nothing that
 * produces another.
 */
function mvsecretkey(string $root, string $name): string
{
    return mvhmac($root, MV_AAD_SECRET . $name);
}

/**
 * Where a secret lives in the file, derived from its own key so that
 * finding it needs no plaintext name.
 */
function mventryid(string $key): string
{
    return mvhmac($key, MV_LABEL_ID);
}

function mvrandom(int $len): string
{
    return random_bytes($len);
}

// --- sealing ---------------------------------------------------------

/** @return array{iv: string, blob: string} */
function mvseal(string $key, string $plain, string $aad): array
{
    $iv = mvrandom(MV_IVLEN);
    $tag = '';
    $body = openssl_encrypt($plain, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv,
                            $tag, $aad, MV_TAGLEN);

    if (false === $body) {
        mvfail('cannot seal');
    }

    return ['iv' => $iv, 'blob' => $body . $tag];
}

/**
 * The plaintext, or a refusal. A GCM tag that fails to verify is the only
 * evidence there is, and it cannot tell a wrong passphrase from a damaged
 * file, so `what` names the attempt and the message admits both.
 *
 * @param array{iv: string, blob: string} $sealed
 */
function mvunseal(string $key, array $sealed, string $aad, string $what): string
{
    $blob = $sealed['blob'];
    $iv = $sealed['iv'];

    if (strlen($blob) < MV_TAGLEN || MV_IVLEN !== strlen($iv)) {
        mvfail($what . ': truncated');
    }

    $tag = substr($blob, -MV_TAGLEN);
    $body = substr($blob, 0, strlen($blob) - MV_TAGLEN);

    // openssl_decrypt answers false rather than raising when the tag does
    // not verify, and it also warns on a nonce of the wrong length; both
    // are the same refusal to a caller.
    $plain = @openssl_decrypt($body, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag, $aad);

    if (false === $plain) {
        mvfail($what);
    }

    return $plain;
}

/** @return array<string, mixed> */
function mvjsonof(string $plain, string $what): array
{
    $out = json_decode($plain, true);

    if (!is_array($out)) {
        mvfail('unreadable ' . $what);
    }

    return $out;
}

function mvb64(string $bytes): string
{
    return base64_encode($bytes);
}

function mvunb64(mixed $text, string $what): string
{
    if (!is_string($text)) {
        mvfail('missing ' . $what);
    }
    $out = base64_decode($text, false);

    if (false === $out) {
        mvfail('missing ' . $what);
    }

    return $out;
}

// --- the file --------------------------------------------------------

/**
 * A cursor, so that every length check is in one place: a truncated vault
 * is refused rather than read as a short one.
 */
final class MvReader
{
    private int $at = 0;

    public function __construct(private readonly string $bytes)
    {
    }

    public function take(int $len): string
    {
        if (strlen($this->bytes) < $this->at + $len) {
            mvfail('the vault file is truncated');
        }
        $out = substr($this->bytes, $this->at, $len);
        $this->at += $len;

        return $out;
    }

    public function u8(): int
    {
        return ord($this->take(1));
    }

    public function u32(): int
    {
        /** @var array{1: int} $out */
        $out = unpack('N', $this->take(4));

        return $out[1];
    }

    public function small(): string
    {
        return $this->take($this->u8());
    }

    public function large(): string
    {
        return $this->take($this->u32());
    }

    public function magic(): string
    {
        return $this->take(4);
    }

    /** @return array{iv: string, blob: string} */
    public function sealed(): array
    {
        return ['iv' => $this->small(), 'blob' => $this->large()];
    }

    public function done(): bool
    {
        return $this->at === strlen($this->bytes);
    }
}

/** @return array{keys: array<int, array<string, mixed>>, entries: array<int, array<string, mixed>>} */
function mvreadfile(string $bytes): array
{
    $read = new MvReader($bytes);

    if (MV_MAGIC !== $read->magic()) {
        mvfail('not a vault file');
    }

    $version = $read->u8();
    if (MV_FORMAT !== $version) {
        mvfail('unsupported format version: ' . $version);
    }

    $kdf = $read->u8();
    $cipher = $read->u8();
    if (MV_KDF_PBKDF2 !== $kdf || MV_CIPHER_AESGCM !== $cipher) {
        mvfail('unsupported kdf or cipher: ' . $kdf . '/' . $cipher);
    }
    $read->u8();

    $keys = [];
    $keycount = $read->u32();
    for ($index = 0; $index < $keycount; $index++) {
        $id = $read->small();
        $salt = $read->small();
        $iters = $read->u32();
        $keys[] = ['id' => $id, 'salt' => $salt, 'iters' => $iters,
                   'ring' => $read->sealed(), 'meta' => $read->sealed()];
    }

    $entries = [];
    $entrycount = $read->u32();
    for ($index = 0; $index < $entrycount; $index++) {
        $entries[] = ['id' => $read->small(), 'name' => $read->sealed(),
                      'value' => $read->sealed()];
    }

    if (!$read->done()) {
        mvfail('the vault file has trailing bytes');
    }

    return ['keys' => $keys, 'entries' => $entries];
}

/** @param array{keys: array<int, array<string, mixed>>, entries: array<int, array<string, mixed>>} $vault */
function mvwritefile(array $vault): string
{
    $out = '';

    $u8 = function (int $value) use (&$out): void {
        $out .= chr($value);
    };
    $u32 = function (int $value) use (&$out): void {
        $out .= pack('N', $value);
    };
    $small = function (string $bytes) use (&$out, $u8): void {
        $u8(strlen($bytes));
        $out .= $bytes;
    };
    $large = function (string $bytes) use (&$out, $u32): void {
        $u32(strlen($bytes));
        $out .= $bytes;
    };
    $sealed = function (array $value) use ($small, $large): void {
        $small($value['iv']);
        $large($value['blob']);
    };

    $out .= MV_MAGIC;
    $u8(MV_FORMAT);
    $u8(MV_KDF_PBKDF2);
    $u8(MV_CIPHER_AESGCM);
    $u8(0);

    $u32(count($vault['keys']));
    foreach ($vault['keys'] as $key) {
        $small($key['id']);
        $small($key['salt']);
        $u32($key['iters']);
        $sealed($key['ring']);
        $sealed($key['meta']);
    }

    // SORTED BY ID, which is a blinded value: the file therefore records
    // nothing about the order secrets were written in.
    $entries = $vault['entries'];
    usort($entries, fn(array $left, array $right) => strcmp($left['id'], $right['id']));

    $u32(count($entries));
    foreach ($entries as $entry) {
        $small($entry['id']);
        $sealed($entry['name']);
        $sealed($entry['value']);
    }

    return $out;
}

// --- creating --------------------------------------------------------

/** A new vault: one master key, no secrets. */
function mvnew(string $keyid, string $passphrase, int $iterations): array
{
    $root = mvrandom(MV_KEYLEN);
    $salt = mvrandom(MV_SALTLEN);

    $ring = ['v' => MV_FORMAT, 'write' => true, 'root' => mvb64($root)];
    $meta = ['v' => MV_FORMAT, 'master' => true, 'write' => true, 'grants' => []];

    return [
        'keys' => [[
            'id' => $keyid,
            'salt' => $salt,
            'iters' => $iterations,
            'ring' => mvseal(mvkek($passphrase, $salt, $iterations),
                             mvjson($ring), MV_AAD_RING . $keyid),
            'meta' => mvseal(mvhmac($root, MV_LABEL_META),
                             mvjson($meta), MV_AAD_META . $keyid),
        ]],
        'entries' => [],
    ];
}

/**
 * JSON the way every other port writes it: a ring's `grants` is an OBJECT
 * keyed by secret name, and a meta record's is an ARRAY of names. PHP has
 * one `[]` for both, so the ring's is forced to `stdClass` and the meta's
 * is left as the list it already is. A ring is the one with no `master`.
 *
 * FORCED WHATEVER IS IN IT, not only when it is empty, and that is the
 * whole of the bug this once had. `api.token` is a valid secret name and
 * so is `0`: PHP turns the string key `"0"` into the integer key `0`, and
 * `json_encode` writes an array for any map whose keys are `0..n`. So one
 * grant named `0` wrote `"grants":["..."]`, which PHP reads back as its
 * own map and no other port can read at all - java sees an array where it
 * wants an object and the restricted key reaches nothing.
 *
 * @param array<string, mixed> $value
 */
function mvjson(array $value): string
{
    if (isset($value['grants']) && !isset($value['master'])) {
        $value['grants'] = (object) $value['grants'];
    }

    return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
}

/**
 * `fopen` under `x` — O_CREAT|O_EXCL — with the umask set so the kernel
 * creates the file 0600 and no wider.
 *
 * WHY NOT fopen-THEN-chmod, which this used to do: between the two calls
 * the file exists at 0666 & ~umask, and another local user watching a
 * shared directory can open it for writing and keep that descriptor after
 * the chmod lands. PHP has no way to pass a mode to `fopen`, so the umask
 * is the only way to ask the kernel for the mode AT CREATION. It is
 * process-global for the width of this call, which is what every PHP
 * program that needs a private file does.
 */
function mvcreate(string $path)
{
    $was = umask(0o077);

    try {
        return @fopen($path, 'xb');
    } finally {
        umask($was);
    }
}

/**
 * Write a vault file that is not there yet, and REFUSE one that is.
 *
 * Straight to the target under `x` — `O_CREAT|O_EXCL` — rather than
 * through a temporary and a rename. `rename` REPLACES its destination, so
 * two processes creating the same vault both succeeded and the second
 * discarded the first one's secrets.
 */
function mvputnew(string $file, array $vault): void
{
    $handle = mvcreate($file);

    if (false === $handle) {
        if (file_exists($file)) {
            mvfail('vault file already exists: ' . $file);
        }
        mvfail('cannot write ' . $file);
    }

    try {
        // A SHORT WRITE IS NOT A WRITE. `fwrite` answers the byte count,
        // and under a quota or a full disk that count is positive and less
        // than what it was handed - which `false ===` took for success.
        $raw = mvwritefile($vault);
        if (strlen($raw) !== fwrite($handle, $raw)) {
            mvfail('cannot write ' . $file);
        }
    } finally {
        fclose($handle);
    }
}

/** Is this the same sealed blob, byte for byte? */
function mvsameseal(array $left, array $right): bool
{
    return $left['iv'] === $right['iv'] && $left['blob'] === $right['blob'];
}

/**
 * A handle on one vault file, opened as ONE key.
 *
 * Every method answers as that key: `list` shows the names it may read,
 * `get` answers for those and misses on the rest, and the master-only
 * methods refuse for any other key. Nothing is read or derived until the
 * first call that needs the file.
 */
final class MiniVault
{
    private readonly string $file;
    private readonly string $keyid;
    private readonly string $passphrase;
    private readonly int $iterations;
    private readonly bool $create;

    /** @var array<string, mixed>|null */
    private ?array $opened = null;

    /** @param array<string, mixed> $options */
    public function __construct(array $options)
    {
        $file = $options['file'] ?? null;
        $passphrase = $options['passphrase'] ?? null;

        if (!is_string($file) || '' === $file) {
            mvfail('a vault needs a file');
        }
        if (!is_string($passphrase) || '' === $passphrase) {
            mvfail('a vault needs a passphrase');
        }

        $this->file = $file;
        $this->passphrase = $passphrase;
        // AN EMPTY KEY IS NO KEY, so it means `master` - `??` answers for
        // null alone, and the canonical's `opts.key || MASTERKEY` answers
        // for both. A CLI reaches this with SEKRETO_VAULT_KEY set and
        // empty, which is what an unset shell variable expands to.
        $wantkey = (string) ($options['key'] ?? '');
        $this->keyid = mvcheckid('' === $wantkey ? MV_MASTERKEY : $wantkey,
                                 'a vault needs a key id');
        $this->iterations = (int) ($options['iterations'] ?? MV_ITERATIONS);
        $this->create = true === ($options['create'] ?? false);
    }

    /** The file this handle reads. */
    public function file(): string
    {
        return $this->file;
    }

    /** The key id this handle opens with. */
    public function key(): string
    {
        return $this->keyid;
    }

    /**
     * Derive the key and read the file NOW rather than at first use.
     *
     * A COPY. `set` reads `write` to decide whether this key may write, so
     * handing the caller the live record let it flip its own permission.
     * Authorization state does not leave this object.
     *
     * @return array<string, mixed>
     */
    public function open(): array
    {
        [, $opened] = $this->load();
        $info = $opened['info'];

        return ['key' => $info['key'], 'master' => $info['master'],
                'write' => $info['write'], 'grants' => array_values($info['grants'])];
    }

    /** Forget the derived keys. The next call opens again. */
    public function close(): void
    {
        $this->opened = null;
    }

    /**
     * The names this key can read, sorted.
     *
     * @return array<int, string>
     */
    public function list(): array
    {
        [$vault, $opened] = $this->load();

        if (null !== $opened['root']) {
            $namekey = mvhmac($opened['root'], MV_LABEL_NAMES);
            $out = [];
            foreach ($vault['entries'] as $entry) {
                $out[] = mvunseal($namekey, $entry['name'], MV_AAD_NAME,
                                  'a secret name is damaged');
            }
            sort($out);

            return $out;
        }

        // A restricted key has no name key, so it reports the grants it can
        // actually find: the vault never tells it what else is in there.
        $out = [];
        foreach ($opened['info']['grants'] as $name) {
            if (null !== $this->findentry($vault, $opened['grants'][$name])) {
                $out[] = $name;
            }
        }
        sort($out);

        return $out;
    }

    public function has(string $name): bool
    {
        return null !== $this->get($name);
    }

    /**
     * The value, or null when the vault does not hold that name or this
     * key was not granted it.
     */
    public function get(string $name): ?string
    {
        Name::check($name);
        [$vault, $opened] = $this->load();

        $key = $this->keyfor($opened, $name);
        if (null === $key) {
            // OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers
            // as the key that opened it, so a name this key cannot read is
            // a name this store does not hold for this caller.
            return null;
        }

        $entry = $this->findentry($vault, $key);
        if (null === $entry) {
            return null;
        }

        return mvunseal($key, $entry['value'], MV_AAD_SECRET . $name,
                        'the value of ' . $name . ' is damaged');
    }

    /**
     * Write a value. A master writes any name; a restricted key holding
     * `write` overwrites the names it was granted, and creates none.
     */
    public function set(string $name, string $value): void
    {
        Name::check($name);
        [$vault, $opened] = $this->load();

        if (!$opened['info']['write']) {
            mvfail('key ' . $opened['info']['key'] . ' is read-only');
        }

        $key = $this->keyfor($opened, $name);
        if (null === $key) {
            mvfail('key ' . $opened['info']['key'] . ' was not granted ' . $name);
        }

        $sealedvalue = mvseal($key, $value, MV_AAD_SECRET . $name);
        $id = mventryid($key);

        $at = null;
        foreach ($vault['entries'] as $index => $entry) {
            if ($entry['id'] === $id) {
                $at = $index;
                break;
            }
        }

        if (null !== $at) {
            $vault['entries'][$at]['value'] = $sealedvalue;
        } else {
            // A NEW NAME NEEDS THE NAME KEY, which only a master holds. So
            // a restricted key with `write` updates what it was granted and
            // cannot grow the vault.
            $root = $this->rootof($opened, 'creating the secret ' . $name);
            $vault['entries'][] = [
                'id' => $id,
                'name' => mvseal(mvhmac($root, MV_LABEL_NAMES), $name, MV_AAD_NAME),
                'value' => $sealedvalue,
            ];
        }

        $this->save($vault);
    }

    /** Drop a name. Master only. */
    public function remove(string $name): void
    {
        Name::check($name);
        [$vault, $opened] = $this->load();
        $root = $this->rootof($opened, 'removing a secret');

        $wanted = mventryid(mvsecretkey($root, $name));
        $at = null;
        foreach ($vault['entries'] as $index => $entry) {
            if ($entry['id'] === $wanted) {
                $at = $index;
                break;
            }
        }
        if (null === $at) {
            mvfail('no such secret: ' . $name);
        }

        array_splice($vault['entries'], $at, 1);
        $this->save($vault);
    }

    /**
     * Every key in the file, with what it may do. Master only.
     *
     * @return array<int, array<string, mixed>>
     */
    public function keys(): array
    {
        [$vault, $opened] = $this->load();
        $this->rootof($opened, 'listing the keys');

        $out = [];
        foreach ($vault['keys'] as $record) {
            $meta = $this->metaof($opened, $record);
            if (null === $meta) {
                $out[] = ['key' => $record['id'], 'master' => false,
                          'write' => false, 'grants' => []];
                continue;
            }
            $grants = $meta['grants'] ?? [];
            sort($grants);
            $out[] = ['key' => $record['id'], 'master' => true === ($meta['master'] ?? false),
                      'write' => true === ($meta['write'] ?? false), 'grants' => $grants];
        }

        return $out;
    }

    /**
     * Mint a restricted key. Master only.
     *
     * @param array<string, mixed> $spec
     */
    public function grant(array $spec): void
    {
        [$vault, $opened] = $this->load();
        $root = $this->rootof($opened, 'granting a key');

        $id = mvcheckid($spec['key'] ?? null, 'a grant needs a key id');
        $phrase = $spec['passphrase'] ?? null;
        if (!is_string($phrase) || '' === $phrase) {
            mvfail('a grant needs a passphrase');
        }
        foreach ($vault['keys'] as $key) {
            if ($key['id'] === $id) {
                mvfail('key already exists: ' . $id);
            }
        }

        $names = $spec['names'] ?? [];
        sort($names);
        $grants = [];
        foreach ($names as $name) {
            Name::check($name);
            $grants[$name] = mvb64(mvsecretkey($root, $name));
        }

        $write = true === ($spec['write'] ?? false);
        $vault['keys'][] = $this->sealkey(
            $root, $id, $phrase, (int) ($spec['iterations'] ?? $this->iterations),
            ['v' => MV_FORMAT, 'write' => $write, 'grants' => $grants],
            ['v' => MV_FORMAT, 'master' => false, 'write' => $write, 'grants' => $names]
        );

        $this->save($vault);
    }

    /**
     * Drop a key. Master only.
     *
     * Anyone who already copied the file keeps whatever that key could
     * read, so revoking bars future reads of the LIVE file and `rotate` is
     * what takes a secret back.
     */
    public function revoke(string $key): void
    {
        [$vault, $opened] = $this->load();
        $this->rootof($opened, 'revoking a key');

        if ($key === $opened['info']['key']) {
            mvfail('a key cannot revoke itself: ' . $key);
        }

        $at = null;
        foreach ($vault['keys'] as $index => $record) {
            if ($record['id'] === $key) {
                $at = $index;
                break;
            }
        }
        if (null === $at) {
            mvfail('no such key: ' . $key);
        }

        array_splice($vault['keys'], $at, 1);
        $this->save($vault);
    }

    /**
     * A new root key, every value re-encrypted under it, and EVERY OTHER
     * KEY DROPPED. Master only.
     *
     * The other keys go because they must: their rings are sealed under
     * passphrases this process does not have. Re-grant afterwards.
     */
    public function rotate(): void
    {
        [$vault, $opened] = $this->load();
        $this->rootof($opened, 'rotating the vault');

        // Read everything out under the old root before anything changes:
        // once the root is replaced the old derived keys are unreachable.
        $plain = [];
        foreach ($this->list() as $name) {
            $plain[$name] = $this->get($name);
        }

        $root = mvrandom(MV_KEYLEN);
        $namekey = mvhmac($root, MV_LABEL_NAMES);

        $entries = [];
        foreach ($plain as $name => $value) {
            $key = mvsecretkey($root, (string) $name);
            $entries[] = [
                'id' => mventryid($key),
                'name' => mvseal($namekey, (string) $name, MV_AAD_NAME),
                'value' => mvseal($key, $value, MV_AAD_SECRET . $name),
            ];
        }

        $iters = $this->iterations;
        foreach ($vault['keys'] as $record) {
            if ($record['id'] === $this->keyid) {
                $iters = $record['iters'];
            }
        }

        $fresh = $this->sealkey(
            $root, $this->keyid, $this->passphrase, $iters,
            ['v' => MV_FORMAT, 'write' => true, 'root' => mvb64($root)],
            ['v' => MV_FORMAT, 'master' => true, 'write' => true, 'grants' => []]
        );

        // SAVE FIRST, adopt second. A handle holding the new root over a
        // file that still holds the old one reads nothing and says the
        // vault is damaged.
        $this->save(['keys' => [$fresh], 'entries' => $entries]);

        $this->opened = [
            'info' => ['key' => $this->keyid, 'master' => true, 'write' => true, 'grants' => []],
            'root' => $root,
            'grants' => [],
            'ring' => $fresh['ring'],
        ];
    }

    private function bytes(): string
    {
        $raw = @file_get_contents($this->file);

        if (false !== $raw) {
            return $raw;
        }

        // A vault is configured deliberately, with a key. Its absence is a
        // broken deployment and never "no secrets here": answering a miss
        // would send the chain on to a weaker store.
        if (!file_exists($this->file)) {
            if (!$this->create) {
                mvfail('no vault file: ' . $this->file);
            }
            mvputnew($this->file, mvnew($this->keyid, $this->passphrase, $this->iterations));
            $raw = @file_get_contents($this->file);
            if (false !== $raw) {
                return $raw;
            }
        }

        mvfail('cannot read ' . $this->file);
    }

    /** @return array{0: array<string, mixed>, 1: array<string, mixed>} */
    private function load(): array
    {
        $vault = mvreadfile($this->bytes());

        $record = null;
        foreach ($vault['keys'] as $key) {
            if ($key['id'] === $this->keyid) {
                $record = $key;
                break;
            }
        }
        if (null === $record) {
            // REVOKED, or never there. Either way this handle is finished,
            // and dropping what it derived is what stops the next call
            // answering from memory.
            $this->opened = null;
            mvfail('no such key: ' . $this->keyid);
        }

        // The file still holds this key, and holds the SAME ring: a key
        // revoked and re-granted under another passphrase is a different
        // key wearing the id, and re-deriving is what refuses it.
        if (null !== $this->opened && mvsameseal($this->opened['ring'], $record['ring'])) {
            return [$vault, $this->opened];
        }
        $this->opened = null;

        $plain = mvunseal(
            mvkek($this->passphrase, $record['salt'], $record['iters']),
            $record['ring'], MV_AAD_RING . $this->keyid,
            'wrong passphrase for key ' . $this->keyid . ', or a damaged vault'
        );

        $ring = mvjsonof($plain, 'key ring for ' . $this->keyid);

        $grants = [];
        foreach (($ring['grants'] ?? []) as $name => $key) {
            $grants[$name] = mvunb64($key, 'a granted key');
        }
        // `strval`, and it is the same PHP rule as the one `mvjson` fights
        // on the way out: `array_keys` hands back an INTEGER for the key
        // "0", so a grant on a numerically named secret would reach the
        // caller as `[0]` where every other port answers `["0"]`.
        $names = array_map('strval', array_keys($grants));
        sort($names);

        $this->opened = [
            'info' => [
                'key' => $this->keyid,
                'master' => isset($ring['root']),
                'write' => isset($ring['root']) || true === ($ring['write'] ?? false),
                'grants' => $names,
            ],
            'root' => isset($ring['root']) ? mvunb64($ring['root'], 'the root key') : null,
            'grants' => $grants,
            'ring' => $record['ring'],
        ];

        return [$vault, $this->opened];
    }

    private function rootof(array $opened, string $what): string
    {
        if (null === $opened['root']) {
            mvfail($what . ' needs a master key, and ' . $opened['info']['key'] .
                   ' is restricted');
        }

        return $opened['root'];
    }

    /** The key for one name, or null when this key cannot reach it. */
    private function keyfor(array $opened, string $name): ?string
    {
        if (null !== $opened['root']) {
            return mvsecretkey($opened['root'], $name);
        }

        return $opened['grants'][$name] ?? null;
    }

    private function findentry(array $vault, ?string $key): ?array
    {
        if (null === $key) {
            return null;
        }
        $id = mventryid($key);
        foreach ($vault['entries'] as $entry) {
            if ($entry['id'] === $id) {
                return $entry;
            }
        }

        return null;
    }

    private function metaof(array $opened, array $record): ?array
    {
        $root = $this->rootof($opened, 'reading key metadata');
        $what = 'metadata for key ' . $record['id'];

        try {
            return mvjsonof(
                mvunseal(mvhmac($root, MV_LABEL_META), $record['meta'],
                         MV_AAD_META . $record['id'], $what),
                $what
            );
        } catch (SekretoError) {
            // A record written under a root key this one has replaced. The
            // key is still in the file and still opens with its own
            // passphrase, so it is reported rather than hidden - with what
            // it can do unknown.
            return null;
        }
    }

    private function sealkey(string $root, string $id, string $phrase, int $iters,
                            array $ring, array $meta): array
    {
        $salt = mvrandom(MV_SALTLEN);

        return [
            'id' => $id,
            'salt' => $salt,
            'iters' => $iters,
            'ring' => mvseal(mvkek($phrase, $salt, $iters), mvjson($ring), MV_AAD_RING . $id),
            'meta' => mvseal(mvhmac($root, MV_LABEL_META), mvjson($meta), MV_AAD_META . $id),
        ];
    }

    /**
     * Read, change, and REPLACE - never edit in place.
     *
     * THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
     * anyone can predict, so anyone who can write the vault's directory
     * could put a symlink there and have the next save truncate whatever
     * it pointed at.
     */
    private function save(array $vault): void
    {
        $temp = $this->file . '.' . bin2hex(mvrandom(8)) . '.tmp';
        $handle = mvcreate($temp);

        if (false === $handle) {
            mvfail('cannot write ' . $this->file);
        }

        // A SHORT WRITE IS NOT A WRITE; see mvputnew. Here it would be
        // worse: the rename would put a truncated file over a good vault.
        $raw = mvwritefile($vault);
        $ok = strlen($raw) === fwrite($handle, $raw);
        fclose($handle);

        if ($ok) {
            $ok = @rename($temp, $this->file);
        }

        if (!$ok) {
            // The vault is unchanged either way, and the write error is
            // what the caller needs to be told about.
            @unlink($temp);
            mvfail('cannot write ' . $this->file);
        }
    }
}

/**
 * Open a vault file as one key.
 *
 * The handle is lazy. Nothing is read, and no passphrase is stretched,
 * until a method needs the file.
 *
 * @param array<string, mixed> $options
 */
function openvault(array $options): MiniVault
{
    return new MiniVault($options);
}

/**
 * Make a vault file and return a handle on its master key.
 *
 * Refuses a file that is already there: a vault is created once, and
 * overwriting one discards every secret in it.
 *
 * @param array<string, mixed> $options
 */
function createvault(array $options): MiniVault
{
    $file = $options['file'] ?? null;
    $passphrase = $options['passphrase'] ?? null;

    if (!is_string($file) || '' === $file) {
        mvfail('a vault needs a file');
    }
    if (!is_string($passphrase) || '' === $passphrase) {
        mvfail('a vault needs a passphrase');
    }
    $wantkey = (string) ($options['key'] ?? '');
    $keyid = mvcheckid('' === $wantkey ? MV_MASTERKEY : $wantkey, 'a vault needs a key id');

    // No existence check first: the check and the write would be two
    // steps, and `mvputnew` refuses an existing file in ONE.
    mvputnew($file, mvnew($keyid, $passphrase, (int) ($options['iterations'] ?? MV_ITERATIONS)));

    return new MiniVault($options);
}

// --- the provider ----------------------------------------------------

/**
 * Read a vault as one store in a chain.
 *
 * The provider is the READ half and nothing more: a chain resolves
 * secrets, and writing one is a deliberate act with an API of its own.
 */
final class MiniVaultProvider implements Provider
{
    public function __construct(private readonly MiniVault $vault)
    {
    }

    public function lookup(string $name): ?string
    {
        return $this->vault->get($name);
    }

    public function describe(): string
    {
        return 'minivault:' . $this->vault->file();
    }
}

function providerof(MiniVault $vault): Provider
{
    return new MiniVaultProvider($vault);
}

/**
 * A vault provider from options, for a chain built by hand.
 *
 * @param array<string, mixed> $options
 */
function minivaultprovider(array $options): Provider
{
    return providerof(openvault($options));
}

/**
 * The vault options a provider spec describes.
 *
 * @param array<string, mixed> $spec
 * @return array<string, mixed>
 */
function mvoptions(array $spec): array
{
    return [
        'file' => $spec['file'] ?? '',
        'key' => $spec['vaultkey'] ?? null,
        'passphrase' => $spec['passphrase'] ?? '',
        'iterations' => $spec['iterations'] ?? null,
        'create' => true === ($spec['create'] ?? false),
    ];
}

/**
 * The `minivault` provider kind, as a voxgig/plugin definition.
 *
 * Written out rather than built by `providerplugin`, because this
 * definition publishes TWO exports: `provider`, the read half every kind
 * publishes, and `vault`, the programmatic API.
 *
 * @return array<string, mixed>
 */
function minivault(): array
{
    return [
        'name' => 'minivault',
        'define' => function (Inst $inst): void {
            $options = mvoptions($inst->options());

            try {
                // `openvault` refuses bad configuration HERE, so a mistyped
                // chain fails at construction. Reaching the FILE is not
                // configuration: the handle is lazy.
                $vault = openvault($options);
            } catch (SekretoError $err) {
                throw new PluginError(ERROR_CODE, $err->getMessage(),
                                      ['ref' => $inst->ref, 'cause' => $err->getMessage()]);
            }

            $inst->export(PROVIDER_EXPORT, providerof($vault));
            $inst->export(VAULT_EXPORT, $vault);
        },
    ];
}

/**
 * The vault behind a store in a chain, as its programmatic API.
 *
 * With no store named, the unqualified alias answers: one vault in the
 * chain resolves whatever it is called, and two raise rather than picking
 * one.
 */
function vaultof(object $secrets, ?string $store = null): MiniVault
{
    if (null === $store) {
        $found = $secrets->host->exports('minivault/' . VAULT_EXPORT);
        if (null === $found) {
            mvfail('no minivault store in this chain');
        }

        return $found;
    }

    // A NAMED STORE MUST EXIST, and the alias must not stand in for it.
    // `host.exports` falls back to the alias when the exact ref misses, so
    // asking for `minivault` in a chain whose only vault is named `app`
    // used to hand back the `app` vault - and then write to it.
    $ref = 'minivault' === $store ? 'minivault' : 'minivault$' . $store;

    if (null === $secrets->host->instance($ref)) {
        mvfail('no minivault store named ' . $store . ' in this chain');
    }

    return $secrets->host->exports($ref . '/' . VAULT_EXPORT);
}
