# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/point.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Extension points (section 6). Three kinds, chosen because they are what
# the two existing systems actually needed, and no more.
#
# A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
# deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
# undoable, but "this instance holds slot 3 of the request chain" is
# undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
# paper called *Listeners Considered Harmful*, and for exactly this
# reason.

require_relative 'types'

module VoxgigPlugin
  # Section 6.1: "fan-out" is not one answer but four. In a language with
  # asynchrony, "call every binding" hides a decision - start them all
  # and wait, await each in turn, or do not wait - and a design that
  # leaves it unsaid gets four different answers from four ports, in the
  # concurrency behaviour of production code no corpus entry happens to
  # cover.
  MODES = %w[emit parallel serial bail].freeze

  # Fan-out. Return values are ignored except in `bail`.
  def self.point_emit(bindings, mode, arg)
    if mode == 'bail'
      # Stops at the first binding that RETURNS A VALUE - the "handled,
      # stop" case. A `nil` RETURN DECLINES (section 6.1): ruby has one
      # way to say nothing, and the model's rule is written to that
      # rather than to JavaScript's null/undefined pair. `unless
      # v.nil?`, NOT `if v` - `false` is a value.
      bindings.each do |b|
        v = b['fn'].call(arg)
        return v unless v.nil?
      end
      return nil
    end

    errors = []
    bindings.each do |b|
      begin
        b['fn'].call(arg)
      rescue StandardError => e
        # `emit` raises synchronously; the collecting modes gather.
        raise if mode == 'emit'

        errors << e
      end
    end
    mode == 'emit' ? nil : errors
  end

  # Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).
  #
  # Recomputed by the host whenever the live set changes, and cached
  # between changes. Plugins receive `next` as an argument; they never
  # see or store the previous value of anything. A plugin that stashes
  # `next` and calls it after deactivation is a bug the host cannot
  # prevent, and this says so rather than pretending otherwise.
  def self.compose(bindings, base)
    nxt = base
    (bindings.length - 1).downto(0) do |i|
      fn = bindings[i]['fn']
      inner = nxt
      # `fn` and `inner` are block-local here, so each layer closes over
      # its own pair - ruby's blocks capture the binding, and reusing one
      # variable would leave every layer calling the last one.
      nxt = ->(*args) { fn.call(inner, *args) }
    end
    nxt
  end

  # At most one live implementation (section 6.3). The winner is the
  # highest band, ties broken by ref sort, and THE LOSERS ARE VISIBLE
  # rather than silently ignored.
  def self.point_provider(bindings, spec)
    return { 'winner' => nil, 'shadowed' => [] } if bindings.empty?

    if spec['exclusive'] && bindings.length > 1
      refs = bindings.map { |b| b['ref'] }.sort
      fail_with('plugin_point_exclusive',
                "point is exclusive and has #{bindings.length} bindings: " \
                "#{refs.join(', ')}",
                { 'refs' => refs })
    end

    ranked = Util.stable_sort_by(bindings) { |b| [-b['band'], b['ref']] }
    { 'winner' => ranked[0], 'shadowed' => ranked[1..].map { |b| b['ref'] } }
  end
end
