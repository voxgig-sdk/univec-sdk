# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/host.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Host do
  @moduledoc """
  The host: the lifecycle state machine (section 5), extension points
  (section 6), and resource capture (section 8).

  TWO RULES SHAPE EVERY FUNCTION BELOW.

  Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
  never interleaved; a transition triggered from inside a lifecycle
  callback is `plugin_reentrant`. A hard rule, because it is the only way
  the semantics can be identical in Go, in Ruby and in single-threaded
  JavaScript.

  Reconciliation is EAGER (section 18's portability budget). A transition
  settles by running the state machine to a fixed point, not by suspending
  on a promise.

  THE HOST IS THE ONE MUTABLE THING IN THIS PORT, and it is an `Agent`
  because elixir has no other way to hold state that outlives a call. Two
  consequences are worth stating plainly, because both are easy to get
  wrong and neither is visible from a green corpus.

  CALLBACKS RUN OUTSIDE THE AGENT. Every function here executes in the
  CALLER's process and reaches the agent only for short reads and writes;
  a definition's `activate` is never invoked from inside `Agent.update`.
  Running one there would deadlock the moment it called back into its own
  host - which section 5.2 requires to raise `plugin_reentrant`, an answer
  that cannot be given by a process waiting on itself.

  THE AGENT IS NOT A CONCURRENCY BOUNDARY. It serializes individual reads
  and writes and nothing larger: two processes calling `activate` at once
  would interleave transitions, which section 5.2 forbids and which no
  amount of process discipline here would fix, because the interleaving is
  in the CALLER's control flow. The contract is sequential use; the agent
  provides the mutable cell, not the ordering.
  """

  import Kernel, except: [apply: 2, apply: 3]

  alias Voxgig.Plugin.Capability
  alias Voxgig.Plugin.Catalog
  alias Voxgig.Plugin.Config
  alias Voxgig.Plugin.Depend
  alias Voxgig.Plugin.Export
  alias Voxgig.Plugin.Inst
  alias Voxgig.Plugin.Order
  alias Voxgig.Plugin.Point
  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types

  defstruct [:pid]

  def make_host(options \\ nil) do
    opts = options || %{}

    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          opts: opts,
          dependency: Types.get(opts, "dependency") || "restart",
          # Set for the duration of a bulk teardown, so `held` knows this
          # is a coordinated operation rather than an ad-hoc deactivation.
          coordinated: false,
          catalog: Types.get(opts, "catalog") || Catalog.make_catalog(),
          reserved: Types.get(opts, "reserved") || [],
          points: Types.get(opts, "points") || %{},
          inst: %{},
          # Both accumulate at the HEAD and are reversed on the way out:
          # appending to the tail of a list is O(n) here, and section 14's
          # trace is written on every callback of every transition.
          log: [],
          events: [],
          seqn: 0,
          open: 0,
          scopeid: 0,
          intransition: false,
          # WHICH callback is running, not merely that one is. Section 8.1
          # puts resource capture in `activate` and 8.3 says `release`
          # outside `activate` is `plugin_release_scope` - and
          # `intransition` alone cannot tell `activate` from `define`, so
          # it admitted an acquire in `define` whose scope `unload` would
          # never unwind.
          phase: nil
        }
      end)

    %__MODULE__{pid: pid}
  end

  # --- the agent, and the only four ways this module touches it -------

  defp read(%__MODULE__{pid: pid}, fun), do: Agent.get(pid, fun)

  defp write(%__MODULE__{pid: pid}, fun), do: Agent.update(pid, fun)

  defp swap(%__MODULE__{pid: pid}, fun), do: Agent.get_and_update(pid, fun)

  defp ent(host, ref), do: read(host, &Map.get(&1.inst, ref))

  @doc false
  def field(host, ref, key), do: read(host, &get_in(&1.inst, [ref, key]))

  @doc false
  def entry_update(host, ref, fun) do
    write(host, fn st -> %{st | inst: Map.update!(st.inst, ref, fun)} end)
  end

  defp setfield(host, ref, key, value), do: entry_update(host, ref, &Map.put(&1, key, value))

  defp refs(host), do: read(host, &(&1.inst |> Map.keys() |> Enum.sort()))

  # --- what the instance api needs ------------------------------------

  def intransition?(host), do: read(host, & &1.intransition)

  def phase(host), do: read(host, & &1.phase)

  def point?(host, name), do: read(host, &Map.has_key?(&1.points, name))

  def catalog(host), do: read(host, & &1.catalog)

  @doc """
  Extend a LIVE host's catalog. The catalog is a value (see `Catalog`), so
  a caller holding one just keeps the result of `Catalog.add/2`; this is
  for the one that holds a host instead. Validation runs HERE, outside the
  agent, so an invalid definition raises in the caller rather than killing
  the process that holds the registry.
  """
  def catalog_add(host, definition) do
    updated = Catalog.add(catalog(host), definition)
    write(host, &%{&1 | catalog: updated})
    :ok
  end

  def define(host, definition), do: catalog_add(host, definition)

  @doc """
  Register a scope entry and count it open. Returns its own release, which
  is idempotent because releasing POPS THE ENTRY BY ID: a second call finds
  nothing and does nothing, and so does one made after the whole scope
  unwound.
  """
  def scope_push(host, ref, fun, message) do
    if "activate" != phase(host), do: Types.fail("plugin_release_scope", message)

    id =
      swap(host, fn st ->
        entry = %{id: st.scopeid, fun: fun, open: 1}

        {st.scopeid,
         %{st
           | scopeid: st.scopeid + 1,
             open: st.open + 1,
             inst: update_in(st.inst, [ref, "scope"], &(&1 ++ [entry]))}}
      end)

    fn -> scope_release(host, ref, id) end
  end

  @doc false
  def scope_uncounted(host, ref, fun) do
    write(host, fn st ->
      entry = %{id: st.scopeid, fun: fun, open: 0}

      %{st
        | scopeid: st.scopeid + 1,
          inst: update_in(st.inst, [ref, "scope"], &(&1 ++ [entry]))}
    end)
  end

  defp scope_release(host, ref, id) do
    fun =
      swap(host, fn st ->
        scope = get_in(st.inst, [ref, "scope"]) || []

        case Enum.find(scope, &(&1.id == id)) do
          nil ->
            {nil, st}

          one ->
            {one.fun,
             %{st
               | open: st.open - one.open,
                 inst: put_in(st.inst, [ref, "scope"], Enum.reject(scope, &(&1.id == id)))}}
        end
      end)

    if fun, do: fun.()
    :ok
  end

  # --- observation ----------------------------------------------------

  @doc """
  Introspection NEVER advances the state (section 5.2). A status page must
  not be a way to accidentally import twenty packages.
  """
  def list(host) do
    read(host, fn st -> Map.new(st.inst, fn {ref, e} -> {ref, e["status"]} end) end)
  end

  def instance(host, ref), do: ent(host, Ref.canon_ref(ref))

  def trace(host), do: read(host, &Enum.reverse(&1.events))

  def observable(host, result \\ nil) do
    read(host, fn st ->
      %{"status" => Map.new(st.inst, fn {ref, e} -> {ref, e["status"]} end),
        "open" => st.open,
        "log" => Enum.reverse(st.log),
        "result" => result}
    end)
  end

  # --- the state machine ----------------------------------------------

  defp guard(host) do
    if intransition?(host) do
      Types.fail("plugin_reentrant", "transition attempted from inside a lifecycle callback")
    end
  end

  defp need(host, ref) do
    r = Ref.canon_ref(ref)
    entry = ent(host, r)
    if is_nil(entry), do: Types.fail("plugin_not_loaded", "no such instance: #{r}", %{"ref" => r})
    entry
  end

  defp checkreserved(host, ref) do
    if Ref.refname(ref) in read(host, & &1.reserved) do
      Types.fail("plugin_ref_reserved", "ref is reserved by the host: #{ref}", %{"ref" => ref})
    end
  end

  defp run(host, ref, callback, at) do
    entry = ent(host, ref)
    fun = Types.get(entry["def"], callback)

    write(host, fn st ->
      %{st
        | log: ["#{ref}:#{at}" | st.log],
          events: [
            %{"ref" => ref, "event" => at, "seq" => entry["seq"], "status" => entry["status"]}
            | st.events
          ]}
    end)

    if is_function(fun, 1), do: invoke(host, ref, fun, at)
    :ok
  end

  defp invoke(host, ref, fun, at) do
    write(host, &%{&1 | intransition: true, phase: at})

    try do
      fun.(%Inst{host: host, ref: ref})
    rescue
      e ->
        # Section 12: `plugin_define_failed` and its three siblings are "a
        # callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES
        # A CODE KEEPS IT - the code is the error's identity, and a plugin
        # raising `store_unreachable` must not have it rewritten. Only a
        # code-less error is wrapped.
        if "" != Types.codeof(e) do
          reraise(e, __STACKTRACE__)
        else
          Types.fail("plugin_#{at}_failed", "#{ref} raised in #{at}: #{Types.message(e)}",
                     %{"ref" => ref, "cause" => Types.message(e)})
        end
    after
      write(host, &%{&1 | intransition: false, phase: nil})
    end
  end

  # AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare("stripe", %{"tag"
  # => "?"})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the
  # assigned pair. Without `"?"`, a collision is an error.
  defp autotag(host, name) do
    taken = read(host, & &1.inst)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn n ->
      cand = Ref.format_ref(name, Integer.to_string(n))
      if Map.has_key?(taken, cand), do: nil, else: cand
    end)
  end

  def declare(host, ref, spec \\ nil) do
    spec = spec || %{}

    ref =
      if "?" == Types.get(spec, "tag"),
        do: autotag(host, Ref.refname(Ref.canon_ref(ref))),
        else: ref

    r = Ref.canon_ref(ref)
    if not Types.truthy(Types.get(spec, "hostowned")), do: checkreserved(host, r)

    defname = Types.get(spec, "definition") || Ref.refname(r)
    definition = Catalog.get(catalog(host), defname)

    if is_nil(definition) do
      Types.fail("plugin_unknown_definition", "not in catalog: #{defname}", %{"name" => defname})
    end

    existing = ent(host, r)

    cond do
      is_nil(existing) ->
        newentry(host, r, spec, definition)

      # Section 4 rule 1: a pair addresses at most one instance.
      # Re-declaring the SAME definition is the idempotent case; a
      # different one is a duplicate, not a silent overwrite (seneca) and
      # not an impossibility (sdkgen).
      Types.get(existing["def"], "name") != Types.get(definition, "name") ->
        Types.fail("plugin_ref_duplicate", "instance already declared: #{r}", %{"ref" => r})

      true ->
        existing
    end
  end

  defp newentry(host, r, spec, definition) do
    pos = Types.get(spec, "pos")

    swap(host, fn st ->
      entry = %{
        "ref" => r,
        "def" => definition,
        "status" => "declared",
        "pos" => if(is_nil(pos), do: map_size(st.inst), else: pos),
        # Section 14: `seq` distinguishes ONE INCARNATION of stripe$test
        # from the next, which is the whole reason it is not `pos`.
        "seq" => st.seqn,
        "options" => Types.get(spec, "options") || %{},
        "state" => %{},
        "order" => Types.get(spec, "order"),
        "unmet" => [],
        "scope" => [],
        # Section 11.4's ALWAYS-RELUCTANT rebinding made concrete: the
        # provider ref this instance's activation actually chose, per
        # requirement name. Re-ranking on every question silently
        # re-points a live consumer at any better newcomer, and then
        # losing the provider it was really using does not restart it.
        "selected" => %{},
        "bindings" => [],
        "exports" => %{},
        "provides" => [],
        "inner" => nil,
        "barred" => false
      }

      {entry, %{st | seqn: st.seqn + 1, inst: Map.put(st.inst, r, entry)}}
    end)
  end

  @doc """
  Section 9.1: a host that reserves a name MUST still be able to declare
  the instance it reserved - "The host declares those instances itself,
  after the user merge, and always wins."

  THE BOUNDARY IS BY FUNCTION, NOT BY CALLER, and that is a real limit: no
  language here can tell the embedding host from a plugin holding the same
  host value. What reservation protects is CONFIGURATION - documents,
  overlays, `VOXGIG_PLUGIN_*`, construction options and ordinary
  declare/load/options - and all of that still checks.
  """
  def hostdeclare(host, ref, spec \\ nil) do
    guard(host)
    declare(host, ref, Map.put(spec || %{}, "hostowned", true))
  end

  def load(host, ref, spec \\ nil) do
    guard(host)
    spec = spec || %{}
    entry = declare(host, ref, spec)
    r = entry["ref"]

    if "declared" != entry["status"] do
      # Idempotent trivially.
      entry
    else
      options = Types.get(spec, "options")
      if options, do: setfield(host, r, "options", options)
      stage(host, r, fn -> run(host, r, "define", "define") end)
      setfield(host, r, "status", "loaded")

      # AT LOAD, and before anything runs: a cycle through
      # restart-causing requirements does not settle, and the only safe
      # time to report a non-terminating reconcile is before it starts
      # (section 11.3). `provides` is populated by `define`, which has
      # just run, so this is the first moment the graph is complete.
      stage(host, r, fn -> Depend.checkcycle(graphnodes(host)) end)
      ent(host, r)
    end
  end

  # A step whose failure lands the instance in `failed` and re-raises.
  defp stage(host, ref, fun) do
    fun.()
  rescue
    e ->
      setfield(host, ref, "status", "failed")
      reraise(e, __STACKTRACE__)
  end

  # The requirement graph as plain data, for the pure detector.
  defp graphnodes(host) do
    read(host, fn st ->
      st.inst
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn r ->
        e = st.inst[r]

        %{ref: r,
          provides: Enum.map(e["provides"], &Types.get(&1, "name")),
          requires: Depend.requirements(e["options"])}
      end)
    end)
  end

  def activate(host, ref) do
    guard(host)
    entry = need(host, ref)
    r = entry["ref"]

    cond do
      # A no-op returning success.
      "live" == entry["status"] ->
        entry

      "failed" == entry["status"] ->
        Types.fail("plugin_bad_state", "instance has failed: #{r}", %{"ref" => r})

      # Section 9.6: `active: false` bars the instance from running, and
      # the bar is on the INSTANCE rather than on the apply that set it.
      # `ready` reaches this through `activate`, so one guard covers both
      # verbs the design names.
      Types.truthy(entry["barred"]) ->
        Types.fail("plugin_inactive", "instance is barred by active: false: #{r}",
                   %{"ref" => r})

      true ->
        if "declared" == entry["status"], do: load(host, r)
        toactive(host, r)
    end
  end

  defp toactive(host, r) do
    # A declared requirement that is not live means `pending`: activation
    # is a STANDING REQUEST, not a one-shot event.
    unmet = unmetof(host, r)

    if [] != unmet do
      setfield(host, r, "unmet", unmet)
      setfield(host, r, "status", "pending")
      ent(host, r)
    else
      try do
        run(host, r, "activate", "activate")
      rescue
        e ->
          # Unwind whatever the partial activation captured, in reverse.
          unwind(host, r)
          setfield(host, r, "status", "failed")
          reraise(e, __STACKTRACE__)
      end

      # Section 11.4: THE SELECTION IS MADE HERE, once, and remembered.
      # Every later question - the cascade, `hold`, `unmet` - reads it back
      # rather than re-ranking, which is what "always-reluctant" means.
      Enum.each(Depend.requirements(field(host, r, "options")), &chosen(host, r, &1, true))
      setfield(host, r, "status", "live")
      reconcile(host)
      ent(host, r)
    end
  end

  def deactivate(host, ref) do
    guard(host)
    entry = need(host, ref)
    r = entry["ref"]

    cond do
      entry["status"] in ["loaded", "declared"] ->
        entry

      # Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
      "failed" == entry["status"] ->
        Types.fail("plugin_bad_state", "instance has failed: #{r}", %{"ref" => r})

      # DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2). It
      # never reached activate, so it holds no scope and no live bindings;
      # running the definition's deactivate there would be teardown without
      # matching setup, which plugins are not written to survive and which
      # could fail an instance that had done nothing wrong. It cannot fail.
      "pending" == entry["status"] ->
        setfield(host, r, "status", "loaded")
        setfield(host, r, "unmet", [])
        ent(host, r)

      true ->
        held(host, r)
        cascade(host, r, MapSet.new())
        teardown(host, r)
        setfield(host, r, "status", "loaded")
        reconcile(host)
        ent(host, r)
    end
  end

  # The live half of leaving `live`: the callback, then the scope.
  defp teardown(host, r) do
    try do
      run(host, r, "deactivate", "deactivate")
    rescue
      e ->
        unwind(host, r)
        setfield(host, r, "status", "failed")
        reraise(e, __STACKTRACE__)
    end

    releasecheck(host, r, unwind(host, r))
  end

  def unload(host, ref) do
    guard(host)
    entry = need(host, ref)
    r = entry["ref"]

    if entry["status"] in ["live", "pending"] do
      # Section 5.2: ANY failure during a transition lands the instance in
      # `failed`, with the scope STILL FULLY UNWOUND - and the instance
      # STAYS REGISTERED, because `failed` is a state an operator has to be
      # able to see.
      if "live" == entry["status"] do
        held(host, r)
        cascade(host, r, MapSet.new())
        teardown(host, r)
      end

      setfield(host, r, "status", "loaded")
    end

    if field(host, r, "status") in ["loaded", "failed"] do
      try do
        run(host, r, "close", "close")
      after
        drop(host, r)
      end
    else
      drop(host, r)
    end

    nil
  end

  defp drop(host, ref), do: write(host, fn st -> %{st | inst: Map.delete(st.inst, ref)} end)

  @doc "Runs the whole forward path in one call (section 5.1)."
  def ready(host, ref) do
    guard(host)
    r = Ref.canon_ref(ref)
    if is_nil(ent(host, r)), do: declare(host, r)
    if "declared" == field(host, r, "status"), do: load(host, r)
    activate(host, r)
  end

  # Bindings go live only when activation succeeds (section 8.1), so the
  # teardown is the exact inverse: reverse order, always.
  #
  # Returns the errors the scope raised. Section 8.3: "A failing release does
  # not stop the rest. Every entry runs, in reverse order, whatever any of
  # them does; the errors are collected and raised as one
  # `plugin_release_failed`."
  #
  # A selection belongs to ONE activation (section 11.4). Leaving `live` by
  # any door drops it, so the next activation ranks afresh - keeping it would
  # make a consumer prefer a provider it never actually ran against.
  defp unwind(host, ref) do
    entries =
      swap(host, fn st ->
        scope = get_in(st.inst, [ref, "scope"])

        {Enum.reverse(scope),
         %{st
           | open: st.open - Enum.reduce(scope, 0, &(&1.open + &2)),
             inst:
               update_in(st.inst, [ref], &Map.merge(&1, %{"scope" => [], "selected" => %{}}))}}
      end)

    Enum.reduce(entries, [], fn one, errors ->
      try do
        if one.fun, do: one.fun.()
        errors
      rescue
        e -> errors ++ [e]
      end
    end)
  end

  # Section 8.3: "A failed release ends the instance in `failed`, exactly as
  # a failed callback does (5.2) - a release that raised may have leaked, and
  # an instance that may be holding resources it cannot account for must not
  # be reactivated."
  defp releasecheck(_host, _ref, []), do: :ok

  defp releasecheck(host, ref, errors) do
    setfield(host, ref, "status", "failed")
    causes = Enum.map(errors, &Types.message/1)

    Types.fail("plugin_release_failed",
               "release failed for #{ref}: #{Enum.join(causes, "; ")}",
               %{"ref" => ref, "cause" => causes})
  end

  # --- dependencies ---------------------------------------------------

  # A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A bare
  # string is shorthand for `{name}`. A ref satisfies too, because a host
  # that genuinely needs a specific instance should not have to invent a
  # capability for it.
  defp unmetof(host, ref) do
    field(host, ref, "options")
    |> Depend.requirements()
    |> Enum.filter(&Depend.gatesactivation/1)
    |> Enum.filter(&([] == providersof(host, &1)))
    |> Enum.map(&Types.get(&1, "name"))
  end

  # Section 11.4's always-reluctant selection, and the ONE place a provider
  # is picked for a live instance. If this instance already selected a
  # provider for `req` and that provider is STILL a candidate, it keeps it
  # - a better-ranked newcomer does not take it.
  #
  # `remember` is false for the questions asked ABOUT an instance rather
  # than BY it: introspection must not create a binding.
  defp chosen(host, ref, req, remember) do
    cands = providersof(host, req)
    name = Types.get(req, "name")
    held = Types.get(field(host, ref, "selected"), name)

    cond do
      [] == cands ->
        nil

      not is_nil(held) and Enum.any?(cands, &(Types.get(&1, "ref") == held)) ->
        held

      true ->
        pick = Types.get(hd(cands), "ref")

        if remember do
          entry_update(host, ref, &Map.put(&1, "selected", Map.put(&1["selected"], name, pick)))
        end

        pick
    end
  end

  # The instances currently SELECTED for this one's restart-causing
  # requirements. A BINDING IS TO AN INSTANCE, not to a capability (section
  # 11.1): the selected one going away restarts a `static` consumer even
  # though a survivor is available.
  defp boundproviders(host, ref) do
    field(host, ref, "options")
    |> Depend.requirements()
    |> Enum.filter(&Depend.restartsonloss/1)
    |> Enum.map(&chosen(host, ref, &1, false))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Live instances whose selected provider is `ref` and which would be
  # restarted by losing it.
  defp consumersof(host, ref) do
    refs(host)
    |> Enum.filter(fn r ->
      r != ref and "live" == field(host, r, "status") and ref in boundproviders(host, r)
    end)
  end

  # Section 11.3's `hold` asks a DIFFERENT question from the cascade, and
  # reading it off `consumersof` answered the cascade's.
  #
  # The cascade wants the edges that RESTART - mandatory-static and
  # optional-static - because a restart is what it performs. `hold` says
  # "deactivating a REQUIRED instance is `plugin_dependency_held`", and
  # required is cardinality: `gatesactivation`, not `restartsonloss`. The
  # two sets differ in both directions and each difference was a real bug.
  #
  # A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy let
  # a provider go that a live consumer could not do without - `dynamic`
  # promises survival of a SWAP, and under `hold` there is no swap, so the
  # consumer falls back to `pending`.
  #
  # An OPTIONAL-STATIC consumer was included, so `hold` refused a
  # deactivation on behalf of an instance that had said in writing it does
  # not need the thing.
  defp holdersof(host, ref) do
    refs(host)
    |> Enum.filter(fn r ->
      r != ref and "live" == field(host, r, "status") and
        Enum.any?(Depend.requirements(field(host, r, "options")), fn req ->
          Depend.gatesactivation(req) and ref == chosen(host, r, req, false)
        end)
    end)
  end

  defp providersof(host, req) do
    name = Types.get(req, "name")
    want = Ref.canon(name)

    cands =
      read(host, fn st ->
        st.inst
        |> Map.keys()
        |> Enum.sort()
        |> Enum.flat_map(fn ref ->
          target = st.inst[ref]

          cond do
            "live" != target["status"] ->
              []

            # A ref satisfies directly.
            ref == want ->
              [%{"ref" => ref, "pos" => target["pos"], "provides" => %{"name" => name}}]

            true ->
              target["provides"]
              |> Enum.filter(&(Types.get(&1, "name") == name))
              |> Enum.map(&%{"ref" => ref, "pos" => target["pos"], "provides" => &1})
          end
        end)
      end)

    Capability.resolve_capability(req, cands)
  end

  # CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
  #
  # The cascade is part of the provider's own deactivation and runs BEFORE
  # the provider's `deactivate` callback and scope unwind, so a consumer's
  # teardown can still call the thing it depends on - flushing a buffer to
  # the store it is about to lose is exactly what a `deactivate` callback
  # is for, and a cascade that fired after the provider was already gone
  # would make that impossible.
  defp cascade(host, ref, seen) do
    if MapSet.member?(seen, ref) do
      seen
    else
      Enum.reduce(consumersof(host, ref), MapSet.put(seen, ref), fn r, acc ->
        if "live" == field(host, r, "status"), do: drop_consumer(host, r, acc), else: acc
      end)
    end
  end

  defp drop_consumer(host, r, seen) do
    # Deepest-first.
    seen = cascade(host, r, seen)
    bad = failed?(fn -> run(host, r, "deactivate", "deactivate") end)
    errors = unwind(host, r)

    if bad or [] != errors do
      # Section 5.2: ANY failure during a transition lands the instance in
      # `failed`. Marking it `pending` handed it straight back to
      # `reconcile`, which would activate it again the moment the provider
      # returned.
      setfield(host, r, "status", "failed")
    else
      setfield(host, r, "status", "pending")
      setfield(host, r, "unmet", unmetof(host, r))
    end

    seen
  end

  defp failed?(fun) do
    fun.()
    false
  rescue
    _ -> true
  end

  # The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
  # TEARDOWN. In a bulk operation that is removing the holders too -
  # `close`, or an `apply` plan whose own steps deactivate them - it is
  # suspended for exactly those holders, and the teardown still runs
  # consumers before providers.
  defp held(host, ref) do
    if "hold" == read(host, & &1.dependency) and not read(host, & &1.coordinated) do
      holders = holdersof(host, ref)

      if [] != holders do
        Types.fail("plugin_dependency_held",
                   "instance is required by live consumers: #{ref}",
                   %{"ref" => ref, "holders" => holders})
      end
    end
  end

  # EAGER reconciliation: run to a fixed point rather than scheduling.
  #
  # Two directions, and both are the reason `pending` exists. Activation is
  # a STANDING REQUEST, not a one-shot event.
  defp reconcile(host), do: reconcile(host, 0)

  defp reconcile(_host, rounds) when 1000 < rounds, do: :ok

  defp reconcile(host, rounds) do
    # Losses first, so a cascade settles in one pass rather than
    # alternating with re-activations.
    lost = losspass(host)
    gained = gainpass(host)
    if lost or gained, do: reconcile(host, rounds + 1), else: :ok
  end

  defp losspass(host) do
    Enum.reduce(refs(host), false, fn r, moved ->
      if "live" != field(host, r, "status") or not restartable?(host, r) do
        moved
      else
        bad = failed?(fn -> run(host, r, "deactivate", "deactivate") end)
        errors = unwind(host, r)

        if bad or [] != errors do
          setfield(host, r, "status", "failed")
        else
          setfield(host, r, "status", "pending")
          setfield(host, r, "unmet", unmetof(host, r))
        end

        true
      end
    end)
  end

  # POLICY IS PER REQUIREMENT, not per instance (section 11.3). A `dynamic`
  # requirement whose provider is gone leaves the consumer LIVE and
  # notified.
  defp restartable?(host, r) do
    field(host, r, "options")
    |> Depend.requirements()
    |> Enum.filter(&Depend.gatesactivation/1)
    |> Enum.filter(&([] == providersof(host, &1)))
    |> Enum.any?(&Depend.restartsonloss/1)
  end

  defp gainpass(host) do
    Enum.reduce(refs(host), false, fn r, moved ->
      if "pending" != field(host, r, "status") or [] != unmetof(host, r) do
        moved
      else
        try do
          run(host, r, "activate", "activate")
          setfield(host, r, "status", "live")
          setfield(host, r, "unmet", [])
        rescue
          _ ->
            unwind(host, r)
            setfield(host, r, "status", "failed")
        end

        true
      end
    end)
  end

  # --- ordering -------------------------------------------------------

  def order(host, point \\ nil) do
    bindings =
      read(host, fn st ->
        st.inst
        |> Map.keys()
        |> Enum.filter(&("live" == st.inst[&1]["status"]))
        # Sorted by declaration SEQUENCE, which is what makes the section 7
        # sort's fall-through deterministic in a language whose maps have
        # no insertion order. Section 7 breaks ties by `pos`; two instances
        # CAN share one - `declare` defaults `pos` to the registry size, so
        # an unload followed by a fresh declare reuses a surviving
        # instance's - and past that this was falling through to map order.
        # `seq` is that order, made explicit.
        |> Enum.sort_by(&st.inst[&1]["seq"])
        |> Enum.map(&%{ref: &1, pos: st.inst[&1]["pos"], order: st.inst[&1]["order"]})
      end)

    pin = if point, do: Types.get(pointat(host, point), "pin"), else: nil
    Order.resolve_order(bindings, pin)
  end

  # --- points ---------------------------------------------------------

  defp pointat(host, point), do: read(host, &Map.get(&1.points, point))

  # Live bindings on a point, in resolved order. Recomputed on any change
  # to the live set (section 7) rather than cached at startup - the bug a
  # host discovers only when something deactivates in production.
  defp bound(host, point) do
    Enum.flat_map(order(host, point), fn ref ->
      entry = ent(host, ref)
      # The band is the INSTANCE's ordering block (section 7), stamped by
      # the host. A plugin passing its own would be ranking itself above
      # the order its document declared.
      band = Types.asint(Types.get(entry["order"] || %{}, "band")) || 0

      entry["bindings"]
      |> Enum.filter(&(&1.point == point))
      |> Enum.map(&Map.put(&1, :band, band))
    end)
  end

  defp pointspec(host, point, want) do
    spec = pointat(host, point)

    if is_nil(spec) do
      Types.fail("plugin_point_unknown", "no such point: #{point}", %{"point" => point})
    end

    kind = Types.get(spec, "kind")

    cond do
      # A point with no declared kind is a hook, which is what makes `%{}`
      # the minimal point declaration.
      "hook" == want and (is_nil(kind) or "hook" == kind) ->
        spec

      "hook" != want and kind == want ->
        spec

      true ->
        Types.fail("plugin_point_kind", "point is not a #{want}: #{point}",
                   %{"point" => point, "kind" => kind})
    end
  end

  def emit(host, point, arg \\ nil) do
    spec = pointspec(host, point, "hook")
    Point.point_emit(bound(host, point), Types.get(spec, "mode") || "emit", arg)
  end

  def call(host, point, arg \\ nil) do
    spec = pointspec(host, point, "chain")
    base = Types.get(spec, "base") || fn value -> value end
    Point.compose(bound(host, point), base).(arg)
  end

  def provider(host, point, arg \\ nil) do
    spec = pointspec(host, point, "provider")
    pick = Point.point_provider(bound(host, point), spec)
    if is_nil(pick.winner), do: Types.get(spec, "default"), else: pick.winner.fn.(nil, arg)
  end

  @doc "The losers are VISIBLE rather than silently ignored (section 6.3)."
  def shadowed(host, point) do
    spec = pointat(host, point)
    if is_nil(spec), do: [], else: Point.point_provider(bound(host, point), spec).shadowed
  end

  def exports(host, spec) do
    all =
      read(host, fn st ->
        st.inst
        |> Map.keys()
        |> Enum.sort()
        |> Enum.flat_map(fn ref ->
          entry = st.inst[ref]

          # Exports of a `loaded` (not live) instance are VISIBLE (11).
          if entry["status"] in ["declared", "failed"] do
            []
          else
            entry["exports"]
            |> Map.keys()
            |> Enum.sort()
            |> Enum.map(&%{ref: ref, key: &1, value: entry["exports"][&1]})
          end
        end)
      end)

    Export.resolve_export(spec, all)
  end

  @doc "The live providers of a capability, best-first (section 11.1)."
  def capability(host, name) do
    cands =
      read(host, fn st ->
        st.inst
        |> Map.keys()
        |> Enum.sort()
        |> Enum.flat_map(fn ref ->
          entry = st.inst[ref]

          if "live" != entry["status"] do
            []
          else
            entry["provides"]
            |> Enum.filter(&(Types.get(&1, "name") == name))
            |> Enum.map(&%{"ref" => ref, "pos" => entry["pos"], "provides" => &1})
          end
        end)
      end)

    %{"name" => name} |> Capability.resolve_capability(cands) |> Enum.map(&Types.get(&1, "ref"))
  end

  # --- documents ------------------------------------------------------

  @doc """
  Section 9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
  changed, and move activation state to match", with the stated ordering -
  "deactivations and unloads first (reverse load order), then loads, then
  activations in load order".

  FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
  document once, which never looked at instances the new document had
  DROPPED - so an integration removed from a config reload stayed live with
  its bindings and resources.
  """
  def apply(host, doc, profile \\ nil) do
    guard(host)
    opts = read(host, & &1.opts)
    profile = profile || Types.get(opts, "profile")

    norm =
      Config.normalize_config(%{
        "doc" => doc,
        "profile" => profile,
        "keys" => Types.get(opts, "keys"),
        "reserved" => read(host, & &1.reserved)
      })

    want = norm["order"]
    defaults = Types.get(opts, "defaults") || %{}

    optionsof =
      Map.new(want, fn ref ->
        {ref,
         Config.resolve_options(%{
           "ref" => ref,
           "doc" => doc,
           "profile" => profile,
           "shape" => shapeof(host, ref),
           "hostdefaults" => Types.get(defaults, Ref.refname(ref))
         })}
      end)

    # Should this ref be LIVE after the apply? False for a ref the document
    # declares lazy or inactive AND for one it does not name at all - which
    # is what makes "unload what is gone" and "unload what was toggled off"
    # one rule rather than two.
    wantlive = fn ref ->
      e = Types.get(norm["instance"], ref)
      not is_nil(e) and Types.truthy(e["active"]) and "eager" == e["start"]
    end

    dropphase(host, wantlive)
    Enum.each(want, &declarephase(host, &1, norm, optionsof))
    # ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances is
    # twenty map entries and no executed code" (9.6).
    Enum.each(want, fn ref -> if wantlive.(ref), do: load(host, ref) end)
    Enum.each(want, fn ref -> if wantlive.(ref), do: activate(host, ref) end)
    nil
  end

  # Phase 1: deactivations and unloads, REVERSE load order.
  defp dropphase(host, wantlive) do
    refs(host)
    |> Enum.reject(&("declared" == field(host, &1, "status") or wantlive.(&1)))
    # Highest `pos` first, ref-descending for a tie, so a consumer declared
    # after its provider goes down first.
    |> Enum.sort(fn a, b ->
      pa = field(host, a, "pos")
      pb = field(host, b, "pos")
      if pa == pb, do: a > b, else: pa > pb
    end)
    |> Enum.each(&unload(host, &1))
  end

  # Phase 2: declare and patch EVERYTHING, in load order.
  defp declarephase(host, ref, norm, optionsof) do
    ent = Types.get(norm["instance"], ref)
    declare(host, ref, %{"options" => optionsof[ref], "order" => ent["order"], "pos" => ent["pos"]})

    entry_update(host, ref, fn e ->
      Map.merge(e, %{
        # The bar is REASSERTED ON EVERY APPLY, in both directions - a
        # document that turns the instance back on clears it, which is the
        # whole point of a config switch.
        "barred" => not Types.truthy(ent["active"]),
        "options" => optionsof[ref],
        "order" => ent["order"],
        "pos" => ent["pos"]
      })
    end)
  end

  defp shapeof(host, ref) do
    Types.get(Catalog.get(catalog(host), Ref.refname(ref)), "shape")
  end

  def options(host, ref, patch) do
    guard(host)
    entry = need(host, ref)
    r = entry["ref"]
    previous = entry["options"]

    resolved =
      Config.resolve_options(%{
        "ref" => r,
        "shape" => shapeof(host, r),
        "doc" => %{},
        "patch" => Map.merge(previous, patch || %{})
      })

    setfield(host, r, "options", resolved)
    if "live" == entry["status"], do: reconfigure(host, r, entry["def"], resolved, previous)
    nil
  end

  defp reconfigure(host, r, definition, resolved, previous) do
    fun = Types.get(definition, "reconfigure")

    if is_function(fun, 3) do
      write(host, &%{&1 | intransition: true})

      try do
        fun.(%Inst{host: host, ref: r}, resolved, previous)
      after
        write(host, &%{&1 | intransition: false})
      end
    else
      # Always correct and sometimes expensive; `reconfigure` exists to
      # make the common case cheap (section 9.4).
      deactivate(host, r)
      activate(host, r)
    end
  end

  def close(host) do
    # A bulk teardown removing the holders too, so `hold` is suspended for
    # exactly those holders (section 11.3) - while the consumers-first
    # cascade still runs, which is the half that matters.
    write(host, &%{&1 | coordinated: true})

    try do
      host |> refs() |> Enum.reverse() |> Enum.each(&unload(host, &1))
    after
      write(host, &%{&1 | coordinated: false})
    end
  end

  @doc """
  The same record section 6.6 gives a plugin about itself, reachable from
  outside for the corpus.
  """
  def positionof(host, ref, point) do
    entry = ent(host, Ref.canon(ref))

    if is_nil(entry) do
      Types.fail("plugin_not_loaded", "no such instance: #{ref}", %{"ref" => ref})
    end

    ranked = order(host, point)
    index = Enum.find_index(ranked, &(&1 == entry["ref"])) || -1

    %{"index" => index,
      "count" => length(ranked),
      # Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
      # OUTERMOST, so these are not index 0 and index count-1 the other way
      # round.
      "outermost" => 0 == index,
      "innermost" => index == length(ranked) - 1}
  end
end
