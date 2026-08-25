# Univec SDK feature base + shared helpers.
#
# A feature instance is a reference-stable struct map node carrying its
# name/version/active/options plus any per-instance state, and a member
# closure per hook it implements (keyed by hook name — PreRequest, PrePoint,
# ...). feature_hook dispatches by reading `getprop(f, name)` and calling it
# when it is a function, so a feature only installs the hooks it needs (a
# base feature installs none — the no-op equivalent of the donor base).

defmodule Univec.Feature do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H

  # Base node: name, version, active(true), empty options.
  def base(name, version \\ "0.0.1") do
    f = S.jm([])
    S.setprop(f, "name", name)
    S.setprop(f, "version", version)
    S.setprop(f, "active", true)
    S.setprop(f, "options", S.jm([]))
    f
  end

  def install(f, name, fun), do: S.setprop(f, name, fun)

  def get_name(f), do: S.getprop(f, "name")

  def new, do: base("base")

  # options accessor
  def opts(f), do: H.or_(S.getprop(f, "options"), S.jm([]))

  # Set active from options.active == true (the common init prologue).
  def init_common(f, ctx, options) do
    S.setprop(f, "client", S.getprop(ctx, "client"))
    o = if S.ismap(options), do: options, else: S.jm([])
    S.setprop(f, "options", o)
    active = S.getprop(o, "active") == true
    S.setprop(f, "active", active)
    active
  end

  def active?(f), do: S.getprop(f, "active") == true

  # Injectable clock (ms) — options.now() when a function, else wall clock.
  def now(f) do
    n = S.getprop(opts(f), "now")
    if S.isfunc(n), do: n.(), else: System.system_time(:millisecond)
  end

  # Injectable sleep — options.sleep(ms) when a function, else real sleep.
  def sleep(f, ms) do
    if ms != nil and ms > 0 do
      s = S.getprop(opts(f), "sleep")
      if S.isfunc(s), do: s.(ms), else: :timer.sleep(trunc(ms))
    end

    nil
  end

  # Push onto a struct list node (append).
  def list_push(vlist, val), do: S.setprop(vlist, S.size(vlist), val)

  # Get-or-create a tracking node on the client under `key`.
  def track_node(client, key, init_node) do
    t = S.getprop(client, key)

    if t == nil do
      S.setprop(client, key, init_node)
      init_node
    else
      t
    end
  end

  # Case-insensitive header lookup, nil when absent.
  def header_get(headers, name) do
    lower = String.downcase(name)

    Enum.find_value(H.entries(headers), fn {k, v} ->
      if String.downcase(to_string(k)) == lower, do: v
    end)
  end

  # Case-insensitive presence test.
  def header_has?(headers, name) do
    lower = String.downcase(name)
    Enum.any?(H.entries(headers), fn {k, _v} -> String.downcase(to_string(k)) == lower end)
  end
end
