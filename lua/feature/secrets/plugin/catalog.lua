-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/catalog.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The definition catalog (section 10.1).
--
-- A definition is registered once and may back many instances. Option
-- shapes are validated AT REGISTRATION, not when a document happens to
-- exercise a key - so a malformed shape fails once, and in the same place
-- everywhere (section 9.4).

local T = require 'feature.secrets.plugin.types'
local R = require 'feature.secrets.plugin.ref'
local C = require 'feature.secrets.plugin.config'

local M = {}

local Catalog = {}
Catalog.__index = Catalog
M.Catalog = Catalog

function Catalog.new()
  return setmetatable({ defs = {} }, Catalog)
end

function Catalog:add(definition)
  local name = 'table' == type(definition) and definition.name or definition
  if 'table' ~= type(definition) or not R.check_name(name) then
    T.fail('plugin_definition_name',
           'invalid definition name: ' .. T.encode(name), nil)
  end
  -- Validate the shape HERE. Deferring it to resolution time means a
  -- malformed shape surfaces at a different moment in every host that
  -- loads it, which is the divergence the stated domain exists to prevent.
  if T.truthy(definition.shape) then
    C.check_shape(definition.shape)
  end
  self.defs[name] = definition
end

function Catalog:get(name)
  return self.defs[name]
end

function Catalog:has(name)
  return nil ~= self.defs[name]
end

function Catalog:names()
  local out = {}
  for k in pairs(self.defs) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function M.make_catalog(definitions)
  local catalog = Catalog.new()
  for _, d in ipairs(definitions or {}) do
    catalog:add(d)
  end
  return catalog
end

return M
