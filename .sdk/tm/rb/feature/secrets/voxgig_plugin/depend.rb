# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/depend.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Dependency cardinality, policy, and the restart graph (section 11.3).
#
# TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
# because only it knows what it can cope with:
#
#                | static (default)          | dynamic
#   -------------|---------------------------|--------------------------
#   mandatory    | unmet -> pending;         | unmet -> pending;
#   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
#                |          recursively      |          notified
#   -------------|---------------------------|--------------------------
#   optional:true| never gates activation;   | never gates activation;
#                | a change deactivates and  | a change is a
#                | reactivates               | notification, nothing else
#
# `dynamic` means the plugin has said, IN WRITING, that it can survive
# its provider being swapped underneath it. It is not the default because
# most plugins cannot, and the cost of wrongly assuming they can is a
# live instance holding a dead reference.
#
# The rebinding-preference axis is deliberately omitted. OSGi has
# reluctant vs greedy and it is a knob every author must understand to
# read anyone else's component; we take always-reluctant. Three axes were
# more than the model can carry across twenty ports.

require_relative 'types'

module VoxgigPlugin
  # A bare string is shorthand for `{name}`.
  def self.normrequire(raw)
    return { 'name' => raw } if raw.is_a?(String)

    (raw || {}).dup
  end

  # The requirements a definition declared, normalized.
  #
  # BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
  #
  # The instance-level `policy` and `optional` list are how a DOCUMENT
  # states the axis without editing the definition, and they apply to
  # every requirement. The per-requirement form is the one section 11.1's
  # object syntax exists for, and it is strictly more expressive: an
  # instance that is `static` on its store and `dynamic` on its metrics
  # cannot be written at all at the instance level.
  #
  # `optional` unions rather than overriding - both spellings are
  # statements that this requirement need not gate activation, and there
  # is no reading under which one of them means "actually, mandatory".
  def self.requirements(options)
    options ||= {}
    raw = options['requires'] || []
    marked = options['optional'] || []
    fallback = options['policy']

    raw.map do |item|
      req = normrequire(item)
      req['optional'] = true if req['optional'] || marked.include?(req['name'])
      req['policy'] = fallback if req['policy'].nil? && !fallback.nil?
      req
    end
  end

  # Does losing this requirement's SELECTED provider restart the
  # consumer? The mandatory ones under `static`, and the `static`
  # optional ones - both make a capability change deactivate and
  # reactivate. `dynamic` never restarts.
  def self.restartsonloss(req)
    (req['policy'] || 'static') != 'dynamic'
  end

  # Does an unmet requirement keep the consumer out of `live`?
  #
  # Cardinality alone decides this, NOT policy. `dynamic` is a statement
  # about surviving a SWAP, not about starting without the thing at all -
  # a mandatory-dynamic consumer still waits in `pending` for its first
  # provider.
  def self.gatesactivation(req)
    req['optional'] != true
  end

  # Edges that can cause a restart, which is exactly the set a cycle must
  # be detected over (section 11.3).
  #
  # ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
  # exclusion was for: two plugins that optionally and dynamically
  # consume each other's capabilities both activate happily, neither
  # gates on the other, and each is merely notified when the other
  # appears. Nothing restarts, so nothing oscillates.
  #
  # An earlier draft of section 11.3 excluded EVERY optional edge and
  # thereby admitted the non-terminating case it was trying to permit.
  def self.restartcausing(req)
    gatesactivation(req) || restartsonloss(req)
  end

  # A cycle through restart-causing requirements is
  # `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
  # because the failure it describes is a non-terminating reconcile and
  # the only safe time to report that is before it starts.
  #
  # The graph is over capabilities, not refs: an edge runs from a
  # consumer to EVERY node that provides what it needs, because any of
  # them could be the one selected and a cycle through any is a cycle. A
  # node also satisfies its own name as a ref (section 11.1), which is
  # why the ref is a provider of itself here.
  def self.dependencycycle(nodes)
    # TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    # matched differently - a capability by its exact name, a ref through
    # the canonical spelling (section 4 rule 5) - and one map keyed by
    # both can only do one of them. Keyed by both and looked up raw, as
    # this was, a cycle spelled `a$`/`b$` found no providers and EVADED
    # the load-time check that exists to catch a non-terminating
    # reconcile.
    bycap = {}
    isref = {}
    nodes.each do |n|
      isref[n['ref']] = true
      n['provides'].each do |cap|
        (bycap[cap] ||= []) << n['ref']
      end
    end

    edges = {}
    nodes.each do |n|
      out = []
      n['requires'].each do |req|
        next unless restartcausing(req)

        from = (bycap[req['name']] || []).dup
        # A node satisfies its own name AS A REF (section 11.1),
        # canonically - exactly what `providersof` does at runtime.
        # `canon` hands back a name no ref could have unchanged, and no
        # instance ref can equal one, so it is the tolerant test here.
        asref = VoxgigPlugin.canon(req['name'])
        from << asref if isref[asref] && !from.include?(asref)
        from.each do |p|
          out << p if p != n['ref'] && !out.include?(p)
        end
      end
      edges[n['ref']] = out.sort
    end

    # Iterative DFS with an explicit stack: twenty ports, and several of
    # them have no recursion budget worth relying on.
    white = 0
    grey = 1
    black = 2
    colour = {}
    nodes.each { |n| colour[n['ref']] = white }

    edges.keys.sort.each do |start|
      next unless colour[start] == white

      path = [start]
      stack = [[start, 0]]
      colour[start] = grey

      until stack.empty?
        top = stack[-1]
        if top[1] >= edges[top[0]].length
          colour[top[0]] = black
          stack.pop
          path.pop
          next
        end
        nxt = edges[top[0]][top[1]]
        top[1] += 1
        if colour[nxt] == grey
          # Report the cycle itself, not the walk that found it.
          return path[path.index(nxt)..] + [nxt]
        end
        next if colour[nxt] == black

        colour[nxt] = grey
        path << nxt
        stack << [nxt, 0]
      end
    end
    nil
  end

  # Raise on a cycle, naming it. Separate from the detector so the
  # detector stays pure and corpus-testable.
  def self.checkcycle(nodes)
    cycle = dependencycycle(nodes)
    return if cycle.nil?

    fail_with('plugin_dependency_cycle',
              "requirements cycle: #{cycle.join(' -> ')}", { 'cycle' => cycle })
  end
end
