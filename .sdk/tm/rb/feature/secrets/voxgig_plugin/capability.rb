# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/capability.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Capabilities (section 11.1).
#
# A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
# dependency on something that can do the job, and which instance is
# doing it is exactly the configuration detail a plugin must not care
# about.
#
# But A BINDING IS TO AN INSTANCE, not to a capability, which is what
# decides behaviour when the bound provider leaves while another match
# remains.

require_relative 'types'
require_relative 'version'

module VoxgigPlugin
  # Rank the matching live providers and return them best-first: highest
  # `version`, then LOWEST `priority` (default 0), then declaration
  # position `pos` ascending.
  #
  # `priority` is a field on the capability rather than section 7's
  # `order` band, because bands live on POINT BINDINGS: a provider may
  # have several bindings with different bands, or none at all, so a rank
  # reaching for one would be undefined in the common case.
  #
  # Without a total rank, "any provider satisfies" is true of the GRAPH
  # and useless to the PLUGIN - two ports could bind different `store`
  # instances, both resolve green, and behave differently, which is
  # precisely the divergence a shared corpus exists to catch.
  def self.resolve_capability(req, candidates)
    hits = candidates.select { |c| matches(req, c['provides'] || {}) }
    # STABLE: Ruby's sort is not, and the rank falls through to `pos`.
    Util.stable_sort_by(hits) { |c| rank_key(c) }
  end

  def self.rank_key(cand)
    prov = cand['provides'] || {}
    version = prov['version']
    # An ABSENT version sorts LAST, whatever the other is - "no version"
    # loses to every version rather than being read as 0.0.0. The leading
    # flag is what expresses that in a sort KEY rather than a comparator.
    [version.nil? ? 1 : 0,
     version.nil? ? [0, 0, 0] : version_parts(version).map { |n| -n },
     prov['priority'] || 0,
     cand['pos'] || 0]
  end

  def self.matches(req, prov)
    return false if req['name'] != prov['name']

    unless req['range'].nil?
      return false if prov['version'].nil?
      return false unless satisfiesq(prov['version'], req['range'])
    end

    # `match` is checked against the provider's `attrs`, key by key. A
    # key the provider does not carry is a miss, not a pass: a
    # requirement asking for `transactional: true` must not be satisfied
    # by a provider that never said.
    unless req['match'].nil?
      attrs = prov['attrs'] || {}
      req['match'].each do |k, want|
        return false unless attrs.key?(k)
        return false unless matchvalue(want, attrs[k])
      end
    end

    true
  end

  # PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).
  #
  # Section 11.1 defines `match` as "a partial match against `attrs`,
  # with exactly the semantics voxgig/struct and the omni corpus already
  # define for `match` - every leaf in the requirement must be present
  # and equal in the capability, keys not mentioned are not checked."
  #
  # Equality is by JSON TYPE as well as value: `transactional: 1` does
  # not satisfy `transactional: true`. RUBY NEEDS NO GUARD FOR THAT -
  # `true == 1` is already false, because TrueClass and Integer are
  # different classes with no coercion between them. Python, PHP, Perl
  # and Lua all need one, and `capability/match` pins the behaviour for
  # every port rather than trusting each language's `==`.
  #
  # An explicit `boolean?(want) != boolean?(got)` check was written here
  # first and then removed: it could never fire, and a guard that cannot
  # fire is dead code that reads as protection. A mutation deleting it
  # survived the corpus, which is what a non-mutation looks like.
  #
  # A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
  def self.matchvalue(want, got)
    if want.is_a?(Hash)
      return false unless got.is_a?(Hash)

      want.each do |k, v|
        return false unless got.key?(k)
        return false unless matchvalue(v, got[k])
      end
      return true
    end

    if want.is_a?(Array)
      return false unless got.is_a?(Array) && want.length == got.length

      return want.each_with_index.all? { |v, i| matchvalue(v, got[i]) }
    end

    want == got
  end

  def self.version_parts(text)
    text.split('.').map(&:to_i)
  end
end
