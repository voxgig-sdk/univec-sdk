-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/export.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Exports (section 11).
--
-- An instance publishes values for other plugins and for the application.
-- Read with `host:exports('retry$fast/client')`.
--
-- THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves
-- to the UNTAGGED instance if one exists; if not, and exactly one tagged
-- instance exports that key, it resolves to that one; if two do, it is
-- `plugin_export_ambiguous` - deliberately diverging from seneca's silent
-- last-wins, because with multi-instance as a headline feature an
-- ambiguous alias is a defect waiting for production.

local T = require 'feature.secrets.plugin.types'
local R = require 'feature.secrets.plugin.ref'

local M = {}

-- `exported` is a plain lua array of {ref=, key=, value=} records: an
-- internal shape, never a corpus value, so it is not tagged.
function M.resolve_export(spec, exported)
  local cut = spec:find('/', 1, true)
  if nil == cut then
    T.fail('plugin_export_ambiguous', 'export spec needs a key: ' .. spec,
           T.map { spec = spec })
  end
  local head = spec:sub(1, cut - 1)
  local key = spec:sub(cut + 1)

  -- A fully qualified ref: exactly one answer or none.
  local want = R.canon(head)
  for _, e in ipairs(exported) do
    if e.ref == want and e.key == key then
      return e.value
    end
  end

  -- An alias: the name, not a ref. Look at every instance of it.
  local byname = {}
  for _, e in ipairs(exported) do
    if R.refname(e.ref) == head and e.key == key then
      byname[#byname + 1] = e
    end
  end
  if 0 == #byname then return nil end

  for _, e in ipairs(byname) do
    if '' == R.parse_ref(e.ref).tag then
      return e.value
    end
  end

  if 1 == #byname then return byname[1].value end

  local refs = {}
  for _, e in ipairs(byname) do refs[#refs + 1] = e.ref end
  table.sort(refs)
  T.fail('plugin_export_ambiguous',
         'alias ' .. spec .. ' matches ' .. #refs .. ' instances: '
         .. table.concat(refs, ', '),
         T.map { spec = spec, refs = T.list(refs) })
end

return M
