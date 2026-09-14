# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/order.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Ordering (section 7) - one rule, one place.
#
# sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
# and the third was not far off. This sort is the whole replacement, and
# the tiers are in this order for a reason:
#
#   1 constraints   before/after edges, by ref or by name
#   2 bands         integer, lower first, default 0
#   3 declaration   ties break by `pos`
#
# CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
# present. A band expresses a genuine cross-cutting layer; a constraint
# expresses a relationship between two specific things; and a band chosen
# by trial and error to fix an ordering bug is a bug wearing a number.

require_relative 'types'
require_relative 'ref'

module VoxgigPlugin
  def self.resolve_order(bindings, pin = nil)
    nodes = bindings.dup
    byref = {}
    nodes.each { |b| byref[b['ref']] = b }

    # Constraints are edges. A constraint naming an ABSENT binding is
    # satisfied VACUOUSLY (section 7) - a plugin ordered `after: 'test'`
    # must load in a host with no test plugin. That is sdkgen's
    # __after__ behaviour, kept.
    edges = {}
    nodes.each { |b| edges[b['ref']] = [] }

    nodes.each do |b|
      block = b['order'] || {}
      # An ABSENT constraint and an EMPTY LIST are both "no constraint".
      if order_declared(block['after'])
        order_targets(block['after'], nodes).each { |t| edges[t] << b['ref'] }
      end
      if order_declared(block['before'])
        order_targets(block['before'], nodes).each { |t| edges[b['ref']] << t }
      end
    end

    # Stable topological sort. Among ready nodes, band first (lower runs
    # first), then `pos` - the position the DOCUMENT visibly states, not
    # the order instances happened to load and not the incarnation `seq`.
    indeg = {}
    nodes.each { |b| indeg[b['ref']] = 0 }
    edges.each_value { |tos| tos.each { |to| indeg[to] += 1 } }

    out = []
    ready = nodes.select { |b| indeg[b['ref']].zero? }

    until ready.empty?
      ready = Util.stable_sort_by(ready) { |b| [order_band(b), b['pos'] || 0] }
      nxt = ready.shift
      out << nxt['ref']
      edges[nxt['ref']].each do |to|
        indeg[to] -= 1
        ready << byref[to] if indeg[to].zero?
      end
    end

    if out.length != nodes.length
      stuck = nodes.reject { |b| out.include?(b['ref']) }.map { |b| b['ref'] }
      fail_with('plugin_order_cycle',
                "before/after constraints cycle: #{stuck.join(' -> ')}",
                { 'cycle' => stuck })
    end

    applypin(out, edges, pin)
  end

  def self.order_band(binding)
    block = binding['order'] || {}
    value = block['band']
    value.is_a?(Integer) ? value : 0
  end

  # Matching is by REF, or by NAME across all of that definition's
  # instances (section 7) - which is the whole reason the two spellings
  # exist.
  # Was a constraint stated? An absent value and an EMPTY LIST are both
  # no-constraint - and [] is truthy in Ruby, which is exactly how this
  # class of bug survives a reading.
  def self.order_declared(spec)
    return false if spec.nil?
    return spec.any? { |one| '' != one } if spec.is_a?(Array)

    '' != spec
  end

  # One spelling or a LIST of them. A list fans out to the UNION of what
  # each names, so after: ['a','b'] means after BOTH, and the same
  # instance named twice - once by name, once by ref - is one edge.
  def self.order_targets(spec, nodes)
    specs = spec.is_a?(Array) ? spec : [spec]
    hit = []
    specs.each do |one|
      nodes.each do |b|
        next if hit.include?(b['ref'])

        hit << b['ref'] if b['ref'] == one || refname(b['ref']) == one
      end
    end
    hit
  end

  # A PIN IS NOT A CONSTRAINT (section 7).
  #
  # Constraints and bands are negotiable by definition - they are what
  # plugins and documents say they want, and the sort's job is to satisfy
  # them all. A pin is the host stating a structural invariant of its own
  # architecture, which is a different kind of claim and must not lose a
  # tie to a document.
  #
  # So a pin PLACES the binding at the named end, and an ordering that
  # would move it away is `plugin_order_pinned` - rejected, not honoured
  # into a broken wrap.
  def self.applypin(order, edges, pin)
    return order if pin.nil?

    out = order.dup

    # SORTED, not insertion order. A pin map is data - it can arrive from
    # a host's own construction options in any order, and two names
    # pinned to the same end are order-sensitive (`{b:'first',
    # a:'first'}` and `{a:'first', b:'first'}` give different results).
    # Ruby hashes are insertion-ordered and a Go map has no order at all,
    # so leaving it unstated made the same declaration mean different
    # things in different ports.
    pin.keys.sort.each do |name|
      want = pin[name]
      idx = out.index { |r| refname(r) == name }
      next if idx.nil?

      # `first`/`outermost` is index 0; `last`/`innermost` is the end.
      # Section 6.2 makes the first chain binding outermost, which is why
      # the vocabulary is positional and why the two spellings pair this
      # way.
      wantfirst = %w[first outermost].include?(want)
      ref = out.delete_at(idx)
      wantfirst ? out.unshift(ref) : out.push(ref)
    end

    # Now check that the placement did not break a constraint. This is
    # the half that makes a pin a rejection rather than an override: the
    # host wins on position, but it does not get to silently discard a
    # relationship a plugin declared.
    at = {}
    out.each_with_index { |r, i| at[r] = i }
    edges.each do |from, tos|
      tos.each do |to|
        next unless at[from] > at[to]

        fail_with('plugin_order_pinned',
                  'a pin would move a binding an ordering constrains: ' \
                  "#{from} must precede #{to}",
                  { 'before' => from, 'after' => to })
      end
    end

    out
  end
end
