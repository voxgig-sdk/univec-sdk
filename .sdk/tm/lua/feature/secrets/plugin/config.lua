-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/config.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The declarative document (section 9): normalization, and the ten-level
-- precedence ladder.
--
-- TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
--
-- `normalize_config` normalizes STRUCTURE and ENTRY KEYS. It does not
-- merge options, and cannot: section 9.4 makes merge behaviour a property
-- of the definition's option SHAPE, which normalization has never seen. A
-- normalizer that flattened the option layers would make `$MERGE: append`
-- unimplementable at load time, because the layers it must concatenate
-- would already be collapsed.
--
-- `resolve_options` applies the ladder, and it is the only place that
-- knows the shape.

local T = require 'feature.secrets.plugin.types'
local R = require 'feature.secrets.plugin.ref'

local M = {}

M.MERGE_WORDS = { replace = true, append = true }

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

-- PRESENCE decides, not truthiness and not nil. A JSON `null` is a present
-- value in JavaScript (`undefined !== null`), so it must be one here - and
-- `T.has` is the only test that can tell them apart, because a lua table
-- cannot store a nil.
local function pick(src, key, dflt)
  if T.has(src, key) then return src[key] end
  return dflt
end

-- Both document forms reduce to {ref -> entry} plus the order the form
-- implies: array POSITION for the array form, sorted refs for the map
-- form.
local function entries(src)
  local map = {}
  local order = {}
  if nil == src or T.NULL == src then
    return map, order
  end

  if T.islist(src) then
    for i = 1, #src do
      local item = src[i]
      local ref = R.canon_ref(T.getv(item, 'ref'))
      map[ref] = item
      order[#order + 1] = ref
    end
    return map, order
  end

  -- Map-form refs arrive as KEYS, through a different path than an array
  -- element's `ref` field - and must canonicalize the same way.
  for _, key in ipairs(T.keys(src)) do
    map[R.canon_ref(key)] = src[key]
  end
  -- Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
  -- sort identically under all three, so only mixed input discriminates:
  -- '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. Lua's `<` on
  -- strings is byte-wise (it uses strcoll only under a non-C locale, which
  -- this port never sets).
  for k in pairs(map) do order[#order + 1] = k end
  table.sort(order)
  return map, order
end

function M.normalize_config(input)
  input = input or T.map {}
  local doc = T.getv(input, 'doc') or T.map {}
  local keys = T.getv(input, 'keys') or T.map {}
  local ikey = T.getv(keys, 'instance') or 'instance'
  local dkey = T.getv(keys, 'default') or 'default'
  local reserved = T.getv(input, 'reserved') or T.list {}
  local profile = T.getv(input, 'profile')

  -- The rename is applied at TWO PLACES AND NO OTHERS: the document root,
  -- and every profile.<name> overlay root (section 9.1). A rename applied
  -- only at the root would leave `profile.prod.sdk` untranslated and
  -- silently drop every environment override the host depends on.
  -- Recursing further would be worse: option data is the definition's.
  local baseinst = T.getv(doc, ikey)
  local basedef = T.getv(doc, dkey) or T.map {}

  local overlay
  if nil ~= profile then
    overlay = T.getv(T.getv(doc, 'profile') or T.map {}, profile)
  end
  if not T.ismap(overlay) then overlay = T.map {} end
  local overinst = T.getv(overlay, ikey)
  local overdef = T.getv(overlay, dkey) or T.map {}

  local basemap, baseorder = entries(baseinst)
  local overmap, overorder = entries(overinst)

  for _, group in ipairs { basemap, overmap, basedef, overdef } do
    local names = {}
    for k in pairs(group) do names[#names + 1] = k end
    table.sort(names)
    for _, r in ipairs(names) do checkreserved(r, reserved) end
  end

  -- A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this the
  -- hard way: deriving order from a partial array silently dropped
  -- config-activated features. Refs in the base but absent from the
  -- overlay still load, in sorted position AFTER the listed ones. A
  -- profile may also INTRODUCE a ref the base never declared.
  local order = {}
  local seen = {}
  for _, group in ipairs { overorder, baseorder } do
    for _, r in ipairs(group) do
      if not seen[r] then
        seen[r] = true
        order[#order + 1] = r
      end
    end
  end

  local instance = T.map {}
  for i, ref in ipairs(order) do
    local b = basemap[ref]
    local o = overmap[ref]

    -- MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
    -- (section 9.3). A safety rule, not a tidiness one: if the overlay had
    -- its defaults filled in before merging it would carry a synthesized
    -- active:true and overwrite a base's false - silently re-enabling a
    -- deliberately disabled integration in production.
    local active = pick(o, 'active', pick(b, 'active', true))
    local start = pick(o, 'start', pick(b, 'start', 'eager'))
    local block = pick(o, 'order', pick(b, 'order', nil))

    -- Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
    local nm = R.refname(ref)
    local layers = {}
    for _, src in ipairs { { s = basedef[nm] }, { s = b },
                           { s = overdef[nm] }, { s = o } } do
      if T.has(src.s, 'options') then
        layers[#layers + 1] = src.s.options
      end
    end

    local ent = T.map {
      pos = i - 1,
      active = active,
      start = start,
      optionlayers = T.list(layers),
    }
    if nil ~= block then ent.order = block end
    instance[ref] = ent
  end

  -- `default` DECLARES NOTHING (section 9.3). It is a base for every
  -- instance of that definition; it does not create one, and an entry for
  -- a name with no instances is inert rather than an error - which is what
  -- makes a shared library of defaults shippable.
  local defout = T.map {}
  for _, n in ipairs(T.keys(basedef)) do defout[n] = basedef[n] end
  for _, n in ipairs(T.keys(overdef)) do defout[n] = overdef[n] end

  return T.map {
    instance = instance,
    order = T.list(order),
    default = defout,
  }
end

-- -------------------------------------------------------------------
-- resolve_options - section 9.3's ten levels, and 9.4's directives
-- -------------------------------------------------------------------

local function defaultsof(shape)
  local out = T.map {}
  for _, k in ipairs(T.keys(shape)) do
    local v = shape[k]
    if not T.has(v, '$MERGE') then
      out[k] = v
    end
  end
  return out
end

local function optsof(src, key)
  if nil == src or T.NULL == src then return nil end

  -- The array form is equivalent to the map form (section 9.1).
  if T.islist(src) then
    for i = 1, #src do
      if R.canon_ref(T.getv(src[i], 'ref')) == key then
        return T.getv(src[i], 'options')
      end
    end
    return nil
  end

  for _, k in ipairs(T.keys(src)) do
    if R.canon_ref(k) == key then
      local entry = src[k]
      if T.ismap(entry) then return T.getv(entry, 'options') end
      return nil
    end
  end
  return nil
end

local mergeone, deepto

-- Merge ONE layer onto the accumulator, honouring the shape's directives.
-- The directive holds at EVERY precedence level, not only between document
-- levels - section 9.4 makes it a property of the shape, which does not
-- know which layer a value arrived from.
mergeone = function(base, over, shape)
  if nil == over then return base end
  if not T.ismap(base) or not T.ismap(over) then return T.copy(over) end

  local out = T.map {}
  for k, v in pairs(base) do out[k] = v end

  for _, k in ipairs(T.keys(over)) do
    local o = over[k]
    local directive = T.getv(T.getv(shape, k) or T.map {}, '$MERGE')
    local b = out[k]

    if 'replace' == directive then
      out[k] = T.copy(o)
    elseif 'append' == directive then
      local merged = {}
      if T.islist(b) then
        for i = 1, #b do merged[#merged + 1] = b[i] end
      end
      if T.islist(o) then
        for i = 1, #o do merged[#merged + 1] = o[i] end
      else
        merged[#merged + 1] = o
      end
      out[k] = T.list(merged)
    elseif T.has(directive, 'deep') then
      out[k] = deepto(b, o, directive.deep)
    else
      -- Library default: deep for maps, REPLACE for lists. struct.merge is
      -- element-wise by index, which for option maps is nearly always
      -- wrong - ["a"] over ["x","y","z"] yielding ["a","y","z"] is the
      -- defect station hit on secrets.providers.
      if T.ismap(b) and T.ismap(o) then
        out[k] = mergeone(b, o, nil)
      else
        out[k] = T.copy(o)
      end
    end
  end
  return out
end

-- Merge N levels below this key, replace below that.
deepto = function(base, over, n)
  if n <= 0 then return T.copy(over) end
  if not T.ismap(base) or not T.ismap(over) then return T.copy(over) end
  local out = T.map {}
  for k, v in pairs(base) do out[k] = v end
  for _, k in ipairs(T.keys(over)) do
    out[k] = deepto(out[k], over[k], n - 1)
  end
  return out
end

function M.resolve_options(input)
  local shape = T.getv(input, 'shape') or T.map {}
  M.check_shape(shape)

  local ref = R.canon_ref(T.getv(input, 'ref'))
  local name = R.refname(ref)
  local doc = T.getv(input, 'doc') or T.map {}
  local profile = T.getv(input, 'profile')

  local overlay
  if nil ~= profile then
    overlay = T.getv(T.getv(doc, 'profile') or T.map {}, profile)
  end
  if not T.ismap(overlay) then overlay = T.map {} end

  -- ONE ordered merge, lowest to highest. Levels 3-6 are not two
  -- namespaces collapsed separately and composed afterwards: that inverts
  -- the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION SPECIFICITY, so
  -- a prod per-definition default would lose to a base instance value.
  local layers = {
    defaultsof(shape),                                 -- 1
    T.getv(input, 'hostdefaults'),                     -- 2
    optsof(T.getv(doc, 'default'), name),              -- 3
    optsof(T.getv(doc, 'instance'), ref),              -- 4
    optsof(T.getv(overlay, 'default'), name),          -- 5
    optsof(T.getv(overlay, 'instance'), ref),          -- 6
    T.getv(input, 'env'),                              -- 7
    T.getv(input, 'hostoptions'),                      -- 8
    T.getv(input, 'loadoptions'),                      -- 9
    T.getv(input, 'patch'),                            -- 10
  }

  local out = T.map {}
  -- `ipairs` stops at the first nil, and a missing layer is normal - so
  -- this walks the fixed ten by index.
  for i = 1, 10 do
    if nil ~= layers[i] then
      out = mergeone(out, layers[i], shape)
    end
  end
  return out
end

-- Section 9.4: N is an integer of at least 1, and everything else is an
-- error.
--
-- `{"deep": 0}` is rejected DESPITE having an obvious reading, because
-- "replace at this key" already has a spelling and two spellings for one
-- behaviour is the defect class this repo exists to avoid.
function M.check_shape(shape)
  if not T.ismap(shape) then return end

  for _, k in ipairs(T.keys(shape)) do
    local v = shape[k]
    if T.has(v, '$MERGE') then
      local directive = v['$MERGE']

      if 'string' == type(directive) then
        if not M.MERGE_WORDS[directive] then
          T.fail('plugin_shape_invalid',
                 'invalid $MERGE directive at ' .. k .. ': ' .. directive,
                 T.map { key = k })
        end
      elseif T.has(directive, 'deep') then
        local n = directive.deep
        -- A JSON NUMBER, and an integer of at least 1. `math.type` is the
        -- test: `true` is a boolean and `'2'` a string, and lua would
        -- coerce the string in a comparison.
        if 'integer' ~= math.type(n) or n < 1 then
          T.fail('plugin_shape_invalid',
                 'invalid $MERGE deep at ' .. k .. ': ' .. T.encode(n),
                 T.map { key = k })
        end
      else
        T.fail('plugin_shape_invalid',
               'invalid $MERGE directive at ' .. k .. ': ' .. T.encode(directive),
               T.map { key = k })
      end
    end
  end
end

return M
