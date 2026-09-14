-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/name.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The pure name functions: everything sekreto knows about a secret's
-- name before any store is asked.
--
-- All synchronous, all pure, all accepting any Lua value - the shared
-- corpus feeds them numbers, booleans and nulls. All of them check the
-- name first, except `validname`, which never raises at all.
--
-- These live in their own module rather than in `sekreto.lua` because the
-- providers need them too, and `sekreto.lua` requires the providers: one
-- of the two edges has to be somewhere else.
--
-- A port of typescript/src/Sekreto.ts, which is canonical.

local err = require('feature.secrets.sekreto.err')

local M = {}

-- ASCII case folding, spelled out. `string.upper` goes through the C
-- library's toupper, which follows the machine's locale - and in a
-- Turkish locale `i` does not fold to `I`, which would silently change
-- every environment-variable key this library computes.
local function upperascii(text)
  return (text:gsub('[a-z]', function(ch) return string.char(ch:byte() - 32) end))
end

--- Split on `.`, keeping empty segments (so `a..b` yields an empty one).
local function segments(name)
  local out = {}
  local at = 1

  while true do
    local stop = name:find('.', at, true)
    if not stop then
      out[#out + 1] = name:sub(at)
      return out
    end
    out[#out + 1] = name:sub(at, stop - 1)
    at = stop + 1
  end
end

M.segments = segments

--- Is this a well-formed secret name? Never raises, whatever it is given.
---
--- Scanned byte by byte rather than matched against `^[a-z0-9_]+$`: in
--- several languages `$` also matches before a final newline, and four
--- ports accepted `api.token\n` because of it. A scan cannot make that
--- mistake, and the corpus pins all three newline forms as false.
function M.validname(name)
  if 'string' ~= type(name) or '' == name then
    return false
  end

  for _, part in ipairs(segments(name)) do
    if '' == part then
      return false
    end

    for index = 1, #part do
      local byte = part:byte(index)
      local okbyte = (97 <= byte and 122 >= byte) or
        (48 <= byte and 57 >= byte) or
        95 == byte

      if not okbyte then
        return false
      end
    end
  end

  return true
end

--- The name, or a SekretoError. Every entry point checks its name here.
function M.checkname(name)
  if not M.validname(name) then
    err.fail('sekreto: invalid name: ' .. ('string' == type(name) and name or
      (nil == name and '' or tostring(name))))
  end

  return name
end

--- The environment-variable key for a name: `api.token` -> `API_TOKEN`.
--- The prefix is joined verbatim and is NOT uppercased.
function M.envkey(name, prefix)
  local checked = M.checkname(name)
  return (prefix or '') .. upperascii(table.concat(segments(checked), '_'))
end

--- Where a name lives in a KV vault: `api.token` -> `api` / `token`.
---
--- A single-segment name has no path of its own, so it becomes a secret
--- of that name with the conventional field `value`.
function M.vaultref(name)
  local parts = segments(M.checkname(name))

  if 1 == #parts then
    return { path = parts[1], field = 'value' }
  end

  local field = parts[#parts]
  table.remove(parts)

  return { path = table.concat(parts, '/'), field = field }
end

--- A name flattened to one segment: `api.token` -> `api_token` (GCP
--- Secret Manager, `_`) or `api-token` (Azure Key Vault, `-`).
---
--- With `-` as the separator underscores flatten too: Key Vault's
--- alphabet is letters, digits and hyphens only, so `with_underscore`
--- must still be representable there.
function M.flatname(name, sep)
  local usesep = sep or ''
  local flat = table.concat(segments(M.checkname(name)), usesep)

  if '-' == usesep then
    return (flat:gsub('_', '-'))
  end

  return flat
end

--- The AWS SSM Parameter Store name: dots become the path hierarchy,
--- rooted at `/` or at a prefix. `db.pass.main` -> `/db/pass/main`.
function M.awsparam(name, prefix)
  local checked = M.checkname(name)

  local base = prefix or ''
  if '' ~= base and '/' ~= base:sub(1, 1) then
    base = '/' .. base
  end
  if '/' == base:sub(-1) then
    base = base:sub(1, #base - 1)
  end

  return base .. '/' .. table.concat(segments(checked), '/')
end

local function trim(text)
  return (text:gsub('^[ \t\r\n\f\v]+', ''):gsub('[ \t\r\n\f\v]+$', ''))
end

M.trim = trim

--- Unescape a double-quoted `.env` value.
---
--- `\n \r \t \\ \"` only. Any other escape is preserved as backslash plus
--- the character, and a trailing backslash is literal. A scan, not a
--- chain of replacements, so `\\n` cannot be read as a newline.
local function unescape(text)
  local out = {}
  local index = 1

  while index <= #text do
    local ch = text:sub(index, index)

    if '\\' == ch and index < #text then
      local next = text:sub(index + 1, index + 1)
      index = index + 2

      if 'n' == next then
        out[#out + 1] = '\n'
      elseif 'r' == next then
        out[#out + 1] = '\r'
      elseif 't' == next then
        out[#out + 1] = '\t'
      elseif '\\' == next then
        out[#out + 1] = '\\'
      elseif '"' == next then
        out[#out + 1] = '"'
      else
        out[#out + 1] = '\\' .. next
      end
    else
      out[#out + 1] = ch
      index = index + 1
    end
  end

  return table.concat(out)
end

--- Parse `.env` text into raw keys and values.
---
--- There is no `.env` standard, so this function IS the specification:
--- `KEY=value`, an optional `export`, `#` comments on their own line, and
--- single- or double-quoted values (double quotes also unescape). A line
--- with no `=`, or with an empty key, is skipped silently rather than
--- aborting the rest of the file.
---
--- Returns a plain table of key to value, plus the key order under
--- `order` - Lua tables have no insertion order of their own.
function M.parsedotenv(text)
  local values = {}
  local order = {}

  if 'string' ~= type(text) then
    return values, order
  end

  local at = 1

  while at <= #text + 1 do
    local stop = text:find('\n', at, true)
    local rawline = stop and text:sub(at, stop - 1) or text:sub(at)
    at = (stop or #text) + 1

    if '\r' == rawline:sub(-1) then
      rawline = rawline:sub(1, #rawline - 1)
    end

    local line = trim(rawline)

    if '' ~= line and '#' ~= line:sub(1, 1) then
      local body = line
      if 'export ' == body:sub(1, 7) then
        body = trim(body:sub(8))
      end

      local eq = body:find('=', 1, true)

      -- `nil` is "no =", `1` is "empty key": both are skipped.
      if nil ~= eq and 1 < eq then
        local key = trim(body:sub(1, eq - 1))
        local value = trim(body:sub(eq + 1))

        if 2 <= #value and '"' == value:sub(1, 1) and '"' == value:sub(-1) then
          value = unescape(value:sub(2, #value - 1))
        elseif 2 <= #value and "'" == value:sub(1, 1) and "'" == value:sub(-1) then
          value = value:sub(2, #value - 1)
        end

        if nil == values[key] then
          order[#order + 1] = key
        end
        values[key] = value
      end
    end

    if not stop then
      break
    end
  end

  return values, order
end

--- Replace every occurrence of `needle` in `text` with `replacement`.
--- A literal search, never a pattern: a secret containing `%` or `-`
--- must not be interpreted as one.
local function replaceall(text, needle, replacement)
  local out = {}
  local at = 1

  while true do
    local start, stop = text:find(needle, at, true)
    if not start then
      out[#out + 1] = text:sub(at)
      return table.concat(out)
    end

    out[#out + 1] = text:sub(at, start - 1)
    out[#out + 1] = replacement
    at = stop + 1
  end
end

--- Replace known secret values in text with `[redacted]`.
---
--- Only values of four characters or more: shorter ones are too likely to
--- appear in ordinary text, and redacting them would make logs unreadable
--- without making them safer.
---
--- Longest first, always, so `abcd1234` is replaced before `abcd` can eat
--- its prefix - the corpus pins both arrival orders of that pair. The
--- list is COPIED before sorting: `Sekreto.redact` passes its own live
--- redaction history, and an in-place sort would reorder it.
function M.redact(text, values)
  local out = 'string' == type(text) and text or ''

  local usable = {}
  for _, value in ipairs(values or {}) do
    if 'string' == type(value) and 4 <= #value then
      usable[#usable + 1] = value
    end
  end

  table.sort(usable, function(left, right) return #left > #right end)

  for _, value in ipairs(usable) do
    out = replaceall(out, value, '[redacted]')
  end

  return out
end

--- The store name a provider answers to when nothing says otherwise.
---
--- `describe()` opens with the provider's kind - `hashicorp:...`,
--- `dotenv:...`, plain `env` - so the kind is the natural default, and a
--- custom provider gets a sensible name without implementing anything
--- extra.
function M.storename(provider)
  local text = provider.describe()
  local mark = text:find(':', 1, true)
  return mark and text:sub(1, mark - 1) or text
end

return M
