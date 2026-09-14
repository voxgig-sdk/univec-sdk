# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/graph.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Whole-graph resolution (section 11.4) - a phase, not a discovery.
#
# "Activate, and wait in `pending` if you must" is correct and, on its
# own, produces a terrible experience: apply twenty instances against a
# registry missing one thing and you get NINETEEN pending rows and no
# statement of what is actually wrong.
#
# `resolve_graph` is a PURE FUNCTION of the registry and the intended
# activation set. No callbacks run, no state changes, nothing is touched.
# It answers for the whole graph at once which instances can be live, and
# for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
#
# The failure mode being designed against is a famous one: OSGi's
# resolver is correct and its diagnostics are legendarily unusable. A
# resolver that says "blocked" without saying WHY has moved the problem
# rather than solved it, so `why` is part of the contract and the corpus
# pins its shape.

require_relative 'capability'
require_relative 'version'

module VoxgigPlugin
  def self.resolve_graph(nodes)
    byref = {}
    nodes.each { |n| byref[n['ref']] = n }

    resolved = {}
    blocked = {}

    # Fixed point: a node resolves when every mandatory requirement is
    # met by an ALREADY-RESOLVED provider. Iterating to a fixed point is
    # what makes a provider that is itself blocked propagate, rather than
    # each node being judged against the raw registry.
    moved = true
    while moved
      moved = false
      nodes.each do |n|
        next if resolved[n['ref']]
        next unless firstunmet(n, byref, resolved).nil?

        resolved[n['ref']] = true
        moved = true
      end
    end

    nodes.each do |n|
      next if resolved[n['ref']]

      why = firstunmet(n, byref, resolved)
      blocked[n['ref']] = why unless why.nil?
    end

    { 'resolved' => resolved.keys.sort,
      'blocked' => blocked.keys.sort.map { |r| blocked[r] } }
  end

  # The FIRST unmet requirement, with the most specific explanation
  # available. Order matters: "no provider at all" and "a provider at the
  # wrong version" are different problems and a reader must not have to
  # guess which they have.
  def self.firstunmet(node, byref, resolved)
    (node['requires'] || []).each do |req|
      next if req['optional']

      all = graph_candidates(byref, req['name'])
      if all.empty?
        return { 'ref' => node['ref'], 'unmet' => req['name'],
                 'why' => { 'kind' => 'absent' } }
      end

      ok = resolve_capability(req, all)
      unless ok.empty?
        # A provider exists and matches - but if none of them is itself
        # resolved, this node is blocked BEHIND it, and the chain is the
        # useful answer rather than "unmet".
        next unless ok.none? { |c| resolved[c['ref']] }

        return { 'ref' => node['ref'], 'unmet' => req['name'],
                 'why' => { 'kind' => 'blocked',
                            'chain' => ok.map { |c| c['ref'] }.sort } }
      end

      # Providers exist and none matched. Say which test failed.
      unless req['range'].nil?
        versions = all.select do |c|
          c['provides']['version'].nil? ||
            !satisfiesq(c['provides']['version'], req['range'])
        end.map { |c| c['provides']['version'] || '(none)' }
        unless versions.empty?
          return { 'ref' => node['ref'], 'unmet' => req['name'],
                   'why' => { 'kind' => 'version', 'range' => req['range'],
                              'found' => versions.sort } }
        end
      end

      unless req['match'].nil?
        all.each do |c|
          attrs = c['provides']['attrs'] || {}
          req['match'].keys.sort.each do |k|
            next if attrs.key?(k) && matchvalue(req['match'][k], attrs[k])

            return { 'ref' => node['ref'], 'unmet' => req['name'],
                     'why' => { 'kind' => 'match', 'failing' => k,
                                'want' => req['match'][k],
                                'found' => attrs[k] } }
          end
        end
      end

      return { 'ref' => node['ref'], 'unmet' => req['name'],
               'why' => { 'kind' => 'absent' } }
    end
    nil
  end

  def self.graph_candidates(byref, name)
    out = []
    # A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned
    # it here. Considering only declared capabilities made `resolve`
    # answer `absent` about a provider sitting right there and live -
    # section 11.4's job is explaining the graph the runtime reconciles,
    # and it was explaining a different one.
    asref = VoxgigPlugin.canon(name)
    byref.keys.sort.each do |ref|
      node = byref[ref]
      # The ref match WINS OUTRIGHT for that node, as at runtime: one
      # candidate, not two, for a node both named `b` and providing `b`.
      if ref == asref
        out << { 'ref' => node['ref'], 'pos' => node['pos'] || 0,
                 'provides' => { 'name' => name } }
        next
      end
      (node['provides'] || []).each do |prov|
        next unless prov['name'] == name

        out << { 'ref' => node['ref'], 'pos' => node['pos'] || 0,
                 'provides' => prov }
      end
    end
    out
  end
end
