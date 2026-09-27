// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (csharp/plugins/MiniVault.cs)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The mini vault, as a voxgig/plugin definition.
//
// A port of typescript/plugins/minivault.ts, which is canonical.
//
// PLUGIN CODE. This file is in the VoxgigSekretoPlugins assembly, which
// the core does not reference - so nothing here is linked into an
// application whose chain names only built-in kinds. It needs crypto,
// which is the line the four built-ins stay behind. See
// docs/design/plugin-providers.md.
//
// THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
// every name and mints restricted keys. A restricted key reads the names
// it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
// cryptography rather than a check this code performs. What that does and
// does not protect is set out in DOCS.md under "What the mini vault
// protects".
//
// System.Security.Cryptography carries all four primitives, so nothing
// here is hand-rolled (AGENTS.md rule 3).

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

using Definition = Voxgig.Plugin.Definition;
using Types = Voxgig.Plugin.Types;
using PluginException = Voxgig.Plugin.PluginException;

namespace Voxgig.Sekreto.Plugins
{
    /// <summary>
    /// A mini vault: every secret a project owns, encrypted, in ONE FILE.
    ///
    /// <para>The format:</para>
    /// <code>
    ///   magic       4   'SKMV'
    ///   version     1   FORMAT
    ///   kdf         1   1 = PBKDF2-HMAC-SHA256
    ///   cipher      1   1 = AES-256-GCM
    ///   reserved    1   0
    ///   keycount    4   uint32
    ///   per key:
    ///     id        1 + bytes      the key id, PLAINTEXT
    ///     salt      1 + bytes
    ///     iters     4              PBKDF2 rounds for this key
    ///     ring      1 + iv, 4 + bytes    sealed under the passphrase
    ///     meta      1 + iv, 4 + bytes    sealed under the vault's meta key
    ///   entrycount  4   uint32
    ///   per entry:
    ///     id        1 + bytes      the blinded lookup id
    ///     name      1 + iv, 4 + bytes    sealed under the vault's name key
    ///     value     1 + iv, 4 + bytes    sealed under that secret's own key
    /// </code>
    ///
    /// <para>Integers are big-endian, and every length precedes its bytes.
    /// A file one port writes is read by every other; `test/fixture` pins
    /// that with a committed vault rather than with agreement.</para>
    /// </summary>
    public static class MiniVault
    {
        internal const string Magic = "SKMV";
        internal const int Format = 1;
        internal const int KdfPbkdf2 = 1;
        internal const int CipherAesGcm = 1;

        /// <summary>AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.</summary>
        internal const int KeyLen = 32;

        internal const int IvLen = 12;
        internal const int TagLen = 16;
        internal const int SaltLen = 16;

        /// <summary>PBKDF2-HMAC-SHA256 rounds when a caller names none.</summary>
        public const int Iterations = 210000;

        /// <summary>The key id a vault gets when a caller names none.</summary>
        public const string MasterKey = "master";

        /// <summary>
        /// The lock every handle on one file shares.
        ///
        /// <para>Each <c>Vault</c> is its own object, so two handles on one
        /// path did not coordinate: both could finish <c>Load()</c> before
        /// either saved, and the second <c>File.Move</c> then discarded the
        /// first one's change while reporting success. Keyed by the ABSOLUTE
        /// path, so two handles spelled differently still meet.</para>
        ///
        /// <para>A guarantee WITHIN one process, which is what DOCS.md
        /// promises and what the go port arranges the same way. Two
        /// processes still race, and the format's answer to that is the
        /// exclusive create and the atomic rename.</para>
        /// </summary>
        private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, object>
            Locks = new System.Collections.Concurrent.ConcurrentDictionary<string, object>();

        internal static object LockFor(string file)
        {
            string key;
            try
            {
                key = Path.GetFullPath(file);
            }
            catch (Exception)
            {
                key = file;
            }

            return Locks.GetOrAdd(key, _ => new object());
        }

        /// <summary>
        /// The key a caller asked for, or <c>master</c>: an EMPTY key is no
        /// key. The canonical's <c>opts.key || MASTERKEY</c> answers for
        /// both null and empty, where <c>??</c> answers for null alone - and
        /// a CLI reaches this with SEKRETO_VAULT_KEY set and empty, which is
        /// what an unset shell variable expands to.
        /// </summary>
        internal static string WantKey(string? value)
        {
            return string.IsNullOrEmpty(value) ? MasterKey : value;
        }

        // Additional authenticated data. Every blob is bound to its PLACE in
        // the file, so no ciphertext can be moved.
        internal const string AadRing = "skmv1:ring:";
        internal const string AadMeta = "skmv1:meta:";
        internal const string AadName = "skmv1:name";
        internal const string AadSecret = "skmv1:secret:";

        // Everything a master can reach is derived from the root key, so a
        // rotation is one new random value rather than a re-wrap of each part.
        internal const string LabelNames = "skmv1:names";
        internal const string LabelMeta = "skmv1:meta";
        internal const string LabelId = "skmv1:id";

        /// <summary>
        /// The largest key id the format can record.
        ///
        /// <para>`Small` writes a length in ONE byte. A longer id wrapped
        /// that byte and the writer then appended the whole thing, so every
        /// field after it shifted. Checked where an id is ACCEPTED, so the
        /// refusal names the id rather than the file.</para>
        /// </summary>
        internal const int IdMax = 255;

        /// <summary>
        /// The export key the vault API is published under, beside the
        /// `provider` key every kind publishes.
        /// </summary>
        public const string VaultExport = "vault";

        internal static SekretoError Fail(string text)
        {
            return new SekretoError("sekreto: minivault: " + text);
        }

        internal static string CheckId(object id, string what)
        {
            var text = id as string;

            if (null == text || 0 == text.Length)
            {
                throw Fail(what);
            }

            if (Utf8(text).Length > IdMax)
            {
                throw Fail("key id is longer than " + IdMax + " bytes: "
                    + text.Substring(0, Math.Min(32, text.Length)) + "...");
            }

            return text;
        }

        internal static byte[] Utf8(string text)
        {
            return Encoding.UTF8.GetBytes(text);
        }

        // --- keys --------------------------------------------------------

        internal static byte[] Hmac(byte[] key, string text)
        {
            using (var mac = new HMACSHA256(key))
            {
                return mac.ComputeHash(Utf8(text));
            }
        }

        /// <summary>The key-encryption key a passphrase unwraps a ring with.</summary>
        internal static byte[] Kek(string passphrase, byte[] salt, int iters)
        {
            return Rfc2898DeriveBytes.Pbkdf2(
                Utf8(passphrase), salt, iters, HashAlgorithmName.SHA256, KeyLen);
        }

        /// <summary>
        /// The key one named secret's value is encrypted with.
        ///
        /// <para>DERIVED, never stored, for a master: it holds the root key
        /// and so reaches every name, including ones written after it was
        /// made. A restricted key holds the derived keys it was granted and
        /// nothing that produces another.</para>
        /// </summary>
        internal static byte[] SecretKey(byte[] root, string name)
        {
            return Hmac(root, AadSecret + name);
        }

        /// <summary>
        /// Where a secret lives in the file, derived from its own key so that
        /// finding it needs no plaintext name.
        /// </summary>
        internal static byte[] EntryId(byte[] key)
        {
            return Hmac(key, LabelId);
        }

        internal static byte[] Random(int len)
        {
            return RandomNumberGenerator.GetBytes(len);
        }

        // --- sealing ------------------------------------------------------

        /// <summary>A nonce and the ciphertext with its tag appended.</summary>
        internal sealed class Sealed
        {
            internal byte[] Iv;
            internal byte[] Blob;

            internal Sealed(byte[] iv, byte[] blob)
            {
                Iv = iv;
                Blob = blob;
            }
        }

        internal static Sealed Seal(byte[] key, byte[] plain, string aad)
        {
            var iv = Random(IvLen);
            var body = new byte[plain.Length];
            var tag = new byte[TagLen];

            using (var gcm = new AesGcm(key, TagLen))
            {
                gcm.Encrypt(iv, plain, body, tag, Utf8(aad));
            }

            var blob = new byte[body.Length + TagLen];
            Buffer.BlockCopy(body, 0, blob, 0, body.Length);
            Buffer.BlockCopy(tag, 0, blob, body.Length, TagLen);

            return new Sealed(iv, blob);
        }

        /// <summary>
        /// The plaintext, or a refusal. A GCM tag that fails to verify is the
        /// only evidence there is, and it cannot tell a wrong passphrase from
        /// a damaged file, so `what` names the attempt and the message admits
        /// both.
        /// </summary>
        internal static byte[] Unseal(byte[] key, Sealed sealedvalue, string aad, string what)
        {
            if (sealedvalue.Blob.Length < TagLen || IvLen != sealedvalue.Iv.Length)
            {
                throw Fail(what + ": truncated");
            }

            var bodylen = sealedvalue.Blob.Length - TagLen;
            var body = new byte[bodylen];
            var tag = new byte[TagLen];
            Buffer.BlockCopy(sealedvalue.Blob, 0, body, 0, bodylen);
            Buffer.BlockCopy(sealedvalue.Blob, bodylen, tag, 0, TagLen);

            var plain = new byte[bodylen];

            // The WHOLE round-trip is guarded, not only the tag check: a key
            // of the wrong length makes the constructor itself raise, and a
            // damaged file reaching a caller as a raw ArgumentException is a
            // refusal nobody can act on.
            try
            {
                using (var gcm = new AesGcm(key, TagLen))
                {
                    gcm.Decrypt(sealedvalue.Iv, body, tag, plain, Utf8(aad));
                }
            }
            catch (Exception err) when (err is CryptographicException || err is ArgumentException)
            {
                throw Fail(what);
            }

            return plain;
        }

        internal static Dictionary<string, object> JsonOf(byte[] plain, string what)
        {
            object parsed;

            if (!Json.TryParse(Encoding.UTF8.GetString(plain), out parsed))
            {
                throw Fail("unreadable " + what);
            }

            var map = parsed as Dictionary<string, object>;

            if (null == map)
            {
                throw Fail("unreadable " + what);
            }

            return map;
        }

        internal static string B64(byte[] bytes)
        {
            return Convert.ToBase64String(bytes);
        }

        internal static byte[] UnB64(object text, string what)
        {
            var encoded = text as string;

            if (null == encoded)
            {
                throw Fail("missing " + what);
            }

            try
            {
                return Convert.FromBase64String(encoded);
            }
            catch (FormatException)
            {
                throw Fail("missing " + what);
            }
        }

        // --- the file -----------------------------------------------------

        internal sealed class KeyRecord
        {
            internal string Id;
            internal byte[] Salt;
            internal int Iters;
            internal Sealed Ring;
            internal Sealed Meta;
        }

        internal sealed class EntryRecord
        {
            internal byte[] Id;
            internal Sealed Name;
            internal Sealed Value;
        }

        internal sealed class VaultFile
        {
            internal readonly List<KeyRecord> Keys = new List<KeyRecord>();
            internal readonly List<EntryRecord> Entries = new List<EntryRecord>();
        }

        /// <summary>
        /// A cursor, so that every length check is in one place: a truncated
        /// vault is refused rather than read as a short one.
        /// </summary>
        internal sealed class Reader
        {
            private readonly byte[] bytes;
            private int at;

            internal Reader(byte[] bytes)
            {
                this.bytes = bytes;
            }

            internal byte[] Take(int len)
            {
                if (len < 0 || bytes.Length < at + len)
                {
                    throw Fail("the vault file is truncated");
                }

                var out_ = new byte[len];
                Buffer.BlockCopy(bytes, at, out_, 0, len);
                at += len;
                return out_;
            }

            internal int U8()
            {
                return Take(1)[0];
            }

            internal int U32()
            {
                var four = Take(4);
                // A length over int.MaxValue cannot address an array, and
                // reading it as a negative int is what turned a damaged file
                // into a crash instead of a refusal.
                var value = ((uint)four[0] << 24) | ((uint)four[1] << 16)
                    | ((uint)four[2] << 8) | four[3];

                if (value > int.MaxValue)
                {
                    throw Fail("the vault file is truncated");
                }

                return (int)value;
            }

            internal byte[] Small()
            {
                return Take(U8());
            }

            internal byte[] Large()
            {
                return Take(U32());
            }

            internal string MagicWord()
            {
                return Encoding.Latin1.GetString(Take(4));
            }

            internal Sealed SealedValue()
            {
                return new Sealed(Small(), Large());
            }

            internal bool Done()
            {
                return at == bytes.Length;
            }
        }

        internal static VaultFile ReadFile(byte[] bytes)
        {
            var read = new Reader(bytes);

            if (Magic != read.MagicWord())
            {
                throw Fail("not a vault file");
            }

            var version = read.U8();
            if (Format != version)
            {
                throw Fail("unsupported format version: " + version);
            }

            var kdf = read.U8();
            var cipher = read.U8();
            if (KdfPbkdf2 != kdf || CipherAesGcm != cipher)
            {
                throw Fail("unsupported kdf or cipher: " + kdf + "/" + cipher);
            }
            read.U8();

            var vault = new VaultFile();

            var keycount = read.U32();
            for (var index = 0; index < keycount; index++)
            {
                vault.Keys.Add(new KeyRecord
                {
                    Id = Encoding.UTF8.GetString(read.Small()),
                    Salt = read.Small(),
                    Iters = read.U32(),
                    Ring = read.SealedValue(),
                    Meta = read.SealedValue(),
                });
            }

            var entrycount = read.U32();
            for (var index = 0; index < entrycount; index++)
            {
                vault.Entries.Add(new EntryRecord
                {
                    Id = read.Small(),
                    Name = read.SealedValue(),
                    Value = read.SealedValue(),
                });
            }

            if (!read.Done())
            {
                throw Fail("the vault file has trailing bytes");
            }

            return vault;
        }

        internal static byte[] WriteFile(VaultFile vault)
        {
            var out_ = new MemoryStream();

            Action<byte[]> raw = bytes => out_.Write(bytes, 0, bytes.Length);
            Action<int> u8 = value => out_.WriteByte((byte)value);
            Action<int> u32 = value => raw(new[]
            {
                (byte)((value >> 24) & 0xff), (byte)((value >> 16) & 0xff),
                (byte)((value >> 8) & 0xff), (byte)(value & 0xff),
            });
            Action<byte[]> small = bytes => { u8(bytes.Length); raw(bytes); };
            Action<byte[]> large = bytes => { u32(bytes.Length); raw(bytes); };
            Action<Sealed> sealedvalue = value => { small(value.Iv); large(value.Blob); };

            raw(Encoding.Latin1.GetBytes(Magic));
            u8(Format);
            u8(KdfPbkdf2);
            u8(CipherAesGcm);
            u8(0);

            u32(vault.Keys.Count);
            foreach (var key in vault.Keys)
            {
                small(Utf8(key.Id));
                small(key.Salt);
                u32(key.Iters);
                sealedvalue(key.Ring);
                sealedvalue(key.Meta);
            }

            // SORTED BY ID, which is a blinded value: the file therefore
            // records nothing about the order secrets were written in.
            var entries = new List<EntryRecord>(vault.Entries);
            entries.Sort((left, right) => Compare(left.Id, right.Id));

            u32(entries.Count);
            foreach (var entry in entries)
            {
                small(entry.Id);
                sealedvalue(entry.Name);
                sealedvalue(entry.Value);
            }

            return out_.ToArray();
        }

        /// <summary>Unsigned, byte by byte, the way every other port sorts.</summary>
        internal static int Compare(byte[] left, byte[] right)
        {
            var len = Math.Min(left.Length, right.Length);

            for (var index = 0; index < len; index++)
            {
                if (left[index] != right[index])
                {
                    return left[index] < right[index] ? -1 : 1;
                }
            }

            return left.Length.CompareTo(right.Length);
        }

        internal static bool Same(byte[] left, byte[] right)
        {
            return null != left && null != right && 0 == Compare(left, right);
        }

        internal static bool SameSeal(Sealed left, Sealed right)
        {
            return Same(left.Iv, right.Iv) && Same(left.Blob, right.Blob);
        }

        // --- what a key is -------------------------------------------------

        /// <summary>
        /// What a key may do. `Grants` is empty for a master key.
        ///
        /// <para>Read-only, so what a caller is handed cannot become what the
        /// vault believes: `vault.Open().Write = true` does not compile.</para>
        /// </summary>
        public sealed class KeyInfo
        {
            public string Key { get; }

            public bool Master { get; }

            public bool Write { get; }

            public IReadOnlyList<string> Grants { get; }

            internal KeyInfo(string key, bool master, bool write, List<string> grants)
            {
                Key = key;
                Master = master;
                Write = write;
                Grants = grants.AsReadOnly();
            }

            public override string ToString()
            {
                return Key + "/" + (Master ? "true" : "false") + "/"
                    + (Write ? "true" : "false") + "/[" + string.Join(", ", Grants) + "]";
            }
        }

        /// <summary>What a caller asks for when minting a restricted key.</summary>
        public sealed class Grant
        {
            public string Key { get; set; }

            public string Passphrase { get; set; }

            public List<string> Names { get; set; } = new List<string>();

            public bool Write { get; set; }

            public int? Iterations { get; set; }
        }

        /// <summary>How a vault handle is configured.</summary>
        public sealed class Options
        {
            public string File { get; set; }

            public string Key { get; set; } = MasterKey;

            public string Passphrase { get; set; }

            public int Iterations { get; set; } = MiniVault.Iterations;

            public bool Create { get; set; }
        }

        internal sealed class Opened
        {
            internal KeyInfo Info;
            internal byte[] Root;
            internal Dictionary<string, byte[]> Grants = new Dictionary<string, byte[]>();
            internal Sealed Ring;
        }

        // --- creating ------------------------------------------------------

        internal static VaultFile NewVault(string keyid, string passphrase, int iterations)
        {
            var root = Random(KeyLen);
            var salt = Random(SaltLen);

            var ring = new Dictionary<string, object>
            {
                { "v", (double)Format }, { "write", true }, { "root", B64(root) },
            };

            var meta = new Dictionary<string, object>
            {
                { "v", (double)Format }, { "master", true }, { "write", true },
                { "grants", new List<object>() },
            };

            var vault = new VaultFile();
            vault.Keys.Add(new KeyRecord
            {
                Id = keyid,
                Salt = salt,
                Iters = iterations,
                Ring = Seal(Kek(passphrase, salt, iterations),
                    Utf8(Json.Stringify(ring)), AadRing + keyid),
                Meta = Seal(Hmac(root, LabelMeta),
                    Utf8(Json.Stringify(meta)), AadMeta + keyid),
            });

            return vault;
        }

        /// <summary>
        /// Write a vault file that is not there yet, and REFUSE one that is.
        ///
        /// <para>Straight to the target with CreateNew rather than through a
        /// temporary and a rename. A rename REPLACES its destination, so two
        /// processes creating the same vault both succeeded and the second
        /// discarded the first one's secrets.</para>
        /// </summary>
        internal static void PutNew(string file, VaultFile vault)
        {
            try
            {
                using (var handle = new FileStream(file, FileMode.CreateNew, FileAccess.Write))
                {
                    var bytes = WriteFile(vault);
                    handle.Write(bytes, 0, bytes.Length);
                }

                OwnerOnly(file);
            }
            catch (IOException err) when (File.Exists(file))
            {
                throw Fail("vault file already exists: " + file);
            }
            catch (Exception err) when (err is IOException || err is UnauthorizedAccessException)
            {
                throw Fail("cannot write " + file + ": " + err.Message);
            }
        }

        internal static void OwnerOnly(string file)
        {
            try
            {
                if (!OperatingSystem.IsWindows())
                {
                    File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                }
            }
            catch (Exception err) when (err is IOException || err is PlatformNotSupportedException)
            {
                // A filesystem with no POSIX permissions is not a reason to
                // refuse a write that otherwise succeeded.
            }
        }

        /// <summary>
        /// A handle on one vault file, opened as ONE key.
        ///
        /// <para>Every method answers as that key: `List` shows the names it
        /// may read, `Get` answers for those and misses on the rest, and the
        /// master-only methods refuse for any other key. Nothing is read or
        /// derived until the first call that needs the file.</para>
        /// </summary>
        public sealed class Vault
        {
            private readonly string file;
            private readonly string keyid;
            private readonly string passphrase;
            private readonly int iterations;
            private readonly bool create;

            private Opened opened;

            internal Vault(Options options)
            {
                var opts = options ?? new Options();

                if (string.IsNullOrEmpty(opts.File))
                {
                    throw Fail("a vault needs a file");
                }

                if (string.IsNullOrEmpty(opts.Passphrase))
                {
                    throw Fail("a vault needs a passphrase");
                }

                file = opts.File;
                passphrase = opts.Passphrase;
                keyid = CheckId(WantKey(opts.Key), "a vault needs a key id");
                iterations = opts.Iterations;
                create = opts.Create;
            }

            /// <summary>The file this handle reads.</summary>
            public string File()
            {
                return file;
            }

            /// <summary>The key id this handle opens with.</summary>
            public string Key()
            {
                return keyid;
            }

            /// <summary>Derive the key and read the file NOW rather than at first use.</summary>
            public KeyInfo Open()
            {
                VaultFile vault;
                return Load(out vault).Info;
            }

            /// <summary>Forget the derived keys. The next call opens again.</summary>
            public void Close()
            {
                opened = null;
            }

            /// <summary>The names this key can read, sorted.</summary>
            public List<string> List()
            {
                VaultFile vault;
                var open = Load(out vault);

                var out_ = new List<string>();

                if (null != open.Root)
                {
                    var namekey = Hmac(open.Root, LabelNames);

                    foreach (var entry in vault.Entries)
                    {
                        out_.Add(Encoding.UTF8.GetString(
                            Unseal(namekey, entry.Name, AadName, "a secret name is damaged")));
                    }

                    out_.Sort(StringComparer.Ordinal);
                    return out_;
                }

                // A restricted key has no name key, so it reports the grants
                // it can actually find: the vault never tells it what else is
                // in there.
                foreach (var name in open.Info.Grants)
                {
                    if (null != FindEntry(vault, open.Grants[name]))
                    {
                        out_.Add(name);
                    }
                }

                out_.Sort(StringComparer.Ordinal);
                return out_;
            }

            public bool Has(string name)
            {
                return null != Get(name);
            }

            /// <summary>
            /// The value, or null when the vault does not hold that name or
            /// this key was not granted it.
            /// </summary>
            public string Get(string name)
            {
                Names.CheckName(name);

                VaultFile vault;
                var open = Load(out vault);

                var key = KeyFor(open, name);

                if (null == key)
                {
                    // OUTSIDE THE GRANT IS A MISS, deliberately. The vault
                    // answers as the key that opened it, so a name this key
                    // cannot read is a name this store does not hold for this
                    // caller.
                    return null;
                }

                var entry = FindEntry(vault, key);

                if (null == entry)
                {
                    return null;
                }

                return Encoding.UTF8.GetString(Unseal(
                    key, entry.Value, AadSecret + name, "the value of " + name + " is damaged"));
            }

            /// <summary>
            /// Write a value. A master writes any name; a restricted key
            /// holding `write` overwrites the names it was granted, and
            /// creates none.
            /// </summary>
            public void Set(string name, string value)
            {
                // Every write on this file, from any handle in this process,
                // serializes here; see LockFor.
                lock (LockFor(file))
                {
                    Names.CheckName(name);

                    if (null == value)
                    {
                        throw Fail("a secret value must be text: " + name);
                    }

                    VaultFile vault;
                    var open = Load(out vault);

                    if (!open.Info.Write)
                    {
                        throw Fail("key " + open.Info.Key + " is read-only");
                    }

                    var key = KeyFor(open, name);

                    if (null == key)
                    {
                        throw Fail("key " + open.Info.Key + " was not granted " + name);
                    }

                    var sealedvalue = Seal(key, Utf8(value), AadSecret + name);
                    var found = FindEntry(vault, key);

                    if (null != found)
                    {
                        found.Value = sealedvalue;
                    }
                    else
                    {
                        // A NEW NAME NEEDS THE NAME KEY, which only a master
                        // holds. So a restricted key with `write` updates what it
                        // was granted and cannot grow the vault.
                        var root = RootOf(open, "creating the secret " + name);

                        vault.Entries.Add(new EntryRecord
                        {
                            Id = EntryId(key),
                            Name = Seal(Hmac(root, LabelNames), Utf8(name), AadName),
                            Value = sealedvalue,
                        });
                    }

                    Save(vault);
                }
            }

            /// <summary>Drop a name. Master only.</summary>
            public void Remove(string name)
            {
                // Every write on this file, from any handle in this process,
                // serializes here; see LockFor.
                lock (LockFor(file))
                {
                    Names.CheckName(name);

                    VaultFile vault;
                    var open = Load(out vault);
                    var root = RootOf(open, "removing a secret");

                    var wanted = EntryId(SecretKey(root, name));
                    var found = vault.Entries.FirstOrDefault(entry => Same(entry.Id, wanted));

                    if (null == found)
                    {
                        throw Fail("no such secret: " + name);
                    }

                    vault.Entries.Remove(found);
                    Save(vault);
                }
            }

            /// <summary>Every key in the file, with what it may do. Master only.</summary>
            public List<KeyInfo> Keys()
            {
                VaultFile vault;
                var open = Load(out vault);
                RootOf(open, "listing the keys");

                var out_ = new List<KeyInfo>();

                foreach (var record in vault.Keys)
                {
                    var meta = MetaOf(open, record);

                    if (null == meta)
                    {
                        out_.Add(new KeyInfo(record.Id, false, false, new List<string>()));
                        continue;
                    }

                    var grants = new List<string>();
                    var raw = meta.TryGetValue("grants", out var value) ? value : null;

                    if (raw is List<object> names)
                    {
                        foreach (var name in names)
                        {
                            grants.Add(Convert.ToString(name));
                        }
                    }

                    grants.Sort(StringComparer.Ordinal);

                    out_.Add(new KeyInfo(
                        record.Id, True(meta, "master"), True(meta, "write"), grants));
                }

                return out_;
            }

            /// <summary>Mint a restricted key. Master only.</summary>
            public void Grant(Grant spec)
            {
                // Every write on this file, from any handle in this process,
                // serializes here; see LockFor.
                lock (LockFor(file))
                {
                    VaultFile vault;
                    var open = Load(out vault);
                    var root = RootOf(open, "granting a key");

                    var want = spec ?? new Grant();
                    var id = CheckId(want.Key, "a grant needs a key id");

                    if (string.IsNullOrEmpty(want.Passphrase))
                    {
                        throw Fail("a grant needs a passphrase");
                    }

                    if (vault.Keys.Any(record => record.Id == id))
                    {
                        throw Fail("key already exists: " + id);
                    }

                    var names = new List<string>(want.Names ?? new List<string>());
                    names.Sort(StringComparer.Ordinal);

                    // A SortedDictionary, for a ring whose JSON is the same
                    // text on every run. It is NOT an interop requirement -
                    // the ring is sealed under a fresh nonce, so its
                    // ciphertext differs per write whatever the key order is,
                    // and a reader parses it back into a map. It is so that
                    // two runs of this port over the same grant produce the
                    // same plaintext.
                    var grants = new SortedDictionary<string, object>(StringComparer.Ordinal);

                    foreach (var name in names)
                    {
                        Names.CheckName(name);
                        grants[name] = B64(SecretKey(root, name));
                    }

                    var ring = new Dictionary<string, object>
                    {
                        { "v", (double)Format }, { "write", want.Write },
                        { "grants", new Dictionary<string, object>(grants) },
                    };

                    var meta = new Dictionary<string, object>
                    {
                        { "v", (double)Format }, { "master", false }, { "write", want.Write },
                        { "grants", names.Cast<object>().ToList() },
                    };

                    vault.Keys.Add(SealKey(root, id, want.Passphrase,
                        want.Iterations ?? iterations, ring, meta));

                    Save(vault);
                }
            }

            /// <summary>
            /// Drop a key. Master only.
            ///
            /// <para>Anyone who already copied the file keeps whatever that
            /// key could read, so revoking bars future reads of the LIVE file
            /// and `Rotate` is what takes a secret back.</para>
            /// </summary>
            public void Revoke(string key)
            {
                // Every write on this file, from any handle in this process,
                // serializes here; see LockFor.
                lock (LockFor(file))
                {
                    VaultFile vault;
                    var open = Load(out vault);
                    RootOf(open, "revoking a key");

                    if (key == open.Info.Key)
                    {
                        throw Fail("a key cannot revoke itself: " + key);
                    }

                    var found = vault.Keys.FirstOrDefault(record => record.Id == key);

                    if (null == found)
                    {
                        throw Fail("no such key: " + key);
                    }

                    vault.Keys.Remove(found);
                    Save(vault);
                }
            }

            /// <summary>
            /// A new root key, every value re-encrypted under it, and EVERY
            /// OTHER KEY DROPPED. Master only.
            ///
            /// <para>The other keys go because they must: their rings are
            /// sealed under passphrases this process does not have. Re-grant
            /// afterwards.</para>
            /// </summary>
            public void Rotate()
            {
                // Every write on this file, from any handle in this process,
                // serializes here; see LockFor.
                lock (LockFor(file))
                {
                    VaultFile vault;
                    var open = Load(out vault);
                    RootOf(open, "rotating the vault");

                    // Read everything out under the old root before anything
                    // changes: once the root is replaced the old derived keys are
                    // unreachable.
                    var plain = new List<KeyValuePair<string, string>>();

                    foreach (var name in List())
                    {
                        plain.Add(new KeyValuePair<string, string>(name, Get(name)));
                    }

                    var root = Random(KeyLen);
                    var namekey = Hmac(root, LabelNames);

                    var fresh = new VaultFile();

                    foreach (var secret in plain)
                    {
                        var key = SecretKey(root, secret.Key);

                        fresh.Entries.Add(new EntryRecord
                        {
                            Id = EntryId(key),
                            Name = Seal(namekey, Utf8(secret.Key), AadName),
                            Value = Seal(key, Utf8(secret.Value), AadSecret + secret.Key),
                        });
                    }

                    var iters = iterations;

                    foreach (var record in vault.Keys)
                    {
                        if (record.Id == keyid)
                        {
                            iters = record.Iters;
                        }
                    }

                    var ring = new Dictionary<string, object>
                    {
                        { "v", (double)Format }, { "write", true }, { "root", B64(root) },
                    };

                    var meta = new Dictionary<string, object>
                    {
                        { "v", (double)Format }, { "master", true }, { "write", true },
                        { "grants", new List<object>() },
                    };

                    var record2 = SealKey(root, keyid, passphrase, iters, ring, meta);
                    fresh.Keys.Add(record2);

                    // SAVE FIRST, adopt second. A handle holding the new root over
                    // a file that still holds the old one reads nothing and says
                    // the vault is damaged.
                    Save(fresh);

                    opened = new Opened
                    {
                        Info = new KeyInfo(keyid, true, true, new List<string>()),
                        Root = root,
                        Ring = record2.Ring,
                    };
                }
            }

            // --- the inside -------------------------------------------------

            private static bool True(Dictionary<string, object> map, string key)
            {
                return map.TryGetValue(key, out var value) && value is bool flag && flag;
            }

            private byte[] Bytes()
            {
                try
                {
                    return System.IO.File.ReadAllBytes(file);
                }
                catch (FileNotFoundException)
                {
                    return Make();
                }
                catch (DirectoryNotFoundException)
                {
                    return Make();
                }
                catch (Exception err) when (err is IOException || err is UnauthorizedAccessException)
                {
                    throw Fail("cannot read " + file + ": " + err.Message);
                }
            }

            private byte[] Make()
            {
                // A vault is configured deliberately, with a key. Its absence
                // is a broken deployment and never "no secrets here":
                // answering a miss would send the chain on to a weaker store.
                if (!create)
                {
                    throw Fail("no vault file: " + file);
                }

                PutNew(file, NewVault(keyid, passphrase, iterations));

                try
                {
                    return System.IO.File.ReadAllBytes(file);
                }
                catch (IOException err)
                {
                    throw Fail("cannot read " + file + ": " + err.Message);
                }
            }

            private Opened Load(out VaultFile vault)
            {
                vault = ReadFile(Bytes());

                var record = vault.Keys.FirstOrDefault(key => key.Id == keyid);

                if (null == record)
                {
                    // REVOKED, or never there. Either way this handle is
                    // finished, and dropping what it derived is what stops the
                    // next call answering from memory.
                    opened = null;
                    throw Fail("no such key: " + keyid);
                }

                // The file still holds this key, and holds the SAME ring: a
                // key revoked and re-granted under another passphrase is a
                // different key wearing the id, and re-deriving is what
                // refuses it.
                if (null != opened && SameSeal(opened.Ring, record.Ring))
                {
                    return opened;
                }

                opened = null;

                var plain = Unseal(
                    Kek(passphrase, record.Salt, record.Iters), record.Ring, AadRing + keyid,
                    "wrong passphrase for key " + keyid + ", or a damaged vault");

                var ring = JsonOf(plain, "key ring for " + keyid);

                var grants = new Dictionary<string, byte[]>();

                if (ring.TryGetValue("grants", out var raw)
                    && raw is Dictionary<string, object> map)
                {
                    foreach (var pair in map)
                    {
                        grants[pair.Key] = UnB64(pair.Value, "a granted key");
                    }
                }

                var names = new List<string>(grants.Keys);
                names.Sort(StringComparer.Ordinal);

                var root = ring.TryGetValue("root", out var rootvalue) ? rootvalue : null;

                opened = new Opened
                {
                    Info = new KeyInfo(
                        keyid, null != root, null != root || True(ring, "write"), names),
                    Root = null == root ? null : UnB64(root, "the root key"),
                    Grants = grants,
                    Ring = record.Ring,
                };

                return opened;
            }

            private byte[] RootOf(Opened open, string what)
            {
                if (null == open.Root)
                {
                    throw Fail(what + " needs a master key, and " + open.Info.Key
                        + " is restricted");
                }

                return open.Root;
            }

            /// <summary>The key for one name, or null when this key cannot reach it.</summary>
            private byte[] KeyFor(Opened open, string name)
            {
                if (null != open.Root)
                {
                    return SecretKey(open.Root, name);
                }

                return open.Grants.TryGetValue(name, out var key) ? key : null;
            }

            private EntryRecord FindEntry(VaultFile vault, byte[] key)
            {
                if (null == key)
                {
                    return null;
                }

                var id = EntryId(key);
                return vault.Entries.FirstOrDefault(entry => Same(entry.Id, id));
            }

            private Dictionary<string, object> MetaOf(Opened open, KeyRecord record)
            {
                var root = RootOf(open, "reading key metadata");
                var what = "metadata for key " + record.Id;

                try
                {
                    return JsonOf(
                        Unseal(Hmac(root, LabelMeta), record.Meta, AadMeta + record.Id, what),
                        what);
                }
                catch (SekretoError)
                {
                    // A record written under a root key this one has replaced.
                    // The key is still in the file and still opens with its
                    // own passphrase, so it is reported rather than hidden -
                    // with what it can do unknown.
                    return null;
                }
            }

            private KeyRecord SealKey(byte[] root, string id, string phrase, int iters,
                Dictionary<string, object> ring, Dictionary<string, object> meta)
            {
                var salt = Random(SaltLen);

                return new KeyRecord
                {
                    Id = id,
                    Salt = salt,
                    Iters = iters,
                    Ring = Seal(Kek(phrase, salt, iters), Utf8(Json.Stringify(ring)),
                        AadRing + id),
                    Meta = Seal(Hmac(root, LabelMeta), Utf8(Json.Stringify(meta)),
                        AadMeta + id),
                };
            }

            /// <summary>
            /// Read, change, and REPLACE - never edit in place.
            ///
            /// <para>THE TEMPORARY IS RANDOM AND EXCLUSIVE. `&lt;vault&gt;.&lt;pid&gt;.tmp` is a
            /// name anyone can predict, so anyone who can write the vault's
            /// directory could put a symlink there and have the next save
            /// truncate whatever it pointed at.</para>
            /// </summary>
            private void Save(VaultFile vault)
            {
                var temp = file + "." + Convert.ToHexString(Random(8)).ToLowerInvariant() + ".tmp";

                try
                {
                    using (var handle = new FileStream(temp, FileMode.CreateNew, FileAccess.Write))
                    {
                        var bytes = WriteFile(vault);
                        handle.Write(bytes, 0, bytes.Length);
                    }

                    OwnerOnly(temp);
                    System.IO.File.Move(temp, file, true);
                }
                catch (Exception err) when (err is IOException || err is UnauthorizedAccessException)
                {
                    try
                    {
                        System.IO.File.Delete(temp);
                    }
                    catch (IOException)
                    {
                        // The vault is unchanged either way, and the write
                        // error is what the caller needs to be told about.
                    }

                    throw Fail("cannot write " + file + ": " + err.Message);
                }
            }
        }

        /// <summary>
        /// Open a vault file as one key.
        ///
        /// <para>The handle is lazy. Nothing is read, and no passphrase is
        /// stretched, until a method needs the file.</para>
        /// </summary>
        public static Vault OpenVault(Options options)
        {
            return new Vault(options);
        }

        /// <summary>
        /// Make a vault file and return a handle on its master key.
        ///
        /// <para>Refuses a file that is already there: a vault is created
        /// once, and overwriting one discards every secret in it.</para>
        /// </summary>
        public static Vault CreateVault(Options options)
        {
            var opts = options ?? new Options();

            if (string.IsNullOrEmpty(opts.File))
            {
                throw Fail("a vault needs a file");
            }

            if (string.IsNullOrEmpty(opts.Passphrase))
            {
                throw Fail("a vault needs a passphrase");
            }

            var keyid = CheckId(WantKey(opts.Key), "a vault needs a key id");

            // No existence check first: the check and the write would be two
            // steps, and `PutNew` refuses an existing file in ONE.
            PutNew(opts.File, NewVault(keyid, opts.Passphrase, opts.Iterations));

            return new Vault(opts);
        }

        // --- the provider ---------------------------------------------------

        /// <summary>
        /// Read a vault as one store in a chain.
        ///
        /// <para>The provider is the READ half and nothing more: a chain
        /// resolves secrets, and writing one is a deliberate act with an API
        /// of its own.</para>
        /// </summary>
        private sealed class MiniVaultProvider : IProvider
        {
            private readonly Vault vault;

            internal MiniVaultProvider(Vault vault)
            {
                this.vault = vault;
            }

            public string Lookup(string name)
            {
                return vault.Get(name);
            }

            public string Describe()
            {
                return "minivault:" + vault.File();
            }
        }

        public static IProvider ProviderOf(Vault vault)
        {
            return new MiniVaultProvider(vault);
        }

        /// <summary>A vault provider from options, for a chain built by hand.</summary>
        public static IProvider MiniVaultProviderOf(Options options)
        {
            return ProviderOf(OpenVault(options));
        }

        /// <summary>The vault options a provider spec describes.</summary>
        internal static Options VaultOptions(Dictionary<string, object> spec)
        {
            var out_ = new Options
            {
                File = Providers.TextOr(Get(spec, "file"), ""),
                Key = WantKey(Providers.Text(Get(spec, "vaultkey"))),
                Passphrase = Providers.TextOr(Get(spec, "passphrase"), ""),
                Create = Get(spec, "create") is bool flag && flag,
            };

            if (Get(spec, "iterations") is double iterations)
            {
                out_.Iterations = (int)iterations;
            }

            return out_;
        }

        private static object Get(Dictionary<string, object> spec, string key)
        {
            return null != spec && spec.TryGetValue(key, out var value) ? value : null;
        }

        /// <summary>
        /// The `minivault` provider kind, as a voxgig/plugin definition.
        ///
        /// <para>Written out rather than built by `Providers.ProviderPlugin`,
        /// because this definition publishes TWO exports: `provider`, the read
        /// half every kind publishes, and `vault`, the programmatic API.</para>
        /// </summary>
        public static Definition Plugin
        {
            get
            {
                var definition = new Definition("minivault");

                definition.Define = inst =>
                {
                    var spec = inst.Options() as Dictionary<string, object>
                        ?? new Dictionary<string, object>();

                    Vault vault;

                    try
                    {
                        // `OpenVault` refuses bad configuration HERE, so a
                        // mistyped chain fails at construction. Reaching the
                        // FILE is not configuration: the handle is lazy.
                        vault = OpenVault(VaultOptions(spec));
                    }
                    catch (SekretoError err)
                    {
                        throw new PluginException(
                            Providers.ErrorCode, err.Message,
                            Types.Details("ref", inst.Ref, "cause", err.Message));
                    }

                    inst.Export(Providers.ProviderExport, ProviderOf(vault));
                    inst.Export(VaultExport, vault);
                };

                return definition;
            }
        }

        /// <summary>
        /// The vault behind a store in a chain, as its programmatic API.
        ///
        /// <para>With no store named, the unqualified alias answers: one vault
        /// in the chain resolves whatever it is called, and two raise rather
        /// than picking one.</para>
        /// </summary>
        public static Vault VaultOf(Sekreto secrets)
        {
            var found = secrets.Host.Exports("minivault/" + VaultExport) as Vault;

            if (null == found)
            {
                throw Fail("no minivault store in this chain");
            }

            return found;
        }

        /// <summary>The vault behind one NAMED store in a chain.</summary>
        public static Vault VaultOf(Sekreto secrets, string store)
        {
            if (null == store)
            {
                return VaultOf(secrets);
            }

            // A NAMED STORE MUST EXIST, and the alias must not stand in for
            // it. `Host.Exports` falls back to the alias when the exact ref
            // misses, so asking for `minivault` in a chain whose only vault is
            // named `app` used to hand back the `app` vault - and then write
            // to it.
            var eref = "minivault" == store ? "minivault" : "minivault$" + store;

            if (null == secrets.Host.Instance(eref))
            {
                throw Fail("no minivault store named " + store + " in this chain");
            }

            return secrets.Host.Exports(eref + "/" + VaultExport) as Vault;
        }
    }
}
