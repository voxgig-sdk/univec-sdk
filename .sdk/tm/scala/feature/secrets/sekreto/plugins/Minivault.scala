// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (scala/plugins/Minivault.scala)
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

package com.voxgig.sekreto.plugins

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions
import java.security.GeneralSecurityException
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import scala.collection.immutable.ListMap
import scala.util.control.NonFatal

import voxgig.plugin.Definition
import voxgig.plugin.Inst
import voxgig.plugin.PluginError
import voxgig.plugin.VOpaque
import voxgig.plugin.VStr
import com.voxgig.sekreto.*

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

private val MAGIC = "SKMV"
private val FORMAT = 1
private val KDF_PBKDF2 = 1
private val CIPHER_AESGCM = 1

/** AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags. */
private val KEYLEN = 32
private val IVLEN = 12
private val TAGLEN = 16
private val SALTLEN = 16

/** PBKDF2-HMAC-SHA256 rounds when a caller names none. */
val MINIVAULT_ITERATIONS = 210000

/** The key id a vault gets when a caller names none. */
val MASTERKEY = "master"

// Additional authenticated data. Every blob is bound to its PLACE in the
// file, so no ciphertext can be moved.
private val AAD_RING = "skmv1:ring:"
private val AAD_META = "skmv1:meta:"
private val AAD_NAME = "skmv1:name"
private val AAD_SECRET = "skmv1:secret:"

// Everything a master can reach is derived from the root key, so a
// rotation is one new random value rather than a re-wrap of each part.
private val LABEL_NAMES = "skmv1:names"
private val LABEL_META = "skmv1:meta"
private val LABEL_ID = "skmv1:id"

/** The largest key id the format can record.
  *
  * `small` writes a length in ONE byte. A longer id wrapped that byte and
  * the writer then appended the whole thing, so every field after it
  * shifted. Checked where an id is ACCEPTED, so the refusal names the id
  * rather than the file.
  */
private val IDMAX = 255

/** The export key the vault API is published under, beside `provider`. */
val VAULT_EXPORT = "vault"

private val MVRANDOM = SecureRandom()

private def mvfail(text: String): Nothing =
  throw SekretoError("sekreto: minivault: " + text)

private def mvutf8(text: String): Array[Byte] = text.getBytes(StandardCharsets.UTF_8)

/** The key a caller asked for, or [[MASTERKEY]]: an EMPTY key is no key.
  * The canonical's `opts.key || MASTERKEY` answers for both absent and
  * empty, where `getOrElse` answers for absent alone - and a CLI reaches
  * this with SEKRETO_VAULT_KEY set and empty, which is what an unset shell
  * variable expands to.
  */
/** The lock every handle on one file shares.
  *
  * Each [[MiniVault]] is its own object, so two handles on one path did
  * not coordinate: both could finish `load` before either saved, and the
  * second rename then discarded the first one's change while reporting
  * success. Keyed by the ABSOLUTE path, so two handles spelled
  * differently still meet.
  *
  * A guarantee WITHIN one process, which is what DOCS.md promises and
  * what the go port arranges the same way. Two processes still race, and
  * the format's answer to that is the exclusive create and the atomic
  * rename: a reader sees one whole vault or the other, never half of one.
  */
private val MVLOCKS = java.util.concurrent.ConcurrentHashMap[String, AnyRef]()

private def mvlockfor(file: String): AnyRef =
  val key =
    try Paths.get(file).toAbsolutePath.normalize.toString
    catch case _: RuntimeException => file

  MVLOCKS.computeIfAbsent(key, _ => Object())

private def mvwantkey(value: String): String =
  if value.isEmpty then MASTERKEY else value

private def mvcheckid(id: Option[String], what: String): String =
  val text = id.getOrElse("")
  if text.isEmpty then mvfail(what)
  if mvutf8(text).length > IDMAX then
    mvfail(s"key id is longer than $IDMAX bytes: ${text.take(32)}...")
  text

// --- keys ------------------------------------------------------------

private def mvhmac(key: Array[Byte], text: String): Array[Byte] =
  try
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    mac.doFinal(mvutf8(text))
  catch case err: GeneralSecurityException => mvfail("hmac: " + err.getMessage)

/** The key-encryption key a passphrase unwraps a ring with. */
private def mvkek(passphrase: String, salt: Array[Byte], iters: Int): Array[Byte] =
  try
    SecretKeyFactory
      .getInstance("PBKDF2WithHmacSHA256")
      .generateSecret(PBEKeySpec(passphrase.toCharArray, salt, iters, KEYLEN * 8))
      .getEncoded
  catch case err: GeneralSecurityException => mvfail("pbkdf2: " + err.getMessage)

/** The key one named secret's value is encrypted with.
  *
  * DERIVED, never stored, for a master: it holds the root key and so
  * reaches every name, including ones written after it was made. A
  * restricted key holds the derived keys it was granted and nothing that
  * produces another.
  */
private def mvsecretkey(root: Array[Byte], name: String): Array[Byte] =
  mvhmac(root, AAD_SECRET + name)

/** Where a secret lives in the file, derived from its own key so that
  * finding it needs no plaintext name.
  */
private def mventryid(key: Array[Byte]): Array[Byte] = mvhmac(key, LABEL_ID)

private def mvrandom(len: Int): Array[Byte] =
  val out = new Array[Byte](len)
  MVRANDOM.nextBytes(out)
  out

// --- sealing ---------------------------------------------------------

/** A nonce and the ciphertext with its tag appended. */
private final case class Sealed(iv: Array[Byte], blob: Array[Byte]):
  def same(other: Sealed): Boolean =
    java.util.Arrays.equals(iv, other.iv) && java.util.Arrays.equals(blob, other.blob)

private def mvseal(key: Array[Byte], plain: Array[Byte], aad: String): Sealed =
  try
    val iv = mvrandom(IVLEN)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAGLEN * 8, iv))
    cipher.updateAAD(mvutf8(aad))
    Sealed(iv, cipher.doFinal(plain))
  catch case err: GeneralSecurityException => mvfail("cannot seal: " + err.getMessage)

/** The plaintext, or a refusal. A GCM tag that fails to verify is the only
  * evidence there is, and it cannot tell a wrong passphrase from a damaged
  * file, so `what` names the attempt and the message admits both.
  */
private def mvunseal(key: Array[Byte], sealed_ : Sealed, aad: String, what: String): Array[Byte] =
  if sealed_.blob.length < TAGLEN || IVLEN != sealed_.iv.length then
    mvfail(what + ": truncated")

  // The WHOLE round-trip is guarded, not only the tag check: a nonce of the
  // wrong length makes `init` itself raise, and a damaged file reaching a
  // caller as a raw GeneralSecurityException is a refusal nobody can act
  // on.
  try
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(
      Cipher.DECRYPT_MODE,
      SecretKeySpec(key, "AES"),
      GCMParameterSpec(TAGLEN * 8, sealed_.iv),
    )
    cipher.updateAAD(mvutf8(aad))
    cipher.doFinal(sealed_.blob)
  catch case NonFatal(_) => mvfail(what)

// THE JSON IS AN ENUM HERE and a plain map everywhere else. This port's
// `Json` carries `Json.Obj` / `Json.Str` rather than `Any`, so a ring
// crosses the boundary twice: `mvplain` on the way in, `mvtagged` on the
// way out. The bytes are the same either way.
private def mvjsonof(plain: Array[Byte], what: String): Map[String, Any] =
  Json.parse(String(plain, StandardCharsets.UTF_8)) match
    case Some(Json.Obj(value)) => value.map((key, one) => (key, mvplain(one))).toMap
    case _                     => mvfail("unreadable " + what)

private def mvplain(value: Json): Any = value match
  case Json.Null       => null
  case Json.Bool(one)  => one
  case Json.Num(one)   => one
  case Json.Str(one)   => one
  case Json.Arr(items) => items.map(mvplain)
  case Json.Obj(pairs) => pairs.map((key, one) => (key, mvplain(one))).toMap

private def mvtagged(value: Any): Json = value match
  case null              => Json.Null
  case one: Boolean      => Json.Bool(one)
  case one: Int          => Json.Num(one.toDouble)
  case one: Double       => Json.Num(one)
  case one: String       => Json.Str(one)
  case one: List[?]      => Json.Arr(one.map(mvtagged))
  case one: ListMap[?, ?] =>
    Json.Obj(ListMap.from(one.map((key, item) => (key.toString, mvtagged(item)))))
  case one: Map[?, ?] =>
    Json.Obj(ListMap.from(one.map((key, item) => (key.toString, mvtagged(item)))))
  case other => mvfail("cannot encode " + other)

private def mvstringify(value: ListMap[String, Any]): String = Json.stringify(mvtagged(value))

private def mvb64(bytes: Array[Byte]): String = Base64.getEncoder.encodeToString(bytes)

private def mvunb64(text: Any, what: String): Array[Byte] = text match
  case one: String =>
    try Base64.getDecoder.decode(one)
    catch case _: IllegalArgumentException => mvfail("missing " + what)
  case _ => mvfail("missing " + what)

// --- the file --------------------------------------------------------

private final case class KeyRecord(
    id: String,
    salt: Array[Byte],
    iters: Int,
    ring: Sealed,
    meta: Sealed,
)

private final case class EntryRecord(id: Array[Byte], name: Sealed, value: Sealed)

private final case class VaultFile(keys: List[KeyRecord], entries: List[EntryRecord])

/** A cursor, so that every length check is in one place: a truncated vault
  * is refused rather than read as a short one.
  */
private final class MvReader(bytes: Array[Byte]):
  private var at = 0

  def take(len: Int): Array[Byte] =
    if len < 0 || bytes.length < at + len then mvfail("the vault file is truncated")
    val out = bytes.slice(at, at + len)
    at += len
    out

  def u8: Int = take(1)(0) & 0xff

  def u32: Int =
    // A length over Int.MaxValue cannot address an array, and reading it as
    // a negative int is what turned a damaged file into a crash instead of
    // a refusal.
    val value = ByteBuffer.wrap(take(4)).getInt.toLong & 0xffffffffL
    if value > Int.MaxValue then mvfail("the vault file is truncated")
    value.toInt

  def small: Array[Byte] = take(u8)
  def large: Array[Byte] = take(u32)
  def magic: String = String(take(4), StandardCharsets.ISO_8859_1)
  def sealedvalue: Sealed = Sealed(small, large)
  def done: Boolean = at == bytes.length

private def mvreadfile(bytes: Array[Byte]): VaultFile =
  val read = MvReader(bytes)

  if MAGIC != read.magic then mvfail("not a vault file")

  val version = read.u8
  if FORMAT != version then mvfail(s"unsupported format version: $version")

  val kdf = read.u8
  val cipher = read.u8
  if KDF_PBKDF2 != kdf || CIPHER_AESGCM != cipher then
    mvfail(s"unsupported kdf or cipher: $kdf/$cipher")
  read.u8

  val keys = List.fill(read.u32):
    KeyRecord(
      String(read.small, StandardCharsets.UTF_8),
      read.small,
      read.u32,
      read.sealedvalue,
      read.sealedvalue,
    )

  val entries = List.fill(read.u32):
    EntryRecord(read.small, read.sealedvalue, read.sealedvalue)

  if !read.done then mvfail("the vault file has trailing bytes")

  VaultFile(keys, entries)

/** Unsigned, byte by byte, the way every other port sorts. */
private def mvcompare(left: Array[Byte], right: Array[Byte]): Int =
  var index = 0
  var out = 0

  while out == 0 && index < math.min(left.length, right.length) do
    val one = left(index) & 0xff
    val two = right(index) & 0xff
    if one != two then out = if one < two then -1 else 1
    index += 1

  if out != 0 then out else left.length.compare(right.length)

private def mvwritefile(vault: VaultFile): Array[Byte] =
  val out = java.io.ByteArrayOutputStream()

  def raw(bytes: Array[Byte]): Unit = out.write(bytes)
  def u8(value: Int): Unit = out.write(value & 0xff)
  def u32(value: Int): Unit = raw(ByteBuffer.allocate(4).putInt(value).array)
  def small(bytes: Array[Byte]): Unit = { u8(bytes.length); raw(bytes) }
  def large(bytes: Array[Byte]): Unit = { u32(bytes.length); raw(bytes) }
  def sealedvalue(value: Sealed): Unit = { small(value.iv); large(value.blob) }

  raw(MAGIC.getBytes(StandardCharsets.ISO_8859_1))
  u8(FORMAT)
  u8(KDF_PBKDF2)
  u8(CIPHER_AESGCM)
  u8(0)

  u32(vault.keys.length)
  for key <- vault.keys do
    small(mvutf8(key.id))
    small(key.salt)
    u32(key.iters)
    sealedvalue(key.ring)
    sealedvalue(key.meta)

  // SORTED BY ID, which is a blinded value: the file therefore records
  // nothing about the order secrets were written in.
  val entries = vault.entries.sortWith((left, right) => mvcompare(left.id, right.id) < 0)

  u32(entries.length)
  for entry <- entries do
    small(entry.id)
    sealedvalue(entry.name)
    sealedvalue(entry.value)

  out.toByteArray

// --- what a key is ---------------------------------------------------

/** What a key may do. `grants` is empty for a master key.
  *
  * A case class of `val` fields over an immutable list, so what a caller is
  * handed cannot become what the vault believes: `info.write = true` does
  * not compile.
  */
final case class VaultKeyInfo(
    key: String,
    master: Boolean,
    write: Boolean,
    grants: List[String],
):
  def show: String = s"$key/$master/$write/${grants.mkString("[", ", ", "]")}"

/** What a caller asks for when minting a restricted key. */
final case class GrantSpec(
    key: String,
    passphrase: String,
    names: List[String] = Nil,
    write: Boolean = false,
    iterations: Option[Int] = None,
)

/** How a vault handle is configured. */
final case class VaultOptions(
    file: String,
    passphrase: String,
    key: String = MASTERKEY,
    iterations: Int = MINIVAULT_ITERATIONS,
    create: Boolean = false,
)

private final case class Opened(
    info: VaultKeyInfo,
    root: Option[Array[Byte]],
    grants: Map[String, Array[Byte]],
    ring: Sealed,
)

// --- creating --------------------------------------------------------

private def mvnewvault(keyid: String, passphrase: String, iterations: Int): VaultFile =
  val root = mvrandom(KEYLEN)
  val salt = mvrandom(SALTLEN)

  val ring = ListMap[String, Any]("v" -> FORMAT, "write" -> true, "root" -> mvb64(root))
  val meta =
    ListMap[String, Any]("v" -> FORMAT, "master" -> true, "write" -> true, "grants" -> List())

  VaultFile(
    List(
      KeyRecord(
        keyid,
        salt,
        iterations,
        mvseal(mvkek(passphrase, salt, iterations), mvutf8(mvstringify(ring)), AAD_RING + keyid),
        mvseal(mvhmac(root, LABEL_META), mvutf8(mvstringify(meta)), AAD_META + keyid),
      ),
    ),
    Nil,
  )

private def mvowneronly(path: Path): Unit =
  try Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rw-------"))
  catch
    // A filesystem with no POSIX permissions is not a reason to refuse a
    // write that otherwise succeeded.
    case _: IOException                   => ()
    case _: UnsupportedOperationException  => ()

/** Write a vault file that is not there yet, and REFUSE one that is.
  *
  * Straight to the target with CREATE_NEW rather than through a temporary
  * and a rename. A rename REPLACES its destination, so two processes
  * creating the same vault both succeeded and the second discarded the
  * first one's secrets.
  */
private def mvputnew(file: String, vault: VaultFile): Unit =
  val path = Path.of(file)
  try
    Files.write(path, mvwritefile(vault), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
    mvowneronly(path)
  catch
    case _: FileAlreadyExistsException => mvfail("vault file already exists: " + file)
    case err: IOException              => mvfail(s"cannot write $file: ${err.getMessage}")

/** A handle on one vault file, opened as ONE key.
  *
  * Every method answers as that key: `list` shows the names it may read,
  * `get` answers for those and misses on the rest, and the master-only
  * methods refuse for any other key. Nothing is read or derived until the
  * first call that needs the file.
  */
final class MiniVault private[plugins] (options: VaultOptions):

  if options.file.isEmpty then mvfail("a vault needs a file")
  if options.passphrase.isEmpty then mvfail("a vault needs a passphrase")

  private val thefile = options.file
  private val thekey = mvcheckid(Some(mvwantkey(options.key)), "a vault needs a key id")
  private val thephrase = options.passphrase
  private val theiters = options.iterations
  private val thecreate = options.create

  private var opened: Option[Opened] = None

  /** The file this handle reads. */
  def file: String = thefile

  /** The key id this handle opens with. */
  def key: String = thekey

  /** Derive the key and read the file NOW rather than at first use. */
  def open: VaultKeyInfo = load._2.info

  /** Forget the derived keys. The next call opens again. */
  def close(): Unit = opened = None

  /** The names this key can read, sorted. */
  def list: List[String] =
    val (vault, state) = load

    state.root match
      case Some(root) =>
        val namekey = mvhmac(root, LABEL_NAMES)
        vault.entries
          .map(entry =>
            String(
              mvunseal(namekey, entry.name, AAD_NAME, "a secret name is damaged"),
              StandardCharsets.UTF_8,
            ),
          )
          .sorted

      // A restricted key has no name key, so it reports the grants it can
      // actually find: the vault never tells it what else is in there.
      case None =>
        state.info.grants.filter(name => findentry(vault, state.grants.get(name)).isDefined).sorted

  def has(name: String): Boolean = get(name).isDefined

  /** The value, or None when the vault does not hold that name or this key
    * was not granted it.
    */
  def get(name: String): Option[String] =
    checkname(name)
    val (vault, state) = load

    // OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as the
    // key that opened it, so a name this key cannot read is a name this
    // store does not hold for this caller.
    keyfor(state, name).flatMap: key =>
      findentry(vault, Some(key)).map: entry =>
        String(
          mvunseal(key, entry.value, AAD_SECRET + name, s"the value of $name is damaged"),
          StandardCharsets.UTF_8,
        )

  /** Write a value. A master writes any name; a restricted key holding
    * `write` overwrites the names it was granted, and creates none.
    */
  def set(name: String, value: String): Unit =
    // Every write on this file, from any handle in this process,
    // serializes here; see mvlockfor.
    mvlockfor(file).synchronized:
      checkname(name)
      val (vault, state) = load

      if !state.info.write then mvfail(s"key ${state.info.key} is read-only")

      val key = keyfor(state, name).getOrElse(
        mvfail(s"key ${state.info.key} was not granted $name"),
      )

      val sealedvalue = mvseal(key, mvutf8(value), AAD_SECRET + name)
      val id = mventryid(key)

      val entries =
        if vault.entries.exists(entry => java.util.Arrays.equals(entry.id, id)) then
          vault.entries.map: entry =>
            if java.util.Arrays.equals(entry.id, id) then entry.copy(value = sealedvalue) else entry
        else
          // A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
          // restricted key with `write` updates what it was granted and cannot
          // grow the vault.
          val root = rootof(state, s"creating the secret $name")
          vault.entries :+ EntryRecord(
            id,
            mvseal(mvhmac(root, LABEL_NAMES), mvutf8(name), AAD_NAME),
            sealedvalue,
          )

      save(vault.copy(entries = entries))

  /** Drop a name. Master only. */
  def remove(name: String): Unit =
    // Every write on this file, from any handle in this process,
    // serializes here; see mvlockfor.
    mvlockfor(file).synchronized:
      checkname(name)
      val (vault, state) = load
      val root = rootof(state, "removing a secret")

      val wanted = mventryid(mvsecretkey(root, name))
      if !vault.entries.exists(entry => java.util.Arrays.equals(entry.id, wanted)) then
        mvfail(s"no such secret: $name")

      save(
        vault.copy(entries =
          vault.entries.filterNot(entry => java.util.Arrays.equals(entry.id, wanted)),
        ),
      )

  /** Every key in the file, with what it may do. Master only. */
  def keys: List[VaultKeyInfo] =
    val (vault, state) = load
    rootof(state, "listing the keys")

    vault.keys.map: record =>
      metaof(state, record) match
        case None => VaultKeyInfo(record.id, false, false, Nil)
        case Some(meta) =>
          val grants = meta.get("grants") match
            case Some(items: List[?]) => items.map(_.toString).sorted
            case _                    => Nil
          VaultKeyInfo(
            record.id,
            meta.get("master").contains(true),
            meta.get("write").contains(true),
            grants,
          )

  /** Mint a restricted key. Master only. */
  def grant(spec: GrantSpec): Unit =
    // Every write on this file, from any handle in this process,
    // serializes here; see mvlockfor.
    mvlockfor(file).synchronized:
      val (vault, state) = load
      val root = rootof(state, "granting a key")

      val id = mvcheckid(Some(spec.key), "a grant needs a key id")
      if spec.passphrase.isEmpty then mvfail("a grant needs a passphrase")
      if vault.keys.exists(_.id == id) then mvfail(s"key already exists: $id")

      val names = spec.names.sorted

      // A ListMap built from the sorted names, for a ring whose JSON is the
      // same text on every run. It is NOT an interop requirement - the ring
      // is sealed under a fresh nonce, so its ciphertext differs per write
      // whatever the key order is.
      val grants = ListMap.from(names.map: name =>
        checkname(name)
        (name, mvb64(mvsecretkey(root, name))))

      val record = sealkey(
        root,
        id,
        spec.passphrase,
        spec.iterations.getOrElse(theiters),
        ListMap[String, Any]("v" -> FORMAT, "write" -> spec.write, "grants" -> grants),
        ListMap[String, Any](
          "v" -> FORMAT,
          "master" -> false,
          "write" -> spec.write,
          "grants" -> names,
        ),
      )

      save(vault.copy(keys = vault.keys :+ record))

  /** Drop a key. Master only.
    *
    * Anyone who already copied the file keeps whatever that key could read,
    * so revoking bars future reads of the LIVE file and `rotate` is what
    * takes a secret back.
    */
  def revoke(key: String): Unit =
    // Every write on this file, from any handle in this process,
    // serializes here; see mvlockfor.
    mvlockfor(file).synchronized:
      val (vault, state) = load
      rootof(state, "revoking a key")

      if key == state.info.key then mvfail(s"a key cannot revoke itself: $key")
      if !vault.keys.exists(_.id == key) then mvfail(s"no such key: $key")

      save(vault.copy(keys = vault.keys.filterNot(_.id == key)))

  /** A new root key, every value re-encrypted under it, and EVERY OTHER KEY
    * DROPPED. Master only.
    *
    * The other keys go because they must: their rings are sealed under
    * passphrases this process does not have. Re-grant afterwards.
    */
  def rotate(): Unit =
    // Every write on this file, from any handle in this process,
    // serializes here; see mvlockfor.
    mvlockfor(file).synchronized:
      val (vault, state) = load
      rootof(state, "rotating the vault")

      // Read everything out under the old root before anything changes: once
      // the root is replaced the old derived keys are unreachable.
      val plain = list.map(name => (name, get(name).getOrElse("")))

      val root = mvrandom(KEYLEN)
      val namekey = mvhmac(root, LABEL_NAMES)

      val entries = plain.map: (name, value) =>
        val key = mvsecretkey(root, name)
        EntryRecord(
          mventryid(key),
          mvseal(namekey, mvutf8(name), AAD_NAME),
          mvseal(key, mvutf8(value), AAD_SECRET + name),
        )

      val iters = vault.keys.find(_.id == thekey).map(_.iters).getOrElse(theiters)

      val record = sealkey(
        root,
        thekey,
        thephrase,
        iters,
        ListMap[String, Any]("v" -> FORMAT, "write" -> true, "root" -> mvb64(root)),
        ListMap[String, Any]("v" -> FORMAT, "master" -> true, "write" -> true, "grants" -> List()),
      )

      // SAVE FIRST, adopt second. A handle holding the new root over a file
      // that still holds the old one reads nothing and says the vault is
      // damaged.
      write(VaultFile(List(record), entries))

      opened = Some(
        Opened(VaultKeyInfo(thekey, true, true, Nil), Some(root), Map.empty, record.ring),
      )

  // --- the inside ----------------------------------------------------

  private def bytes: Array[Byte] =
    try Files.readAllBytes(Path.of(thefile))
    catch
      case _: NoSuchFileException =>
        // A vault is configured deliberately, with a key. Its absence is a
        // broken deployment and never "no secrets here": answering a miss
        // would send the chain on to a weaker store.
        if !thecreate then mvfail(s"no vault file: $thefile")
        mvputnew(thefile, mvnewvault(thekey, thephrase, theiters))
        try Files.readAllBytes(Path.of(thefile))
        catch case err: IOException => mvfail(s"cannot read $thefile: ${err.getMessage}")
      case err: IOException => mvfail(s"cannot read $thefile: ${err.getMessage}")

  private def load: (VaultFile, Opened) =
    val vault = mvreadfile(bytes)

    val record = vault.keys.find(_.id == thekey).getOrElse:
      // REVOKED, or never there. Either way this handle is finished, and
      // dropping what it derived is what stops the next call answering from
      // memory.
      opened = None
      mvfail(s"no such key: $thekey")

    // The file still holds this key, and holds the SAME ring: a key revoked
    // and re-granted under another passphrase is a different key wearing
    // the id, and re-deriving is what refuses it.
    opened match
      case Some(held) if held.ring.same(record.ring) => (vault, held)
      case _ =>
        opened = None

        val plain = mvunseal(
          mvkek(thephrase, record.salt, record.iters),
          record.ring,
          AAD_RING + thekey,
          s"wrong passphrase for key $thekey, or a damaged vault",
        )

        val ring = mvjsonof(plain, s"key ring for $thekey")

        val grants = ring.get("grants") match
          case Some(pairs: Map[?, ?]) =>
            pairs.map((name, one) => (name.toString, mvunb64(one, "a granted key"))).toMap
          case _ => Map.empty[String, Array[Byte]]

        val root = ring.get("root")

        val next = Opened(
          VaultKeyInfo(
            thekey,
            root.isDefined,
            root.isDefined || ring.get("write").contains(true),
            grants.keys.toList.sorted,
          ),
          root.map(one => mvunb64(one, "the root key")),
          grants,
          record.ring,
        )

        opened = Some(next)
        (vault, next)

  private def rootof(state: Opened, what: String): Array[Byte] =
    state.root.getOrElse(
      mvfail(s"$what needs a master key, and ${state.info.key} is restricted"),
    )

  /** The key for one name, or None when this key cannot reach it. */
  private def keyfor(state: Opened, name: String): Option[Array[Byte]] =
    state.root match
      case Some(root) => Some(mvsecretkey(root, name))
      case None       => state.grants.get(name)

  private def findentry(vault: VaultFile, key: Option[Array[Byte]]): Option[EntryRecord] =
    key.flatMap: one =>
      val id = mventryid(one)
      vault.entries.find(entry => java.util.Arrays.equals(entry.id, id))

  private def metaof(state: Opened, record: KeyRecord): Option[Map[String, Any]] =
    val root = rootof(state, "reading key metadata")
    val what = s"metadata for key ${record.id}"

    try
      Some(
        mvjsonof(
          mvunseal(mvhmac(root, LABEL_META), record.meta, AAD_META + record.id, what),
          what,
        ),
      )
    catch
      // A record written under a root key this one has replaced. The key is
      // still in the file and still opens with its own passphrase, so it is
      // reported rather than hidden - with what it can do unknown.
      case _: SekretoError => None

  private def sealkey(
      root: Array[Byte],
      id: String,
      phrase: String,
      iters: Int,
      ring: ListMap[String, Any],
      meta: ListMap[String, Any],
  ): KeyRecord =
    val salt = mvrandom(SALTLEN)
    KeyRecord(
      id,
      salt,
      iters,
      mvseal(mvkek(phrase, salt, iters), mvutf8(mvstringify(ring)), AAD_RING + id),
      mvseal(mvhmac(root, LABEL_META), mvutf8(mvstringify(meta)), AAD_META + id),
    )

  private def save(vault: VaultFile): Unit = write(vault)

  /** Read, change, and REPLACE - never edit in place.
    *
    * THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
    * anyone can predict, so anyone who can write the vault's directory
    * could put a symlink there and have the next save truncate whatever it
    * pointed at.
    */
  private def write(vault: VaultFile): Unit =
    val suffix = mvrandom(8).map(one => f"${one & 0xff}%02x").mkString
    val temp = Path.of(s"$thefile.$suffix.tmp")

    try
      Files.write(temp, mvwritefile(vault), StandardOpenOption.CREATE_NEW,
        StandardOpenOption.WRITE)
      mvowneronly(temp)
      Files.move(temp, Path.of(thefile), StandardCopyOption.REPLACE_EXISTING)
    catch
      case err: IOException =>
        try Files.deleteIfExists(temp)
        catch
          // The vault is unchanged either way, and the write error is what
          // the caller needs to be told about.
          case _: IOException => ()
        mvfail(s"cannot write $thefile: ${err.getMessage}")

/** Open a vault file as one key.
  *
  * The handle is lazy. Nothing is read, and no passphrase is stretched,
  * until a method needs the file.
  */
def openvault(options: VaultOptions): MiniVault = MiniVault(options)

/** Make a vault file and return a handle on its master key.
  *
  * Refuses a file that is already there: a vault is created once, and
  * overwriting one discards every secret in it.
  */
def createvault(options: VaultOptions): MiniVault =
  if options.file.isEmpty then mvfail("a vault needs a file")
  if options.passphrase.isEmpty then mvfail("a vault needs a passphrase")
  val keyid = mvcheckid(Some(mvwantkey(options.key)), "a vault needs a key id")

  // No existence check first: the check and the write would be two steps,
  // and `mvputnew` refuses an existing file in ONE.
  mvputnew(options.file, mvnewvault(keyid, options.passphrase, options.iterations))

  MiniVault(options)

// --- the provider ----------------------------------------------------

/** Read a vault as one store in a chain.
  *
  * The provider is the READ half and nothing more: a chain resolves
  * secrets, and writing one is a deliberate act with an API of its own.
  */
private final class MiniVaultProvider(vault: MiniVault) extends Provider:
  def lookup(name: String): Option[String] = vault.get(name)
  def describe(): String = "minivault:" + vault.file

def providerof(vault: MiniVault): Provider = MiniVaultProvider(vault)

/** A vault provider from options, for a chain built by hand. */
def minivaultprovider(options: VaultOptions): Provider = providerof(openvault(options))

/** The `minivault` provider kind, as a voxgig/plugin definition.
  *
  * Written out rather than built by `providerplugin`, because this
  * definition publishes TWO exports: `provider`, the read half every kind
  * publishes, and `vault`, the programmatic API.
  */
val minivault: Definition =
  val define: Inst => Unit = inst =>
    val spec = specof(inst.options)

    val vault =
      try
        // `openvault` refuses bad configuration HERE, so a mistyped chain
        // fails at construction. Reaching the FILE is not configuration:
        // the handle is lazy.
        openvault(
          VaultOptions(
            file = spec.file.getOrElse(""),
            passphrase = spec.passphrase.getOrElse(""),
            key = mvwantkey(spec.vaultkey.getOrElse("")),
            iterations = spec.iterations.getOrElse(MINIVAULT_ITERATIONS),
            create = spec.create.contains(true),
          ),
        )
      catch
        case err: SekretoError =>
          val text = Option(err.getMessage).getOrElse("")
          throw PluginError(ERROR_CODE, text, Map("ref" -> VStr(inst.ref), "cause" -> VStr(text)))

    inst.`export`(PROVIDER_EXPORT, VOpaque(providerof(vault)))
    inst.`export`(VAULT_EXPORT, VOpaque(vault))

  voxgig.plugin.Definition(name = "minivault", define = Some(define))

/** The vault behind a store in a chain, as its programmatic API.
  *
  * With no store named, the unqualified alias answers: one vault in the
  * chain resolves whatever it is called, and two raise rather than picking
  * one.
  */
def vaultof(secrets: Sekreto, store: Option[String] = None): MiniVault =
  store match
    case None =>
      secrets.host.exports("minivault/" + VAULT_EXPORT) match
        case VOpaque(vault: MiniVault) => vault
        case _                         => mvfail("no minivault store in this chain")

    case Some(name) =>
      // A NAMED STORE MUST EXIST, and the alias must not stand in for it.
      // `host.exports` falls back to the alias when the exact ref misses,
      // so asking for `minivault` in a chain whose only vault is named
      // `app` used to hand back the `app` vault - and then write to it.
      val eref = if "minivault" == name then "minivault" else "minivault$" + name

      if secrets.host.instance(VStr(eref)).isEmpty then
        mvfail(s"no minivault store named $name in this chain")

      secrets.host.exports(eref + "/" + VAULT_EXPORT) match
        case VOpaque(vault: MiniVault) => vault
        case _ => mvfail(s"no minivault store named $name in this chain")
