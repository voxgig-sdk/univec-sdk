// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (zig/plugins/minivault.zig)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! A mini vault: every secret a project owns, encrypted, in ONE FILE.
//!
//! The store to reach for before there is a vault server. There is
//! nothing to run and nothing to reach over a socket - the whole store is
//! a single binary file - and the same chain that reads it in development
//! reads HashiCorp or AWS in production by changing config, which is the
//! reason sekreto exists.
//!
//! It is a plugin rather than a built-in kind because it needs crypto,
//! which is the line the four built-ins stay behind. `std.crypto` carries
//! every primitive the format names, so nothing here is hand-rolled.
//!
//! THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
//! every name and mints restricted keys. A restricted key reads the names
//! it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
//! cryptography rather than a check this code performs, so a copy of the
//! file plus a restricted passphrase yields exactly what was granted and
//! nothing else. What that does and does not protect is set out in
//! DOCS.md under "What the mini vault protects".
//!
//! THE FILE FORMAT, which is the contract between the ports:
//!
//!     magic       4   'SKMV'
//!     version     1   FORMAT
//!     kdf         1   1 = PBKDF2-HMAC-SHA256
//!     cipher      1   1 = AES-256-GCM
//!     reserved    1   0
//!     keycount    4   u32
//!     per key:
//!       id        1 + bytes      the key id, PLAINTEXT
//!       salt      1 + bytes
//!       iters     4              PBKDF2 rounds for this key
//!       ring      1 + iv, 4 + bytes    sealed under the passphrase
//!       meta      1 + iv, 4 + bytes    sealed under the vault's meta key
//!     entrycount  4   u32
//!     per entry:
//!       id        1 + bytes      the blinded lookup id
//!       name      1 + iv, 4 + bytes    sealed under the vault's name key
//!       value     1 + iv, 4 + bytes    sealed under that secret's own key
//!
//! Integers are big-endian and every length precedes its bytes, so the
//! file is written with the same two primitives it is read with.
//!
//! NOTHING OUTSIDE A KEY RECORD IS PLAINTEXT. Secret names are sealed,
//! and an entry is addressed by a blinded id derived from its own key, so
//! a restricted key finds what it was granted without the file ever
//! naming the rest. What the file does show anyone is the key ids and how
//! many secrets there are.
//!
//! A port of typescript/plugins/minivault.ts, which is canonical. The
//! bytes are pinned by ../../test/fixture/*.skmv rather than left to
//! agreement between implementations.

const std = @import("std");

const sekreto = @import("sekreto");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Config = sekreto.Config;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

const plugin = sekreto.plugin;
const pv = plugin.value;
const pt = plugin.types;

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64encoder = std.base64.standard.Encoder;
const b64decoder = std.base64.standard.Decoder;

// --- the format -------------------------------------------------------

const MAGIC = "SKMV";
const FORMAT = 1;

const KDF_PBKDF2 = 1;
const CIPHER_AESGCM = 1;

/// AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
const KEYLEN = 32;
const IVLEN = 12;
const TAGLEN = 16;
const SALTLEN = 16;

/// The PBKDF2-HMAC-SHA256 round count when a caller names none.
pub const ITERATIONS: u32 = 210000;

/// The key id a vault gets when a caller names none.
pub const MASTERKEY = "master";

// Additional authenticated data. Every blob is bound to its PLACE in the
// file, so no ciphertext can be moved: a restricted key's ring cannot be
// relabelled as the master's, and one secret's value cannot be served
// under a name it was never written for.
const AAD_RING = "skmv1:ring:";
const AAD_META = "skmv1:meta:";
const AAD_NAME = "skmv1:name";
const AAD_SECRET = "skmv1:secret:";

// Everything a master reaches is derived from the root key, so rotating
// is one new random value rather than a re-wrap of each part.
const LABEL_NAMES = "skmv1:names";
const LABEL_META = "skmv1:meta";
const LABEL_ID = "skmv1:id";

/// The largest key id the format can record.
///
/// `small` writes a length in ONE byte. A longer id wrapped that byte and
/// the writer then appended the whole thing, so every field after it
/// shifted: a grant with a 300-character id replaced a working vault with
/// an unreadable one, and said nothing. Checked where an id is ACCEPTED,
/// so the refusal names the id rather than the file.
const IDMAX = 255;

/// Owner-only, because a vault file is the whole store. POSIX only: on
/// Windows `Permissions` is a file-attribute set with no mode bits, and
/// `.default_file` is what every other writer there uses.
const OWNERONLY: std.Io.File.Permissions = if (.windows == @import("builtin").os.tag)
    .default_file
else
    @enumFromInt(0o600);

fn fail(alloc: Allocator, comptime format: []const u8, args: anytype) Allocator.Error![]const u8 {
    return sekreto.fail(alloc, "sekreto: minivault: " ++ format, args);
}

fn checkid(alloc: Allocator, id: []const u8, what: []const u8) Allocator.Error!Answer([]const u8) {
    if (0 == id.len) {
        return .{ .err = try fail(alloc, "{s}", .{what}) };
    }
    if (IDMAX < id.len) {
        const cut = id[0..@min(32, id.len)];
        return .{ .err = try fail(alloc, "key id is longer than {d} bytes: {s}...", .{ IDMAX, cut }) };
    }
    return .{ .ok = id };
}

// --- keys -------------------------------------------------------------

fn mac(alloc: Allocator, key: []const u8, text: []const u8) Allocator.Error![]const u8 {
    const out = try alloc.alloc(u8, HmacSha256.mac_length);
    HmacSha256.create(out[0..HmacSha256.mac_length], text, key);
    return out;
}

/// The key-encryption key a passphrase unwraps a ring with.
///
/// PBKDF2 refuses a zero round count, which is what a damaged or hostile
/// file records to make the derivation free; that comes back as a
/// refusal rather than a panic.
fn kek(
    alloc: Allocator,
    passphrase: []const u8,
    salt: []const u8,
    iters: u32,
) Allocator.Error!Answer([]const u8) {
    const out = try alloc.alloc(u8, KEYLEN);
    std.crypto.pwhash.pbkdf2(out, passphrase, salt, iters, HmacSha256) catch {
        return .{ .err = try fail(alloc, "unusable round count: {d}", .{iters}) };
    };
    return .{ .ok = out };
}

/// The key one named secret's value is encrypted with.
///
/// DERIVED, never stored, for a master: it holds the root key and so
/// reaches every name, including ones written after it was made. A
/// restricted key holds the derived keys it was granted and nothing that
/// produces another, so every other name is ciphertext to it in exactly
/// the way it is to a stranger.
fn secretkey(alloc: Allocator, root: []const u8, name: []const u8) Allocator.Error![]const u8 {
    const label = try std.fmt.allocPrint(alloc, AAD_SECRET ++ "{s}", .{name});
    defer alloc.free(label);
    return mac(alloc, root, label);
}

/// Where a secret lives in the file, derived from its own key so that
/// finding it needs no plaintext name. One-way: an id yields nothing
/// about the key that produced it.
fn entryid(alloc: Allocator, key: []const u8) Allocator.Error![]const u8 {
    return mac(alloc, key, LABEL_ID);
}

/// Fresh entropy, from outside the process.
///
/// `randomSecure` rather than `random`: it always makes the syscall and
/// keeps no RNG state in process memory, and it reports failure instead
/// of falling back to a weaker source. A nonce repeated under one
/// AES-GCM key loses the confidentiality of both messages, so a silent
/// downgrade is not something a vault can accept.
fn random(alloc: Allocator, io: std.Io, length: usize) Allocator.Error!Answer([]u8) {
    const out = try alloc.alloc(u8, length);
    io.randomSecure(out) catch {
        return .{ .err = try fail(alloc, "no randomness available", .{}) };
    };
    return .{ .ok = out };
}

// --- sealing ----------------------------------------------------------

const Sealed = struct {
    iv: []const u8,
    blob: []const u8,
};

fn sameseal(left: Sealed, right: Sealed) bool {
    return std.mem.eql(u8, left.iv, right.iv) and std.mem.eql(u8, left.blob, right.blob);
}

fn copyseal(alloc: Allocator, box: Sealed) Allocator.Error!Sealed {
    return .{ .iv = try alloc.dupe(u8, box.iv), .blob = try alloc.dupe(u8, box.blob) };
}

fn seal(
    alloc: Allocator,
    io: std.Io,
    key: []const u8,
    plain: []const u8,
    aad: []const u8,
) Allocator.Error!Answer(Sealed) {
    if (KEYLEN != key.len) {
        return .{ .err = try fail(alloc, "bad key", .{}) };
    }

    const iv = switch (try random(alloc, io, IVLEN)) {
        .err => |message| return .{ .err = message },
        .ok => |made| made,
    };

    // The tag rides at the end of the blob, which is where every other
    // port's AEAD leaves it and therefore what the format records.
    const blob = try alloc.alloc(u8, plain.len + TAGLEN);
    Aes256Gcm.encrypt(
        blob[0..plain.len],
        blob[plain.len..][0..TAGLEN],
        plain,
        aad,
        iv[0..IVLEN].*,
        key[0..KEYLEN].*,
    );

    return .{ .ok = .{ .iv = iv, .blob = blob } };
}

/// The plaintext, or a refusal. A GCM tag that fails to verify is the
/// only evidence there is, and it cannot tell a wrong passphrase from a
/// damaged file, so `what` names the attempt and the message admits both.
fn unseal(
    alloc: Allocator,
    key: []const u8,
    box: Sealed,
    aad: []const u8,
    what: []const u8,
) Allocator.Error!Answer([]const u8) {
    if (box.blob.len < TAGLEN or IVLEN != box.iv.len) {
        return .{ .err = try fail(alloc, "{s}: truncated", .{what}) };
    }
    if (KEYLEN != key.len) {
        return .{ .err = try fail(alloc, "bad key", .{}) };
    }

    const cut = box.blob.len - TAGLEN;
    const plain = try alloc.alloc(u8, cut);

    Aes256Gcm.decrypt(
        plain,
        box.blob[0..cut],
        box.blob[cut..][0..TAGLEN].*,
        aad,
        box.iv[0..IVLEN].*,
        key[0..KEYLEN].*,
    ) catch {
        return .{ .err = try fail(alloc, "{s}", .{what}) };
    };

    return .{ .ok = plain };
}

// --- base64 and json --------------------------------------------------

fn b64(alloc: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const out = try alloc.alloc(u8, b64encoder.calcSize(raw.len));
    return b64encoder.encode(out, raw);
}

fn unb64(alloc: Allocator, text: []const u8, what: []const u8) Allocator.Error!Answer([]const u8) {
    const size = b64decoder.calcSizeForSlice(text) catch {
        return .{ .err = try fail(alloc, "missing {s}", .{what}) };
    };
    const out = try alloc.alloc(u8, size);
    b64decoder.decode(out, text) catch {
        return .{ .err = try fail(alloc, "missing {s}", .{what}) };
    };
    return .{ .ok = out };
}

/// A JSON string literal.
///
/// Every string this writes is either base64 or a secret name, and
/// `sekreto.checkname` has already confined a name to `[a-z0-9_.]` - but
/// "this cannot contain a quote" is exactly the assumption that stops
/// being true when a rule moves, so the escaping is done rather than
/// assumed away.
fn jsonstring(out: *std.ArrayList(u8), alloc: Allocator, text: []const u8) Allocator.Error!void {
    try out.append(alloc, '"');
    for (text) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => if (0x20 > ch) {
                try out.print(alloc, "\\u{x:0>4}", .{ch});
            } else {
                try out.append(alloc, ch);
            },
        }
    }
    try out.append(alloc, '"');
}

fn jsonof(
    alloc: Allocator,
    plain: []const u8,
    what: []const u8,
) Allocator.Error!Answer(std.json.Parsed(std.json.Value)) {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, plain, .{}) catch {
        return .{ .err = try fail(alloc, "unreadable {s}", .{what}) };
    };
    return .{ .ok = parsed };
}

fn jget(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (.object != value) {
        return null;
    }
    return value.object.get(key);
}

fn jbool(value: ?std.json.Value) bool {
    const given = value orelse return false;
    return .bool == given and given.bool;
}

fn jstr(value: ?std.json.Value) ?[]const u8 {
    const given = value orelse return null;
    return if (.string == given) given.string else null;
}

// --- the file ---------------------------------------------------------

const KeyRecord = struct {
    id: []const u8,
    salt: []const u8,
    iters: u32,
    ring: Sealed,
    meta: Sealed,
};

const EntryRecord = struct {
    id: []const u8,
    name: Sealed,
    value: Sealed,
};

const VaultFile = struct {
    keys: std.ArrayList(KeyRecord) = .empty,
    entries: std.ArrayList(EntryRecord) = .empty,

    fn key(self: *const VaultFile, id: []const u8) ?*KeyRecord {
        for (self.keys.items) |*record| {
            if (std.mem.eql(u8, id, record.id)) {
                return record;
            }
        }
        return null;
    }

    fn entry(self: *const VaultFile, id: []const u8) ?*EntryRecord {
        for (self.entries.items) |*record| {
            if (std.mem.eql(u8, id, record.id)) {
                return record;
            }
        }
        return null;
    }
};

/// A cursor, so that every length check is in one place: a truncated
/// vault is refused rather than read as a short one.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    bad: bool = false,

    /// Reads `length` bytes, or records the refusal.
    ///
    /// The bound is checked as a u64 AGAINST WHAT IS LEFT, never by
    /// adding it to `at`: a damaged vault can encode a length near
    /// 0xffffffff, and `at + length` would wrap on a 32-bit target and
    /// hand back a slice the caller had no business seeing.
    fn take(self: *Reader, length: u64) []const u8 {
        if (self.bad) {
            return "";
        }
        if (@as(u64, self.bytes.len - self.at) < length) {
            self.bad = true;
            return "";
        }
        const out = self.bytes[self.at..][0..@intCast(length)];
        self.at += @intCast(length);
        return out;
    }

    fn u8v(self: *Reader) u8 {
        const out = self.take(1);
        return if (0 == out.len) 0 else out[0];
    }

    fn u32v(self: *Reader) u32 {
        const out = self.take(4);
        return if (4 != out.len) 0 else std.mem.readInt(u32, out[0..4], .big);
    }

    fn small(self: *Reader) []const u8 {
        return self.take(self.u8v());
    }

    fn large(self: *Reader) []const u8 {
        return self.take(self.u32v());
    }

    fn sealed(self: *Reader) Sealed {
        // The iv is read before the blob, and zig evaluates struct
        // fields in source order, so the two reads stay in file order.
        const iv = self.small();
        return .{ .iv = iv, .blob = self.large() };
    }
};

fn readfile(alloc: Allocator, raw: []const u8) Allocator.Error!Answer(VaultFile) {
    var read = Reader{ .bytes = raw };

    if (!std.mem.eql(u8, MAGIC, read.take(4))) {
        if (read.bad) {
            return .{ .err = try fail(alloc, "the vault file is truncated", .{}) };
        }
        return .{ .err = try fail(alloc, "not a vault file", .{}) };
    }

    const version = read.u8v();
    if (read.bad) {
        return .{ .err = try fail(alloc, "the vault file is truncated", .{}) };
    }
    if (FORMAT != version) {
        return .{ .err = try fail(alloc, "unsupported format version: {d}", .{version}) };
    }

    const kdf = read.u8v();
    const cipher = read.u8v();
    if (read.bad) {
        return .{ .err = try fail(alloc, "the vault file is truncated", .{}) };
    }
    if (KDF_PBKDF2 != kdf or CIPHER_AESGCM != cipher) {
        return .{ .err = try fail(alloc, "unsupported kdf or cipher: {d}/{d}", .{ kdf, cipher }) };
    }
    _ = read.u8v();

    var file = VaultFile{};

    // A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a
    // few bytes, so a file claiming four billion of them is damaged; the
    // loop would find that out one truncation at a time, and a caller
    // that preallocated would not.
    const keycount = read.u32v();
    if (raw.len - read.at < keycount) {
        return .{ .err = try fail(alloc, "the vault file is truncated", .{}) };
    }
    for (0..keycount) |_| {
        if (read.bad) {
            break;
        }
        const id = read.small();
        const salt = read.small();
        const iters = read.u32v();
        const ring = read.sealed();
        try file.keys.append(alloc, .{
            .id = id,
            .salt = salt,
            .iters = iters,
            .ring = ring,
            .meta = read.sealed(),
        });
    }

    const entrycount = read.u32v();
    if (raw.len - read.at < entrycount) {
        return .{ .err = try fail(alloc, "the vault file is truncated", .{}) };
    }
    for (0..entrycount) |_| {
        if (read.bad) {
            break;
        }
        const id = read.small();
        const name = read.sealed();
        try file.entries.append(alloc, .{ .id = id, .name = name, .value = read.sealed() });
    }

    if (read.bad) {
        return .{ .err = try fail(alloc, "the vault file is truncated", .{}) };
    }
    if (read.at != raw.len) {
        return .{ .err = try fail(alloc, "the vault file has trailing bytes", .{}) };
    }

    return .{ .ok = file };
}

const Writer = struct {
    out: std.ArrayList(u8) = .empty,
    alloc: Allocator,

    fn u8v(self: *Writer, value: u8) Allocator.Error!void {
        try self.out.append(self.alloc, value);
    }

    fn u32v(self: *Writer, value: u32) Allocator.Error!void {
        var four: [4]u8 = undefined;
        std.mem.writeInt(u32, &four, value, .big);
        try self.out.appendSlice(self.alloc, &four);
    }

    fn small(self: *Writer, value: []const u8) Allocator.Error!void {
        try self.u8v(@intCast(value.len));
        try self.out.appendSlice(self.alloc, value);
    }

    fn large(self: *Writer, value: []const u8) Allocator.Error!void {
        try self.u32v(@intCast(value.len));
        try self.out.appendSlice(self.alloc, value);
    }

    fn sealed(self: *Writer, value: Sealed) Allocator.Error!void {
        try self.small(value.iv);
        try self.large(value.blob);
    }
};

fn byid(_: void, left: EntryRecord, right: EntryRecord) bool {
    return .lt == std.mem.order(u8, left.id, right.id);
}

fn writefile(alloc: Allocator, file: *const VaultFile) Allocator.Error![]const u8 {
    var write = Writer{ .alloc = alloc };

    try write.out.appendSlice(alloc, MAGIC);
    try write.u8v(FORMAT);
    try write.u8v(KDF_PBKDF2);
    try write.u8v(CIPHER_AESGCM);
    try write.u8v(0);

    try write.u32v(@intCast(file.keys.items.len));
    for (file.keys.items) |record| {
        try write.small(record.id);
        try write.small(record.salt);
        try write.u32v(record.iters);
        try write.sealed(record.ring);
        try write.sealed(record.meta);
    }

    // SORTED BY ID, which is a blinded value: the file therefore records
    // nothing about the order secrets were written in.
    const entries = try alloc.dupe(EntryRecord, file.entries.items);
    std.mem.sort(EntryRecord, entries, {}, byid);

    try write.u32v(@intCast(entries.len));
    for (entries) |record| {
        try write.small(record.id);
        try write.sealed(record.name);
        try write.sealed(record.value);
    }

    return write.out.items;
}

// --- the vault --------------------------------------------------------

/// What a key may do. `grants` is empty for a master key, which reads and
/// writes every name there is.
pub const KeyInfo = struct {
    key: []const u8,
    master: bool = false,
    write: bool = false,
    /// Sorted, and `[]const` so that a caller cannot write through it.
    /// The struct itself is a VALUE: `info.write = true` edits the
    /// caller's copy and nothing the vault reads, which is how this port
    /// answers the defect the review round found in the canonical.
    grants: []const []const u8 = &.{},
};

/// What mints a restricted key.
pub const GrantSpec = struct {
    /// The id the new key answers to.
    key: []const u8,
    /// What unwraps it. Nothing else does, and no master can recover it -
    /// a lost restricted passphrase is re-granted, never read back.
    passphrase: []const u8,
    /// The names the key may read. A name that does not exist yet is
    /// allowed and means what it says: the key reads it once a master
    /// writes it.
    names: []const []const u8 = &.{},
    /// Whether it may overwrite the values it can read.
    write: bool = false,
    /// PBKDF2 rounds for this key, defaulting to the opening handle's.
    iterations: u32 = 0,
};

/// How a vault file is opened as one key.
pub const Options = struct {
    /// The vault file.
    file: []const u8,
    /// Which key to open with. Defaults to `MASTERKEY`.
    key: []const u8 = "",
    /// What unwraps that key.
    passphrase: []const u8,
    /// The PBKDF2 round count used when this handle CREATES a key.
    /// Reading uses what the file records for the key being opened.
    iterations: u32 = 0,
    /// Make the file, with this key as its master, if it is not there.
    ///
    /// Off by default. A missing vault is far more often a broken
    /// deployment than a new one, and a store that invents itself where a
    /// real vault was meant to be answers every read with a miss.
    create: bool = false,
};

const Grant = struct {
    name: []const u8,
    key: []const u8,
};

/// A handle on one vault file, opened as ONE key.
///
/// Every method answers as that key: `list` shows the names it may read,
/// `get` answers for those and misses on the rest, and the master-only
/// methods refuse for any other key. Nothing is read or derived until the
/// first call that needs the file, so putting a vault in a chain costs no
/// key derivation until a secret is actually wanted.
///
/// ONE THREAD. This port builds and reads a chain from one thread, as
/// voxgig/plugin's zig port does and as `provider.Building` says outright;
/// two handles on one file in one thread interleave only between calls,
/// and the format's answer to two PROCESSES is the exclusive create and
/// the atomic rename - a reader sees one whole vault or the other, never
/// half of one.
pub const Vault = struct {
    alloc: Allocator,
    io: std.Io,
    file: []const u8,
    key: []const u8,
    passphrase: []const u8,
    iterations: u32,
    create: bool,
    /// Where `VAULTS` holds this handle, so that a definition can export
    /// an index; see `VAULTS`.
    slot: usize,

    /// The derived state, which outlives one call and is dropped
    /// wholesale by `close`. Its own arena because a ring unwraps into a
    /// dozen small allocations of three different lifetimes, and one
    /// reset covers them all.
    state: std.heap.ArenaAllocator,
    info: ?KeyInfo = null,
    root: ?[]const u8 = null,
    grants: []const Grant = &.{},
    /// THE SEALED RING THIS WAS DERIVED FROM, kept so that every later
    /// call can check the file still says the same thing. A handle that
    /// cached its keys and never looked again kept reading a vault after
    /// its key was revoked, which is the one thing `revoke` promises.
    ring: ?Sealed = null,

    /// The vault file this handle reads.
    pub fn vaultfile(self: *const Vault) []const u8 {
        return self.file;
    }

    /// The key id this handle opens with.
    pub fn vaultkey(self: *const Vault) []const u8 {
        return self.key;
    }

    /// Derives the key and reads the file NOW rather than at first use.
    ///
    /// A COPY, allocated from `alloc`. `set` asks this whether the key
    /// may write, and handing back the value that answer lives in let a
    /// caller flip its own permission.
    pub fn open(self: *Vault, alloc: Allocator) Allocator.Error!Answer(KeyInfo) {
        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();

        const held = switch (try self.load(work.allocator(), alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        return .{ .ok = try copyinfo(alloc, held.info) };
    }

    /// Forgets the derived keys. The next call opens again.
    pub fn close(self: *Vault) void {
        _ = self.state.reset(.free_all);
        self.info = null;
        self.root = null;
        self.grants = &.{};
        self.ring = null;
    }

    /// Releases the handle itself. The slot it held is reused.
    pub fn deinit(self: *Vault) void {
        self.state.deinit();
        VAULTS.items[self.slot] = null;
        self.alloc.free(self.file);
        self.alloc.free(self.key);
        self.alloc.free(self.passphrase);
        self.alloc.destroy(self);
    }

    // --- reading the file ---------------------------------------------

    fn bytes(self: *Vault, work: Allocator, alloc: Allocator) Allocator.Error!Answer([]const u8) {
        const raw = std.Io.Dir.cwd().readFileAlloc(self.io, self.file, work, .unlimited) catch |err| switch (err) {
            // A vault is configured deliberately, with a key. Its absence
            // is a broken deployment and never "no secrets here":
            // answering a miss would send the chain on to a weaker store,
            // which is the failure mode this library most has to avoid.
            // `create` is the caller saying the opposite, in writing.
            error.FileNotFound, error.NotDir => {
                if (!self.create) {
                    return .{ .err = try fail(alloc, "no vault file: {s}", .{self.file}) };
                }

                switch (try self.newvault(work, alloc, self.key, self.passphrase, self.iterations)) {
                    .err => |message| return .{ .err = message },
                    .ok => |fresh| switch (try self.putnew(work, alloc, &fresh)) {
                        .err => |message| return .{ .err = message },
                        .ok => {},
                    },
                }

                const made = std.Io.Dir.cwd().readFileAlloc(self.io, self.file, work, .unlimited) catch |again| {
                    return .{ .err = try fail(alloc, "cannot read {s}: {s}", .{ self.file, @errorName(again) }) };
                };
                return .{ .ok = made };
            },
            else => return .{ .err = try fail(alloc, "cannot read {s}: {s}", .{ self.file, @errorName(err) }) },
        };

        return .{ .ok = raw };
    }

    /// What one call works with: the parsed file and this key's rights.
    ///
    /// The file is parsed into the CALL's arena - it is different bytes
    /// every time - while the unwrapped ring lives in the handle's own,
    /// because stretching a passphrase once per lookup is the cost this
    /// caching exists to avoid.
    const Loaded = struct {
        file: VaultFile,
        info: KeyInfo,
    };

    fn load(self: *Vault, work: Allocator, alloc: Allocator) Allocator.Error!Answer(Loaded) {
        const raw = switch (try self.bytes(work, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |read| read,
        };

        const file = switch (try readfile(work, raw)) {
            .err => |message| return .{ .err = message },
            .ok => |parsed| parsed,
        };

        const record = file.key(self.key) orelse {
            // REVOKED, or never there. Either way this handle is
            // finished, and dropping what it derived is what stops the
            // next call answering from memory.
            self.close();
            return .{ .err = try fail(alloc, "no such key: {s}", .{self.key}) };
        };

        // The file still holds this key, and holds the SAME ring: a key
        // revoked and re-granted under another passphrase is a different
        // key wearing the id, and re-deriving is what refuses it.
        if (self.info) |held| {
            if (self.ring) |was| {
                if (sameseal(was, record.ring)) {
                    return .{ .ok = .{ .file = file, .info = held } };
                }
            }
        }
        self.close();

        const keep = self.state.allocator();

        const unwrapped = switch (try kek(work, self.passphrase, record.salt, record.iters)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        const label = try std.fmt.allocPrint(work, AAD_RING ++ "{s}", .{self.key});
        const what = try std.fmt.allocPrint(
            work,
            "wrong passphrase for key {s}, or a damaged vault",
            .{self.key},
        );

        const plain = switch (try unseal(work, unwrapped, record.ring, label, what)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        const parsed = switch (try jsonof(work, plain, "key ring")) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };
        const held = parsed.value;

        var grants: std.ArrayList(Grant) = .empty;
        var names: std.ArrayList([]const u8) = .empty;

        if (jget(held, "grants")) |given| {
            if (.object == given) {
                var it = given.object.iterator();
                while (it.next()) |pair| {
                    const text = jstr(pair.value_ptr.*) orelse {
                        return .{ .err = try fail(alloc, "missing a granted key", .{}) };
                    };
                    const raw_key = switch (try unb64(work, text, "a granted key")) {
                        .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                        .ok => |made| made,
                    };
                    const name = try keep.dupe(u8, pair.key_ptr.*);
                    try grants.append(keep, .{ .name = name, .key = try keep.dupe(u8, raw_key) });
                    try names.append(keep, name);
                }
            }
        }

        std.mem.sort([]const u8, names.items, {}, bytext);

        var root: ?[]const u8 = null;
        if (jstr(jget(held, "root"))) |text| {
            const raw_root = switch (try unb64(work, text, "the root key")) {
                .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                .ok => |made| made,
            };
            root = try keep.dupe(u8, raw_root);
        }

        self.root = root;
        self.grants = grants.items;
        self.ring = try copyseal(keep, record.ring);
        self.info = .{
            .key = self.key,
            .master = null != root,
            .write = null != root or jbool(jget(held, "write")),
            .grants = names.items,
        };

        return .{ .ok = .{ .file = file, .info = self.info.? } };
    }

    /// The root key, or a refusal naming what needed it.
    fn rootof(self: *Vault, alloc: Allocator, what: []const u8) Allocator.Error!Answer([]const u8) {
        const root = self.root orelse {
            return .{ .err = try fail(
                alloc,
                "{s} needs a master key, and {s} is restricted",
                .{ what, self.key },
            ) };
        };
        return .{ .ok = root };
    }

    /// The key for one name, or null when this key cannot reach it.
    fn keyfor(self: *Vault, work: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        if (self.root) |root| {
            return try secretkey(work, root, name);
        }
        for (self.grants) |held| {
            if (std.mem.eql(u8, name, held.name)) {
                return held.key;
            }
        }
        return null;
    }

    /// Replaces the file rather than editing it in place. The rename is
    /// what makes a concurrent reader see either the old file or the new
    /// one, so a write interrupted halfway leaves a vault rather than
    /// wreckage.
    ///
    /// THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a
    /// name anyone can predict, and an ordinary create FOLLOWS a symlink,
    /// so anyone who could write the vault's directory could point that
    /// name at another file and have the next save truncate it. An
    /// exclusive create refuses an existing path and will not follow a
    /// symlink to make one, and the random suffix stops two writers
    /// colliding on the name.
    fn save(self: *Vault, work: Allocator, alloc: Allocator, file: *const VaultFile) Allocator.Error!Answer(void) {
        const suffix = switch (try random(work, self.io, 8)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        const temp = try std.fmt.allocPrint(work, "{s}.{x}.tmp", .{ self.file, suffix });
        const raw = try writefile(work, file);

        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = temp,
            .data = raw,
            .flags = .{ .exclusive = true, .permissions = OWNERONLY },
        }) catch |err| {
            return .{ .err = try fail(alloc, "cannot write {s}: {s}", .{ self.file, @errorName(err) }) };
        };

        std.Io.Dir.cwd().rename(temp, .cwd(), self.file, self.io) catch |err| {
            // The vault is unchanged either way, and the write error is
            // what the caller needs to be told about.
            std.Io.Dir.cwd().deleteFile(self.io, temp) catch {};
            return .{ .err = try fail(alloc, "cannot write {s}: {s}", .{ self.file, @errorName(err) }) };
        };

        return .{ .ok = {} };
    }

    /// Writes a vault file that is not there yet, and REFUSES one that is.
    ///
    /// Straight to the target under an exclusive create rather than
    /// through a temporary and a rename. A rename REPLACES its
    /// destination, so two processes creating the same vault both
    /// succeeded and the second discarded the first one's secrets; a stat
    /// beforehand only narrows that window. There is nothing to lose by
    /// writing the target directly here, because there is no file to
    /// damage: either this call creates it or it fails.
    fn putnew(self: *Vault, work: Allocator, alloc: Allocator, file: *const VaultFile) Allocator.Error!Answer(void) {
        const raw = try writefile(work, file);

        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.file,
            .data = raw,
            .flags = .{ .exclusive = true, .permissions = OWNERONLY },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                return .{ .err = try fail(alloc, "vault file already exists: {s}", .{self.file}) };
            },
            else => return .{ .err = try fail(alloc, "cannot write {s}: {s}", .{ self.file, @errorName(err) }) },
        };

        return .{ .ok = {} };
    }

    // --- reading secrets ----------------------------------------------

    /// The names this key can read, sorted.
    pub fn list(self: *Vault, alloc: Allocator) Allocator.Error!Answer([]const []const u8) {
        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();
        const scratch = work.allocator();

        const held = switch (try self.load(scratch, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        var names: std.ArrayList([]const u8) = .empty;

        if (self.root) |root| {
            const namekey = try mac(scratch, root, LABEL_NAMES);
            for (held.file.entries.items) |entry| {
                const plain = switch (try unseal(
                    scratch,
                    namekey,
                    entry.name,
                    AAD_NAME,
                    "a secret name is damaged",
                )) {
                    .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                    .ok => |made| made,
                };
                try names.append(alloc, try alloc.dupe(u8, plain));
            }
        } else {
            // A restricted key has no name key, so it reports the grants
            // it can actually find: the vault never tells it what else is
            // there.
            for (held.info.grants) |name| {
                const key = try self.keyfor(scratch, name) orelse continue;
                if (null != held.file.entry(try entryid(scratch, key))) {
                    try names.append(alloc, try alloc.dupe(u8, name));
                }
            }
        }

        std.mem.sort([]const u8, names.items, {}, bytext);

        return .{ .ok = names.items };
    }

    /// The value, or a miss. A name the vault does not hold and a name
    /// this key was not granted are both a miss.
    pub fn get(self: *Vault, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        switch (try sekreto.checkname(alloc, name)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();
        const scratch = work.allocator();

        const held = switch (try self.load(scratch, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        // OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as
        // the key that opened it, so a name this key cannot read is a
        // name this store does not hold for this caller - the same answer
        // a stranger's vault gives, and the one that makes a restricted
        // key in front of a broader store a workable chain.
        const key = try self.keyfor(scratch, name) orelse return .{ .ok = null };

        const entry = held.file.entry(try entryid(scratch, key)) orelse return .{ .ok = null };

        const label = try std.fmt.allocPrint(scratch, AAD_SECRET ++ "{s}", .{name});
        const what = try std.fmt.allocPrint(scratch, "the value of {s} is damaged", .{name});

        const plain = switch (try unseal(scratch, key, entry.value, label, what)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        return .{ .ok = try alloc.dupe(u8, plain) };
    }

    /// Whether this key can read that name.
    pub fn has(self: *Vault, alloc: Allocator, name: []const u8) Allocator.Error!Answer(bool) {
        return switch (try self.get(alloc, name)) {
            .err => |message| .{ .err = message },
            .ok => |found| .{ .ok = null != found },
        };
    }

    // --- writing ------------------------------------------------------

    /// Writes a value. A master writes any name; a restricted key holding
    /// `write` overwrites the names it was granted, and creates none.
    pub fn set(self: *Vault, alloc: Allocator, name: []const u8, value: []const u8) Allocator.Error!Answer(void) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        const onefile = try lockfor(self.io, self.file);
        onefile.lockUncancelable(self.io);
        defer onefile.unlock(self.io);

        switch (try sekreto.checkname(alloc, name)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();
        const scratch = work.allocator();

        var held = switch (try self.load(scratch, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        if (!held.info.write) {
            return .{ .err = try fail(alloc, "key {s} is read-only", .{held.info.key}) };
        }

        const key = try self.keyfor(scratch, name) orelse {
            return .{ .err = try fail(alloc, "key {s} was not granted {s}", .{ held.info.key, name }) };
        };

        const label = try std.fmt.allocPrint(scratch, AAD_SECRET ++ "{s}", .{name});

        const box = switch (try seal(scratch, self.io, key, value, label)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        const id = try entryid(scratch, key);

        if (held.file.entry(id)) |entry| {
            entry.value = box;
        } else {
            // A NEW NAME NEEDS THE NAME KEY, which only a master holds.
            // So a restricted key with `write` updates what it was
            // granted and cannot grow the vault, which is what
            // "restricted" has to mean for the grant list to stay the
            // whole story.
            const what = try std.fmt.allocPrint(scratch, "creating the secret {s}", .{name});
            const root = switch (try self.rootof(alloc, what)) {
                .err => |message| return .{ .err = message },
                .ok => |made| made,
            };

            const namekey = try mac(scratch, root, LABEL_NAMES);
            const sealedname = switch (try seal(scratch, self.io, namekey, name, AAD_NAME)) {
                .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                .ok => |made| made,
            };

            try held.file.entries.append(scratch, .{ .id = id, .name = sealedname, .value = box });
        }

        return switch (try self.save(scratch, alloc, &held.file)) {
            .err => |message| .{ .err = message },
            .ok => .{ .ok = {} },
        };
    }

    /// Drops a name. Master only.
    pub fn remove(self: *Vault, alloc: Allocator, name: []const u8) Allocator.Error!Answer(void) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        const onefile = try lockfor(self.io, self.file);
        onefile.lockUncancelable(self.io);
        defer onefile.unlock(self.io);

        switch (try sekreto.checkname(alloc, name)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();
        const scratch = work.allocator();

        var held = switch (try self.load(scratch, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        const root = switch (try self.rootof(alloc, "removing a secret")) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        const want = try entryid(scratch, try secretkey(scratch, root, name));

        var kept: std.ArrayList(EntryRecord) = .empty;
        var found = false;

        for (held.file.entries.items) |entry| {
            if (!found and std.mem.eql(u8, want, entry.id)) {
                found = true;
                continue;
            }
            try kept.append(scratch, entry);
        }

        if (!found) {
            return .{ .err = try fail(alloc, "no such secret: {s}", .{name}) };
        }

        held.file.entries = kept;

        return switch (try self.save(scratch, alloc, &held.file)) {
            .err => |message| .{ .err = message },
            .ok => .{ .ok = {} },
        };
    }

    // --- keys ---------------------------------------------------------

    /// Every key in the file, with what it may do. Master only.
    pub fn keys(self: *Vault, alloc: Allocator) Allocator.Error!Answer([]const KeyInfo) {
        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();
        const scratch = work.allocator();

        const held = switch (try self.load(scratch, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        const root = switch (try self.rootof(alloc, "listing the keys")) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        const metakey = try mac(scratch, root, LABEL_META);
        var out: std.ArrayList(KeyInfo) = .empty;

        for (held.file.keys.items) |record| {
            var info = KeyInfo{ .key = try alloc.dupe(u8, record.id) };

            const label = try std.fmt.allocPrint(scratch, AAD_META ++ "{s}", .{record.id});

            // A record written under a root key this one has replaced is
            // still in the file and still opens with its own passphrase,
            // so it is reported rather than hidden - with what it can do
            // unknown.
            switch (try unseal(scratch, metakey, record.meta, label, "metadata")) {
                .err => {},
                .ok => |plain| {
                    const parsed = switch (try jsonof(scratch, plain, "metadata")) {
                        .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                        .ok => |made| made,
                    };
                    const noted = parsed.value;

                    info.master = jbool(jget(noted, "master"));
                    info.write = jbool(jget(noted, "write"));

                    var names: std.ArrayList([]const u8) = .empty;
                    if (jget(noted, "grants")) |given| {
                        if (.array == given) {
                            for (given.array.items) |item| {
                                if (jstr(item)) |text| {
                                    try names.append(alloc, try alloc.dupe(u8, text));
                                }
                            }
                        }
                    }
                    std.mem.sort([]const u8, names.items, {}, bytext);
                    info.grants = names.items;
                },
            }

            try out.append(alloc, info);
        }

        return .{ .ok = out.items };
    }

    /// Mints a restricted key. Master only.
    pub fn grant(self: *Vault, alloc: Allocator, spec: GrantSpec) Allocator.Error!Answer(void) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        const onefile = try lockfor(self.io, self.file);
        onefile.lockUncancelable(self.io);
        defer onefile.unlock(self.io);

        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();
        const scratch = work.allocator();

        var held = switch (try self.load(scratch, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        const root = switch (try self.rootof(alloc, "granting a key")) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        switch (try checkid(alloc, spec.key, "a grant needs a key id")) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }
        if (0 == spec.passphrase.len) {
            return .{ .err = try fail(alloc, "a grant needs a passphrase", .{}) };
        }
        if (null != held.file.key(spec.key)) {
            return .{ .err = try fail(alloc, "key already exists: {s}", .{spec.key}) };
        }

        const names = try scratch.dupe([]const u8, spec.names);
        std.mem.sort([]const u8, names, {}, bytext);

        var ring: std.ArrayList(u8) = .empty;
        try ring.print(scratch, "{{\"v\":{d},\"write\":{s},\"grants\":{{", .{
            FORMAT,
            if (spec.write) "true" else "false",
        });

        for (names, 0..) |name, at| {
            switch (try sekreto.checkname(alloc, name)) {
                .err => |message| return .{ .err = message },
                .ok => {},
            }
            if (0 != at) {
                try ring.append(scratch, ',');
            }
            try jsonstring(&ring, scratch, name);
            try ring.append(scratch, ':');
            try jsonstring(&ring, scratch, try b64(scratch, try secretkey(scratch, root, name)));
        }
        try ring.appendSlice(scratch, "}}");

        var meta: std.ArrayList(u8) = .empty;
        try meta.print(scratch, "{{\"v\":{d},\"master\":false,\"write\":{s},\"grants\":[", .{
            FORMAT,
            if (spec.write) "true" else "false",
        });
        for (names, 0..) |name, at| {
            if (0 != at) {
                try meta.append(scratch, ',');
            }
            try jsonstring(&meta, scratch, name);
        }
        try meta.appendSlice(scratch, "]}");

        const iterations = if (0 < spec.iterations) spec.iterations else self.iterations;

        const record = switch (try sealkey(
            scratch,
            self.io,
            root,
            spec.key,
            spec.passphrase,
            iterations,
            ring.items,
            meta.items,
        )) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        try held.file.keys.append(scratch, record);

        return switch (try self.save(scratch, alloc, &held.file)) {
            .err => |message| .{ .err = message },
            .ok => .{ .ok = {} },
        };
    }

    /// Drops a key. Master only.
    ///
    /// Anyone who already copied the file keeps whatever that key could
    /// read, so revoking bars future reads of the LIVE file and `rotate`
    /// is what takes a secret back.
    pub fn revoke(self: *Vault, alloc: Allocator, key: []const u8) Allocator.Error!Answer(void) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        const onefile = try lockfor(self.io, self.file);
        onefile.lockUncancelable(self.io);
        defer onefile.unlock(self.io);

        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();
        const scratch = work.allocator();

        var held = switch (try self.load(scratch, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        switch (try self.rootof(alloc, "revoking a key")) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        if (std.mem.eql(u8, key, held.info.key)) {
            return .{ .err = try fail(alloc, "a key cannot revoke itself: {s}", .{key}) };
        }
        if (null == held.file.key(key)) {
            return .{ .err = try fail(alloc, "no such key: {s}", .{key}) };
        }

        var kept: std.ArrayList(KeyRecord) = .empty;
        for (held.file.keys.items) |record| {
            if (!std.mem.eql(u8, key, record.id)) {
                try kept.append(scratch, record);
            }
        }
        held.file.keys = kept;

        return switch (try self.save(scratch, alloc, &held.file)) {
            .err => |message| .{ .err = message },
            .ok => .{ .ok = {} },
        };
    }

    /// Takes a new root key, re-encrypts every value under it, and DROPS
    /// EVERY OTHER KEY. Master only.
    ///
    /// The other keys go because they must: their rings are sealed under
    /// passphrases this process does not have, so there is no way to hand
    /// them keys they can unwrap. Re-grant afterwards.
    pub fn rotate(self: *Vault, alloc: Allocator) Allocator.Error!Answer(void) {
        // Every write on this file, from any handle in this process,
        // serializes here; see lockfor.
        const onefile = try lockfor(self.io, self.file);
        onefile.lockUncancelable(self.io);
        defer onefile.unlock(self.io);

        var work = std.heap.ArenaAllocator.init(self.alloc);
        defer work.deinit();
        const scratch = work.allocator();

        const held = switch (try self.load(scratch, alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        const oldroot = switch (try self.rootof(alloc, "rotating the vault")) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        const iters = held.file.key(self.key).?.iters;

        // Read everything out under the old root before anything changes:
        // once the root is replaced the old derived keys are unreachable.
        const oldnamekey = try mac(scratch, oldroot, LABEL_NAMES);

        var names: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList([]const u8) = .empty;

        for (held.file.entries.items) |entry| {
            const name = switch (try unseal(
                scratch,
                oldnamekey,
                entry.name,
                AAD_NAME,
                "a secret name is damaged",
            )) {
                .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                .ok => |made| made,
            };

            const label = try std.fmt.allocPrint(scratch, AAD_SECRET ++ "{s}", .{name});
            const what = try std.fmt.allocPrint(scratch, "the value of {s} is damaged", .{name});

            const value = switch (try unseal(
                scratch,
                try secretkey(scratch, oldroot, name),
                entry.value,
                label,
                what,
            )) {
                .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                .ok => |made| made,
            };

            try names.append(scratch, name);
            try values.append(scratch, value);
        }

        const root = switch (try random(scratch, self.io, KEYLEN)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        const namekey = try mac(scratch, root, LABEL_NAMES);
        var fresh = VaultFile{};

        for (names.items, values.items) |name, value| {
            const key = try secretkey(scratch, root, name);
            const label = try std.fmt.allocPrint(scratch, AAD_SECRET ++ "{s}", .{name});

            const sealedname = switch (try seal(scratch, self.io, namekey, name, AAD_NAME)) {
                .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                .ok => |made| made,
            };
            const box = switch (try seal(scratch, self.io, key, value, label)) {
                .err => |message| return .{ .err = try alloc.dupe(u8, message) },
                .ok => |made| made,
            };

            try fresh.entries.append(scratch, .{
                .id = try entryid(scratch, key),
                .name = sealedname,
                .value = box,
            });
        }

        const record = switch (try masterkey(scratch, self.io, root, self.key, self.passphrase, iters)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };
        try fresh.keys.append(scratch, record);

        // SAVE FIRST, adopt second. A handle holding the new root over a
        // file that still holds the old one reads nothing and says the
        // vault is damaged, which is the wrong story about a failed write.
        switch (try self.save(scratch, alloc, &fresh)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        // Dropped rather than replaced: the next call re-derives from the
        // file this one just wrote, which is the same rule every other
        // change follows.
        self.close();

        return .{ .ok = {} };
    }

    fn newvault(
        self: *Vault,
        work: Allocator,
        alloc: Allocator,
        keyid: []const u8,
        passphrase: []const u8,
        iterations: u32,
    ) Allocator.Error!Answer(VaultFile) {
        const root = switch (try random(work, self.io, KEYLEN)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        const record = switch (try masterkey(work, self.io, root, keyid, passphrase, iterations)) {
            .err => |message| return .{ .err = try alloc.dupe(u8, message) },
            .ok => |made| made,
        };

        var file = VaultFile{};
        try file.keys.append(work, record);

        return .{ .ok = file };
    }
};

fn bytext(_: void, left: []const u8, right: []const u8) bool {
    return .lt == std.mem.order(u8, left, right);
}

fn copyinfo(alloc: Allocator, info: KeyInfo) Allocator.Error!KeyInfo {
    const grants = try alloc.alloc([]const u8, info.grants.len);
    for (info.grants, 0..) |name, at| {
        grants[at] = try alloc.dupe(u8, name);
    }
    return .{
        .key = try alloc.dupe(u8, info.key),
        .master = info.master,
        .write = info.write,
        .grants = grants,
    };
}

fn sealkey(
    alloc: Allocator,
    io: std.Io,
    root: []const u8,
    id: []const u8,
    passphrase: []const u8,
    iters: u32,
    ring: []const u8,
    meta: []const u8,
) Allocator.Error!Answer(KeyRecord) {
    const salt = switch (try random(alloc, io, SALTLEN)) {
        .err => |message| return .{ .err = message },
        .ok => |made| made,
    };

    const unwrapped = switch (try kek(alloc, passphrase, salt, iters)) {
        .err => |message| return .{ .err = message },
        .ok => |made| made,
    };

    const ringlabel = try std.fmt.allocPrint(alloc, AAD_RING ++ "{s}", .{id});
    const sealedring = switch (try seal(alloc, io, unwrapped, ring, ringlabel)) {
        .err => |message| return .{ .err = message },
        .ok => |made| made,
    };

    const metalabel = try std.fmt.allocPrint(alloc, AAD_META ++ "{s}", .{id});
    const sealedmeta = switch (try seal(alloc, io, try mac(alloc, root, LABEL_META), meta, metalabel)) {
        .err => |message| return .{ .err = message },
        .ok => |made| made,
    };

    return .{ .ok = .{
        .id = id,
        .salt = salt,
        .iters = iters,
        .ring = sealedring,
        .meta = sealedmeta,
    } };
}

/// The one key record a new or rotated vault starts with: a master
/// holding the root, granted nothing because it needs nothing.
fn masterkey(
    alloc: Allocator,
    io: std.Io,
    root: []const u8,
    id: []const u8,
    passphrase: []const u8,
    iters: u32,
) Allocator.Error!Answer(KeyRecord) {
    var ring: std.ArrayList(u8) = .empty;
    try ring.print(alloc, "{{\"v\":{d},\"write\":true,\"root\":", .{FORMAT});
    try jsonstring(&ring, alloc, try b64(alloc, root));
    try ring.append(alloc, '}');

    const meta = try std.fmt.allocPrint(
        alloc,
        "{{\"v\":{d},\"master\":true,\"write\":true,\"grants\":[]}}",
        .{FORMAT},
    );

    return sealkey(alloc, io, root, id, passphrase, iters, ring.items, meta);
}

// --- opening and creating ---------------------------------------------

/// THE LOCK EVERY HANDLE ON ONE FILE SHARES.
///
/// Each `Vault` is its own object, so two handles on one path did not
/// coordinate: both could finish `load` before either saved, and the
/// second rename then discarded the first one's change while reporting
/// success.
///
/// Keyed by the path AS THE HANDLE HOLDS IT. Every other port keys by the
/// absolute path so that two spellings of one file still meet; realpath
/// at this level would want an allocator and a syscall per write, and
/// this port says what it does rather than implying the stronger thing.
///
/// A guarantee WITHIN one process, which is what DOCS.md promises and
/// what the go port arranges the same way. Two processes still race, and
/// the format's answer to that is the exclusive create and the atomic
/// rename: a reader sees one whole vault or the other, never half of one.
var LOCKSMUTEX: std.Io.Mutex = .init;
var LOCKS: std.ArrayList(Held) = .empty;

const Held = struct {
    file: []const u8,
    lock: *std.Io.Mutex,
};

/// The lock for one path, made once and never dropped: a mutex is two
/// words, a process opens few vaults, and freeing one a thread might
/// still be waiting on is the bug this exists to avoid.
///
/// FROM THE PAGE ALLOCATOR, NOT THE CALLER'S. This table outlives every
/// handle in it, and the callers are two different threads with two
/// different arenas; taking the memory from whichever got here first
/// would leave the other holding a pointer into a freed arena. The page
/// allocator is process-lifetime and thread-safe, which is exactly what
/// process-global state wants.
fn lockfor(io: std.Io, file: []const u8) Allocator.Error!*std.Io.Mutex {
    const alloc = std.heap.page_allocator;

    LOCKSMUTEX.lockUncancelable(io);
    defer LOCKSMUTEX.unlock(io);


    for (LOCKS.items) |held| {
        if (std.mem.eql(u8, held.file, file)) {
            return held.lock;
        }
    }

    const owned = try alloc.dupe(u8, file);
    const made = try alloc.create(std.Io.Mutex);
    made.* = .init;
    try LOCKS.append(alloc, .{ .file = owned, .lock = made });

    return made;
}

/// The vaults this module has built.
///
/// voxgig/plugin's values are numbers and strings, not pointers, so a
/// definition exports the INDEX of what it made and the reader looks it
/// up - exactly as `providerplugin` exports an index into
/// `provider.Building.made`. A closed vault nulls its slot, so `vaultof`
/// on a torn-down chain refuses rather than following a dangling pointer,
/// and the next vault reuses the slot rather than growing the list.
///
/// MODULE-GLOBAL, for the reason `provider.building` is: a lifecycle
/// callback is a bare function pointer with no context. One thread, as
/// that comment also says.
var VAULTS: std.ArrayList(?*Vault) = .empty;

fn hold(alloc: Allocator, vault: *Vault) Allocator.Error!usize {
    for (VAULTS.items, 0..) |slot, at| {
        if (null == slot) {
            VAULTS.items[at] = vault;
            return at;
        }
    }
    try VAULTS.append(alloc, vault);
    return VAULTS.items.len - 1;
}

/// Opens a vault file as one key.
///
/// The handle is lazy. Nothing is read, and no passphrase is stretched,
/// until a method needs the file - so a chain of ten providers costs ten
/// objects rather than ten PBKDF2 runs.
pub fn openvault(alloc: Allocator, io: std.Io, options: Options) Allocator.Error!Answer(*Vault) {
    if (0 == options.file.len) {
        return .{ .err = try fail(alloc, "a vault needs a file", .{}) };
    }
    if (0 == options.passphrase.len) {
        return .{ .err = try fail(alloc, "a vault needs a passphrase", .{}) };
    }

    const key = if (0 != options.key.len) options.key else MASTERKEY;

    switch (try checkid(alloc, key, "a vault needs a key id")) {
        .err => |message| return .{ .err = message },
        .ok => {},
    }

    const vault = try alloc.create(Vault);
    errdefer alloc.destroy(vault);

    vault.* = .{
        .alloc = alloc,
        .io = io,
        .file = try alloc.dupe(u8, options.file),
        .key = try alloc.dupe(u8, key),
        .passphrase = try alloc.dupe(u8, options.passphrase),
        .iterations = if (0 < options.iterations) options.iterations else ITERATIONS,
        .create = options.create,
        .slot = 0,
        .state = std.heap.ArenaAllocator.init(alloc),
    };
    vault.slot = try hold(alloc, vault);

    return .{ .ok = vault };
}

/// Makes a vault file and returns a handle on its master key.
///
/// Refuses a file that is already there: a vault is created once, and
/// overwriting one discards every secret in it along with every key that
/// could read them.
pub fn createvault(alloc: Allocator, io: std.Io, options: Options) Allocator.Error!Answer(*Vault) {
    const vault = switch (try openvault(alloc, io, options)) {
        .err => |message| return .{ .err = message },
        .ok => |made| made,
    };

    var work = std.heap.ArenaAllocator.init(alloc);
    defer work.deinit();
    const scratch = work.allocator();

    // No stat first: the check and the write would be two steps, and
    // `putnew` refuses an existing file in ONE, which is what makes two
    // processes racing to create a vault leave one vault.
    const fresh = switch (try vault.newvault(scratch, alloc, vault.key, vault.passphrase, vault.iterations)) {
        .err => |message| {
            vault.deinit();
            return .{ .err = message };
        },
        .ok => |made| made,
    };

    switch (try vault.putnew(scratch, alloc, &fresh)) {
        .err => |message| {
            vault.deinit();
            return .{ .err = message };
        },
        .ok => {},
    }

    return .{ .ok = vault };
}

// --- the provider -----------------------------------------------------

/// Reads a vault as one store in a chain.
///
/// The provider is the READ half and nothing more: a chain resolves
/// secrets, and writing one is a deliberate act with an API of its own.
/// That API is the same handle, reached with `vaultof` off a chain or
/// built directly with `openvault`.
pub const MiniVaultProvider = struct {
    vault: *Vault,

    pub fn lookup(self: *MiniVaultProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        return self.vault.get(alloc, name);
    }

    pub fn describe(self: *MiniVaultProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "minivault:{s}", .{self.vault.vaultfile()});
    }

    pub fn deinit(self: *MiniVaultProvider, _: Allocator) void {
        self.vault.deinit();
    }
};

/// The export key the vault API is published under, beside the `provider`
/// key every kind publishes.
pub const VAULT_EXPORT = "vault";

/// The `minivault` provider kind, as a voxgig/plugin definition.
///
/// Written out rather than built by `sekreto.providerplugin`, because
/// this definition publishes TWO exports: `provider`, the read half every
/// kind publishes, and `vault`, the programmatic API. voxgig/plugin's
/// exports are how a definition offers an application more than the
/// host's own vocabulary, and a store that can only be read is half a
/// vault.
///
/// The `sekreto_error` wrapping is what `providerplugin` would have done:
/// plugin wraps a code-less error raised in `define` as
/// `plugin_define_failed`, and keeps one that already carries a code, so
/// a refusal of this provider's own configuration travels under
/// `sekreto_error` and comes back out of the host as itself.
pub const minivault: sekreto.Definition = .{ .name = "minivault", .define = define };

fn define(inst: *sekreto.provider.Inst) pt.Err!void {
    const b = sekreto.provider.building orelse {
        return pt.fail("plugin_bad_state", "sekreto: a provider was built outside Sekreto.init", null);
    };

    const spec = sekreto.provider.specof(inst.options);

    // Configuration is refused HERE, so a mistyped chain fails at
    // construction. Reaching the file is not configuration: the handle is
    // lazy, and nothing is read or stretched until a lookup.
    const vault = switch (openvault(b.alloc, b.config.io, .{
        .file = spec.file,
        .key = spec.vaultkey,
        .passphrase = spec.passphrase,
        .iterations = if (0 < spec.iterations) @intCast(spec.iterations) else 0,
        .create = spec.create,
    }) catch {
        b.oom = true;
        return pt.fail(sekreto.ERROR_CODE, "sekreto: out of memory", null);
    }) {
        .err => |message| {
            defer b.alloc.free(message);
            const details = pv.vmap();
            pv.set(details, "ref", pv.vstr(inst.ref));
            pv.set(details, "cause", pv.vstr(pv.dupe(message)));
            return pt.fail(sekreto.ERROR_CODE, message, details);
        },
        .ok => |made| made,
    };

    const made = sekreto.provide(b.alloc, MiniVaultProvider, .{ .vault = vault }) catch {
        vault.deinit();
        b.oom = true;
        return pt.fail(sekreto.ERROR_CODE, "sekreto: out of memory", null);
    };

    b.made.append(b.alloc, made) catch {
        made.deinit(b.alloc);
        b.oom = true;
        return pt.fail(sekreto.ERROR_CODE, "sekreto: out of memory", null);
    };

    plugin.host.exportvalue(inst, sekreto.PROVIDER_EXPORT, pv.vnum(@floatFromInt(b.made.items.len - 1)));
    plugin.host.exportvalue(inst, VAULT_EXPORT, pv.vnum(@floatFromInt(vault.slot)));
}

/// The vault behind a store in a chain, as its programmatic API.
///
/// `secrets.host` is the voxgig/plugin host the chain is made of, and a
/// definition's exports are readable off it by ref. This is the one call
/// that turns a store into an API, and it lives here rather than on
/// `Sekreto` because the core knows no plugin.
///
/// With no store named, the unqualified alias answers: one vault in the
/// chain resolves whatever it is called, and two raise rather than
/// picking one.
pub fn vaultof(
    alloc: Allocator,
    secrets: *sekreto.Sekreto,
    store: []const u8,
) Allocator.Error!Answer(*Vault) {
    if (0 == store.len) {
        const found = plugin.host.exports(secrets.host, "minivault/" ++ VAULT_EXPORT) catch {
            _ = pt.take();
            return .{ .err = try fail(alloc, "no minivault store in this chain", .{}) };
        };
        return slotof(alloc, found, "no minivault store in this chain");
    }

    // A NAMED STORE MUST EXIST, and the alias must not stand in for it.
    // `host.exports` falls back to the alias when the exact ref misses, so
    // asking for `minivault` in a chain whose only vault is named `app`
    // used to hand back the `app` vault - and then write to it. Naming a
    // store that is not there raises, which is the rule the whole library
    // follows: `tryget` already means "may not have it", so it cannot also
    // mean "may not exist".
    const ref = if (std.mem.eql(u8, "minivault", store))
        "minivault"
    else
        try std.fmt.allocPrint(alloc, "minivault${s}", .{store});

    const missing = try fail(alloc, "no minivault store named {s} in this chain", .{store});

    const live = plugin.host.instance(secrets.host, ref) catch {
        _ = pt.take();
        return .{ .err = missing };
    };
    if (null == live) {
        return .{ .err = missing };
    }

    const key = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ ref, VAULT_EXPORT });
    const found = plugin.host.exports(secrets.host, key) catch {
        _ = pt.take();
        return .{ .err = missing };
    };

    return slotof(alloc, found, missing);
}

fn slotof(alloc: Allocator, found: ?*pv.Value, missing: []const u8) Allocator.Error!Answer(*Vault) {
    if (!pv.isNum(found)) {
        return .{ .err = try alloc.dupe(u8, missing) };
    }

    const at: usize = @intFromFloat(pv.asNum(found));
    if (VAULTS.items.len <= at) {
        return .{ .err = try alloc.dupe(u8, missing) };
    }

    const vault = VAULTS.items[at] orelse {
        // The chain was torn down; the slot is free and may already hold
        // somebody else's vault. Refusing is the only safe answer.
        return .{ .err = try alloc.dupe(u8, missing) };
    };

    return .{ .ok = vault };
}
