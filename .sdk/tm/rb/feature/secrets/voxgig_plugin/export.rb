# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/export.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Exports (section 11).
#
# An instance publishes values for other plugins and for the application.
# Read with `host.exports('retry$fast/client')`.
#
# THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves
# to the UNTAGGED instance if one exists; if not, and exactly one tagged
# instance exports that key, it resolves to that one; if two do, it is
# `plugin_export_ambiguous` - deliberately diverging from seneca's silent
# last-wins, because with multi-instance as a headline feature an
# ambiguous alias is a defect waiting for production.

require_relative 'types'
require_relative 'ref'

module VoxgigPlugin
  def self.resolve_export(spec, exported)
    cut = spec.index('/')
    if cut.nil?
      fail_with('plugin_export_ambiguous', "export spec needs a key: #{spec}",
                { 'spec' => spec })
    end
    head = spec[0, cut]
    key = spec[(cut + 1)..]

    # A fully qualified ref: exactly one answer or none.
    want = canon(head)
    exported.each do |e|
      return e['value'] if e['ref'] == want && e['key'] == key
    end

    # An alias: the name, not a ref. Look at every instance of it.
    byname = exported.select { |e| refname(e['ref']) == head && e['key'] == key }
    return nil if byname.empty?

    byname.each do |e|
      return e['value'] if parse_ref(e['ref'])['tag'].empty?
    end

    return byname[0]['value'] if byname.length == 1

    refs = byname.map { |e| e['ref'] }.sort
    fail_with('plugin_export_ambiguous',
              "alias #{spec} matches #{refs.length} instances: #{refs.join(', ')}",
              { 'spec' => spec, 'refs' => refs })
  end
end
