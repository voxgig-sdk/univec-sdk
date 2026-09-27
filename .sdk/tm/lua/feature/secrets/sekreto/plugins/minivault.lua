-- VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (lua/src/sekreto/plugins/minivault.lua)
-- Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- A mini vault: every secret a project owns, encrypted, in ONE FILE.
--
-- The store to reach for before there is a vault server. There is
-- nothing to run and nothing to reach over a socket - the whole store is
-- a single binary file - and the same chain that reads it in development
-- reads HashiCorp or AWS in production by changing config, which is the
-- reason sekreto exists.
--
-- A PLUGIN, not a built-in: this kind needs crypto, which is the line the
-- four built-in kinds stay behind. Lua 5.4's standard library has no
-- cryptography at all and the no-new-package rule stands, so the four
-- primitives come from the OpenSSL this port already links, through
-- `native/sekretovault.c` - a LOADABLE MODULE rather than a child
-- process, for the reason its header gives: a vault `list` over a hundred
-- secrets is a hundred AEAD opens, and a hundred spawns is not a store
-- anybody would use.
--
-- THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
-- every name and mints restricted keys. A restricted key reads the names
-- it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
-- cryptography rather than a check this code performs, so a copy of the
-- file plus a restricted passphrase yields exactly what was granted and
-- nothing else. What that does and does not protect is set out in DOCS.md
-- under "What the mini vault protects".
--
-- THE FILE FORMAT, which is the contract between the ports:
--
--   magic       4   'SKMV'
--   version     1   FORMAT
--   kdf         1   1 = PBKDF2-HMAC-SHA256
--   cipher      1   1 = AES-256-GCM
--   reserved    1   0
--   keycount    4   uint32
--   per key:
--     id        1 + bytes      the key id, PLAINTEXT
--     salt      1 + bytes
--     iters     4              PBKDF2 rounds for this key
--     ring      1 + iv, 4 + bytes    sealed under the passphrase
--     meta      1 + iv, 4 + bytes    sealed under the vault's meta key
--   entrycount  4   uint32
--   per entry:
--     id        1 + bytes      the blinded lookup id
--     name      1 + iv, 4 + bytes    sealed under the vault's name key
--     value     1 + iv, 4 + bytes    sealed under that secret's own key
--
-- Integers are big-endian and every length precedes its bytes, so the
-- file is written with the same two primitives it is read with.
--
-- NOTHING OUTSIDE A KEY RECORD IS PLAINTEXT. Secret names are sealed, and
-- an entry is addressed by a blinded id derived from its own key, so a
-- restricted key finds what it was granted without the file ever naming
-- the rest. What the file does show anyone is the key ids and how many
-- secrets there are.
--
-- A port of typescript/plugins/minivault.ts, which is canonical. The
-- bytes are pinned by the vaults in test/fixture rather than left to
-- agreement between implementations.

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')
local providers = require('feature.secrets.sekreto.providers')
local json = require('feature.secrets.sekreto.plugins.json')

local fail = err.fail
local checkname = name.checkname

local M = {}

-- ------------------------------------------------------- the primitives

--- Where the crypto module is, worked out from THIS FILE'S OWN PATH
--- rather than from the working directory or `package.cpath`: the CLI is
--- run from an empty directory with the environment wiped, exactly as
--- `net.lua` finds the transport helper.
local function vaultlib()
  local source = debug.getinfo(1, 'S').source

  if '@' == source:sub(1, 1) then
    local dir = source:sub(2):match('^(.*)/feature/secrets/sekreto/plugins/minivault%.lua$')
    if nil ~= dir then
      return dir .. '/feature/secrets/native/sekretovault.so'
    end
  end

  return 'feature/secrets/native/sekretovault.so'
end

M.VAULTLIB = vaultlib()

--- Loaded on first use, not at require time: a consumer that requires
--- this module and never builds a chain must not be stopped by a missing
--- `.so`, and the refusal when there IS one names what to build.
local loaded = nil

local function native()
  if nil ~= loaded then
    return loaded
  end

  local open = package.loadlib(M.VAULTLIB, 'luaopen_sekretovault')
  if nil == open then
    fail('sekreto: minivault: the vault crypto module is missing (is '
      .. M.VAULTLIB .. ' built?)')
  end

  loaded = open()

  return loaded
end

-- ------------------------------------------------------------ the format

local MAGIC = 'SKMV'
local FORMAT = 1
local KDF_PBKDF2 = 1
local CIPHER_AESGCM = 1

--- AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
local KEYLEN = 32
local IVLEN = 12
local TAGLEN = 16
local SALTLEN = 16

--- The PBKDF2-HMAC-SHA256 round count when a caller names none.
M.ITERATIONS = 210000

--- The key id a vault gets when a caller names none.
M.MASTERKEY = 'master'

--- The export key the vault API is published under, beside the `provider`
--- key every kind publishes.
M.VAULT_EXPORT = 'vault'

-- Additional authenticated data. Every blob is bound to its PLACE in the
-- file, so no ciphertext can be moved: a restricted key's ring cannot be
-- relabelled as the master's, and one secret's value cannot be served
-- under a name it was never written for.
local AAD_RING = 'skmv1:ring:'
local AAD_META = 'skmv1:meta:'
local AAD_NAME = 'skmv1:name'
local AAD_SECRET = 'skmv1:secret:'

-- Everything a master reaches is derived from the root key, so rotating
-- is one new random value rather than a re-wrap of each part.
local LABEL_NAMES = 'skmv1:names'
local LABEL_META = 'skmv1:meta'
local LABEL_ID = 'skmv1:id'

--- The largest key id the format can record.
---
--- A length is written in ONE byte. A longer id wrapped that byte and the
--- writer then appended the whole thing, so every field after it shifted:
--- a grant with a 300-character id replaced a working vault with an
--- unreadable one, and said nothing. Checked where an id is ACCEPTED, so
--- the refusal names the id rather than the file.
local IDMAX = 255

local function mvfail(why)
  fail('sekreto: minivault: ' .. why)
end

local function checkid(id, what)
  if nil == id or '' == id then
    mvfail(what)
  end
  if IDMAX < #id then
    mvfail('key id is longer than ' .. IDMAX .. ' bytes: ' .. id:sub(1, 32) .. '...')
  end
  return id
end

-- ---------------------------------------------------------------- keys

local function mac(key, text)
  return native().hmac(key, text)
end

--- The key-encryption key a passphrase unwraps a ring with.
---
--- A round count below one is refused in the module, which is what a
--- damaged or hostile file records to make the derivation free.
local function kek(passphrase, salt, iters)
  local ok, got = pcall(function() return native().pbkdf2(passphrase, salt, iters) end)
  if not ok then
    mvfail('unusable round count: ' .. tostring(iters))
  end
  return got
end

--- The key one named secret's value is encrypted with.
---
--- DERIVED, never stored, for a master: it holds the root key and so
--- reaches every name, including ones written after it was made. A
--- restricted key holds the derived keys it was granted and nothing that
--- produces another, so every other name is ciphertext to it in exactly
--- the way it is to a stranger.
local function secretkey(root, secret)
  return mac(root, AAD_SECRET .. secret)
end

--- Where a secret lives in the file, derived from its own key so that
--- finding it needs no plaintext name. One-way: an id yields nothing
--- about the key that produced it.
local function entryid(key)
  return mac(key, LABEL_ID)
end

local function random(len)
  local ok, got = pcall(function() return native().random(len) end)
  if not ok then
    mvfail('no randomness available')
  end
  return got
end

-- -------------------------------------------------------------- sealing

--- The tag rides at the END of the blob, which is where every other
--- port's AEAD leaves it and therefore what the format records.
local function seal(key, plain, aad)
  if KEYLEN ~= #key then
    mvfail('bad key')
  end

  local iv = random(IVLEN)
  local ok, blob = pcall(function() return native().seal(key, iv, plain, aad) end)

  if not ok then
    mvfail('cannot seal')
  end

  return { iv = iv, blob = blob }
end

--- The plaintext, or a refusal. A GCM tag that fails to verify is the
--- only evidence there is, and it cannot tell a wrong passphrase from a
--- damaged file, so `what` names the attempt and the message admits both.
local function unseal(key, box, aad, what)
  if TAGLEN > #box.blob or IVLEN ~= #box.iv then
    mvfail(what .. ': truncated')
  end
  if KEYLEN ~= #key then
    mvfail('bad key')
  end

  local ok, plain = pcall(function() return native().unseal(key, box.iv, box.blob, aad) end)

  if not ok or nil == plain then
    mvfail(what)
  end

  return plain
end

local function sameseal(left, right)
  return left.iv == right.iv and left.blob == right.blob
end

-- --------------------------------------------------------------- base64

-- Here rather than in `support.lua`, which the HTTP stores share:
-- requiring that module would load the transport and the TLS binding
-- behind it into a program whose only store opens nothing, which is the
-- cost the core/plugin split exists to remove.
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function b64(raw)
  local out = {}

  for at = 1, #raw, 3 do
    local left = #raw - at + 1
    local a = raw:byte(at)
    local b = 1 < left and raw:byte(at + 1) or 0
    local c = 2 < left and raw:byte(at + 2) or 0
    local triple = a * 65536 + b * 256 + c

    out[#out + 1] = B64:sub((triple >> 18 & 0x3f) + 1, (triple >> 18 & 0x3f) + 1)
    out[#out + 1] = B64:sub((triple >> 12 & 0x3f) + 1, (triple >> 12 & 0x3f) + 1)
    out[#out + 1] = 1 < left and B64:sub((triple >> 6 & 0x3f) + 1, (triple >> 6 & 0x3f) + 1) or '='
    out[#out + 1] = 2 < left and B64:sub((triple & 0x3f) + 1, (triple & 0x3f) + 1) or '='
  end

  return table.concat(out)
end

--- STRICT. A lenient decoder hands back plausible bytes for a corrupted
--- payload, and those bytes are then used AS A KEY.
local function unb64(text, what)
  if 'string' ~= type(text) or '' == text or 0 ~= #text % 4 then
    mvfail('missing ' .. what)
  end

  local body, pad = text:match('^([^=]*)(=*)$')
  if nil == body or 2 < #pad then
    mvfail('missing ' .. what)
  end

  local out = {}
  local held = 0
  local bits = 0

  for at = 1, #body do
    local sextet = B64:find(body:sub(at, at), 1, true)
    if nil == sextet then
      mvfail('missing ' .. what)
    end

    held = (held << 6) | (sextet - 1)
    bits = bits + 6

    if 8 <= bits then
      bits = bits - 8
      out[#out + 1] = string.char(held >> bits & 0xff)
    end
  end

  return table.concat(out)
end

-- ------------------------------------------------------------- the file

--- A cursor, so that every length check is in one place: a truncated
--- vault is refused rather than read as a short one.
local Reader = {}
Reader.__index = Reader

local function reader(raw)
  return setmetatable({ raw = raw, at = 1 }, Reader)
end

--- Reads `len` bytes, or refuses.
---
--- The bound is checked AGAINST WHAT IS LEFT, never by adding the length
--- to the cursor. Lua's integers are 64-bit so the sum cannot wrap here,
--- but the check reads the same in every port and is the one that is
--- right everywhere.
function Reader:take(len)
  if 0 > len or #self.raw - self.at + 1 < len then
    mvfail('the vault file is truncated')
  end

  local out = self.raw:sub(self.at, self.at + len - 1)
  self.at = self.at + len

  return out
end

function Reader:u8()
  return self:take(1):byte(1)
end

function Reader:u32()
  local four = self:take(4)
  return four:byte(1) * 16777216 + four:byte(2) * 65536 + four:byte(3) * 256 + four:byte(4)
end

function Reader:small()
  return self:take(self:u8())
end

function Reader:large()
  return self:take(self:u32())
end

function Reader:sealed()
  -- The iv is read before the blob, and the two statements keep that
  -- order; a table constructor would not, because Lua leaves the order
  -- its fields are evaluated in unspecified.
  local iv = self:small()
  return { iv = iv, blob = self:large() }
end

function Reader:left()
  return #self.raw - self.at + 1
end

local function readfile(raw)
  local read = reader(raw)

  if MAGIC ~= read:take(4) then
    mvfail('not a vault file')
  end

  local version = read:u8()
  if FORMAT ~= version then
    mvfail('unsupported format version: ' .. version)
  end

  local kdf = read:u8()
  local cipher = read:u8()
  if KDF_PBKDF2 ~= kdf or CIPHER_AESGCM ~= cipher then
    mvfail('unsupported kdf or cipher: ' .. kdf .. '/' .. cipher)
  end
  read:u8()

  local file = { keys = {}, entries = {} }

  -- A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a
  -- few bytes, so a file claiming four billion of them is damaged; the
  -- loop would find that out one truncation at a time.
  local keycount = read:u32()
  if read:left() < keycount then
    mvfail('the vault file is truncated')
  end
  for _ = 1, keycount do
    local id = read:small()
    local salt = read:small()
    local iters = read:u32()
    local ring = read:sealed()
    file.keys[#file.keys + 1] =
      { id = id, salt = salt, iters = iters, ring = ring, meta = read:sealed() }
  end

  local entrycount = read:u32()
  if read:left() < entrycount then
    mvfail('the vault file is truncated')
  end
  for _ = 1, entrycount do
    local id = read:small()
    local secretname = read:sealed()
    file.entries[#file.entries + 1] =
      { id = id, name = secretname, value = read:sealed() }
  end

  if read.at ~= #raw + 1 then
    mvfail('the vault file has trailing bytes')
  end

  return file
end

local function keyof(file, id)
  for _, record in ipairs(file.keys) do
    if id == record.id then
      return record
    end
  end
  return nil
end

local function entryof(file, id)
  for _, record in ipairs(file.entries) do
    if id == record.id then
      return record
    end
  end
  return nil
end

local function putu32(value)
  return string.char(value >> 24 & 0xff, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff)
end

local function putsmall(value)
  return string.char(#value & 0xff) .. value
end

local function putlarge(value)
  return putu32(#value) .. value
end

local function putsealed(box)
  return putsmall(box.iv) .. putlarge(box.blob)
end

local function writefile(file)
  local out = { MAGIC, string.char(FORMAT, KDF_PBKDF2, CIPHER_AESGCM, 0) }

  out[#out + 1] = putu32(#file.keys)
  for _, record in ipairs(file.keys) do
    out[#out + 1] = putsmall(record.id)
    out[#out + 1] = putsmall(record.salt)
    out[#out + 1] = putu32(record.iters)
    out[#out + 1] = putsealed(record.ring)
    out[#out + 1] = putsealed(record.meta)
  end

  -- SORTED BY ID, which is a blinded value: the file therefore records
  -- nothing about the order secrets were written in.
  local entries = {}
  for at, record in ipairs(file.entries) do
    entries[at] = record
  end
  table.sort(entries, function(left, right) return left.id < right.id end)

  out[#out + 1] = putu32(#entries)
  for _, record in ipairs(entries) do
    out[#out + 1] = putsmall(record.id)
    out[#out + 1] = putsealed(record.name)
    out[#out + 1] = putsealed(record.value)
  end

  return table.concat(out)
end

-- ----------------------------------------------------- the file on disk

--- Read as BINARY, byte for byte: a vault is full of NULs and of bytes no
--- encoding claims.
local function slurp(path)
  local handle = io.open(path, 'rb')
  if nil == handle then
    return nil
  end

  local raw = handle:read('a')
  handle:close()

  return raw
end

--- Owner-only, because a vault file is the whole store.
---
--- LUA CANNOT ASK FOR AN EXCLUSIVE CREATE, and it cannot chmod: `io.open`
--- has `w` and nothing else, and the mode is the process umask's to
--- decide. So the two guarantees the other ports get from `O_EXCL | 0600`
--- are arranged differently here: `putnew` looks first and refuses a file
--- that is there - a check-then-write that two processes could both pass,
--- which is stated rather than hidden - and the file is created under the
--- umask a service normally runs with. A deployment that needs 0600 on a
--- shared host sets its umask, and the port says so rather than implying
--- a protection it cannot give.
local function spill(path, raw)
  local handle = io.open(path, 'wb')
  if nil == handle then
    mvfail('cannot write ' .. path)
  end

  local ok = handle:write(raw)
  handle:close()

  if not ok then
    os.remove(path)
    mvfail('cannot write ' .. path)
  end
end

local function hex(raw)
  local out = {}
  for at = 1, #raw do
    out[at] = string.format('%02x', raw:byte(at))
  end
  return table.concat(out)
end

-- ------------------------------------------------------------ the vault

-- A MASTER'S ring holds the root and no grants; a RESTRICTED key's holds
-- grants and no root, even when it was granted nothing. That asymmetry is
-- the format rather than a saving: a ring with a root reaches every name
-- there will ever be, so a grant list beside it would be a second answer
-- to the same question.
local function masterring(root)
  return json.stringify(json.obj({
    { 'v', FORMAT },
    { 'write', true },
    { 'root', b64(root) },
  }))
end

local function grantring(write, grants)
  local held = {}
  for _, pair in ipairs(grants) do
    held[#held + 1] = { pair[1], b64(pair[2]) }
  end

  return json.stringify(json.obj({
    { 'v', FORMAT },
    { 'write', write },
    { 'grants', json.obj(held) },
  }))
end

local function metaof(master, write, names)
  return json.stringify(json.obj({
    { 'v', FORMAT },
    { 'master', master },
    { 'write', write },
    -- An ARRAY here and an OBJECT in the ring, which is the format and
    -- not an accident: the ring holds a key per name, and the record
    -- holds only the names.
    { 'grants', json.arr(names) },
  }))
end

local function sealkey(root, id, passphrase, iters, ring, meta)
  local salt = random(SALTLEN)

  return {
    id = id,
    salt = salt,
    iters = iters,
    ring = seal(kek(passphrase, salt, iters), ring, AAD_RING .. id),
    meta = seal(mac(root, LABEL_META), meta, AAD_META .. id),
  }
end

--- The one key record a new or rotated vault starts with: a master
--- holding the root, granted nothing because it needs nothing.
local function masterrecord(root, id, passphrase, iters)
  return sealkey(root, id, passphrase, iters, masterring(root), metaof(true, true, {}))
end

local function newvault(id, passphrase, iters)
  return { keys = { masterrecord(random(KEYLEN), id, passphrase, iters) }, entries = {} }
end

--- Writes a vault file that is not there yet, and REFUSES one that is.
---
--- A LOOK AND THEN A WRITE, which is two steps: see `spill` for why this
--- port cannot make it one. Two processes racing to create the same vault
--- can therefore both pass the look, and the second overwrites the first;
--- every other port refuses that in one syscall.
local function putnew(path, made)
  if nil ~= slurp(path) then
    mvfail('vault file already exists: ' .. path)
  end

  spill(path, writefile(made))
end

--- A handle on one vault file, opened as ONE key.
---
--- Every method answers as that key: `list` shows the names it may read,
--- `get` answers for those and misses on the rest, and the master-only
--- methods refuse for any other key. Nothing is read or derived until the
--- first call that needs the file, so putting a vault in a chain costs no
--- key derivation until a secret is actually wanted.
local Vault = {}
Vault.__index = Vault

function Vault:file()
  return self.path
end

function Vault:key()
  return self.keyid
end

--- Forget the derived keys. The next call opens again.
function Vault:close()
  self.opened = nil
end

--- Replaces the file rather than editing it in place. The rename is what
--- makes a concurrent reader see either the old file or the new one, so a
--- write interrupted halfway leaves a vault rather than wreckage.
---
--- THE TEMPORARY IS RANDOM, though it cannot be exclusive here: see
--- `spill`. `<vault>.<pid>.tmp` is a name anyone can predict, and the
--- random suffix is what stops that and what stops two writers colliding.
function Vault:save(made)
  local temp = self.path .. '.' .. hex(random(8)) .. '.tmp'

  spill(temp, writefile(made))

  local ok = os.rename(temp, self.path)
  if not ok then
    -- The vault is unchanged either way, and the write error is what the
    -- caller needs to be told about.
    os.remove(temp)
    mvfail('cannot write ' .. self.path)
  end
end

function Vault:bytes()
  local raw = slurp(self.path)
  if nil ~= raw then
    return raw
  end

  -- A vault is configured deliberately, with a key. Its absence is a
  -- broken deployment and never "no secrets here": answering a miss would
  -- send the chain on to a weaker store, which is the failure mode this
  -- library most has to avoid. `create` is the caller saying the
  -- opposite, in writing.
  if not self.create then
    mvfail('no vault file: ' .. self.path)
  end

  putnew(self.path, newvault(self.keyid, self.passphrase, self.iterations))

  raw = slurp(self.path)
  if nil == raw then
    mvfail('cannot read ' .. self.path)
  end

  return raw
end

local function jsontrue(held, key)
  return true == json.dig(held, key)
end

--- The file as this key sees it: parsed every call - it is different
--- bytes every time - while the unwrapped ring is kept, because
--- stretching a passphrase once per lookup is the cost that caching
--- exists to avoid.
function Vault:load()
  local file = readfile(self:bytes())
  local record = keyof(file, self.keyid)

  if nil == record then
    -- REVOKED, or never there. Either way this handle is finished, and
    -- dropping what it derived is what stops the next call answering from
    -- memory.
    self:close()
    mvfail('no such key: ' .. self.keyid)
  end

  -- The file still holds this key, and holds the SAME ring: a key revoked
  -- and re-granted under another passphrase is a different key wearing
  -- the id, and re-deriving is what refuses it.
  if nil ~= self.opened and sameseal(self.opened.ring, record.ring) then
    return file
  end
  self:close()

  local plain = unseal(
    kek(self.passphrase, record.salt, record.iters),
    record.ring,
    AAD_RING .. self.keyid,
    'wrong passphrase for key ' .. self.keyid .. ', or a damaged vault')

  local held = json.parse(plain)
  if not json.isobj(held) then
    mvfail('unreadable key ring for ' .. self.keyid)
  end

  local grants = {}
  local names = {}

  local listed = json.dig(held, 'grants')
  if json.isobj(listed) then
    for _, key in ipairs(listed.keys) do
      local text = json.asstr(listed.vals[key])
      if nil == text then
        mvfail('missing a granted key')
      end
      grants[key] = unb64(text, 'a granted key')
      names[#names + 1] = key
    end
  end
  table.sort(names)

  local root = json.asstr(json.dig(held, 'root'))
  if nil ~= root then
    root = unb64(root, 'the root key')
  end

  self.opened = {
    root = root,
    grants = grants,
    names = names,
    write = nil ~= root or jsontrue(held, 'write'),
    ring = record.ring,
  }

  return file
end

--- The root key, or a refusal naming what needed it.
function Vault:rootof(what)
  if nil == self.opened.root then
    mvfail(what .. ' needs a master key, and ' .. self.keyid .. ' is restricted')
  end
  return self.opened.root
end

--- The key for one name, or nil when this key cannot reach it.
function Vault:keyfor(secret)
  if nil ~= self.opened.root then
    return secretkey(self.opened.root, secret)
  end
  return self.opened.grants[secret]
end

--- Derive the key and read the file NOW rather than at first use.
---
--- A COPY, built fresh. `set` asks this whether the key may write, and
--- handing back the table that answer lives in let a caller flip its own
--- permission: `local info = v:open(); info.write = true` turned a
--- read-only key into a writing one. Authorization state does not leave
--- this object.
function Vault:open()
  self:load()

  local grants = {}
  for at, held in ipairs(self.opened.names) do
    grants[at] = held
  end

  return {
    key = self.keyid,
    master = nil ~= self.opened.root,
    write = self.opened.write,
    grants = grants,
  }
end

--- The names this key can read, sorted.
function Vault:list()
  local file = self:load()
  local names = {}

  if nil ~= self.opened.root then
    local namekey = mac(self.opened.root, LABEL_NAMES)
    for _, entry in ipairs(file.entries) do
      names[#names + 1] = unseal(namekey, entry.name, AAD_NAME, 'a secret name is damaged')
    end
  else
    -- A restricted key has no name key, so it reports the grants it can
    -- actually find: the vault never tells it what else is there.
    for _, held in ipairs(self.opened.names) do
      if nil ~= entryof(file, entryid(self.opened.grants[held])) then
        names[#names + 1] = held
      end
    end
  end

  table.sort(names)

  return names
end

--- The value, or nil for a MISS. A name the vault does not hold and a
--- name this key was not granted are both a miss.
function Vault:get(secret)
  checkname(secret)

  local file = self:load()

  -- OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as the
  -- key that opened it, so a name this key cannot read is a name this
  -- store does not hold for this caller - the same answer a stranger's
  -- vault gives, and the one that makes a restricted key in front of a
  -- broader store a workable chain.
  local key = self:keyfor(secret)
  if nil == key then
    return nil
  end

  local entry = entryof(file, entryid(key))
  if nil == entry then
    return nil
  end

  return unseal(key, entry.value, AAD_SECRET .. secret,
    'the value of ' .. secret .. ' is damaged')
end

function Vault:has(secret)
  return nil ~= self:get(secret)
end

--- Write a value. A master writes any name; a restricted key holding
--- `write` overwrites the names it was granted, and creates none.
function Vault:set(secret, value)
  checkname(secret)

  local file = self:load()

  if not self.opened.write then
    mvfail('key ' .. self.keyid .. ' is read-only')
  end

  local key = self:keyfor(secret)
  if nil == key then
    mvfail('key ' .. self.keyid .. ' was not granted ' .. secret)
  end

  local box = seal(key, value, AAD_SECRET .. secret)
  local id = entryid(key)
  local entry = entryof(file, id)

  if nil ~= entry then
    entry.value = box
  else
    -- A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
    -- restricted key with `write` updates what it was granted and cannot
    -- grow the vault, which is what "restricted" has to mean for the
    -- grant list to stay the whole story.
    local root = self:rootof('creating the secret ' .. secret)
    file.entries[#file.entries + 1] = {
      id = id,
      name = seal(mac(root, LABEL_NAMES), secret, AAD_NAME),
      value = box,
    }
  end

  self:save(file)
end

--- Drop a name. Master only.
function Vault:remove(secret)
  checkname(secret)

  local file = self:load()
  local root = self:rootof('removing a secret')
  local want = entryid(secretkey(root, secret))

  local kept = {}
  local found = false

  for _, entry in ipairs(file.entries) do
    if not found and want == entry.id then
      found = true
    else
      kept[#kept + 1] = entry
    end
  end

  if not found then
    mvfail('no such secret: ' .. secret)
  end

  file.entries = kept

  self:save(file)
end

--- Every key in the file, with what it may do. Master only.
function Vault:keys()
  local file = self:load()
  local metakey = mac(self:rootof('listing the keys'), LABEL_META)
  local out = {}

  for _, record in ipairs(file.keys) do
    local info = { key = record.id, master = false, write = false, grants = {} }

    -- A record written under a root key this one has replaced is still in
    -- the file and still opens with its own passphrase, so it is reported
    -- rather than hidden - with what it can do unknown.
    local ok, plain = pcall(function()
      return unseal(metakey, record.meta, AAD_META .. record.id, 'metadata')
    end)

    if ok then
      local noted = json.parse(plain)
      if not json.isobj(noted) then
        mvfail('unreadable metadata for key ' .. record.id)
      end

      info.master = jsontrue(noted, 'master')
      info.write = jsontrue(noted, 'write')

      local listed = json.dig(noted, 'grants')
      if json.isarr(listed) then
        for _, held in ipairs(listed.items) do
          if 'string' == type(held) then
            info.grants[#info.grants + 1] = held
          end
        end
      end
      table.sort(info.grants)
    end

    out[#out + 1] = info
  end

  return out
end

--- Mint a restricted key. Master only.
function Vault:grant(spec)
  local file = self:load()
  local root = self:rootof('granting a key')
  local want = spec or {}

  checkid(want.key, 'a grant needs a key id')
  if nil == want.passphrase or '' == want.passphrase then
    mvfail('a grant needs a passphrase')
  end
  if nil ~= keyof(file, want.key) then
    mvfail('key already exists: ' .. want.key)
  end

  local names = {}
  for at, held in ipairs(want.names or {}) do
    names[at] = held
  end
  table.sort(names)

  local grants = {}
  for at, held in ipairs(names) do
    checkname(held)
    grants[at] = { held, secretkey(root, held) }
  end

  local record = sealkey(root, want.key, want.passphrase,
    (nil ~= want.iterations and 0 < want.iterations) and want.iterations or self.iterations,
    grantring(true == want.write, grants),
    metaof(false, true == want.write, names))

  file.keys[#file.keys + 1] = record

  self:save(file)
end

--- Drop a key. Master only.
---
--- Anyone who already copied the file keeps whatever that key could read,
--- so revoking bars future reads of the LIVE file and `rotate` is what
--- takes a secret back.
function Vault:revoke(id)
  local file = self:load()
  self:rootof('revoking a key')

  if id == self.keyid then
    mvfail('a key cannot revoke itself: ' .. id)
  end
  if nil == keyof(file, id) then
    mvfail('no such key: ' .. tostring(id))
  end

  local kept = {}
  for _, record in ipairs(file.keys) do
    if id ~= record.id then
      kept[#kept + 1] = record
    end
  end
  file.keys = kept

  self:save(file)
end

--- Take a new root key, re-encrypt every value under it, and DROP EVERY
--- OTHER KEY. Master only.
---
--- The other keys go because they must: their rings are sealed under
--- passphrases this process does not have, so there is no way to hand
--- them keys they can unwrap. Re-grant afterwards.
function Vault:rotate()
  local file = self:load()
  local oldroot = self:rootof('rotating the vault')
  local iters = keyof(file, self.keyid).iters

  -- Read everything out under the old root before anything changes: once
  -- the root is replaced the old derived keys are unreachable.
  local oldnamekey = mac(oldroot, LABEL_NAMES)
  local held = {}

  for _, entry in ipairs(file.entries) do
    local secret = unseal(oldnamekey, entry.name, AAD_NAME, 'a secret name is damaged')
    held[#held + 1] = {
      secret,
      unseal(secretkey(oldroot, secret), entry.value, AAD_SECRET .. secret,
        'the value of ' .. secret .. ' is damaged'),
    }
  end

  local root = random(KEYLEN)
  local namekey = mac(root, LABEL_NAMES)
  local entries = {}

  for at, pair in ipairs(held) do
    local key = secretkey(root, pair[1])
    entries[at] = {
      id = entryid(key),
      name = seal(namekey, pair[1], AAD_NAME),
      value = seal(key, pair[2], AAD_SECRET .. pair[1]),
    }
  end

  -- SAVE FIRST, adopt second. A handle holding the new root over a file
  -- that still holds the old one reads nothing and says the vault is
  -- damaged, which is the wrong story about a failed write.
  self:save({
    keys = { masterrecord(root, self.keyid, self.passphrase, iters) },
    entries = entries,
  })

  -- Dropped rather than replaced: the next call re-derives from the file
  -- this one just wrote, which is the same rule every other change
  -- follows.
  self:close()
end

-- --------------------------------------------------- opening and creating

--- Open a vault file as one key.
---
--- The handle is LAZY. Nothing is read, and no passphrase is stretched,
--- until a call needs the file - so a chain of ten providers costs ten
--- tables rather than ten PBKDF2 runs.
function M.openvault(options)
  local want = options or {}

  if nil == want.file or '' == want.file then
    mvfail('a vault needs a file')
  end
  if nil == want.passphrase or '' == want.passphrase then
    mvfail('a vault needs a passphrase')
  end

  local keyid = checkid(
    (nil ~= want.key and '' ~= want.key) and want.key or M.MASTERKEY,
    'a vault needs a key id')

  return setmetatable({
    path = want.file,
    keyid = keyid,
    passphrase = want.passphrase,
    iterations = (nil ~= want.iterations and 0 < want.iterations)
      and want.iterations or M.ITERATIONS,
    create = true == want.create,
    opened = nil,
  }, Vault)
end

--- Make a vault file and answer a handle on its master key.
---
--- Refuses a file that is already there: a vault is created once, and
--- overwriting one discards every secret in it along with every key that
--- could read them.
function M.createvault(options)
  local vault = M.openvault(options)

  putnew(vault.path, newvault(vault.keyid, vault.passphrase, vault.iterations))

  return vault
end

-- ------------------------------------------------------------ the provider

--- Reads a vault as one store in a chain.
---
--- The provider is the READ half and nothing more: a chain resolves
--- secrets, and writing one is a deliberate act with an API of its own.
--- That API is the same handle, reached with `vaultof` off a chain or
--- built directly with `openvault`.
local function minivaultprovider(vault)
  return {
    lookup = function(secret) return vault:get(secret) end,
    describe = function() return 'minivault:' .. vault:file() end,
  }
end

--- The `minivault` provider kind, as a voxgig/plugin definition.
---
--- Written out rather than built by `providerplugin`, because this
--- definition publishes TWO exports: `provider`, the read half every kind
--- publishes, and `vault`, the programmatic API. voxgig/plugin's exports
--- are how a definition offers an application more than the host's own
--- vocabulary, and a store that can only be read is half a vault.
---
--- The `sekreto_error` wrapping is what `providerplugin` would have done:
--- plugin wraps a code-less error raised in `define` as
--- `plugin_define_failed` and keeps one that already carries a code, so a
--- refusal of this provider's own configuration travels under
--- `sekreto_error` and comes back out of the host as itself.
M.minivault = {
  name = 'minivault',
  define = function(inst)
    local spec = inst:options() or {}

    -- Configuration is refused HERE, so a mistyped chain fails at
    -- construction. Reaching the file is not configuration: the handle is
    -- lazy, and nothing is read or stretched until a lookup.
    local ok, built = pcall(M.openvault, {
      file = spec.file,
      key = spec.vaultkey,
      passphrase = spec.passphrase,
      iterations = spec.iterations,
      create = spec.create,
    })

    if not ok then
      if err.issekretoerror(built) then
        local message = err.message(built)
        local plugin = require('plugin')
        plugin.types.fail(providers.ERROR_CODE, message,
          plugin.types.map({ ref = inst.ref, cause = message }))
      end
      error(built, 0)
    end

    inst:export(providers.PROVIDER_EXPORT, minivaultprovider(built))
    inst:export(M.VAULT_EXPORT, built)
  end,
}

--- The vault behind a store in a chain, as its programmatic API.
---
--- `secrets.host` is the voxgig/plugin host the chain is made of, and a
--- definition's exports are readable off it by ref. This is the one call
--- that turns a store into an API, and it lives here rather than on
--- `Sekreto` because the core knows no plugin.
---
--- With no store named, the unqualified alias answers: one vault in the
--- chain resolves whatever it is called, and two refuse rather than
--- picking one.
function M.vaultof(secrets, store)
  if nil == store or '' == store then
    local found = secrets.host:exports('minivault/' .. M.VAULT_EXPORT)
    if nil == found then
      mvfail('no minivault store in this chain')
    end
    return found
  end

  -- A NAMED STORE MUST EXIST, and the alias must not stand in for it.
  -- `host:exports` falls back to the alias when the exact ref misses, so
  -- asking for `minivault` in a chain whose only vault is named `app`
  -- used to hand back the `app` vault - and then write to it. Naming a
  -- store that is not there refuses, which is the rule the whole library
  -- follows: `try` already means "may not have it", so it cannot also
  -- mean "may not exist".
  local missing = 'no minivault store named ' .. store .. ' in this chain'
  local ref = ('minivault' == store) and 'minivault' or ('minivault$' .. store)

  if nil == secrets.host:instance(ref) then
    mvfail(missing)
  end

  local found = secrets.host:exports(ref .. '/' .. M.VAULT_EXPORT)
  if nil == found then
    mvfail(missing)
  end

  return found
end

return M
