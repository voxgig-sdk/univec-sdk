// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (java/plugins/com/voxgig/sekreto/plugins/Minivault.java)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The mini vault, as a voxgig/plugin definition.
//
// A port of typescript/plugins/minivault.ts, which is canonical.
//
// A PLUGIN, NOT PART OF THE CORE: it needs crypto, which is the line the
// four built-ins stay behind. See docs/design/plugin-providers.md.
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

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import JAVAPACKAGE.feature.secrets.sekreto.Json;
import JAVAPACKAGE.feature.secrets.sekreto.Provider;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import JAVAPACKAGE.feature.secrets.sekreto.Support;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.PBEKeySpec;
import javax.crypto.spec.SecretKeySpec;
import JAVAPACKAGE.feature.secrets.plugin.Definition;
import JAVAPACKAGE.feature.secrets.plugin.PluginException;

/**
 * A mini vault: every secret a project owns, encrypted, in ONE FILE.
 *
 * <p>The format:
 *
 * <pre>
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
 * </pre>
 *
 * <p>Integers are big-endian, and every length precedes its bytes. A file one port writes is read
 * by every other; `test/fixture` pins that with a committed vault rather than with agreement.
 */
public final class Minivault {

  private Minivault() {}

  static final String MAGIC = "SKMV";
  static final int FORMAT = 1;
  static final int KDF_PBKDF2 = 1;
  static final int CIPHER_AESGCM = 1;

  /** AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags. */
  static final int KEYLEN = 32;

  static final int IVLEN = 12;
  static final int TAGLEN = 16;
  static final int SALTLEN = 16;

  /** PBKDF2-HMAC-SHA256 rounds when a caller names none. */
  public static final int ITERATIONS = 210000;

  /** The key id a vault gets when a caller names none. */
  public static final String MASTERKEY = "master";

  // Additional authenticated data. Every blob is bound to its PLACE in the
  // file, so no ciphertext can be moved.
  static final String AAD_RING = "skmv1:ring:";
  static final String AAD_META = "skmv1:meta:";
  static final String AAD_NAME = "skmv1:name";
  static final String AAD_SECRET = "skmv1:secret:";

  // Everything a master can reach is derived from the root key, so a
  // rotation is one new random value rather than a re-wrap of each part.
  static final String LABEL_NAMES = "skmv1:names";
  static final String LABEL_META = "skmv1:meta";
  static final String LABEL_ID = "skmv1:id";

  /**
   * The largest key id the format can record.
   *
   * <p>`small` writes a length in ONE byte. A longer id wrapped that byte and the writer then
   * appended the whole thing, so every field after it shifted. Checked where an id is ACCEPTED, so
   * the refusal names the id rather than the file.
   */
  static final int IDMAX = 255;

  /** The export key the vault API is published under, beside `provider`. */
  public static final String VAULT_EXPORT = "vault";

  private static final SecureRandom RANDOM = new SecureRandom();

  static SekretoError fail(String text) {
    return new SekretoError("sekreto: minivault: " + text);
  }

  static String checkid(Object id, String what) {
    if (!(id instanceof String) || ((String) id).isEmpty()) {
      throw fail(what);
    }
    String text = (String) id;
    if (utf8(text).length > IDMAX) {
      throw fail(
          "key id is longer than "
              + IDMAX
              + " bytes: "
              + text.substring(0, Math.min(32, text.length()))
              + "...");
    }
    return text;
  }

  static byte[] utf8(String text) {
    return text.getBytes(StandardCharsets.UTF_8);
  }

  // --- keys ------------------------------------------------------------

  static byte[] hmac(byte[] key, String text) {
    try {
      Mac mac = Mac.getInstance("HmacSHA256");
      mac.init(new SecretKeySpec(key, "HmacSHA256"));
      return mac.doFinal(utf8(text));
    } catch (GeneralSecurityException err) {
      throw fail("hmac: " + err.getMessage());
    }
  }

  /** The key-encryption key a passphrase unwraps a ring with. */
  static byte[] kek(String passphrase, byte[] salt, int iters) {
    try {
      SecretKeyFactory factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256");
      return factory
          .generateSecret(new PBEKeySpec(passphrase.toCharArray(), salt, iters, KEYLEN * 8))
          .getEncoded();
    } catch (GeneralSecurityException err) {
      throw fail("pbkdf2: " + err.getMessage());
    }
  }

  /**
   * The key one named secret's value is encrypted with.
   *
   * <p>DERIVED, never stored, for a master: it holds the root key and so reaches every name,
   * including ones written after it was made. A restricted key holds the derived keys it was
   * granted and nothing that produces another.
   */
  static byte[] secretkey(byte[] root, String name) {
    return hmac(root, AAD_SECRET + name);
  }

  /**
   * Where a secret lives in the file, derived from its own key so that finding it needs no
   * plaintext name.
   */
  static byte[] entryid(byte[] key) {
    return hmac(key, LABEL_ID);
  }

  static byte[] random(int len) {
    byte[] out = new byte[len];
    RANDOM.nextBytes(out);
    return out;
  }

  // --- sealing ---------------------------------------------------------

  /** A nonce and the ciphertext with its tag appended. */
  static final class Sealed {
    final byte[] iv;
    final byte[] blob;

    Sealed(byte[] iv, byte[] blob) {
      this.iv = iv;
      this.blob = blob;
    }
  }

  static Sealed seal(byte[] key, byte[] plain, String aad) {
    try {
      byte[] iv = random(IVLEN);
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(
          Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(TAGLEN * 8, iv));
      cipher.updateAAD(utf8(aad));
      return new Sealed(iv, cipher.doFinal(plain));
    } catch (GeneralSecurityException err) {
      throw fail("cannot seal: " + err.getMessage());
    }
  }

  /**
   * The plaintext, or a refusal. A GCM tag that fails to verify is the only evidence there is, and
   * it cannot tell a wrong passphrase from a damaged file, so `what` names the attempt and the
   * message admits both.
   */
  static byte[] unseal(byte[] key, Sealed sealed, String aad, String what) {
    if (sealed.blob.length < TAGLEN || IVLEN != sealed.iv.length) {
      throw fail(what + ": truncated");
    }

    // The WHOLE round-trip is guarded, not only the final block: a nonce
    // of the wrong length makes `init` itself raise, and a damaged file
    // reaching a caller as a raw GeneralSecurityException is a refusal
    // nobody can act on.
    try {
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(
          Cipher.DECRYPT_MODE,
          new SecretKeySpec(key, "AES"),
          new GCMParameterSpec(TAGLEN * 8, sealed.iv));
      cipher.updateAAD(utf8(aad));
      return cipher.doFinal(sealed.blob);
    } catch (GeneralSecurityException | RuntimeException err) {
      throw fail(what);
    }
  }

  @SuppressWarnings("unchecked")
  static Map<String, Object> jsonof(byte[] plain, String what) {
    Object parsed;
    try {
      parsed = Json.parse(new String(plain, StandardCharsets.UTF_8));
    } catch (RuntimeException err) {
      throw fail("unreadable " + what);
    }
    if (!(parsed instanceof Map)) {
      throw fail("unreadable " + what);
    }
    return (Map<String, Object>) parsed;
  }

  static String b64(byte[] bytes) {
    return Base64.getEncoder().encodeToString(bytes);
  }

  static byte[] unb64(Object text, String what) {
    if (!(text instanceof String)) {
      throw fail("missing " + what);
    }
    try {
      return Base64.getDecoder().decode((String) text);
    } catch (IllegalArgumentException err) {
      throw fail("missing " + what);
    }
  }

  // --- the file --------------------------------------------------------

  static final class KeyRecord {
    String id;
    byte[] salt;
    int iters;
    Sealed ring;
    Sealed meta;
  }

  static final class EntryRecord {
    byte[] id;
    Sealed name;
    Sealed value;
  }

  static final class VaultFile {
    final List<KeyRecord> keys = new ArrayList<>();
    final List<EntryRecord> entries = new ArrayList<>();
  }

  /**
   * A cursor, so that every length check is in one place: a truncated vault is refused rather than
   * read as a short one.
   */
  static final class Reader {
    private final byte[] bytes;
    private int at;

    Reader(byte[] bytes) {
      this.bytes = bytes;
    }

    byte[] take(int len) {
      if (len < 0 || bytes.length < at + len) {
        throw fail("the vault file is truncated");
      }
      byte[] out = Arrays.copyOfRange(bytes, at, at + len);
      at += len;
      return out;
    }

    int u8() {
      return take(1)[0] & 0xff;
    }

    int u32() {
      // A length over Integer.MAX_VALUE cannot address a byte array, and
      // reading it as a negative int is what turned a damaged file into a
      // crash instead of a refusal.
      long value = ByteBuffer.wrap(take(4)).getInt() & 0xffffffffL;
      if (value > Integer.MAX_VALUE) {
        throw fail("the vault file is truncated");
      }
      return (int) value;
    }

    byte[] small() {
      return take(u8());
    }

    byte[] large() {
      return take(u32());
    }

    String magic() {
      return new String(take(4), StandardCharsets.ISO_8859_1);
    }

    Sealed sealed() {
      return new Sealed(small(), large());
    }

    boolean done() {
      return at == bytes.length;
    }
  }

  static VaultFile readfile(byte[] bytes) {
    Reader read = new Reader(bytes);

    if (!MAGIC.equals(read.magic())) {
      throw fail("not a vault file");
    }

    int version = read.u8();
    if (FORMAT != version) {
      throw fail("unsupported format version: " + version);
    }

    int kdf = read.u8();
    int cipher = read.u8();
    if (KDF_PBKDF2 != kdf || CIPHER_AESGCM != cipher) {
      throw fail("unsupported kdf or cipher: " + kdf + "/" + cipher);
    }
    read.u8();

    VaultFile vault = new VaultFile();

    int keycount = read.u32();
    for (int index = 0; index < keycount; index++) {
      KeyRecord record = new KeyRecord();
      record.id = new String(read.small(), StandardCharsets.UTF_8);
      record.salt = read.small();
      record.iters = read.u32();
      record.ring = read.sealed();
      record.meta = read.sealed();
      vault.keys.add(record);
    }

    int entrycount = read.u32();
    for (int index = 0; index < entrycount; index++) {
      EntryRecord entry = new EntryRecord();
      entry.id = read.small();
      entry.name = read.sealed();
      entry.value = read.sealed();
      vault.entries.add(entry);
    }

    if (!read.done()) {
      throw fail("the vault file has trailing bytes");
    }

    return vault;
  }

  static byte[] writefile(VaultFile vault) {
    Writer out = new Writer();

    out.raw(MAGIC.getBytes(StandardCharsets.ISO_8859_1));
    out.u8(FORMAT);
    out.u8(KDF_PBKDF2);
    out.u8(CIPHER_AESGCM);
    out.u8(0);

    out.u32(vault.keys.size());
    for (KeyRecord key : vault.keys) {
      out.small(utf8(key.id));
      out.small(key.salt);
      out.u32(key.iters);
      out.sealed(key.ring);
      out.sealed(key.meta);
    }

    // SORTED BY ID, which is a blinded value: the file therefore records
    // nothing about the order secrets were written in.
    List<EntryRecord> entries = new ArrayList<>(vault.entries);
    entries.sort(Comparator.comparing(entry -> entry.id, Arrays::compareUnsigned));

    out.u32(entries.size());
    for (EntryRecord entry : entries) {
      out.small(entry.id);
      out.sealed(entry.name);
      out.sealed(entry.value);
    }

    return out.bytes();
  }

  private static final class Writer {
    private byte[] buffer = new byte[256];
    private int at;

    void raw(byte[] bytes) {
      if (buffer.length < at + bytes.length) {
        buffer = Arrays.copyOf(buffer, Math.max(buffer.length * 2, at + bytes.length));
      }
      System.arraycopy(bytes, 0, buffer, at, bytes.length);
      at += bytes.length;
    }

    void u8(int value) {
      raw(new byte[] {(byte) value});
    }

    void u32(int value) {
      raw(ByteBuffer.allocate(4).putInt(value).array());
    }

    void small(byte[] bytes) {
      u8(bytes.length);
      raw(bytes);
    }

    void large(byte[] bytes) {
      u32(bytes.length);
      raw(bytes);
    }

    void sealed(Sealed value) {
      small(value.iv);
      large(value.blob);
    }

    byte[] bytes() {
      return Arrays.copyOf(buffer, at);
    }
  }

  // --- what a key is ---------------------------------------------------

  /** What a key may do. `grants` is empty for a master key. */
  public static final class KeyInfo {
    public final String key;
    public final boolean master;
    public final boolean write;
    public final List<String> grants;

    KeyInfo(String key, boolean master, boolean write, List<String> grants) {
      this.key = key;
      this.master = master;
      this.write = write;
      this.grants = List.copyOf(grants);
    }

    @Override
    public boolean equals(Object other) {
      if (!(other instanceof KeyInfo)) {
        return false;
      }
      KeyInfo that = (KeyInfo) other;
      return key.equals(that.key)
          && master == that.master
          && write == that.write
          && grants.equals(that.grants);
    }

    @Override
    public int hashCode() {
      return key.hashCode();
    }

    @Override
    public String toString() {
      return "{key=" + key + ", master=" + master + ", write=" + write + ", grants=" + grants + "}";
    }
  }

  /** What a caller asks for when minting a restricted key. */
  public static final class Grant {
    String key;
    String passphrase;
    List<String> names = List.of();
    boolean write;
    Integer iterations;

    public Grant key(String value) {
      this.key = value;
      return this;
    }

    public Grant passphrase(String value) {
      this.passphrase = value;
      return this;
    }

    public Grant names(List<String> value) {
      this.names = value;
      return this;
    }

    public Grant write(boolean value) {
      this.write = value;
      return this;
    }

    public Grant iterations(int value) {
      this.iterations = value;
      return this;
    }
  }

  /**
   * The key a caller asked for, or {@code master}: an EMPTY key is no key.
   * The canonical's {@code opts.key || MASTERKEY} answers for both null
   * and empty, and a CLI reaches this with SEKRETO_VAULT_KEY set and
   * empty, which is what an unset shell variable expands to.
   */
  private static String wantkey(String value) {
    return null == value || value.isEmpty() ? MASTERKEY : value;
  }

  /** How a vault handle is configured. */
  public static final class Options {
    String file;
    String key = MASTERKEY;
    String passphrase;
    int iterations = ITERATIONS;
    boolean create;

    public Options file(String value) {
      this.file = value;
      return this;
    }

    public Options key(String value) {
      this.key = wantkey(value);
      return this;
    }

    public Options passphrase(String value) {
      this.passphrase = value;
      return this;
    }

    public Options iterations(int value) {
      this.iterations = value;
      return this;
    }

    public Options create(boolean value) {
      this.create = value;
      return this;
    }
  }

  static final class Opened {
    KeyInfo info;
    byte[] root;
    Map<String, byte[]> grants = new LinkedHashMap<>();
    Sealed ring;
  }

  static boolean sameseal(Sealed left, Sealed right) {
    return Arrays.equals(left.iv, right.iv) && Arrays.equals(left.blob, right.blob);
  }

  // --- creating --------------------------------------------------------

  static VaultFile newvault(String keyid, String passphrase, int iterations) {
    byte[] root = random(KEYLEN);
    byte[] salt = random(SALTLEN);

    Map<String, Object> ring = new LinkedHashMap<>();
    ring.put("v", FORMAT);
    ring.put("write", true);
    ring.put("root", b64(root));

    Map<String, Object> meta = new LinkedHashMap<>();
    meta.put("v", FORMAT);
    meta.put("master", true);
    meta.put("write", true);
    meta.put("grants", List.of());

    KeyRecord record = new KeyRecord();
    record.id = keyid;
    record.salt = salt;
    record.iters = iterations;
    record.ring =
        seal(kek(passphrase, salt, iterations), utf8(Json.stringify(ring)), AAD_RING + keyid);
    record.meta = seal(hmac(root, LABEL_META), utf8(Json.stringify(meta)), AAD_META + keyid);

    VaultFile vault = new VaultFile();
    vault.keys.add(record);
    return vault;
  }

  /**
   * Write a vault file that is not there yet, and REFUSE one that is.
   *
   * <p>Straight to the target with CREATE_NEW rather than through a temporary and a rename.
   * `rename` REPLACES its destination, so two processes creating the same vault both succeeded and
   * the second discarded the first one's secrets.
   */
  static void putnew(String file, VaultFile vault) {
    Path path = Path.of(file);
    try {
      spill(path, writefile(vault));
    } catch (FileAlreadyExistsException err) {
      throw fail("vault file already exists: " + file);
    } catch (IOException err) {
      throw fail("cannot write " + file + ": " + err.getMessage());
    }
  }

  /**
   * The lock every handle on one file shares.
   *
   * <p>Each {@code Vault} is its own object, so two handles on one path did not coordinate: both
   * could finish {@code load()} before either saved, and the second {@code Files.move} then
   * discarded the first one's change while reporting success. Keyed by the ABSOLUTE path, so two
   * handles spelled differently still meet.
   *
   * <p>This is a guarantee WITHIN one process, which is what DOCS.md promises and what the go port
   * arranges the same way. Two processes still race, and the format's answer to that is the
   * exclusive create and the atomic rename: a reader sees one whole vault or the other, never half
   * of one.
   */
  private static final java.util.concurrent.ConcurrentHashMap<String, Object> LOCKS =
      new java.util.concurrent.ConcurrentHashMap<>();

  private static Object lockfor(String file) {
    String key;
    try {
      key = Path.of(file).toAbsolutePath().normalize().toString();
    } catch (RuntimeException err) {
      key = file;
    }

    return LOCKS.computeIfAbsent(key, ignored -> new Object());
  }

  /**
   * Create {@code path} and write {@code raw} to it, owner-only, refusing a path that is already
   * there.
   *
   * <p>THE MODE IS ASKED FOR AT CREATION, not set afterwards. {@code Files.write(CREATE_NEW)}
   * followed by {@code setPosixFilePermissions} leaves the file at the provider default - 0666
   * &amp; ~umask on a POSIX filesystem - for as long as it takes to write every byte, and another
   * local user watching a shared directory can open it for writing in that window and keep the
   * descriptor after the permissions narrow. A {@code FileAttribute} passed to the create is what
   * closes it.
   *
   * <p>On a filesystem with no POSIX permissions the attribute is refused, and the fallback is the
   * old shape: create, write, then narrow if the filesystem will have it. That is not a weaker
   * guarantee than before, and it is the only one such a filesystem offers.
   */
  private static void spill(Path path, byte[] raw) throws IOException {
    java.nio.file.attribute.FileAttribute<?> mode = null;
    try {
      mode =
          java.nio.file.attribute.PosixFilePermissions.asFileAttribute(
              java.nio.file.attribute.PosixFilePermissions.fromString("rw-------"));
    } catch (UnsupportedOperationException err) {
      mode = null;
    }

    if (null != mode) {
      try (java.io.OutputStream out =
          Files.newOutputStream(
              Files.createFile(path, mode), java.nio.file.StandardOpenOption.WRITE)) {
        out.write(raw);
        return;
      } catch (UnsupportedOperationException err) {
        // Fall through: this filesystem has no POSIX permissions.
      }
    }

    Files.write(
        path,
        raw,
        java.nio.file.StandardOpenOption.CREATE_NEW,
        java.nio.file.StandardOpenOption.WRITE);
    owneronly(path);
  }

  private static void owneronly(Path path) {
    try {
      Files.setPosixFilePermissions(
          path, java.nio.file.attribute.PosixFilePermissions.fromString("rw-------"));
    } catch (IOException | UnsupportedOperationException err) {
      // A filesystem with no POSIX permissions is not a reason to refuse a
      // write that otherwise succeeded.
    }
  }

  /**
   * A handle on one vault file, opened as ONE key.
   *
   * <p>Every method answers as that key: `list` shows the names it may read, `get` answers for
   * those and misses on the rest, and the master-only methods refuse for any other key. Nothing is
   * read or derived until the first call that needs the file.
   */
  public static final class Vault {
    private final String file;
    private final String keyid;
    private final String passphrase;
    private final int iterations;
    private final boolean create;

    private Opened opened;

    Vault(Options options) {
      Options opts = null == options ? new Options() : options;

      if (null == opts.file || opts.file.isEmpty()) {
        throw fail("a vault needs a file");
      }
      if (null == opts.passphrase || opts.passphrase.isEmpty()) {
        throw fail("a vault needs a passphrase");
      }

      this.file = opts.file;
      this.passphrase = opts.passphrase;
      this.keyid = checkid(wantkey(opts.key), "a vault needs a key id");
      this.iterations = opts.iterations;
      this.create = opts.create;
    }

    /** The file this handle reads. */
    public String file() {
      return file;
    }

    /** The key id this handle opens with. */
    public String key() {
      return keyid;
    }

    /**
     * Derive the key and read the file NOW rather than at first use.
     *
     * <p>KeyInfo is immutable, so what a caller is handed cannot become what this vault believes:
     * `vault.open().write = true` does not compile, and the list is a copy.
     */
    public KeyInfo open() {
      return load().opened.info;
    }

    /** Forget the derived keys. The next call opens again. */
    public void close() {
      opened = null;
    }

    /** The names this key can read, sorted. */
    public List<String> list() {
      Loaded state = load();

      if (null != state.opened.root) {
        byte[] namekey = hmac(state.opened.root, LABEL_NAMES);
        List<String> out = new ArrayList<>();
        for (EntryRecord entry : state.vault.entries) {
          out.add(
              new String(
                  unseal(namekey, entry.name, AAD_NAME, "a secret name is damaged"),
                  StandardCharsets.UTF_8));
        }
        out.sort(null);
        return out;
      }

      // A restricted key has no name key, so it reports the grants it can
      // actually find: the vault never tells it what else is in there.
      List<String> out = new ArrayList<>();
      for (String name : state.opened.info.grants) {
        if (null != findentry(state.vault, state.opened.grants.get(name))) {
          out.add(name);
        }
      }
      out.sort(null);
      return out;
    }

    public boolean has(String name) {
      return null != get(name);
    }

    /**
     * The value, or null when the vault does not hold that name or this key was not granted it.
     */
    public String get(String name) {
      Sekreto.checkname(name);
      Loaded state = load();

      byte[] key = keyfor(state.opened, name);
      if (null == key) {
        // OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as
        // the key that opened it, so a name this key cannot read is a name
        // this store does not hold for this caller.
        return null;
      }

      EntryRecord entry = findentry(state.vault, key);
      if (null == entry) {
        return null;
      }

      return new String(
          unseal(key, entry.value, AAD_SECRET + name, "the value of " + name + " is damaged"),
          StandardCharsets.UTF_8);
    }

    /**
     * Write a value. A master writes any name; a restricted key holding `write` overwrites the
     * names it was granted, and creates none.
     */
    public void set(String name, String value) {
      // Every write on this file, from any handle in this process,
      // serializes here; see lockfor.
      synchronized (lockfor(file)) {
        Sekreto.checkname(name);
        if (null == value) {
          throw fail("a secret value must be text: " + name);
        }

        Loaded state = load();

        if (!state.opened.info.write) {
          throw fail("key " + state.opened.info.key + " is read-only");
        }

        byte[] key = keyfor(state.opened, name);
        if (null == key) {
          throw fail("key " + state.opened.info.key + " was not granted " + name);
        }

        Sealed sealedvalue = seal(key, utf8(value), AAD_SECRET + name);
        byte[] id = entryid(key);

        EntryRecord found = findentry(state.vault, key);
        if (null != found) {
          found.value = sealedvalue;
        } else {
          // A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
          // restricted key with `write` updates what it was granted and
          // cannot grow the vault.
          byte[] root = rootof(state.opened, "creating the secret " + name);
          EntryRecord entry = new EntryRecord();
          entry.id = id;
          entry.name = seal(hmac(root, LABEL_NAMES), utf8(name), AAD_NAME);
          entry.value = sealedvalue;
          state.vault.entries.add(entry);
        }

        save(state.vault);
      }
    }

    /** Drop a name. Master only. */
    public void remove(String name) {
      // Every write on this file, from any handle in this process,
      // serializes here; see lockfor.
      synchronized (lockfor(file)) {
        Sekreto.checkname(name);
        Loaded state = load();
        byte[] root = rootof(state.opened, "removing a secret");

        byte[] wanted = entryid(secretkey(root, name));
        EntryRecord found = null;
        for (EntryRecord entry : state.vault.entries) {
          if (Arrays.equals(entry.id, wanted)) {
            found = entry;
            break;
          }
        }
        if (null == found) {
          throw fail("no such secret: " + name);
        }

        state.vault.entries.remove(found);
        save(state.vault);
      }
    }

    /** Every key in the file, with what it may do. Master only. */
    public List<KeyInfo> keys() {
      Loaded state = load();
      rootof(state.opened, "listing the keys");

      List<KeyInfo> out = new ArrayList<>();
      for (KeyRecord record : state.vault.keys) {
        Map<String, Object> meta = metaof(state.opened, record);
        if (null == meta) {
          out.add(new KeyInfo(record.id, false, false, List.of()));
          continue;
        }
        List<String> grants = new ArrayList<>();
        Object raw = meta.get("grants");
        if (raw instanceof List) {
          for (Object name : (List<?>) raw) {
            grants.add(String.valueOf(name));
          }
        }
        grants.sort(null);
        out.add(
            new KeyInfo(
                record.id,
                Boolean.TRUE.equals(meta.get("master")),
                Boolean.TRUE.equals(meta.get("write")),
                grants));
      }
      return out;
    }

    /** Mint a restricted key. Master only. */
    public void grant(Grant spec) {
      // Every write on this file, from any handle in this process,
      // serializes here; see lockfor.
      synchronized (lockfor(file)) {
        Loaded state = load();
        byte[] root = rootof(state.opened, "granting a key");

        Grant want = null == spec ? new Grant() : spec;
        String id = checkid(want.key, "a grant needs a key id");
        if (null == want.passphrase || want.passphrase.isEmpty()) {
          throw fail("a grant needs a passphrase");
        }
        for (KeyRecord record : state.vault.keys) {
          if (record.id.equals(id)) {
            throw fail("key already exists: " + id);
          }
        }

        List<String> names = new ArrayList<>(want.names);
        names.sort(null);

        // A TreeMap, for a ring whose JSON is the same text on every run.
        // It is NOT an interop requirement - the ring is sealed under a
        // fresh nonce, so its ciphertext differs per write whatever the key
        // order is, and a reader parses it back into a map. It is so that
        // two runs of this port over the same grant produce the same
        // plaintext, which is the property a reader of this code expects.
        Map<String, Object> grants = new TreeMap<>();
        for (String name : names) {
          Sekreto.checkname(name);
          grants.put(name, b64(secretkey(root, name)));
        }

        Map<String, Object> ring = new LinkedHashMap<>();
        ring.put("v", FORMAT);
        ring.put("write", want.write);
        ring.put("grants", grants);

        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("v", FORMAT);
        meta.put("master", false);
        meta.put("write", want.write);
        meta.put("grants", names);

        state.vault.keys.add(
            sealkey(
                root,
                id,
                want.passphrase,
                null == want.iterations ? iterations : want.iterations,
                ring,
                meta));

        save(state.vault);
      }
    }

    /**
     * Drop a key. Master only.
     *
     * <p>Anyone who already copied the file keeps whatever that key could read, so revoking bars
     * future reads of the LIVE file and `rotate` is what takes a secret back.
     */
    public void revoke(String key) {
      // Every write on this file, from any handle in this process,
      // serializes here; see lockfor.
      synchronized (lockfor(file)) {
        Loaded state = load();
        rootof(state.opened, "revoking a key");

        if (key.equals(state.opened.info.key)) {
          throw fail("a key cannot revoke itself: " + key);
        }

        KeyRecord found = null;
        for (KeyRecord record : state.vault.keys) {
          if (record.id.equals(key)) {
            found = record;
            break;
          }
        }
        if (null == found) {
          throw fail("no such key: " + key);
        }

        state.vault.keys.remove(found);
        save(state.vault);
      }
    }

    /**
     * A new root key, every value re-encrypted under it, and EVERY OTHER KEY DROPPED. Master only.
     *
     * <p>The other keys go because they must: their rings are sealed under passphrases this process
     * does not have. Re-grant afterwards.
     */
    public void rotate() {
      // Every write on this file, from any handle in this process,
      // serializes here; see lockfor.
      synchronized (lockfor(file)) {
        Loaded state = load();
        rootof(state.opened, "rotating the vault");

        // Read everything out under the old root before anything changes:
        // once the root is replaced the old derived keys are unreachable.
        Map<String, String> plain = new LinkedHashMap<>();
        for (String name : list()) {
          plain.put(name, get(name));
        }

        byte[] root = random(KEYLEN);
        byte[] namekey = hmac(root, LABEL_NAMES);

        VaultFile fresh = new VaultFile();
        for (Map.Entry<String, String> secret : plain.entrySet()) {
          byte[] key = secretkey(root, secret.getKey());
          EntryRecord entry = new EntryRecord();
          entry.id = entryid(key);
          entry.name = seal(namekey, utf8(secret.getKey()), AAD_NAME);
          entry.value = seal(key, utf8(secret.getValue()), AAD_SECRET + secret.getKey());
          fresh.entries.add(entry);
        }

        int iters = iterations;
        for (KeyRecord record : state.vault.keys) {
          if (record.id.equals(keyid)) {
            iters = record.iters;
          }
        }

        Map<String, Object> ring = new LinkedHashMap<>();
        ring.put("v", FORMAT);
        ring.put("write", true);
        ring.put("root", b64(root));

        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("v", FORMAT);
        meta.put("master", true);
        meta.put("write", true);
        meta.put("grants", List.of());

        KeyRecord record = sealkey(root, keyid, passphrase, iters, ring, meta);
        fresh.keys.add(record);

        // SAVE FIRST, adopt second. A handle holding the new root over a file
        // that still holds the old one reads nothing and says the vault is
        // damaged.
        save(fresh);

        Opened next = new Opened();
        next.info = new KeyInfo(keyid, true, true, List.of());
        next.root = root;
        next.ring = record.ring;
        opened = next;
      }
    }

    // --- the inside ----------------------------------------------------

    private static final class Loaded {
      VaultFile vault;
      Opened opened;
    }

    private byte[] bytes() {
      Path path = Path.of(file);
      try {
        return Files.readAllBytes(path);
      } catch (NoSuchFileException err) {
        // A vault is configured deliberately, with a key. Its absence is a
        // broken deployment and never "no secrets here": answering a miss
        // would send the chain on to a weaker store.
        if (!create) {
          throw fail("no vault file: " + file);
        }
        putnew(file, newvault(keyid, passphrase, iterations));
        try {
          return Files.readAllBytes(path);
        } catch (IOException again) {
          throw fail("cannot read " + file + ": " + again.getMessage());
        }
      } catch (IOException err) {
        throw fail("cannot read " + file + ": " + err.getMessage());
      }
    }

    private Loaded load() {
      VaultFile vault = readfile(bytes());

      KeyRecord record = null;
      for (KeyRecord key : vault.keys) {
        if (key.id.equals(keyid)) {
          record = key;
          break;
        }
      }
      if (null == record) {
        // REVOKED, or never there. Either way this handle is finished, and
        // dropping what it derived is what stops the next call answering
        // from memory.
        opened = null;
        throw fail("no such key: " + keyid);
      }

      Loaded state = new Loaded();
      state.vault = vault;

      // The file still holds this key, and holds the SAME ring: a key
      // revoked and re-granted under another passphrase is a different key
      // wearing the id, and re-deriving is what refuses it.
      if (null != opened && sameseal(opened.ring, record.ring)) {
        state.opened = opened;
        return state;
      }
      opened = null;

      byte[] plain =
          unseal(
              kek(passphrase, record.salt, record.iters),
              record.ring,
              AAD_RING + keyid,
              "wrong passphrase for key " + keyid + ", or a damaged vault");

      Map<String, Object> ring = jsonof(plain, "key ring for " + keyid);

      Map<String, byte[]> grants = new LinkedHashMap<>();
      Object raw = ring.get("grants");
      if (raw instanceof Map) {
        for (Map.Entry<?, ?> pair : ((Map<?, ?>) raw).entrySet()) {
          grants.put(String.valueOf(pair.getKey()), unb64(pair.getValue(), "a granted key"));
        }
      }

      List<String> names = new ArrayList<>(grants.keySet());
      names.sort(null);

      Object root = ring.get("root");

      Opened next = new Opened();
      next.info =
          new KeyInfo(
              keyid,
              null != root,
              null != root || Boolean.TRUE.equals(ring.get("write")),
              names);
      next.root = null == root ? null : unb64(root, "the root key");
      next.grants = grants;
      next.ring = record.ring;
      opened = next;

      state.opened = next;
      return state;
    }

    private byte[] rootof(Opened open, String what) {
      if (null == open.root) {
        throw fail(what + " needs a master key, and " + open.info.key + " is restricted");
      }
      return open.root;
    }

    /** The key for one name, or null when this key cannot reach it. */
    private byte[] keyfor(Opened open, String name) {
      if (null != open.root) {
        return secretkey(open.root, name);
      }
      return open.grants.get(name);
    }

    private EntryRecord findentry(VaultFile vault, byte[] key) {
      if (null == key) {
        return null;
      }
      byte[] id = entryid(key);
      for (EntryRecord entry : vault.entries) {
        if (Arrays.equals(entry.id, id)) {
          return entry;
        }
      }
      return null;
    }

    private Map<String, Object> metaof(Opened open, KeyRecord record) {
      byte[] root = rootof(open, "reading key metadata");
      String what = "metadata for key " + record.id;
      try {
        return jsonof(
            unseal(hmac(root, LABEL_META), record.meta, AAD_META + record.id, what), what);
      } catch (SekretoError err) {
        // A record written under a root key this one has replaced. The key
        // is still in the file and still opens with its own passphrase, so
        // it is reported rather than hidden - with what it can do unknown.
        return null;
      }
    }

    private KeyRecord sealkey(
        byte[] root,
        String id,
        String phrase,
        int iters,
        Map<String, Object> ring,
        Map<String, Object> meta) {
      byte[] salt = random(SALTLEN);
      KeyRecord record = new KeyRecord();
      record.id = id;
      record.salt = salt;
      record.iters = iters;
      record.ring = seal(kek(phrase, salt, iters), utf8(Json.stringify(ring)), AAD_RING + id);
      record.meta = seal(hmac(root, LABEL_META), utf8(Json.stringify(meta)), AAD_META + id);
      return record;
    }

    /**
     * Read, change, and REPLACE - never edit in place.
     *
     * <p>THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name anyone can predict,
     * so anyone who can write the vault's directory could put a symlink there and have the next
     * save truncate whatever it pointed at.
     */
    private void save(VaultFile vault) {
      StringBuilder suffix = new StringBuilder();
      for (byte one : random(8)) {
        suffix.append(String.format("%02x", one & 0xff));
      }
      Path temp = Path.of(file + "." + suffix + ".tmp");

      try {
        spill(temp, writefile(vault));
        Files.move(temp, Path.of(file), StandardCopyOption.REPLACE_EXISTING);
      } catch (IOException err) {
        try {
          Files.deleteIfExists(temp);
        } catch (IOException ignored) {
          // The vault is unchanged either way, and the write error is what
          // the caller needs to be told about.
        }
        throw fail("cannot write " + file + ": " + err.getMessage());
      }
    }
  }

  /**
   * Open a vault file as one key.
   *
   * <p>The handle is lazy. Nothing is read, and no passphrase is stretched, until a method needs
   * the file.
   */
  public static Vault openvault(Options options) {
    return new Vault(options);
  }

  /**
   * Make a vault file and return a handle on its master key.
   *
   * <p>Refuses a file that is already there: a vault is created once, and overwriting one discards
   * every secret in it.
   */
  public static Vault createvault(Options options) {
    Options opts = null == options ? new Options() : options;

    if (null == opts.file || opts.file.isEmpty()) {
      throw fail("a vault needs a file");
    }
    if (null == opts.passphrase || opts.passphrase.isEmpty()) {
      throw fail("a vault needs a passphrase");
    }
    String keyid = checkid(wantkey(opts.key), "a vault needs a key id");

    // No existence check first: the check and the write would be two steps,
    // and `putnew` refuses an existing file in ONE.
    putnew(opts.file, newvault(keyid, opts.passphrase, opts.iterations));

    return new Vault(opts);
  }

  // --- the provider ----------------------------------------------------

  /**
   * Read a vault as one store in a chain.
   *
   * <p>The provider is the READ half and nothing more: a chain resolves secrets, and writing one is
   * a deliberate act with an API of its own.
   */
  public static Provider providerof(Vault vault) {
    return new Provider() {
      @Override
      public String lookup(String name) {
        return vault.get(name);
      }

      @Override
      public String describe() {
        return "minivault:" + vault.file();
      }
    };
  }

  /** A vault provider from options, for a chain built by hand. */
  public static Provider minivaultprovider(Options options) {
    return providerof(openvault(options));
  }

  /** The vault options a provider spec describes. */
  static Options vaultoptions(Map<String, Object> spec) {
    Options out = new Options();
    out.file(Support.textor(spec.get("file"), ""));
    out.key(Support.text(spec.get("vaultkey")));
    out.passphrase(Support.textor(spec.get("passphrase"), ""));
    out.create(Boolean.TRUE.equals(spec.get("create")));

    Object iterations = spec.get("iterations");
    if (iterations instanceof Number) {
      out.iterations(((Number) iterations).intValue());
    }
    return out;
  }

  /**
   * The `minivault` provider kind, as a voxgig/plugin definition.
   *
   * <p>Written out rather than built by `Support.providerplugin`, because this definition publishes
   * TWO exports: `provider`, the read half every kind publishes, and `vault`, the programmatic API.
   */
  public static final Definition PLUGIN = minivaultplugin();

  private static Definition minivaultplugin() {
    Definition definition = new Definition("minivault");

    definition.define =
        inst -> {
          Map<String, Object> spec = Support.map(inst.options());
          Options options = vaultoptions(null == spec ? new LinkedHashMap<>() : spec);

          Vault vault;
          try {
            // `openvault` refuses bad configuration HERE, so a mistyped
            // chain fails at construction. Reaching the FILE is not
            // configuration: the handle is lazy.
            vault = openvault(options);
          } catch (SekretoError err) {
            Map<String, Object> details = new LinkedHashMap<>();
            details.put("ref", inst.ref);
            details.put("cause", err.getMessage());
            throw new PluginException(Support.ERROR_CODE, err.getMessage(), details);
          }

          inst.export(Support.PROVIDER_EXPORT, providerof(vault));
          inst.export(VAULT_EXPORT, vault);
        };

    return definition;
  }

  /**
   * The vault behind a store in a chain, as its programmatic API.
   *
   * <p>With no store named, the unqualified alias answers: one vault in the chain resolves whatever
   * it is called, and two raise rather than picking one.
   */
  public static Vault vaultof(Sekreto secrets) {
    Object found = secrets.host().exports("minivault/" + VAULT_EXPORT);
    if (null == found) {
      throw fail("no minivault store in this chain");
    }
    return (Vault) found;
  }

  /** The vault behind one NAMED store in a chain. */
  public static Vault vaultof(Sekreto secrets, String store) {
    if (null == store) {
      return vaultof(secrets);
    }

    // A NAMED STORE MUST EXIST, and the alias must not stand in for it.
    // `host.exports` falls back to the alias when the exact ref misses, so
    // asking for `minivault` in a chain whose only vault is named `app`
    // used to hand back the `app` vault - and then write to it.
    String ref = "minivault".equals(store) ? "minivault" : "minivault$" + store;

    if (null == secrets.host().instance(ref)) {
      throw fail("no minivault store named " + store + " in this chain");
    }

    return (Vault) secrets.host().exports(ref + "/" + VAULT_EXPORT);
  }
}
