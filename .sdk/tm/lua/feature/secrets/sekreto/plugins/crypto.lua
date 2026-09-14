-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/crypto.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- SHA-256, HMAC-SHA256, hex and strict base64 - all hand-rolled.
--
-- Lua has no crypto at all. The port links OpenSSL for TLS (see
-- native/sekretonet.c), and it would be one line to call that library's
-- EVP_Digest here instead - but the dependency rule covers cryptographic
-- TRANSPORT and nothing else, so the digests sekreto signs with are its
-- own. Rust took the same decision with `ring` already in rustls's
-- closure.
--
-- Correctness is not argued from the code: SigV4 is a chain of these
-- primitives, so the five known-answer vectors in spec/sekreto.json fail
-- on one wrong bit anywhere below.
--
-- Lua 5.4 has 64-bit integers and native bitwise operators, so the
-- rotations are direct - every addition is masked back to 32 bits.

local M = {}

local MASK = 0xffffffff

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function ror(value, count)
  return ((value >> count) | (value << (32 - count))) & MASK
end

--- SHA-256 of a byte string, as 32 raw bytes.
function M.sha256(message)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  -- 0x80, then zeros until the length lands 8 bytes short of a block,
  -- then the BIT length, big-endian.
  local bitlen = #message * 8
  local padded = message .. '\128'
  local rem = (#padded % 64)
  local fill = (56 - rem) % 64
  padded = padded .. string.rep('\0', fill) .. string.pack('>I8', bitlen)

  local w = {}

  for block = 1, #padded, 64 do
    for index = 0, 15 do
      w[index + 1] = string.unpack('>I4', padded, block + index * 4)
    end

    for index = 17, 64 do
      local a = w[index - 15]
      local b = w[index - 2]
      local s0 = ror(a, 7) ~ ror(a, 18) ~ (a >> 3)
      local s1 = ror(b, 17) ~ ror(b, 19) ~ (b >> 10)
      w[index] = (w[index - 16] + s0 + w[index - 7] + s1) & MASK
    end

    local a, b, c, d = h0, h1, h2, h3
    local e, f, g, h = h4, h5, h6, h7

    for index = 1, 64 do
      local S1 = ror(e, 6) ~ ror(e, 11) ~ ror(e, 25)
      local ch = (e & f) ~ ((~e & MASK) & g)
      local temp1 = (h + S1 + ch + K[index] + w[index]) & MASK
      local S0 = ror(a, 2) ~ ror(a, 13) ~ ror(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local temp2 = (S0 + maj) & MASK

      h = g
      g = f
      f = e
      e = (d + temp1) & MASK
      d = c
      c = b
      b = a
      a = (temp1 + temp2) & MASK
    end

    h0 = (h0 + a) & MASK
    h1 = (h1 + b) & MASK
    h2 = (h2 + c) & MASK
    h3 = (h3 + d) & MASK
    h4 = (h4 + e) & MASK
    h5 = (h5 + f) & MASK
    h6 = (h6 + g) & MASK
    h7 = (h7 + h) & MASK
  end

  return string.pack('>I4I4I4I4I4I4I4I4', h0, h1, h2, h3, h4, h5, h6, h7)
end

--- Lowercase hex, two digits per byte.
function M.hex(bytes)
  local out = {}
  for index = 1, #bytes do
    out[index] = string.format('%02x', bytes:byte(index))
  end
  return table.concat(out)
end

function M.sha256hex(message)
  return M.hex(M.sha256(message))
end

local BLOCK = 64

--- HMAC-SHA256, RFC 2104. The argument order is (key, data) in every
--- port; several standard libraries take (data, key), and that is fixed
--- at the wrapper rather than at the call sites.
function M.hmac(key, data)
  local usekey = key

  if #usekey > BLOCK then
    usekey = M.sha256(usekey)
  end
  if #usekey < BLOCK then
    usekey = usekey .. string.rep('\0', BLOCK - #usekey)
  end

  local ipad = {}
  local opad = {}

  for index = 1, BLOCK do
    local byte = usekey:byte(index)
    ipad[index] = string.char(byte ~ 0x36)
    opad[index] = string.char(byte ~ 0x5c)
  end

  local inner = M.sha256(table.concat(ipad) .. data)
  return M.sha256(table.concat(opad) .. inner)
end

-- ---- base64 ----------------------------------------------------------

local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local VALUES = {}
for index = 1, #ALPHABET do
  VALUES[ALPHABET:sub(index, index)] = index - 1
end

--- Decode standard base64, STRICTLY: returns nil for anything that is not
--- a well-formed payload.
---
--- Strictness is the point. A lenient decoder skips bytes outside the
--- alphabet and hands back plausible-looking bytes for a corrupted
--- payload - which are then returned to the caller AS THE SECRET. A
--- rejection here becomes an error, never a miss.
function M.unbase64(text)
  if 'string' ~= type(text) then
    return nil
  end

  local clean = text:gsub('[ \t\r\n]', '')

  if 0 ~= #clean % 4 then
    return nil
  end

  local body = clean
  local pad = 0

  while 0 < #body and '=' == body:sub(-1) do
    pad = pad + 1
    body = body:sub(1, #body - 1)
  end

  if 2 < pad then
    return nil
  end

  for index = 1, #body do
    if nil == VALUES[body:sub(index, index)] then
      return nil
    end
  end

  local out = {}
  local acc = 0
  local bits = 0

  for index = 1, #body do
    acc = (acc << 6) | VALUES[body:sub(index, index)]
    bits = bits + 6

    if 8 <= bits then
      bits = bits - 8
      out[#out + 1] = string.char((acc >> bits) & 0xff)
    end
  end

  return table.concat(out)
end

return M
