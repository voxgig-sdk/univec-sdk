-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/ref.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Identity: name+tag, written `name$tag` (section 4).
--
-- The four pure functions, and the whole of what `ref` pins. They are the
-- first thing a new port implements and the first corpus section it
-- passes.
--
-- LUA'S `$` IS A TRUE END ANCHOR. A lua pattern has no multiline mode and
-- `$` matches only at the end of the subject, so `^...$` here cannot admit
-- the trailing newline that ruby, python, perl and php each had to write
-- `\A`/`\z` (or a character walk) to exclude. The four
-- `#trailing-newline` entries pass this port without it having to know
-- they exist.

local T = require 'feature.secrets.plugin.types'

local M = {}

-- Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
M.NAME_PAT = '^[a-zA-Z@][a-zA-Z0-9.~_/%-]*$'

-- Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
--
-- The asymmetry with a name is deliberate: a tag MAY start with a digit
-- because auto-tagging assigns integer tags (`stripe$1`), and a tag admits
-- neither `@` nor `/` because a name is a package specifier and a tag is
-- not.
M.TAG_PAT = '^[a-zA-Z0-9.~_%-]+$'

M.REF_MAX = 1024

function M.check_name(name)
  if 'string' ~= type(name) then return false end
  if '' == name or M.REF_MAX < #name then return false end
  return nil ~= name:match(M.NAME_PAT)
end

function M.check_tag(tag)
  if 'string' ~= type(tag) then return false end
  -- The empty tag is an ordinary tag (section 4 rule 2). The
  -- single-instance case writes no tag and never learns tags exist.
  if '' == tag then return true end
  if M.REF_MAX < #tag then return false end
  return nil ~= tag:match(M.TAG_PAT)
end

-- `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both give
-- tag ''.
function M.parse_ref(str)
  if 'string' ~= type(str) then
    T.fail('plugin_bad_name', 'ref must be a string', nil)
  end

  -- Split on the FIRST `$`. Nothing in the grammar decides this - `$` is
  -- in neither character class - so the corpus is the arbiter (section 4
  -- rule 5), and it picks the split that blames the part actually at
  -- fault: `a$b$c` is a good name with a bad tag, not the reverse.
  local cut = str:find('$', 1, true)
  local name = nil == cut and str or str:sub(1, cut - 1)
  local tag = nil == cut and '' or str:sub(cut + 1)

  if not M.check_name(name) then
    T.fail('plugin_bad_name', 'invalid plugin name: ' .. name,
           T.map { name = name })
  end
  if not M.check_tag(tag) then
    T.fail('plugin_bad_tag', 'invalid plugin tag: ' .. tag,
           T.map { name = name, tag = tag })
  end

  return T.map { name = name, tag = tag }
end

-- The pair -> `name$tag`. An empty tag NEVER writes the separator, which
-- is the half of canonicalization format_ref owns: parse tolerates
-- `stripe$`, format never produces it, so a round trip is idempotent.
function M.format_ref(name, tag)
  if nil == tag or T.NULL == tag then tag = '' end
  if not M.check_name(name) then
    T.fail('plugin_bad_name', 'invalid plugin name: ' .. T.encode(name),
           T.map { name = name })
  end
  if not M.check_tag(tag) then
    T.fail('plugin_bad_tag', 'invalid plugin tag: ' .. T.encode(tag),
           T.map { name = name, tag = tag })
  end
  if '' == tag then return name end
  return name .. '$' .. tag
end

-- The canonical spelling of a ref. Section 4 rule 5: ports must
-- canonicalize before comparison.
function M.canon_ref(str)
  local parsed = M.parse_ref(str)
  return M.format_ref(parsed.name, parsed.tag)
end

-- canon_ref for the internal callers that want the input back unchanged
-- when it is not well formed. NEVER use it where a bad ref must be
-- reported - the corpus pins plugin_bad_name at every public entry.
function M.canon(str)
  local ok, out = pcall(M.canon_ref, str)
  if ok then return out end
  return str
end

function M.refname(str)
  local ok, out = pcall(function() return M.parse_ref(str).name end)
  if ok then return out end
  return str
end

return M
