-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/resolve.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Dynamic resolution (section 10.2) - name to candidate module ids.
--
-- PURE. It returns the ids a host WOULD try, in order; it does not load
-- anything. That separation is what lets the corpus pin resolution in
-- every language including those with no dynamic loading at all, and it is
-- why section 15.4 puts real module loading in per-port integration tests
-- rather than here.

local T = require 'feature.secrets.plugin.types'

local M = {}

function M.default_sources()
  return T.list {
    T.map {
      kind = 'module',
      prefix = T.list { '@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', '' },
    },
  }
end

function M.resolve_candidates(name, sources)
  local out = {}
  local seen = {}

  -- A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing` is
  -- already a package id; prefixing it produces
  -- `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
  if '@' == name:sub(1, 1) then
    return T.list { name }
  end

  local list = sources
  if not T.islist(list) or 0 == #list then
    list = M.default_sources()
  end

  for i = 1, #list do
    local src = list[i]
    local kind = T.getv(src, 'kind')
    if 'module' == kind then
      local prefixes = T.getv(src, 'prefix')
      if not T.islist(prefixes) or 0 == #prefixes then
        prefixes = T.list { '' }
      end
      for j = 1, #prefixes do
        local id = prefixes[j] .. name
        if not seen[id] then
          seen[id] = true
          out[#out + 1] = id
        end
      end
    elseif 'path' == kind then
      local dir = (T.getv(src, 'dir') or ''):gsub('/+$', '')
      local id = dir .. '/' .. name
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end

  return T.list(out)
end

-- A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a
-- name with a letter or `@`, so `./local/thing` is not a ref and never
-- reaches candidate generation - seneca allows a path where a plugin name
-- goes, and this design deliberately does not, because a ref is an ADDRESS
-- WITHIN A HOST and a path is a LOCATION ON A DISK.
function M.resolve_from(from)
  return T.list { from }
end

return M
