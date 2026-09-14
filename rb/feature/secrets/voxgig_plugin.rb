# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The canonical surface `make parity` checks (AGENTS.md section 4). Small
# on purpose (section 19): everything else is methods on the host and
# instance types, because a library that grows a second public entry
# point per feature is a library twenty ports pay for twice.

require_relative 'voxgig_plugin/types'
require_relative 'voxgig_plugin/ref'
require_relative 'voxgig_plugin/version'
require_relative 'voxgig_plugin/capability'
require_relative 'voxgig_plugin/resolve'
require_relative 'voxgig_plugin/graph'
require_relative 'voxgig_plugin/order'
require_relative 'voxgig_plugin/config'
require_relative 'voxgig_plugin/env'
require_relative 'voxgig_plugin/export'
require_relative 'voxgig_plugin/point'
require_relative 'voxgig_plugin/catalog'
require_relative 'voxgig_plugin/depend'
require_relative 'voxgig_plugin/host'
