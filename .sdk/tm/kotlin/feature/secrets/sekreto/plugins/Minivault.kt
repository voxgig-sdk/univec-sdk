// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (kotlin/plugins/Minivault.kt)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The mini vault, as a voxgig/plugin definition.
//
// A port of typescript/plugins/minivault.ts, which is canonical.
//
// PLUGIN CODE, not core: it needs crypto, which is the line the four
// built-ins stay behind. See docs/design/plugin-providers.md.
//
// THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
// every name and mints restricted keys. A restricted key reads the names
// it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
// cryptography rather than a check this code performs. What that does and
// does not protect is set out in DOCS.md under "What the mini vault
// protects".
//
// `javax.crypto` carries all four primitives, so nothing here is
// hand-rolled (AGENTS.md rule 3).

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.ERROR_CODE
import KOTLINPACKAGE.feature.secrets.sekreto.Json
import KOTLINPACKAGE.feature.secrets.sekreto.PROVIDER_EXPORT
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.Sekreto
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.checkname
import KOTLINPACKAGE.feature.secrets.sekreto.specof
import KOTLINPACKAGE.feature.secrets.plugin.Inst
import KOTLINPACKAGE.feature.secrets.plugin.PluginError
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions
import java.security.GeneralSecurityException
import java.security.SecureRandom
import java.util.Base64
import java.util.TreeMap
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

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
// Integers are big-endian, and every length precedes its bytes. A file one
// port writes is read by every other; `test/fixture` pins that with a
// committed vault rather than with agreement.

private const val MAGIC = "SKMV"
private const val FORMAT = 1
private const val KDF_PBKDF2 = 1
private const val CIPHER_AESGCM = 1

/** AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags. */
private const val KEYLEN = 32
private const val IVLEN = 12
private const val TAGLEN = 16
private const val SALTLEN = 16

/** PBKDF2-HMAC-SHA256 rounds when a caller names none. */
const val MINIVAULT_ITERATIONS = 210000

/** The key id a vault gets when a caller names none. */
const val MASTERKEY = "master"

// Additional authenticated data. Every blob is bound to its PLACE in the
// file, so no ciphertext can be moved.
private const val AAD_RING = "skmv1:ring:"
private const val AAD_META = "skmv1:meta:"
private const val AAD_NAME = "skmv1:name"
private const val AAD_SECRET = "skmv1:secret:"

// Everything a master can reach is derived from the root key, so a
// rotation is one new random value rather than a re-wrap of each part.
private const val LABEL_NAMES = "skmv1:names"
private const val LABEL_META = "skmv1:meta"
private const val LABEL_ID = "skmv1:id"

/**
 * The largest key id the format can record.
 *
 * `small` writes a length in ONE byte. A longer id wrapped that byte and
 * the writer then appended the whole thing, so every field after it
 * shifted. Checked where an id is ACCEPTED, so the refusal names the id
 * rather than the file.
 */
private const val IDMAX = 255

/** The export key the vault API is published under, beside `provider`. */
const val VAULT_EXPORT = "vault"

private val RANDOM = SecureRandom()

private fun mvfail(text: String): Nothing = throw SekretoError("sekreto: minivault: $text")

/**
 * The key a caller asked for, or [MASTERKEY]: an EMPTY key is no key. The
 * canonical's `opts.key || MASTERKEY` answers for both null and empty,
 * where `?:` answers for null alone - and a CLI reaches this with
 * SEKRETO_VAULT_KEY set and empty, which is what an unset shell variable
 * expands to.
 */
/**
 * The lock every handle on one file shares.
 *
 * Each [MiniVault] is its own object, so two handles on one path did not
 * coordinate: both could finish `load()` before either saved, and the
 * second rename then discarded the first one's change while reporting
 * success. Keyed by the ABSOLUTE path, so two handles spelled differently
 * still meet.
 *
 * A guarantee WITHIN one process, which is what DOCS.md promises and what
 * the go port arranges the same way. Two processes still race, and the
 * format's answer to that is the exclusive create and the atomic rename:
 * a reader sees one whole vault or the other, never half of one.
 */
private val LOCKS = java.util.concurrent.ConcurrentHashMap<String, Any>()

private fun lockfor(file: String): Any {
    val key = try {
        File(file).absoluteFile.normalize().path
    } catch (err: RuntimeException) {
        file
    }

    return LOCKS.computeIfAbsent(key) { Any() }
}

private fun wantkey(value: String?): String =
    if (value.isNullOrEmpty()) MASTERKEY else value

private fun checkid(id: String?, what: String): String {
    if (null == id || id.isEmpty()) {
        mvfail(what)
    }
    if (utf8(id).size > IDMAX) {
        mvfail("key id is longer than $IDMAX bytes: ${id.take(32)}...")
    }
    return id
}

private fun utf8(text: String): ByteArray = text.toByteArray(StandardCharsets.UTF_8)

// --- keys ------------------------------------------------------------

private fun mvhmac(key: ByteArray, text: String): ByteArray = try {
    Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }
        .doFinal(utf8(text))
} catch (err: GeneralSecurityException) {
    mvfail("hmac: ${err.message}")
}

/** The key-encryption key a passphrase unwraps a ring with. */
private fun kek(passphrase: String, salt: ByteArray, iters: Int): ByteArray = try {
    SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        .generateSecret(PBEKeySpec(passphrase.toCharArray(), salt, iters, KEYLEN * 8))
        .encoded
} catch (err: GeneralSecurityException) {
    mvfail("pbkdf2: ${err.message}")
}

/**
 * The key one named secret's value is encrypted with.
 *
 * DERIVED, never stored, for a master: it holds the root key and so
 * reaches every name, including ones written after it was made. A
 * restricted key holds the derived keys it was granted and nothing that
 * produces another.
 */
private fun secretkey(root: ByteArray, name: String): ByteArray = mvhmac(root, AAD_SECRET + name)

/**
 * Where a secret lives in the file, derived from its own key so that
 * finding it needs no plaintext name.
 */
private fun entryid(key: ByteArray): ByteArray = mvhmac(key, LABEL_ID)

private fun random(len: Int): ByteArray = ByteArray(len).also { RANDOM.nextBytes(it) }

// --- sealing ---------------------------------------------------------

/** A nonce and the ciphertext with its tag appended. */
private data class Sealed(val iv: ByteArray, val blob: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is Sealed && iv.contentEquals(other.iv) && blob.contentEquals(other.blob)

    override fun hashCode(): Int = iv.contentHashCode() * 31 + blob.contentHashCode()
}

private fun seal(key: ByteArray, plain: ByteArray, aad: String): Sealed = try {
    val iv = random(IVLEN)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAGLEN * 8, iv))
    cipher.updateAAD(utf8(aad))
    Sealed(iv, cipher.doFinal(plain))
} catch (err: GeneralSecurityException) {
    mvfail("cannot seal: ${err.message}")
}

/**
 * The plaintext, or a refusal. A GCM tag that fails to verify is the only
 * evidence there is, and it cannot tell a wrong passphrase from a damaged
 * file, so `what` names the attempt and the message admits both.
 */
private fun unseal(key: ByteArray, sealed: Sealed, aad: String, what: String): ByteArray {
    if (sealed.blob.size < TAGLEN || IVLEN != sealed.iv.size) {
        mvfail("$what: truncated")
    }

    // The WHOLE round-trip is guarded, not only the tag check: a nonce of
    // the wrong length makes `init` itself raise, and a damaged file
    // reaching a caller as a raw GeneralSecurityException is a refusal
    // nobody can act on.
    return try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(TAGLEN * 8, sealed.iv),
        )
        cipher.updateAAD(utf8(aad))
        cipher.doFinal(sealed.blob)
    } catch (err: GeneralSecurityException) {
        mvfail(what)
    } catch (err: RuntimeException) {
        mvfail(what)
    }
}

// THE JSON IS A SEALED CLASS HERE and a plain map everywhere else. This
// port's `Json` carries `Json.Obj` / `Json.Str` rather than `Any?`, so a
// ring crosses the boundary twice: `plainof` on the way in, `tagged` on
// the way out. The bytes are the same either way - the wrapper is this
// port's representation, not the format's.
private fun jsonof(plain: ByteArray, what: String): Map<String, Any?> {
    val parsed = Json.parse(String(plain, StandardCharsets.UTF_8))
        ?: mvfail("unreadable $what")
    val obj = parsed as? Json.Obj ?: mvfail("unreadable $what")
    return obj.value.mapValues { plainof(it.value) }
}

private fun plainof(value: Json): Any? = when (value) {
    is Json.Null -> null
    is Json.Bool -> value.value
    is Json.Num -> value.value
    is Json.Str -> value.value
    is Json.Arr -> value.value.map { plainof(it) }
    is Json.Obj -> value.value.mapValues { plainof(it.value) }
}

private fun tagged(value: Any?): Json = when (value) {
    null -> Json.Null
    is Boolean -> Json.Bool(value)
    is Double -> Json.Num(value)
    is Int -> Json.Num(value.toDouble())
    is String -> Json.Str(value)
    is List<*> -> Json.Arr(value.map { tagged(it) })
    is Map<*, *> -> Json.Obj(value.entries.associate { "${it.key}" to tagged(it.value) })
    else -> mvfail("cannot encode $value")
}

private fun stringify(value: Map<String, Any?>): String = Json.stringify(tagged(value))

private fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

private fun unb64(text: Any?, what: String): ByteArray {
    if (text !is String) {
        mvfail("missing $what")
    }
    return try {
        Base64.getDecoder().decode(text)
    } catch (err: IllegalArgumentException) {
        mvfail("missing $what")
    }
}

// --- the file --------------------------------------------------------

private class KeyRecord(
    val id: String,
    val salt: ByteArray,
    val iters: Int,
    val ring: Sealed,
    val meta: Sealed,
)

private class EntryRecord(val id: ByteArray, val name: Sealed, var value: Sealed)

private class VaultFile(
    val keys: MutableList<KeyRecord> = mutableListOf(),
    val entries: MutableList<EntryRecord> = mutableListOf(),
)

/**
 * A cursor, so that every length check is in one place: a truncated vault
 * is refused rather than read as a short one.
 */
private class Reader(private val bytes: ByteArray) {
    private var at = 0

    fun take(len: Int): ByteArray {
        if (len < 0 || bytes.size < at + len) {
            mvfail("the vault file is truncated")
        }
        val out = bytes.copyOfRange(at, at + len)
        at += len
        return out
    }

    fun u8(): Int = take(1)[0].toInt() and 0xff

    fun u32(): Int {
        // A length over Int.MAX_VALUE cannot address an array, and reading
        // it as a negative int is what turned a damaged file into a crash
        // instead of a refusal.
        val value = ByteBuffer.wrap(take(4)).int.toLong() and 0xffffffffL
        if (value > Int.MAX_VALUE) {
            mvfail("the vault file is truncated")
        }
        return value.toInt()
    }

    fun small(): ByteArray = take(u8())

    fun large(): ByteArray = take(u32())

    fun magic(): String = String(take(4), StandardCharsets.ISO_8859_1)

    fun sealedvalue(): Sealed = Sealed(small(), large())

    fun done(): Boolean = at == bytes.size
}

private fun readfile(bytes: ByteArray): VaultFile {
    val read = Reader(bytes)

    if (MAGIC != read.magic()) {
        mvfail("not a vault file")
    }

    val version = read.u8()
    if (FORMAT != version) {
        mvfail("unsupported format version: $version")
    }

    val kdf = read.u8()
    val cipher = read.u8()
    if (KDF_PBKDF2 != kdf || CIPHER_AESGCM != cipher) {
        mvfail("unsupported kdf or cipher: $kdf/$cipher")
    }
    read.u8()

    val vault = VaultFile()

    repeat(read.u32()) {
        vault.keys.add(
            KeyRecord(
                String(read.small(), StandardCharsets.UTF_8),
                read.small(),
                read.u32(),
                read.sealedvalue(),
                read.sealedvalue(),
            ),
        )
    }

    repeat(read.u32()) {
        vault.entries.add(EntryRecord(read.small(), read.sealedvalue(), read.sealedvalue()))
    }

    if (!read.done()) {
        mvfail("the vault file has trailing bytes")
    }

    return vault
}

/** Unsigned, byte by byte, the way every other port sorts. */
private fun compare(left: ByteArray, right: ByteArray): Int {
    for (index in 0 until minOf(left.size, right.size)) {
        val one = left[index].toInt() and 0xff
        val two = right[index].toInt() and 0xff
        if (one != two) {
            return if (one < two) -1 else 1
        }
    }
    return left.size.compareTo(right.size)
}

private fun writefile(vault: VaultFile): ByteArray {
    val out = java.io.ByteArrayOutputStream()

    fun raw(bytes: ByteArray) = out.write(bytes)
    fun u8(value: Int) = out.write(value and 0xff)
    fun u32(value: Int) = raw(ByteBuffer.allocate(4).putInt(value).array())
    fun small(bytes: ByteArray) { u8(bytes.size); raw(bytes) }
    fun large(bytes: ByteArray) { u32(bytes.size); raw(bytes) }
    fun sealedvalue(value: Sealed) { small(value.iv); large(value.blob) }

    raw(MAGIC.toByteArray(StandardCharsets.ISO_8859_1))
    u8(FORMAT)
    u8(KDF_PBKDF2)
    u8(CIPHER_AESGCM)
    u8(0)

    u32(vault.keys.size)
    for (key in vault.keys) {
        small(utf8(key.id))
        small(key.salt)
        u32(key.iters)
        sealedvalue(key.ring)
        sealedvalue(key.meta)
    }

    // SORTED BY ID, which is a blinded value: the file therefore records
    // nothing about the order secrets were written in.
    val entries = vault.entries.sortedWith { left, right -> compare(left.id, right.id) }

    u32(entries.size)
    for (entry in entries) {
        small(entry.id)
        sealedvalue(entry.name)
        sealedvalue(entry.value)
    }

    return out.toByteArray()
}

// --- what a key is ---------------------------------------------------

/**
 * What a key may do. `grants` is empty for a master key.
 *
 * A data class with `val` fields and an immutable list, so what a caller
 * is handed cannot become what the vault believes: `info.write = true`
 * does not compile.
 */
data class VaultKeyInfo(
    val key: String,
    val master: Boolean,
    val write: Boolean,
    val grants: List<String>,
)

/** What a caller asks for when minting a restricted key. */
data class GrantSpec(
    val key: String,
    val passphrase: String,
    val names: List<String> = emptyList(),
    val write: Boolean = false,
    val iterations: Int? = null,
)

/** How a vault handle is configured. */
data class VaultOptions(
    val file: String,
    val passphrase: String,
    val key: String = MASTERKEY,
    val iterations: Int = MINIVAULT_ITERATIONS,
    val create: Boolean = false,
)

private class Opened(
    val info: VaultKeyInfo,
    val root: ByteArray?,
    val grants: Map<String, ByteArray>,
    val ring: Sealed,
)

// --- creating --------------------------------------------------------

private fun newvault(keyid: String, passphrase: String, iterations: Int): VaultFile {
    val root = random(KEYLEN)
    val salt = random(SALTLEN)

    val ring = linkedMapOf<String, Any?>(
        "v" to FORMAT.toDouble(), "write" to true, "root" to b64(root),
    )
    val meta = linkedMapOf<String, Any?>(
        "v" to FORMAT.toDouble(), "master" to true, "write" to true,
        "grants" to emptyList<Any?>(),
    )

    return VaultFile(
        mutableListOf(
            KeyRecord(
                keyid, salt, iterations,
                seal(kek(passphrase, salt, iterations), utf8(stringify(ring)),
                    AAD_RING + keyid),
                seal(mvhmac(root, LABEL_META), utf8(stringify(meta)), AAD_META + keyid),
            ),
        ),
    )
}

private fun owneronly(path: Path) {
    try {
        Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rw-------"))
    } catch (err: IOException) {
        // A filesystem with no POSIX permissions is not a reason to refuse
        // a write that otherwise succeeded.
    } catch (err: UnsupportedOperationException) {
        // The same.
    }
}

/**
 * Write a vault file that is not there yet, and REFUSE one that is.
 *
 * Straight to the target with CREATE_NEW rather than through a temporary
 * and a rename. A rename REPLACES its destination, so two processes
 * creating the same vault both succeeded and the second discarded the
 * first one's secrets.
 */
private fun putnew(file: String, vault: VaultFile) {
    val path = Path.of(file)
    try {
        Files.write(path, writefile(vault), StandardOpenOption.CREATE_NEW,
            StandardOpenOption.WRITE)
        owneronly(path)
    } catch (err: FileAlreadyExistsException) {
        mvfail("vault file already exists: $file")
    } catch (err: IOException) {
        mvfail("cannot write $file: ${err.message}")
    }
}

/**
 * A handle on one vault file, opened as ONE key.
 *
 * Every method answers as that key: `list` shows the names it may read,
 * `get` answers for those and misses on the rest, and the master-only
 * methods refuse for any other key. Nothing is read or derived until the
 * first call that needs the file.
 */
class MiniVault internal constructor(options: VaultOptions) {

    private val file: String
    private val keyid: String
    private val passphrase: String
    private val iterations: Int
    private val create: Boolean

    private var opened: Opened? = null

    init {
        if (options.file.isEmpty()) {
            mvfail("a vault needs a file")
        }
        if (options.passphrase.isEmpty()) {
            mvfail("a vault needs a passphrase")
        }

        file = options.file
        passphrase = options.passphrase
        keyid = checkid(wantkey(options.key), "a vault needs a key id")
        iterations = options.iterations
        create = options.create
    }

    /** The file this handle reads. */
    fun file(): String = file

    /** The key id this handle opens with. */
    fun key(): String = keyid

    /** Derive the key and read the file NOW rather than at first use. */
    fun open(): VaultKeyInfo = load().second.info

    /** Forget the derived keys. The next call opens again. */
    fun close() {
        opened = null
    }

    /** The names this key can read, sorted. */
    fun list(): List<String> {
        val (vault, open) = load()
        val root = open.root

        if (null != root) {
            val namekey = mvhmac(root, LABEL_NAMES)
            return vault.entries
                .map { String(unseal(namekey, it.name, AAD_NAME, "a secret name is damaged"),
                    StandardCharsets.UTF_8) }
                .sorted()
        }

        // A restricted key has no name key, so it reports the grants it can
        // actually find: the vault never tells it what else is in there.
        return open.info.grants.filter { null != findentry(vault, open.grants[it]) }.sorted()
    }

    fun has(name: String): Boolean = null != get(name)

    /**
     * The value, or null when the vault does not hold that name or this key
     * was not granted it.
     */
    fun get(name: String): String? {
        checkname(name)
        val (vault, open) = load()

        // OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as
        // the key that opened it, so a name this key cannot read is a name
        // this store does not hold for this caller.
        val key = keyfor(open, name) ?: return null
        val entry = findentry(vault, key) ?: return null

        return String(
            unseal(key, entry.value, AAD_SECRET + name, "the value of $name is damaged"),
            StandardCharsets.UTF_8,
        )
    }

    /**
     * Write a value. A master writes any name; a restricted key holding
     * `write` overwrites the names it was granted, and creates none.
     */
    fun set(name: String, value: String) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        synchronized(lockfor(file)) {
            checkname(name)
            val (vault, open) = load()

            if (!open.info.write) {
                mvfail("key ${open.info.key} is read-only")
            }

            val key = keyfor(open, name) ?: mvfail("key ${open.info.key} was not granted $name")
            val sealedvalue = seal(key, utf8(value), AAD_SECRET + name)
            val found = findentry(vault, key)

            if (null != found) {
                found.value = sealedvalue
            } else {
                // A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
                // restricted key with `write` updates what it was granted and
                // cannot grow the vault.
                val root = rootof(open, "creating the secret $name")
                vault.entries.add(
                    EntryRecord(
                        entryid(key),
                        seal(mvhmac(root, LABEL_NAMES), utf8(name), AAD_NAME),
                        sealedvalue,
                    ),
                )
            }

            save(vault)
        }
    }

    /** Drop a name. Master only. */
    fun remove(name: String) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        synchronized(lockfor(file)) {
            checkname(name)
            val (vault, open) = load()
            val root = rootof(open, "removing a secret")

            val wanted = entryid(secretkey(root, name))
            val found = vault.entries.firstOrNull { it.id.contentEquals(wanted) }
                ?: mvfail("no such secret: $name")

            vault.entries.remove(found)
            save(vault)
        }
    }

    /** Every key in the file, with what it may do. Master only. */
    fun keys(): List<VaultKeyInfo> {
        val (vault, open) = load()
        rootof(open, "listing the keys")

        return vault.keys.map { record ->
            val meta = metaof(open, record)
                ?: return@map VaultKeyInfo(record.id, false, false, emptyList())

            val grants = (meta["grants"] as? List<*>)?.map { "$it" }?.sorted() ?: emptyList()

            VaultKeyInfo(record.id, true == meta["master"], true == meta["write"], grants)
        }
    }

    /** Mint a restricted key. Master only. */
    fun grant(spec: GrantSpec) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        synchronized(lockfor(file)) {
            val (vault, open) = load()
            val root = rootof(open, "granting a key")

            val id = checkid(spec.key, "a grant needs a key id")
            if (spec.passphrase.isEmpty()) {
                mvfail("a grant needs a passphrase")
            }
            if (vault.keys.any { it.id == id }) {
                mvfail("key already exists: $id")
            }

            val names = spec.names.sorted()

            // A TreeMap, for a ring whose JSON is the same text on every run.
            // It is NOT an interop requirement - the ring is sealed under a
            // fresh nonce, so its ciphertext differs per write whatever the key
            // order is. It is so that two runs of this port over the same grant
            // produce the same plaintext.
            val grants = TreeMap<String, Any?>()
            for (name in names) {
                checkname(name)
                grants[name] = b64(secretkey(root, name))
            }

            vault.keys.add(
                sealkey(
                    root, id, spec.passphrase, spec.iterations ?: iterations,
                    linkedMapOf("v" to FORMAT.toDouble(), "write" to spec.write,
                        "grants" to LinkedHashMap(grants)),
                    linkedMapOf("v" to FORMAT.toDouble(), "master" to false,
                        "write" to spec.write, "grants" to names),
                ),
            )

            save(vault)
        }
    }

    /**
     * Drop a key. Master only.
     *
     * Anyone who already copied the file keeps whatever that key could
     * read, so revoking bars future reads of the LIVE file and `rotate` is
     * what takes a secret back.
     */
    fun revoke(key: String) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        synchronized(lockfor(file)) {
            val (vault, open) = load()
            rootof(open, "revoking a key")

            if (key == open.info.key) {
                mvfail("a key cannot revoke itself: $key")
            }

            val found = vault.keys.firstOrNull { it.id == key } ?: mvfail("no such key: $key")
            vault.keys.remove(found)
            save(vault)
        }
    }

    /**
     * A new root key, every value re-encrypted under it, and EVERY OTHER
     * KEY DROPPED. Master only.
     *
     * The other keys go because they must: their rings are sealed under
     * passphrases this process does not have. Re-grant afterwards.
     */
    fun rotate() {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        synchronized(lockfor(file)) {
            val (vault, open) = load()
            rootof(open, "rotating the vault")

            // Read everything out under the old root before anything changes:
            // once the root is replaced the old derived keys are unreachable.
            val plain = list().map { it to (get(it) ?: "") }

            val root = random(KEYLEN)
            val namekey = mvhmac(root, LABEL_NAMES)

            val fresh = VaultFile()
            for ((name, value) in plain) {
                val key = secretkey(root, name)
                fresh.entries.add(
                    EntryRecord(
                        entryid(key),
                        seal(namekey, utf8(name), AAD_NAME),
                        seal(key, utf8(value), AAD_SECRET + name),
                    ),
                )
            }

            val iters = vault.keys.firstOrNull { it.id == keyid }?.iters ?: iterations

            val record = sealkey(
                root, keyid, passphrase, iters,
                linkedMapOf("v" to FORMAT.toDouble(), "write" to true, "root" to b64(root)),
                linkedMapOf("v" to FORMAT.toDouble(), "master" to true, "write" to true,
                    "grants" to emptyList<Any?>()),
            )
            fresh.keys.add(record)

            // SAVE FIRST, adopt second. A handle holding the new root over a
            // file that still holds the old one reads nothing and says the
            // vault is damaged.
            write(fresh)

            opened = Opened(
                VaultKeyInfo(keyid, true, true, emptyList()), root, emptyMap(), record.ring,
            )
        }
    }

    // --- the inside ----------------------------------------------------

    private fun bytes(): ByteArray = try {
        Files.readAllBytes(Path.of(file))
    } catch (err: NoSuchFileException) {
        // A vault is configured deliberately, with a key. Its absence is a
        // broken deployment and never "no secrets here": answering a miss
        // would send the chain on to a weaker store.
        if (!create) {
            mvfail("no vault file: $file")
        }
        putnew(file, newvault(keyid, passphrase, iterations))
        try {
            Files.readAllBytes(Path.of(file))
        } catch (again: IOException) {
            mvfail("cannot read $file: ${again.message}")
        }
    } catch (err: IOException) {
        mvfail("cannot read $file: ${err.message}")
    }

    private fun load(): Pair<VaultFile, Opened> {
        val vault = readfile(bytes())

        val record = vault.keys.firstOrNull { it.id == keyid }
        if (null == record) {
            // REVOKED, or never there. Either way this handle is finished,
            // and dropping what it derived is what stops the next call
            // answering from memory.
            opened = null
            mvfail("no such key: $keyid")
        }

        // The file still holds this key, and holds the SAME ring: a key
        // revoked and re-granted under another passphrase is a different key
        // wearing the id, and re-deriving is what refuses it.
        val held = opened
        if (null != held && held.ring == record.ring) {
            return vault to held
        }
        opened = null

        val plain = unseal(
            kek(passphrase, record.salt, record.iters), record.ring, AAD_RING + keyid,
            "wrong passphrase for key $keyid, or a damaged vault",
        )

        val ring = jsonof(plain, "key ring for $keyid")

        val grants = LinkedHashMap<String, ByteArray>()
        (ring["grants"] as? Map<*, *>)?.forEach { (name, key) ->
            grants["$name"] = unb64(key, "a granted key")
        }

        val root = ring["root"]

        val next = Opened(
            VaultKeyInfo(
                keyid, null != root, null != root || true == ring["write"],
                grants.keys.sorted(),
            ),
            if (null == root) null else unb64(root, "the root key"),
            grants,
            record.ring,
        )
        opened = next

        return vault to next
    }

    private fun rootof(open: Opened, what: String): ByteArray =
        open.root ?: mvfail("$what needs a master key, and ${open.info.key} is restricted")

    /** The key for one name, or null when this key cannot reach it. */
    private fun keyfor(open: Opened, name: String): ByteArray? {
        val root = open.root
        return if (null != root) secretkey(root, name) else open.grants[name]
    }

    private fun findentry(vault: VaultFile, key: ByteArray?): EntryRecord? {
        if (null == key) {
            return null
        }
        val id = entryid(key)
        return vault.entries.firstOrNull { it.id.contentEquals(id) }
    }

    private fun metaof(open: Opened, record: KeyRecord): Map<String, Any?>? {
        val root = rootof(open, "reading key metadata")
        val what = "metadata for key ${record.id}"

        return try {
            jsonof(unseal(mvhmac(root, LABEL_META), record.meta, AAD_META + record.id, what), what)
        } catch (err: SekretoError) {
            // A record written under a root key this one has replaced. The
            // key is still in the file and still opens with its own
            // passphrase, so it is reported rather than hidden - with what
            // it can do unknown.
            null
        }
    }

    private fun sealkey(
        root: ByteArray,
        id: String,
        phrase: String,
        iters: Int,
        ring: Map<String, Any?>,
        meta: Map<String, Any?>,
    ): KeyRecord {
        val salt = random(SALTLEN)
        return KeyRecord(
            id, salt, iters,
            seal(kek(phrase, salt, iters), utf8(stringify(ring)), AAD_RING + id),
            seal(mvhmac(root, LABEL_META), utf8(stringify(meta)), AAD_META + id),
        )
    }

    private fun save(vault: VaultFile) = write(vault)

    /**
     * Read, change, and REPLACE - never edit in place.
     *
     * THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
     * anyone can predict, so anyone who can write the vault's directory
     * could put a symlink there and have the next save truncate whatever it
     * pointed at.
     */
    private fun write(vault: VaultFile) {
        val temp = Path.of(file + "." + random(8).joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        } + ".tmp")

        try {
            Files.write(temp, writefile(vault), StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE)
            owneronly(temp)
            Files.move(temp, Path.of(file), StandardCopyOption.REPLACE_EXISTING)
        } catch (err: IOException) {
            try {
                Files.deleteIfExists(temp)
            } catch (ignored: IOException) {
                // The vault is unchanged either way, and the write error is
                // what the caller needs to be told about.
            }
            mvfail("cannot write $file: ${err.message}")
        }
    }
}

/**
 * Open a vault file as one key.
 *
 * The handle is lazy. Nothing is read, and no passphrase is stretched,
 * until a method needs the file.
 */
fun openvault(options: VaultOptions): MiniVault = MiniVault(options)

/**
 * Make a vault file and return a handle on its master key.
 *
 * Refuses a file that is already there: a vault is created once, and
 * overwriting one discards every secret in it.
 */
fun createvault(options: VaultOptions): MiniVault {
    if (options.file.isEmpty()) {
        mvfail("a vault needs a file")
    }
    if (options.passphrase.isEmpty()) {
        mvfail("a vault needs a passphrase")
    }
    val keyid = checkid(wantkey(options.key), "a vault needs a key id")

    // No existence check first: the check and the write would be two steps,
    // and `putnew` refuses an existing file in ONE.
    putnew(options.file, newvault(keyid, options.passphrase, options.iterations))

    return MiniVault(options)
}

// --- the provider ----------------------------------------------------

/**
 * Read a vault as one store in a chain.
 *
 * The provider is the READ half and nothing more: a chain resolves
 * secrets, and writing one is a deliberate act with an API of its own.
 */
fun providerof(vault: MiniVault): Provider = object : Provider {
    override fun lookup(name: String): String? = vault.get(name)

    override fun describe(): String = "minivault:${vault.file()}"
}

/** A vault provider from options, for a chain built by hand. */
fun minivaultprovider(options: VaultOptions): Provider = providerof(openvault(options))

/**
 * The `minivault` provider kind, as a voxgig/plugin definition.
 *
 * Written out rather than built by `providerplugin`, because this
 * definition publishes TWO exports: `provider`, the read half every kind
 * publishes, and `vault`, the programmatic API.
 */
val minivault: Definition = mapOf(
    "name" to "minivault",
    "define" to { inst: Inst ->
        val spec = specof(inst.options)

        val vault = try {
            // `openvault` refuses bad configuration HERE, so a mistyped
            // chain fails at construction. Reaching the FILE is not
            // configuration: the handle is lazy.
            openvault(
                VaultOptions(
                    file = spec.file ?: "",
                    passphrase = spec.passphrase ?: "",
                    key = wantkey(spec.vaultkey),
                    iterations = spec.iterations ?: MINIVAULT_ITERATIONS,
                    create = true == spec.create,
                ),
            )
        } catch (err: SekretoError) {
            val text = err.message ?: ""
            throw PluginError(ERROR_CODE, text, mapOf("ref" to inst.ref, "cause" to text))
        }

        inst.export(PROVIDER_EXPORT, providerof(vault))
        inst.export(VAULT_EXPORT, vault)
    },
)

/**
 * The vault behind a store in a chain, as its programmatic API.
 *
 * With no store named, the unqualified alias answers: one vault in the
 * chain resolves whatever it is called, and two raise rather than picking
 * one.
 */
fun vaultof(secrets: Sekreto, store: String? = null): MiniVault {
    if (null == store) {
        return secrets.host.exports("minivault/$VAULT_EXPORT") as? MiniVault
            ?: mvfail("no minivault store in this chain")
    }

    // A NAMED STORE MUST EXIST, and the alias must not stand in for it.
    // `host.exports` falls back to the alias when the exact ref misses, so
    // asking for `minivault` in a chain whose only vault is named `app`
    // used to hand back the `app` vault - and then write to it.
    val ref = if ("minivault" == store) "minivault" else "minivault\$$store"

    if (null == secrets.host.instance(ref)) {
        mvfail("no minivault store named $store in this chain")
    }

    return secrets.host.exports("$ref/$VAULT_EXPORT") as MiniVault
}
