-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The canonical surface `make parity` checks (AGENTS.md section 4). Small
-- on purpose (section 19): everything else is methods on the host and
-- instance types, because a library that grows a second public entry point
-- per feature is a library twenty ports pay for twice.
--
--   make_host  make_catalog
--   parse_ref  format_ref  check_name  check_tag
--   normalize_config  resolve_options  resolve_order  resolve_candidates
--   apply_env
--
-- This module FORWARDS rather than implements: the surface is visible in
-- one place, and a name that stops existing stops existing here loudly.

local types = require 'feature.secrets.plugin.types'
local json = require 'feature.secrets.plugin.json'
local ref = require 'feature.secrets.plugin.ref'
local version = require 'feature.secrets.plugin.version'
local capability = require 'feature.secrets.plugin.capability'
local resolve = require 'feature.secrets.plugin.resolve'
local graph = require 'feature.secrets.plugin.graph'
local order = require 'feature.secrets.plugin.order'
local config = require 'feature.secrets.plugin.config'
local env = require 'feature.secrets.plugin.env'
local export = require 'feature.secrets.plugin.export'
local point = require 'feature.secrets.plugin.point'
local catalog = require 'feature.secrets.plugin.catalog'
local depend = require 'feature.secrets.plugin.depend'
local host = require 'feature.secrets.plugin.host'

local M = {
  types = types,
  json = json,

  make_host = host.make_host,
  make_catalog = catalog.make_catalog,

  parse_ref = ref.parse_ref,
  format_ref = ref.format_ref,
  check_name = ref.check_name,
  check_tag = ref.check_tag,
  canon_ref = ref.canon_ref,

  normalize_config = config.normalize_config,
  resolve_options = config.resolve_options,
  resolve_order = order.resolve_order,
  resolve_candidates = resolve.resolve_candidates,
  resolve_from = resolve.resolve_from,
  resolve_capability = capability.resolve_capability,
  resolve_graph = graph.resolve_graph,
  apply_env = env.apply_env,
  parse_range = version.parse_range,
  satisfies = version.satisfies,

  codeof = types.codeof,
  NULL = types.NULL,
}

-- The modules themselves, for the driver and for a host that needs one.
M.ref = ref
M.version = version
M.capability = capability
M.resolve = resolve
M.graph = graph
M.order = order
M.config = config
M.env = env
M.export = export
M.point = point
M.catalog = catalog
M.depend = depend
M.host = host

return M
