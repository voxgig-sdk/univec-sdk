# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/inst.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Inst do
  @moduledoc """
  What a definition's callbacks see. Deliberately not the internal record:
  a plugin that could reach `status` could also write it.

  THE INSTANCE IS A HANDLE, NOT A COPY - `%Inst{host:, ref:}` and nothing
  else. Every accessor reads the entry back out of the host, so a callback
  always sees current values and there is no snapshot to keep in sync.
  That is the whole of this port's answer to the canonical's "REFILL
  rather than REBIND" (section 9.6): the canonical must empty and refill
  the options map because a definition closes over the object it was
  handed at `define`; here there is no such object, so `apply` simply
  replaces the entry's options and the next `options/1` reads them.
  """

  alias Voxgig.Plugin.Host
  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types

  defstruct [:host, :ref]

  def ref(%__MODULE__{ref: ref}), do: ref

  def name(%__MODULE__{ref: ref}), do: Ref.parse_ref(ref)["name"]

  def tag(%__MODULE__{ref: ref}), do: Ref.parse_ref(ref)["tag"]

  def host(%__MODULE__{host: host}), do: host

  def options(%__MODULE__{host: host, ref: ref}), do: Host.field(host, ref, "options")

  def state(%__MODULE__{host: host, ref: ref}), do: Host.field(host, ref, "state")

  @doc """
  The state map is a VALUE here, so a callback cannot mutate what it reads;
  these two are the writes. Every other port spells them `i.state[k] = v`
  because its maps are objects.
  """
  def state_put(%__MODULE__{host: host, ref: ref}, key, value) do
    Host.entry_update(host, ref, &Map.put(&1, "state", Map.put(&1["state"], key, value)))
  end

  def state_update(%__MODULE__{} = inst, key, dflt, fun) do
    state_put(inst, key, fun.(Types.get(state(inst), key) || dflt))
  end

  @doc """
  Foreign resources the host did not hand out are registered explicitly
  (section 8.3); host calls are recorded automatically.

  SYMMETRIC WITH `acquire`, and it has to be: `open` counts the resources
  CURRENTLY HELD, so an entry that is registered and then unwound must
  leave the count where it found it.
  """
  def release(%__MODULE__{host: host, ref: ref}, fun) do
    # Section 8.3: "`inst.release` outside `activate` is
    # `plugin_release_scope`". A scope entry registered in `define` is
    # never unwound, so "in a transition" is not the test - the PHASE is.
    Host.scope_push(host, ref, fun, "release called outside activate")
  end

  @doc """
  The synthetic counter the driver owns, so "what is open" is data rather
  than an assertion each port words differently.

  Returns its own release, so a plugin can hand one back early. The scope
  still holds the entry and unwinding it twice is a no-op - releasing early
  must not make teardown wrong.
  """
  def acquire(%__MODULE__{host: host, ref: ref}) do
    Host.scope_push(host, ref, nil, "acquire called outside activate")
  end

  @doc """
  Bind into a host point. Declared in `define`; the host inserts it only
  after `activate` returns successfully (section 8.1), which is why a
  failing activate leaves no live binding behind.

  Section 12 has carried `plugin_bind_scope` - "binding declared outside
  `define`" - since before anything raised it, and it was the half nobody
  wrote: a binding added from `activate` went live without being part of
  the loaded definition, and a deactivate/activate cycle appended it again.
  """
  def bind(%__MODULE__{host: host, ref: ref}, point, fun, band \\ nil) do
    if "define" != Host.phase(host) do
      Types.fail("plugin_bind_scope", "bind called outside define: #{point}",
                 %{"ref" => ref, "point" => point})
    end

    if not Host.point?(host, point) do
      Types.fail("plugin_point_unknown", "no such point: #{point}", %{"point" => point})
    end

    Host.entry_update(host, ref, fn e ->
      Map.put(e, "bindings",
              e["bindings"] ++ [%{ref: ref, point: point, fn: fun, band: band || 0}])
    end)
  end

  @doc "Published for other plugins and for the application (section 11)."
  def export(%__MODULE__{host: host, ref: ref}, key, value) do
    Host.entry_update(host, ref, &Map.put(&1, "exports", Map.put(&1["exports"], key, value)))
  end

  @doc "What this instance can do for others (section 11.1)."
  def provides(%__MODULE__{host: host, ref: ref}, prov) do
    Host.entry_update(host, ref, &Map.put(&1, "provides", &1["provides"] ++ [prov]))
  end

  @doc """
  Where this binding landed (section 6.6) - the plugin-side counterpart to
  a host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
  available. Verification tells a plugin it was misplaced; a pin (section
  7) stops the misplacement from being expressible at all. The two are not
  substitutes.
  """
  def position(%__MODULE__{host: host, ref: ref}, point), do: Host.positionof(host, ref, point)

  @doc """
  AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE OWNS
  THE INNER ONE'S LIFETIME. Registering the teardown in the instance scope
  is what makes that true rather than aspirational.
  """
  def nest(%__MODULE__{host: host, ref: ref}, nestopts \\ nil) do
    if not Host.intransition?(host) do
      Types.fail("plugin_release_scope", "nest called outside a lifecycle callback")
    end

    inner = Host.make_host(nestopts)
    # NOT through `scope_push`: a nested host is not a counted resource,
    # and `open` must read the same before and after one is created.
    Host.scope_uncounted(host, ref, fn -> Host.close(inner) end)
    Host.entry_update(host, ref, &Map.put(&1, "inner", inner))
    inner
  end
end
