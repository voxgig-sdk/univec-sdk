-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/env.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Environment overrides (section 9.5) - level 7 of the ladder.
--
-- One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
--
--   VOXGIG_PLUGIN_PROFILE            the profile name
--   VOXGIG_PLUGIN_<REF>_<PATH>       one option
--   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
--
-- THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
-- OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` -> `_`.
-- But `_` is legal in a name and in a tag, and the mapping folds case, so
-- `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
--
-- Rather than restrict a grammar the rest of the stack already uses, the
-- host DETECTS THE COLLISION: it encodes every ref it holds, and a key two
-- refs claim is `plugin_env_ambiguous`, naming both.

local T = require 'feature.secrets.plugin.types'
local R = require 'feature.secrets.plugin.ref'
local J = require 'feature.secrets.plugin.json'

local M = {}

M.ENV_PREFIX = 'VOXGIG_PLUGIN_'

-- `retry$fast` -> `RETRY__FAST`.
function M.encode_ref(ref)
  local out = ref:gsub('%$', '__'):gsub('%.', '_')
  return out:upper()
end

local function checkreserved(ref, reserved)
  if not T.islist(reserved) or 0 == #reserved then return end
  local name = R.refname(ref)
  for i = 1, #reserved do
    if reserved[i] == name then
      T.fail('plugin_ref_reserved', 'ref is reserved by the host: ' .. ref,
             T.map { ref = ref })
    end
  end
end

local function split(value)
  local out = {}
  if 'string' ~= type(value) then return out end
  for part in (value .. ','):gmatch('([^,]*),') do
    local trimmed = part:match('^%s*(.-)%s*$')
    if '' ~= trimmed then out[#out + 1] = trimmed end
  end
  return out
end

-- Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
-- `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
-- looks like rather than a parse error.
local function parsevalue(value)
  if 'string' ~= type(value) then return value end
  local ok, parsed = pcall(J.parse, value)
  if ok then return parsed end
  return value
end

function M.apply_env(input)
  input = input or T.map {}
  local env = T.getv(input, 'env') or T.map {}
  local reserved = T.getv(input, 'reserved') or T.list {}

  local refs = {}
  local given = T.getv(input, 'refs') or T.list {}
  for i = 1, T.len(given) do
    refs[#refs + 1] = R.canon_ref(given[i])
  end

  local options = T.map {}
  local active = T.list {}
  local inactive = T.list {}
  local out = T.map { options = options, active = active, inactive = inactive }

  -- Encode every ref the host holds, and refuse a key that two of them
  -- claim. Done up front so the collision is reported even when no
  -- environment variable exercises it - a latent ambiguity is still an
  -- ambiguity, and finding it at deploy time is the failure this exists to
  -- prevent.
  local byencoded = {}
  local encodedkeys = {}
  for _, r in ipairs(refs) do
    local e = M.encode_ref(r)
    if nil == byencoded[e] then
      byencoded[e] = {}
      encodedkeys[#encodedkeys + 1] = e
    end
    table.insert(byencoded[e], r)
  end
  table.sort(encodedkeys)
  for _, e in ipairs(encodedkeys) do
    if 1 < #byencoded[e] then
      local pair = T.sortstrings(byencoded[e])
      T.fail('plugin_env_ambiguous',
             'refs collide in the environment encoding as ' .. e .. ': '
             .. table.concat(pair, ', '),
             T.map { encoded = e, refs = T.list(pair) })
    end
  end

  -- Longest encoded ref first, so `retry$fast` wins over `retry` on
  -- `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
  local encoded = T.stable_sort(encodedkeys, function(a, b)
    return #a > #b
  end)

  for _, key in ipairs(T.keys(env)) do
    if M.ENV_PREFIX == key:sub(1, #M.ENV_PREFIX) then
      local rest = key:sub(#M.ENV_PREFIX + 1)

      if 'PROFILE' == rest then
        out.profile = env[key]
      elseif 'ACTIVE' == rest or 'INACTIVE' == rest then
        local target = 'ACTIVE' == rest and active or inactive
        for _, raw in ipairs(split(env[key])) do
          local ref = R.canon_ref(raw)
          -- The reservation covers EVERY input layer (section 9.1).
          -- VOXGIG_PLUGIN_INACTIVE=station is easier to set than editing a
          -- config file, and INACTIVE has the final word - so guarding
          -- documents alone would leave the one lever this mechanism
          -- exists to deny wide open.
          checkreserved(ref, reserved)
          target[#target + 1] = ref
        end
      else
        local enc
        for _, e in ipairs(encoded) do
          if rest == e or (e .. '_') == rest:sub(1, #e + 1) then
            enc = e
            break
          end
        end

        if nil ~= enc then
          local ref = byencoded[enc][1]
          checkreserved(ref, reserved)

          -- A ref with no path sets nothing.
          if rest ~= enc then
            local path = {}
            for piece in (rest:sub(#enc + 2):lower() .. '_'):gmatch('([^_]*)_') do
              path[#path + 1] = piece
            end

            if not T.ismap(options[ref]) then options[ref] = T.map {} end
            local node = options[ref]
            for i = 1, #path - 1 do
              if not T.ismap(node[path[i]]) then node[path[i]] = T.map {} end
              node = node[path[i]]
            end
            node[path[#path]] = parsevalue(env[key])
          end
        end
      end
    end
  end

  return out
end

return M
