# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/catalog.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The definition catalog (section 10.1).
#
# A definition is registered once and may back many instances. Option
# shapes are validated AT REGISTRATION, not when a document happens to
# exercise a key - so a malformed shape fails once, and in the same place
# everywhere (section 9.4).

require_relative 'types'
require_relative 'ref'
require_relative 'config'

module VoxgigPlugin
  class Catalog
    def initialize
      @defs = {}
    end

    def add(definition)
      unless definition.is_a?(Hash) && VoxgigPlugin.check_name(definition['name'])
        name = definition.is_a?(Hash) ? definition['name'] : definition
        VoxgigPlugin.fail_with('plugin_definition_name',
                               "invalid definition name: #{name}")
      end
      # Validate the shape HERE. Deferring it to resolution time means a
      # malformed shape surfaces at a different moment in every host that
      # loads it, which is the divergence the stated domain exists to
      # prevent.
      VoxgigPlugin.check_shape(definition['shape']) if definition['shape']
      @defs[definition['name']] = definition
    end

    def get(name)
      @defs[name]
    end

    def has?(name)
      @defs.key?(name)
    end

    def names
      @defs.keys.sort
    end
  end

  def self.make_catalog(definitions = nil)
    catalog = Catalog.new
    (definitions || []).each { |d| catalog.add(d) }
    catalog
  end
end
