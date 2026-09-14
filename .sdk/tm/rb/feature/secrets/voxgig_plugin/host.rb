# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/host.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The host: the lifecycle state machine (section 5), extension points
# (section 6), and resource capture (section 8).
#
# TWO RULES SHAPE EVERY METHOD BELOW.
#
# Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
# never interleaved; a transition triggered from inside a lifecycle
# callback is `plugin_reentrant`. A hard rule, because it is the only way
# the semantics can be identical in Go, in Ruby and in single-threaded
# JavaScript.
#
# Reconciliation is EAGER (section 18's portability budget). A transition
# settles by running the state machine to a fixed point, not by
# suspending on a promise.

require_relative 'types'
require_relative 'ref'
require_relative 'catalog'
require_relative 'order'
require_relative 'point'
require_relative 'export'
require_relative 'capability'
require_relative 'config'
require_relative 'depend'

module VoxgigPlugin
  # What a definition's callbacks see. Deliberately not the internal
  # record: a plugin that could reach `status` could also write it.
  class Inst
    attr_reader :ref, :name, :tag

    def initialize(host, entry)
      @host = host
      @entry = entry
      @ref = entry['ref']
      parsed = VoxgigPlugin.parse_ref(entry['ref'])
      @name = parsed['name']
      @tag = parsed['tag']
    end

    def options
      @entry['options']
    end

    def state
      @entry['state']
    end

    def host
      @host
    end

    # Foreign resources the host did not hand out are registered
    # explicitly (section 8.3); host calls are recorded automatically.
    #
    # SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
    # resources CURRENTLY HELD, so an entry that is registered and then
    # unwound must leave the count where it found it.
    def release(&fn)
      # Section 8.3: "`inst.release` outside `activate` is
      # `plugin_release_scope`". `intransition?` is true in `define` too,
      # and a scope entry registered there is never unwound.
      unless @host.phase == 'activate'
        VoxgigPlugin.fail_with('plugin_release_scope',
                               'release called outside activate')
      end
      host = @host
      done = [false]
      @entry['scope'] << lambda {
        unless done[0]
          done[0] = true
          host.open_dec
          fn.call
        end
      }
      host.open_inc
    end

    # The synthetic counter the driver owns, so "what is open" is data
    # rather than an assertion each port words differently.
    #
    # Returns its own release, so a plugin can hand one back early. The
    # scope still holds the entry and unwinding it twice is a no-op -
    # releasing early must not make teardown wrong.
    def acquire
      # Section 8.1: resources are "acquired during `activate` - the
      # scope's actual job". Same reason as `release` above.
      unless @host.phase == 'activate'
        VoxgigPlugin.fail_with('plugin_release_scope',
                               'acquire called outside activate')
      end
      host = @host
      done = [false]
      rel = lambda {
        unless done[0]
          done[0] = true
          host.open_dec
        end
      }
      @entry['scope'] << rel
      host.open_inc
      rel
    end

    # Bind into a host point. Declared in `define`; the host inserts it
    # only after `activate` returns successfully (section 8.1), which is
    # why a failing activate leaves no live binding behind.
    def bind(point, fn, band = nil)
      # Section 12 has carried `plugin_bind_scope` - "binding declared
      # outside `define`" - since before anything raised it. Section 8.1
      # puts binding DECLARATION in `define` and INSERTION at a
      # successful activate, and the guard was the half nobody wrote: a
      # binding added from `activate` went live without being part of the
      # loaded definition, and a deactivate/activate cycle appended it
      # again.
      unless @host.phase == 'define'
        VoxgigPlugin.fail_with('plugin_bind_scope',
                               "bind called outside define: #{point}",
                               { 'ref' => @ref, 'point' => point })
      end
      unless @host.point?(point)
        VoxgigPlugin.fail_with('plugin_point_unknown', "no such point: #{point}",
                               { 'point' => point })
      end
      @entry['bindings'] << { 'ref' => @ref, 'point' => point, 'fn' => fn,
                              'band' => band || 0 }
    end

    # Published for other plugins and for the application (section 11).
    def export(key, value)
      @entry['exports'][key] = value
    end

    # What this instance can do for others (section 11.1).
    def provides(prov)
      @entry['provides'] << prov
    end

    # Where this binding landed (section 6.6) - the plugin-side
    # counterpart to a host pin. THE HOST DOES NOT POLICE THIS; it just
    # makes the fact available. Verification tells a plugin it was
    # misplaced; a pin (section 7) stops the misplacement from being
    # expressible at all. The two are not substitutes.
    def position(point)
      @host.positionof(@ref, point)
    end

    # AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE
    # OWNS THE INNER ONE'S LIFETIME. Registering the teardown in the
    # instance scope is what makes that true rather than aspirational.
    def nest(nestopts = nil)
      unless @host.intransition?
        VoxgigPlugin.fail_with('plugin_release_scope',
                               'nest called outside a lifecycle callback')
      end
      inner = Host.new(nestopts)
      @entry['scope'] << -> { inner.close }
      @entry['inner'] = inner
      inner
    end
  end

  class Host
    attr_reader :catalog

    def initialize(options = nil)
      @opts = options || {}
      @dependency = @opts['dependency'] || 'restart'
      # Set for the duration of a bulk teardown, so `held` knows this is
      # a coordinated operation rather than an ad-hoc deactivation.
      @coordinated = false

      @catalog = @opts['catalog'] || VoxgigPlugin.make_catalog
      @reserved = @opts['reserved'] || []
      @points = @opts['points'] || {}

      @inst = {}
      @log = []
      # Section 14: the lifecycle event record. `seq` distinguishes ONE
      # INCARNATION of stripe$test from the next, which is the whole
      # reason it is not `pos` (section 4 rule 4).
      @events = []
      @seqn = 0
      @open = 0
      @intransition = false
      # WHICH callback is running, not merely that one is. Section 8.1
      # puts resource capture in `activate` and 8.3 says `release`
      # outside `activate` is `plugin_release_scope` - and
      # `@intransition` alone cannot tell `activate` from `define`, so it
      # admitted an acquire in `define` whose scope `unload` would never
      # unwind.
      @phase = nil
    end

    def intransition?
      @intransition
    end

    def phase
      @phase
    end

    def point?(name)
      @points.key?(name)
    end

    def open_inc
      @open += 1
    end

    def open_dec
      @open -= 1
    end

    # --- observation ------------------------------------------------

    # Introspection NEVER advances the state (section 5.2). A status page
    # must not be a way to accidentally import twenty packages.
    def list
      @inst.keys.sort.each_with_object({}) { |r, o| o[r] = @inst[r]['status'] }
    end

    def instance(ref)
      @inst[VoxgigPlugin.canon_ref(ref)]
    end

    def trace
      @events.dup
    end

    def observable(result = nil)
      { 'status' => list, 'open' => @open, 'log' => @log.dup,
        'result' => result }
    end

    # --- the state machine ------------------------------------------

    def guard
      return unless @intransition

      VoxgigPlugin.fail_with(
        'plugin_reentrant',
        'transition attempted from inside a lifecycle callback'
      )
    end

    def need(ref)
      r = VoxgigPlugin.canon_ref(ref)
      entry = @inst[r]
      if entry.nil?
        VoxgigPlugin.fail_with('plugin_not_loaded', "no such instance: #{r}",
                               { 'ref' => r })
      end
      entry
    end

    def checkreserved(ref)
      return if @reserved.empty?
      return unless @reserved.include?(VoxgigPlugin.refname(ref))

      VoxgigPlugin.fail_with('plugin_ref_reserved',
                             "ref is reserved by the host: #{ref}",
                             { 'ref' => ref })
    end

    def run(entry, callback, at)
      fn = entry['def'][callback]
      @log << "#{entry['ref']}:#{at}"
      @events << { 'ref' => entry['ref'], 'event' => at,
                   'seq' => entry['seq'], 'status' => entry['status'] }
      return unless fn.respond_to?(:call)

      @intransition = true
      @phase = at
      begin
        fn.call(Inst.new(self, entry))
      rescue StandardError => e
        # Section 12: `plugin_define_failed` and its three siblings are
        # "a callback raised; wraps the cause". AN ERROR THAT ALREADY
        # CARRIES A CODE KEEPS IT - the code is the error's identity, and
        # a plugin raising `store_unreachable` must not have it
        # rewritten. Only a code-less error is wrapped.
        raise if e.respond_to?(:code) && e.code

        VoxgigPlugin.fail_with("plugin_#{at}_failed",
                               "#{entry['ref']} raised in #{at}: #{e.message}",
                               { 'ref' => entry['ref'], 'cause' => e.message })
      ensure
        @intransition = false
        @phase = nil
      end
    end

    # AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare('stripe',
    # {'tag' => '?'})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and
    # returns the assigned pair. Without `'?'`, a collision is an error.
    def autotag(name)
      n = 1
      loop do
        cand = VoxgigPlugin.format_ref(name, n.to_s)
        return cand unless @inst.key?(cand)

        n += 1
      end
    end

    def declare(ref, spec = nil)
      spec ||= {}
      ref = autotag(VoxgigPlugin.refname(VoxgigPlugin.canon_ref(ref))) if spec['tag'] == '?'
      r = VoxgigPlugin.canon_ref(ref)
      checkreserved(r) unless spec['hostowned']
      defname = spec['definition'] || VoxgigPlugin.refname(r)
      definition = @catalog.get(defname)
      if definition.nil?
        VoxgigPlugin.fail_with('plugin_unknown_definition',
                               "not in catalog: #{defname}", { 'name' => defname })
      end

      existing = @inst[r]
      unless existing.nil?
        # Section 4 rule 1: a pair addresses at most one instance.
        # Re-declaring the SAME definition is the idempotent case; a
        # different one is a duplicate, not a silent overwrite (seneca)
        # and not an impossibility (sdkgen).
        if existing['def']['name'] != definition['name']
          VoxgigPlugin.fail_with('plugin_ref_duplicate',
                                 "instance already declared: #{r}", { 'ref' => r })
        end
        return existing
      end

      entry = {
        'ref' => r, 'def' => definition, 'status' => 'declared',
        'pos' => spec['pos'].nil? ? @inst.length : spec['pos'],
        'seq' => @seqn,
        'options' => spec['options'] || {},
        'state' => {}, 'order' => spec['order'], 'unmet' => [], 'scope' => [],
        # Section 11.4's ALWAYS-RELUCTANT rebinding made concrete: the
        # provider ref this instance's activation actually chose, per
        # requirement name. Re-ranking on every question silently
        # re-points a live consumer at any better newcomer, and then
        # losing the provider it was really using does not restart it.
        'selected' => {},
        'bindings' => [], 'exports' => {}, 'provides' => [], 'inner' => nil
      }
      @seqn += 1
      @inst[r] = entry
      entry
    end

    # Section 9.1: a host that reserves a name MUST still be able to
    # declare the instance it reserved - "The host declares those
    # instances itself, after the user merge, and always wins."
    #
    # THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit:
    # no language here can tell the embedding host from a plugin holding
    # the same host object. What reservation protects is CONFIGURATION -
    # documents, overlays, `VOXGIG_PLUGIN_*`, construction options and
    # ordinary declare/load/options - and all of that still checks.
    def hostdeclare(ref, spec = nil)
      guard
      declare(ref, (spec || {}).merge('hostowned' => true))
    end

    def load(ref, spec = nil)
      guard
      spec ||= {}
      entry = declare(ref, spec)
      return entry if entry['status'] != 'declared' # idempotent trivially

      entry['options'] = spec['options'] if spec['options']
      begin
        run(entry, 'define', 'define')
      rescue StandardError
        entry['status'] = 'failed'
        raise
      end
      entry['status'] = 'loaded'

      # AT LOAD, and before anything runs: a cycle through
      # restart-causing requirements does not settle, and the only safe
      # time to report a non-terminating reconcile is before it starts
      # (section 11.3). `provides` is populated by `define`, which has
      # just run, so this is the first moment the graph is complete.
      begin
        VoxgigPlugin.checkcycle(graphnodes)
      rescue StandardError
        entry['status'] = 'failed'
        raise
      end
      entry
    end

    # The requirement graph as plain data, for the pure detector.
    def graphnodes
      @inst.keys.sort.map do |r|
        { 'ref' => r,
          'provides' => @inst[r]['provides'].map { |p| p['name'] },
          'requires' => VoxgigPlugin.requirements(@inst[r]['options']) }
      end
    end

    def activate(ref)
      guard
      entry = need(ref)
      return entry if entry['status'] == 'live' # no-op returning success

      if entry['status'] == 'failed'
        VoxgigPlugin.fail_with('plugin_bad_state',
                               "instance has failed: #{entry['ref']}",
                               { 'ref' => entry['ref'] })
      end
      # Section 9.6: `active: false` bars the instance from running, and
      # the bar is on the INSTANCE rather than on the apply that set it.
      # `ready` reaches this through `activate`, so one guard covers both
      # verbs the design names.
      if entry['barred']
        VoxgigPlugin.fail_with('plugin_inactive',
                               "instance is barred by active: false: #{entry['ref']}",
                               { 'ref' => entry['ref'] })
      end
      load(entry['ref']) if entry['status'] == 'declared'

      # A declared requirement that is not live means `pending`:
      # activation is a STANDING REQUEST, not a one-shot event.
      unmet = unmetof(entry)
      unless unmet.empty?
        entry['unmet'] = unmet
        entry['status'] = 'pending'
        return entry
      end

      begin
        run(entry, 'activate', 'activate')
      rescue StandardError
        # Unwind whatever the partial activation captured, in reverse.
        unwind(entry)
        entry['status'] = 'failed'
        raise
      end
      # Section 11.4: THE SELECTION IS MADE HERE, once, and remembered.
      # Every later question - the cascade, `hold`, `unmet` - reads it
      # back rather than re-ranking, which is what "always-reluctant"
      # means.
      VoxgigPlugin.requirements(entry['options']).each do |req|
        chosen(entry, req, true)
      end
      entry['status'] = 'live'
      reconcile
      entry
    end

    def deactivate(ref)
      guard
      entry = need(ref)
      return entry if %w[loaded declared].include?(entry['status'])

      # Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
      if entry['status'] == 'failed'
        VoxgigPlugin.fail_with('plugin_bad_state',
                               "instance has failed: #{entry['ref']}",
                               { 'ref' => entry['ref'] })
      end

      if entry['status'] == 'pending'
        # DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2).
        # It never reached activate, so it holds no scope and no live
        # bindings; running the definition's deactivate there would be
        # teardown without matching setup, which plugins are not written
        # to survive and which could fail an instance that had done
        # nothing wrong. It cannot fail.
        entry['status'] = 'loaded'
        entry['unmet'] = []
        return entry
      end

      held(entry)
      cascade(entry, {})

      begin
        run(entry, 'deactivate', 'deactivate')
      rescue StandardError
        unwind(entry)
        entry['status'] = 'failed'
        raise
      end
      releasecheck(entry, unwind(entry))
      entry['status'] = 'loaded'
      reconcile
      entry
    end

    def unload(ref)
      guard
      entry = need(ref)
      if %w[live pending].include?(entry['status'])
        if entry['status'] == 'live'
          held(entry)
          cascade(entry, {})
          begin
            run(entry, 'deactivate', 'deactivate')
          rescue StandardError
            # Section 5.2: ANY failure during a transition lands the
            # instance in `failed`, with the scope STILL FULLY UNWOUND -
            # and the instance STAYS REGISTERED, because `failed` is a
            # state an operator has to be able to see.
            unwind(entry)
            entry['status'] = 'failed'
            raise
          end
          releasecheck(entry, unwind(entry))
        end
        entry['status'] = 'loaded'
      end
      if %w[loaded failed].include?(entry['status'])
        begin
          run(entry, 'close', 'close')
        ensure
          @inst.delete(entry['ref'])
        end
        return
      end
      @inst.delete(entry['ref'])
    end

    # Runs the whole forward path in one call (section 5.1).
    def ready(ref)
      guard
      r = VoxgigPlugin.canon_ref(ref)
      declare(r) unless @inst.key?(r)
      load(r) if @inst[r]['status'] == 'declared'
      activate(r)
    end

    # Bindings go live only when activation succeeds (section 8.1), so
    # the teardown is the exact inverse: reverse order, always.
    # Returns the errors the scope raised. Section 8.3: "A failing
    # release does not stop the rest. Every entry runs, in reverse order,
    # whatever any of them does; the errors are collected and raised as
    # one `plugin_release_failed`."
    # A selection belongs to ONE activation (section 11.4). Leaving
    # `live` by any door drops it, so the next activation ranks afresh -
    # keeping it would make a consumer prefer a provider it never
    # actually ran against.
    def unwind(entry)
      entry['selected'] = {}
      errors = []
      entry['scope'].reverse_each do |fn|
        fn.call
      rescue StandardError => e
        errors << e
      end
      entry['scope'] = []
      errors
    end

    # Section 8.3: "A failed release ends the instance in `failed`,
    # exactly as a failed callback does (5.2) - a release that raised may
    # have leaked, and an instance that may be holding resources it
    # cannot account for must not be reactivated."
    def releasecheck(entry, errors)
      return if errors.empty?

      entry['status'] = 'failed'
      causes = errors.map(&:message)
      VoxgigPlugin.fail_with('plugin_release_failed',
                             "release failed for #{entry['ref']}: #{causes.join('; ')}",
                             { 'ref' => entry['ref'], 'cause' => causes })
    end

    # A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A
    # bare string is shorthand for `{name}`. A ref satisfies too, because
    # a host that genuinely needs a specific instance should not have to
    # invent a capability for it.
    def unmetof(entry)
      VoxgigPlugin.requirements(entry['options'])
                  .select { |r| VoxgigPlugin.gatesactivation(r) }
                  .select { |r| providersof(r).empty? }
                  .map { |r| r['name'] }
    end

    # The instance currently SELECTED for each of this one's
    # restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
    # capability (section 11.1): the selected one going away restarts a
    # `static` consumer even though a survivor is available.
    # Section 11.4's always-reluctant selection, and the ONE place a
    # provider is picked for a live instance. If this instance already
    # selected a provider for `req` and that provider is STILL a
    # candidate, it keeps it - a better-ranked newcomer does not take it.
    # `remember` is false for the questions asked ABOUT an instance
    # rather than BY it: introspection must not create a binding.
    def chosen(entry, req, remember)
      cands = providersof(req)
      return nil if cands.empty?

      held = entry['selected'][req['name']]
      return held if !held.nil? && cands.any? { |c| c['ref'] == held }

      entry['selected'][req['name']] = cands[0]['ref'] if remember
      cands[0]['ref']
    end

    def boundproviders(entry)
      out = []
      VoxgigPlugin.requirements(entry['options']).each do |req|
        next unless VoxgigPlugin.restartsonloss(req)

        ref = chosen(entry, req, false)
        out << ref if !ref.nil? && !out.include?(ref)
      end
      out
    end

    # Live instances whose selected provider is `ref` and which would be
    # restarted by losing it.
    def consumersof(ref)
      @inst.keys.sort.select do |r|
        c = @inst[r]
        r != ref && c['status'] == 'live' && boundproviders(c).include?(ref)
      end
    end

    # Section 11.3's `hold` asks a DIFFERENT question from the cascade,
    # and reading it off `consumersof` answered the cascade's.
    #
    # The cascade wants the edges that RESTART - mandatory-static and
    # optional-static - because a restart is what it performs. `hold`
    # says "deactivating a REQUIRED instance is
    # `plugin_dependency_held`", and required is cardinality:
    # `gatesactivation`, not `restartsonloss`. The two sets differ in
    # both directions and each difference was a real bug.
    #
    # A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy
    # let a provider go that a live consumer could not do without -
    # `dynamic` promises survival of a SWAP, and under `hold` there is
    # no swap, so the consumer falls back to `pending`.
    #
    # An OPTIONAL-STATIC consumer was included, so `hold` refused a
    # deactivation on behalf of an instance that had said in writing it
    # does not need the thing.
    def holdersof(ref)
      @inst.keys.sort.select do |r|
        c = @inst[r]
        next false if r == ref || c['status'] != 'live'

        VoxgigPlugin.requirements(c['options']).any? do |req|
          next false unless VoxgigPlugin.gatesactivation(req)

          chosen(c, req, false) == ref
        end
      end
    end

    def providersof(req)
      cands = []
      want = VoxgigPlugin.canon(req['name'])
      @inst.keys.sort.each do |ref|
        target = @inst[ref]
        next unless target['status'] == 'live'

        # A ref satisfies directly.
        if ref == want
          cands << { 'ref' => ref, 'pos' => target['pos'],
                     'provides' => { 'name' => req['name'] } }
          next
        end
        target['provides'].each do |prov|
          cands << { 'ref' => ref, 'pos' => target['pos'], 'provides' => prov } \
            if prov['name'] == req['name']
        end
      end
      VoxgigPlugin.resolve_capability(req, cands)
    end

    # CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
    #
    # The cascade is part of the provider's own deactivation and runs
    # BEFORE the provider's `deactivate` callback and scope unwind, so a
    # consumer's teardown can still call the thing it depends on -
    # flushing a buffer to the store it is about to lose is exactly what
    # a `deactivate` callback is for, and a cascade that fired after the
    # provider was already gone would make that impossible.
    def cascade(provider, seen)
      return if seen[provider['ref']]

      seen[provider['ref']] = true

      consumersof(provider['ref']).each do |r|
        consumer = @inst[r]
        next unless consumer['status'] == 'live'

        cascade(consumer, seen) # deepest-first
        bad = false
        begin
          run(consumer, 'deactivate', 'deactivate')
        rescue StandardError
          bad = true
        end
        errors = unwind(consumer)
        if bad || !errors.empty?
          # Section 5.2: ANY failure during a transition lands the
          # instance in `failed`. Marking it `pending` handed it straight
          # back to `reconcile`, which would activate it again the moment
          # the provider returned.
          consumer['status'] = 'failed'
          next
        end
        consumer['status'] = 'pending'
        consumer['unmet'] = unmetof(consumer)
      end
    end

    # The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON
    # COORDINATED TEARDOWN. In a bulk operation that is removing the
    # holders too - `close`, or an `apply` plan whose own steps
    # deactivate them - it is suspended for exactly those holders, and
    # the teardown still runs consumers before providers.
    def held(entry)
      return unless @dependency == 'hold'
      return if @coordinated

      holders = holdersof(entry['ref'])
      return if holders.empty?

      VoxgigPlugin.fail_with('plugin_dependency_held',
                             "instance is required by live consumers: #{entry['ref']}",
                             { 'ref' => entry['ref'], 'holders' => holders })
    end

    # EAGER reconciliation: run to a fixed point rather than scheduling.
    #
    # Two directions, and both are the reason `pending` exists.
    # Activation is a STANDING REQUEST, not a one-shot event.
    def reconcile
      moved = true
      rounds = 0
      while moved
        moved = false
        rounds += 1
        break if rounds > 1000

        # Losses first, so a cascade settles in one pass rather than
        # alternating with re-activations.
        @inst.keys.sort.each do |r|
          entry = @inst[r]
          next unless entry['status'] == 'live'

          lost = VoxgigPlugin.requirements(entry['options'])
                             .select { |q| VoxgigPlugin.gatesactivation(q) }
                             .select { |q| providersof(q).empty? }
          next if lost.empty?
          # POLICY IS PER REQUIREMENT, not per instance (section 11.3). A
          # `dynamic` requirement whose provider is gone leaves the
          # consumer LIVE and notified.
          next unless lost.any? { |q| VoxgigPlugin.restartsonloss(q) }

          bad = false
          begin
            run(entry, 'deactivate', 'deactivate')
          rescue StandardError
            bad = true
          end
          errors = unwind(entry)
          if bad || !errors.empty?
            entry['status'] = 'failed'
            moved = true
            next
          end
          entry['status'] = 'pending'
          entry['unmet'] = unmetof(entry)
          moved = true
        end

        @inst.keys.sort.each do |r|
          entry = @inst[r]
          next unless entry['status'] == 'pending'
          next unless unmetof(entry).empty?

          begin
            run(entry, 'activate', 'activate')
            entry['status'] = 'live'
            entry['unmet'] = []
            moved = true
          rescue StandardError
            unwind(entry)
            entry['status'] = 'failed'
            moved = true
          end
        end
      end
    end

    # --- ordering ---------------------------------------------------

    def order(point = nil)
      # Sorted by declaration SEQUENCE, which is what makes the section 7
      # sort's fall-through deterministic in a language whose maps have
      # no insertion order. Section 7 breaks ties by `pos`; two instances
      # CAN share one - `declare` defaults `pos` to the registry size, so
      # an unload followed by a fresh declare reuses a surviving
      # instance's - and past that this was falling through to hash
      # order. `seq` is that order, made explicit.
      bindings = @inst.keys.select { |r| @inst[r]['status'] == 'live' }
                      .sort_by { |r| @inst[r]['seq'] }
                      .map do |r|
        { 'ref' => r, 'pos' => @inst[r]['pos'], 'order' => @inst[r]['order'] }
      end
      spec = point ? @points[point] : nil
      VoxgigPlugin.resolve_order(bindings, spec ? spec['pin'] : nil)
    end

    # --- points -----------------------------------------------------

    # Live bindings on a point, in resolved order. Recomputed on any
    # change to the live set (section 7) rather than cached at startup -
    # the bug a host discovers only when something deactivates in
    # production.
    def bound(point)
      out = []
      order(point).each do |ref|
        entry = @inst[ref]
        # The band is the INSTANCE's ordering block (section 7), stamped
        # by the host. A plugin passing its own would be ranking itself
        # above the order its document declared.
        block = entry['order'] || {}
        band = block['band'].is_a?(Integer) ? block['band'] : 0
        entry['bindings'].each do |b|
          out << b.merge('band' => band) if b['point'] == point
        end
      end
      out
    end

    def pointspec(point, want)
      spec = @points[point]
      if spec.nil?
        VoxgigPlugin.fail_with('plugin_point_unknown', "no such point: #{point}",
                               { 'point' => point })
      end
      kind = spec['kind']
      if want == 'hook'
        # A point with no declared kind is a hook, which is what makes
        # `{}` the minimal point declaration.
        if kind && kind != 'hook'
          VoxgigPlugin.fail_with('plugin_point_kind', "point is not a hook: #{point}",
                                 { 'point' => point, 'kind' => kind })
        end
        return spec
      end
      unless kind == want
        VoxgigPlugin.fail_with('plugin_point_kind',
                               "point is not a #{want}: #{point}",
                               { 'point' => point, 'kind' => kind })
      end
      spec
    end

    def emit(point, arg = nil)
      spec = pointspec(point, 'hook')
      VoxgigPlugin.point_emit(bound(point), spec['mode'] || 'emit', arg)
    end

    def call(point, *args)
      spec = pointspec(point, 'chain')
      base = spec['base'] || ->(*a) { a[0] }
      VoxgigPlugin.compose(bound(point), base).call(*args)
    end

    def provider(point, *args)
      spec = pointspec(point, 'provider')
      pick = VoxgigPlugin.point_provider(bound(point), spec)
      return spec['default'] if pick['winner'].nil?

      pick['winner']['fn'].call(*args)
    end

    # The losers are VISIBLE rather than silently ignored (section 6.3).
    def shadowed(point)
      spec = @points[point]
      return [] if spec.nil?

      VoxgigPlugin.point_provider(bound(point), spec)['shadowed']
    end

    def exports(spec)
      all = []
      @inst.keys.sort.each do |ref|
        entry = @inst[ref]
        # Exports of a `loaded` (not live) instance are VISIBLE (11).
        next if %w[declared failed].include?(entry['status'])

        entry['exports'].keys.sort.each do |k|
          all << { 'ref' => ref, 'key' => k, 'value' => entry['exports'][k] }
        end
      end
      VoxgigPlugin.resolve_export(spec, all)
    end

    # The live providers of a capability, best-first (section 11.1).
    def capability(name)
      cands = []
      @inst.keys.sort.each do |ref|
        entry = @inst[ref]
        next unless entry['status'] == 'live'

        entry['provides'].each do |prov|
          cands << { 'ref' => ref, 'pos' => entry['pos'], 'provides' => prov } \
            if prov['name'] == name
        end
      end
      VoxgigPlugin.resolve_capability({ 'name' => name }, cands).map { |c| c['ref'] }
    end

    # --- documents --------------------------------------------------

    # Section 9.6: "load what is missing, UNLOAD WHAT IS GONE, patch
    # what changed, and move activation state to match", with the stated
    # ordering - "deactivations and unloads first (reverse load order),
    # then loads, then activations in load order".
    #
    # FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
    # document once, which never looked at instances the new document had
    # DROPPED - so an integration removed from a config reload stayed live
    # with its bindings and resources.
    def apply(doc, profile = nil)
      guard
      profile ||= @opts['profile']
      norm = VoxgigPlugin.normalize_config(
        { 'doc' => doc, 'profile' => profile,
          'keys' => @opts['keys'], 'reserved' => @reserved }
      )

      want = norm['order']
      defaults = @opts['defaults'] || {}
      optionsof = {}
      want.each do |ref|
        optionsof[ref] = VoxgigPlugin.resolve_options(
          { 'ref' => ref, 'doc' => doc, 'profile' => profile,
            'shape' => shapeof(ref),
            'hostdefaults' => defaults[VoxgigPlugin.refname(ref)] }
        )
      end

      # Should this ref be LIVE after the apply? False for a ref the
      # document declares lazy or inactive AND for one it does not name
      # at all - which is what makes "unload what is gone" and "unload
      # what was toggled off" one rule rather than two.
      wantlive = lambda do |ref|
        ent = norm['instance'][ref]
        !ent.nil? && ent['active'] && ent['start'] == 'eager'
      end

      # --- phase 1: deactivations and unloads, REVERSE load order ----
      drop = @inst.keys.reject do |r|
        @inst[r]['status'] == 'declared' || wantlive.call(r)
      end
      # Highest `pos` first, ref-descending for a tie, so a consumer
      # declared after its provider goes down first.
      drop = drop.sort_by { |r| [-@inst[r]['pos'], r] }
                 .chunk_while { |a, b| @inst[a]['pos'] == @inst[b]['pos'] }
                 .flat_map(&:reverse)
      drop.each { |ref| unload(ref) }

      # --- phase 2: declare and patch EVERYTHING, in load order ------
      want.each do |ref|
        ent = norm['instance'][ref]
        # NO OPTIONS HERE, and the omission is the fix rather than an
        # oversight. `declare` ADOPTS the options map it is handed as the
        # instance's own, so passing the resolved map made target and
        # source THE SAME MAP in the refill below - which cleared its own
        # source and left a first-time instance with no options at all.
        # `declare` makes its own empty map and the refill fills it, so
        # both paths are now one path.
        declare(ref, { 'order' => ent['order'], 'pos' => ent['pos'] })
        # The bar is REASSERTED ON EVERY APPLY, in both directions - a
        # document that turns the instance back on clears it, which is
        # the whole point of a config switch.
        @inst[ref]['barred'] = !ent['active']
        # REFILL rather than REBIND. A definition's callbacks close over
        # the options map they were handed at `define`.
        refill(@inst[ref]['options'], optionsof[ref])
        @inst[ref]['order'] = ent['order']
        @inst[ref]['pos'] = ent['pos']
      end

      # --- phase 3: loads, in load order -----------------------------
      # ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances
      # is twenty map entries and no executed code" (9.6).
      want.each { |ref| load(ref) if wantlive.call(ref) }

      # --- phase 4: activations, in load order -----------------------
      want.each { |ref| activate(ref) if wantlive.call(ref) }
    end

    def shapeof(ref)
      definition = @catalog.get(VoxgigPlugin.refname(ref))
      definition ? definition['shape'] : nil
    end

    def options(ref, patch)
      guard
      entry = need(ref)
      previous = entry['options'].dup
      refill(entry['options'], VoxgigPlugin.resolve_options(
                                 { 'ref' => entry['ref'],
                                   'shape' => shapeof(entry['ref']),
                                   'doc' => {},
                                   'patch' => previous.merge(patch || {}) }
                               ))
      return unless entry['status'] == 'live'

      reconfigure = entry['def']['reconfigure']
      if reconfigure.respond_to?(:call)
        @intransition = true
        begin
          reconfigure.call(Inst.new(self, entry), entry['options'], previous)
        ensure
          @intransition = false
        end
      else
        # Always correct and sometimes expensive; `reconfigure` exists to
        # make the common case cheap (section 9.4).
        deactivate(entry['ref'])
        activate(entry['ref'])
      end
    end

    # Empty the target and refill it, so callers holding the reference
    # see the new values.
    def refill(target, source)
      target.clear
      (source || {}).each { |k, v| target[k] = v }
    end

    def close
      # A bulk teardown removing the holders too, so `hold` is suspended
      # for exactly those holders (section 11.3) - while the
      # consumers-first cascade still runs, which is the half that
      # matters.
      @coordinated = true
      begin
        @inst.keys.sort.reverse.each { |r| unload(r) }
      ensure
        @coordinated = false
      end
    end

    # The same record section 6.6 gives a plugin about itself, reachable
    # from outside for the corpus.
    def positionof(ref, point)
      entry = @inst[VoxgigPlugin.canon(ref)]
      if entry.nil?
        VoxgigPlugin.fail_with('plugin_not_loaded', "no such instance: #{ref}",
                               { 'ref' => ref })
      end
      ranked = order(point)
      index = ranked.index(entry['ref']) || -1
      { 'index' => index, 'count' => ranked.length,
        # Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
        # OUTERMOST, so these are not index 0 and index count-1 the other
        # way round.
        'outermost' => index.zero?,
        'innermost' => index == ranked.length - 1 }
    end

    def define(definition)
      @catalog.add(definition)
    end
  end

  def self.make_host(options = nil)
    Host.new(options)
  end
end
