# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/src/sekreto.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# sekreto: one interface for secrets, wherever they live.
#
# A Sekreto is an ordered chain of providers. `get` asks each in turn and
# returns the first hit, so an app can be configured from environment
# variables in development and a vault in production without changing a
# line of its own code.
#
# THE CORE NAMES NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR
# SIGNS A REQUEST. The four built-in kinds - env, memory, dotenv, file -
# read at most a local file; every other kind is a voxgig/plugin
# definition under plugins/, and a chain may name one only if the calling
# project handed it in through `plugins`. See
# docs/design/plugin-providers.md.
#
# A port of typescript/src/Sekreto.ts, which is canonical.

defmodule Sekreto.Error do
  @moduledoc """
  Anything sekreto refuses to do: a bad name, a missing secret, a provider
  that could not be reached.

  The message is the whole contract - there is no code and no cause, in any
  port.
  """
  defexception [:message]
end

defmodule Sekreto do
  @moduledoc """
  The secrets facade: a chain of providers plus a cache.

  Two ways to read. `get` is transparent - it walks the chain and takes the
  first hit, and the caller never learns which store answered. `getfrom` is
  directed - it names the store, and only that store is asked. Use the
  first for ordinary configuration, the second when *which* store holds a
  secret is part of what you mean.
  """

  alias Sekreto.Error
  alias Sekreto.Provider
  alias Sekreto.Providers
  alias Sekreto.ProviderSpec
  alias Voxgig.Plugin
  alias Voxgig.Plugin.Host

  @typedoc "A secret name: dot-separated lowercase segments, e.g. `api.token`."
  @type name :: binary

  # `catalog` is the definitions this Sekreto can build - the four
  # built-ins plus whatever `plugins` handed in - and `host` is the
  # voxgig/plugin host every spec'd provider is an instance of. Both are
  # public: read `Host.list(sek.host)` for a store's ref and status.
  # Nothing on either advances the chain.
  defstruct [:state, :catalog, :host]

  # ------------------------------------------------------ name functions

  @doc """
  Is this a well-formed secret name?

  Scanned byte by byte rather than matched against `^[a-z0-9_]+$`: in four
  of the twelve regex flavours these ports use, `$` also matches before a
  final newline, so `api.token\\n` passed - and the spec pins that exact
  case as false.
  """
  def validname(name) when is_binary(name) do
    "" != name and Enum.all?(String.split(name, "."), &segment?/1)
  end

  def validname(_other), do: false

  defp segment?(""), do: false

  defp segment?(segment) do
    Enum.all?(:binary.bin_to_list(segment), fn ch ->
      (?a <= ch and ?z >= ch) or (?0 <= ch and ?9 >= ch) or ?_ == ch
    end)
  end

  @doc "The name, or a `Sekreto.Error`. Every entry point checks its name here."
  def checkname(name) do
    if not validname(name) do
      raise Error, message: "sekreto: invalid name: " <> nametext(name)
    end

    name
  end

  # A name that is not a name still has to be printable. Absence renders as
  # the empty string, so the message ends with a trailing space - which the
  # spec pins.
  defp nametext(name) when is_binary(name), do: name
  defp nametext(nil), do: ""
  defp nametext(other), do: inspect(other)

  @doc """
  The environment-variable key for a name: `api.token` -> `API_TOKEN`.

  The prefix is NOT uppercased: it is written as it is meant to appear.
  Uppercasing is ASCII-only, because a Turkish locale turns `i` into `İ`
  and `API_TOKEN` into something no environment holds.
  """
  def envkey(name, prefix \\ "") do
    (prefix || "") <> String.upcase(Enum.join(String.split(checkname(name), "."), "_"), :ascii)
  end

  @doc """
  Where a name lives in a KV vault: `api.token` -> `api` / `token`.

  A single-segment name has no path of its own, so it becomes a secret of
  that name with the conventional field `value`.
  """
  def vaultref(name) do
    parts = String.split(checkname(name), ".")

    if 1 == length(parts) do
      %{path: hd(parts), field: "value"}
    else
      %{path: Enum.join(Enum.drop(parts, -1), "/"), field: List.last(parts)}
    end
  end

  @doc """
  A name flattened to one segment: `api.token` -> `api_token` (GCP Secret
  Manager, `_`) or `api-token` (Azure Key Vault, `-`).

  Those stores have no path hierarchy and reject dots in ids, so the dots
  become the store's conventional separator. With `-` as the separator,
  underscores flatten too: Azure Key Vault's alphabet is letters, digits
  and hyphens only, and a valid sekreto name like `with_underscore` must
  still be representable there.
  """
  def flatname(name, sep) do
    flat = Enum.join(String.split(checkname(name), "."), sep)
    if "-" == sep, do: String.replace(flat, "_", "-"), else: flat
  end

  @doc """
  The AWS SSM Parameter Store name for a name: dots become the path
  hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
  `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
  """
  def awsparam(name, prefix \\ "") do
    checked = checkname(name)

    base = prefix || ""
    base = if "" != base and not String.starts_with?(base, "/"), do: "/" <> base, else: base
    base = dropsuffix(base, "/")

    base <> "/" <> Enum.join(String.split(checked, "."), "/")
  end

  @doc "Drop a suffix if it is there."
  def dropsuffix(text, suffix) do
    if String.ends_with?(text, suffix) and byte_size(text) >= byte_size(suffix) do
      binary_part(text, 0, byte_size(text) - byte_size(suffix))
    else
      text
    end
  end

  @doc """
  Parse `.env` text into an ORDERED list of `{key, value}` pairs.

  A list rather than a map because the order a file declares its keys in is
  the order this answers them in, in every port; an Elixir map has no order
  at all once it grows past a handful of keys.

  Deliberately small: `KEY=value`, optional `export`, `#` comments on their
  own line, and single- or double-quoted values (double quotes also
  unescape `\\n`, `\\r`, `\\t` and `\\\\`). A line with no `=`, or with an
  empty key, is skipped rather than failing the file.
  """
  def parsedotenv(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn rawline, out ->
      line = String.trim(dropsuffix(rawline, "\r"))

      if "" == line or String.starts_with?(line, "#") do
        out
      else
        entry =
          if String.starts_with?(line, "export "),
            do: String.trim(binary_part(line, 7, byte_size(line) - 7)),
            else: line

        case :binary.match(entry, "=") do
          # Both "no `=`" and "empty key", silently, without abandoning the
          # lines below.
          :nomatch ->
            out

          {0, _len} ->
            out

          {at, _len} ->
            key = String.trim(binary_part(entry, 0, at))
            value = String.trim(binary_part(entry, at + 1, byte_size(entry) - at - 1))
            pairput(out, key, unquote_value(value))
        end
      end
    end)
  end

  def parsedotenv(_other), do: []

  defp unquote_value(value) do
    inner = fn -> binary_part(value, 1, byte_size(value) - 2) end

    cond do
      2 <= byte_size(value) and String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        unescape(inner.())

      2 <= byte_size(value) and String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        inner.()

      true ->
        value
    end
  end

  # A scan, not a chain of replacements: an unknown escape is kept as
  # backslash plus character, and a trailing backslash is literal.
  defp unescape(text), do: unescape(text, [])

  defp unescape(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp unescape(<<?\\, next, rest::binary>>, acc) do
    piece =
      case next do
        ?n -> "\n"
        ?r -> "\r"
        ?t -> "\t"
        ?\\ -> "\\"
        ?" -> "\""
        other -> <<?\\, other>>
      end

    unescape(rest, [piece | acc])
  end

  defp unescape(<<ch, rest::binary>>, acc), do: unescape(rest, [<<ch>> | acc])

  @doc """
  Put a key into an ordered pair list, keeping its first position: a later
  duplicate overwrites the value, not the order.
  """
  def pairput(pairs, key, value) do
    if List.keymember?(pairs, key, 0) do
      List.keyreplace(pairs, key, 0, {key, value})
    else
      pairs ++ [{key, value}]
    end
  end

  @doc "The value for a key in an ordered pair list, or nil."
  def pairget(pairs, key) do
    case List.keyfind(pairs, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  @doc """
  Replace known secret values in text with `[redacted]`.

  Only values of four characters or more are replaced: shorter ones are too
  likely to appear in ordinary text, and redacting them would make logs
  unreadable without making them safer.

  Longest first, always, so that a value which contains a shorter one is
  redacted whole. Literal substring replacement, never a regex: a secret
  full of metacharacters must not be interpreted.
  """
  def redact(text, values) do
    out = if is_binary(text), do: text, else: ""

    (values || [])
    |> Enum.filter(fn value -> is_binary(value) and 4 <= String.length(value) end)
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.reduce(out, fn value, acc -> String.replace(acc, value, "[redacted]") end)
  end

  @doc """
  The store name a provider answers to when nothing says otherwise.

  `describe()` opens with the provider's kind - `hashicorp:...`,
  `dotenv:...`, plain `env` - so the kind is the natural default, and a
  custom provider gets a sensible name without implementing anything extra.
  """
  def storename(provider) do
    provider |> Provider.describe() |> String.split(":") |> hd()
  end

  # ------------------------------------------------------------ the chain

  @doc """
  Build a chain from provider specs, live providers, or a mix of the two.

  Options:

    * `plugins:` - the provider kinds beyond the four built-ins that this
      chain may name. A kind that is not in the list cannot be built, and
      naming one is refused with a message that says so.
    * `cache: false` - turns the read cache off. Only an exact `false`
      does; anything else leaves it on.

  Two spellings, and they mean the same thing. The chain reads naturally
  first:

      Sekreto.new(chain, plugins: [Hashicorp.hashicorp()], cache: false)

  ...and every other port writes one options object, which is what DOCS.md
  documents, so that is accepted too:

      Sekreto.new(plugins: [...], providers: chain)

  One argument is options when it is a non-empty keyword list, and the
  chain otherwise: a chain entry is a `Sekreto.ProviderSpec` or a live
  provider - a struct or a map - and never a `{key, value}` pair, so
  nothing is ambiguous. `Sekreto.new([])` reads as both and means the same
  either way.

  Construction contacts nothing. `load` runs each definition's `define`,
  which builds the provider from its spec, and `activate` takes the
  instance live; the first network call is still the first lookup. A spec
  that cannot be built at all - an unknown kind, an unsupported KV version
  - raises here, in chain order.
  """
  def new(entries \\ [], opts \\ [])

  def new(opts, []) when is_list(opts) and [] != opts do
    if Keyword.keyword?(opts) do
      build(Keyword.get(opts, :providers) || [], opts)
    else
      build(opts, [])
    end
  end

  def new(entries, opts), do: build(entries, opts)

  defp build(entries, opts) do
    # Built-ins first, then the plugins, into one catalog: a plugin that
    # names a built-in kind replaces it, which is how a host substitutes an
    # implementation and never an accident, because the four names are
    # documented.
    catalog =
      Plugin.make_catalog(
        Providers.builtins() ++ Enum.map(Keyword.get(opts, :plugins) || [], &definition/1)
      )

    host = Plugin.make_host(%{"catalog" => catalog})

    # A provider handed in live is backed by no instance; a spec'd one is
    # an instance of its kind on the host.
    built =
      Enum.map(entries, fn entry ->
        if Provider.provider?(entry) do
          %{store: storename(entry), provider: entry}
        else
          declare(host, catalog, entry)
        end
      end)

    %Sekreto{
      catalog: catalog,
      host: host,
      state:
        Sekreto.Cell.new(%{
          entries: built,
          cache: [],
          seen: [],
          docache: false != Keyword.get(opts, :cache, true)
        })
    }
  end

  # One chain entry, as a plugin instance.
  #
  # The instance is `kind` for a store named after its kind and
  # `kind$store` otherwise - `hashicorp$prod` - so `Host.list/1` reads like
  # the chain. A store name that is already taken gets a numbered tag from
  # the host instead, because two providers MAY share a store name (a
  # directed read walks both) and an instance ref may not.
  defp declare(host, catalog, spec) do
    kind = if is_struct(spec, ProviderSpec), do: spec.kind, else: nil

    if nil == kind or not Voxgig.Plugin.Catalog.has?(catalog, kind) do
      raise Error, message: unknownkind(kind, catalog)
    end

    # An empty name falls back to the kind, so a chain of two unnamed
    # vaults is addressable as `hashicorp` rather than as nothing.
    store = if spec.name in ["", nil], do: kind, else: spec.name

    if not (is_binary(store) and Plugin.check_tag(store)) do
      raise Error, message: "sekreto: invalid store name: " <> nametext(store)
    end

    ref = if store == kind, do: kind, else: Plugin.format_ref(kind, store)

    # `"tag" => "?"` is voxgig/plugin's own auto-tagging: the lowest unused
    # integer tag for that name, assigned by the host rather than guessed
    # at here.
    load =
      if nil == Host.instance(host, ref),
        do: %{"options" => spec},
        else: %{"options" => spec, "tag" => "?"}

    provider =
      try do
        entry = Host.load(host, ref, load)
        Host.activate(host, entry["ref"])
        Host.exports(host, entry["ref"] <> "/" <> Providers.provider_export())
      rescue
        err -> reraise unwrap(err), __STACKTRACE__
      end

    # A definition that exports no provider is a definition all the same,
    # and voxgig/plugin has no opinion about it - so this port does, here,
    # rather than at the first lookup.
    if not Provider.provider?(provider) do
      raise Error, message: "sekreto: not a provider plugin: " <> kind
    end

    %{store: store, provider: provider}
  end

  # A plugin entry, checked to be a definition before the catalog sees it.
  #
  # Every plugin module is named after the kind it holds and answers the
  # definition from a function, so `plugins: [Sekreto.Plugins.Hashicorp]`
  # hands over the MODULE - an atom - and a module in the catalog would
  # fail inside voxgig/plugin with a message about a definition name.
  # Refused here instead, naming the call that was meant.
  defp definition(plugin) when is_map(plugin) and not is_struct(plugin), do: plugin

  defp definition(plugin) when is_atom(plugin) do
    # A module alias is an atom whose name the compiler prefixes; `nil`,
    # `true` and any other atom is just a value that is not a definition.
    if String.starts_with?(Atom.to_string(plugin), "Elixir.") do
      raise Error,
        message:
          "sekreto: not a plugin definition: the module " <>
            inspect(plugin) <>
            " - a plugin is a definition a plugin module answers, such as" <>
            " Sekreto.Plugins.Hashicorp.hashicorp(), or Sekreto.Plugins.all() for every one"
    else
      raise Error, message: "sekreto: not a plugin definition: " <> inspect(plugin)
    end
  end

  defp definition(plugin) do
    raise Error, message: "sekreto: not a plugin definition: " <> inspect(plugin)
  end

  # The message for a kind the catalog does not hold.
  #
  # A kind sekreto has never heard of is a typo; a kind that exists as a
  # plugin but was not passed in is the split working as designed and
  # telling you what to pass. Collapsing the two was the first thing that
  # made the split confusing to use.
  defp unknownkind(kind, catalog) do
    text = if is_binary(kind), do: kind, else: inspect(kind)

    "sekreto: unknown provider kind: " <>
      text <>
      " (available: " <>
      Enum.join(Voxgig.Plugin.Catalog.names(catalog), ", ") <>
      ")" <>
      if text in Providers.kinds().plugin do
        " - " <> text <> " is a sekreto plugin, not built in: pass it in the plugins option"
      else
        ""
      end
  end

  # A `Sekreto.Error` that crossed the plugin boundary comes back out as
  # itself, byte for byte. Anything else is not sekreto's to rewrite.
  defp unwrap(%Voxgig.Plugin.Error{code: code, details: details} = err) do
    cause = if is_map(details), do: Map.get(details, "cause"), else: nil

    if Providers.error_code() == code and is_binary(cause) do
      %Error{message: cause}
    else
      err
    end
  end

  defp unwrap(err), do: err

  @doc """
  A provider kind, as a voxgig/plugin definition - the one call that makes
  a custom kind. See `Sekreto.Providers.providerplugin/2`.
  """
  defdelegate providerplugin(kind, make), to: Providers

  @doc "The four built-in provider kinds, as definitions."
  defdelegate builtins(), to: Providers

  @doc "Every kind this library ships: `%{builtin: [...], plugin: [...]}`."
  defdelegate kinds(), to: Providers

  @doc "The secret, or a `Sekreto.Error` if no provider has it."
  def get(%Sekreto{} = sek, name) do
    case tryget(sek, name) do
      nil -> raise Error, message: "sekreto: unknown secret: " <> name
      value -> value
    end
  end

  @doc """
  The secret, or nil if no provider has it.

  Named `tryget` because `try` is an Elixir special form.
  """
  def tryget(%Sekreto{} = sek, name), do: resolve(sek, "", name, entries(sek))

  @doc "The secret from one named store, or a `Sekreto.Error`."
  def getfrom(%Sekreto{} = sek, store, name) do
    case tryfrom(sek, store, name) do
      nil -> raise Error, message: "sekreto: unknown secret: " <> store <> ":" <> name
      value -> value
    end
  end

  @doc """
  The secret from one named store, or nil if that store does not have it.

  Naming a store that is not in the chain is an error, not a miss:
  `tryget` already means "this store may not have it", so it cannot also
  mean "this store may not exist" without hiding a typo. That check comes
  before the name is validated.
  """
  def tryfrom(%Sekreto{} = sek, store, name) do
    matching = Enum.filter(entries(sek), fn entry -> store == entry.store end)

    if [] == matching do
      raise Error, message: "sekreto: unknown store: " <> store
    end

    resolve(sek, store, name, matching)
  end

  defp resolve(%Sekreto{state: state}, store, name, useentries) do
    checkname(name)

    held = Sekreto.Cell.get(state)

    hit =
      if held.docache do
        Enum.find(held.cache, fn entry -> store == entry.store and name == entry.name end)
      end

    cond do
      nil != hit ->
        hit.value

      true ->
        # Sequentially, in chain order, short-circuiting on the first hit.
        # A provider that raises is not caught: a store that could not
        # answer must not read as a store that did not have it.
        found =
          Enum.reduce_while(useentries, nil, fn entry, _acc ->
            case Provider.lookup(entry.provider, name) do
              nil -> {:cont, nil}
              value -> {:halt, value}
            end
          end)

        if nil != found do
          later = Sekreto.Cell.get(state)

          Sekreto.Cell.put(state, %{
            later
            | cache:
                if(later.docache,
                  do: later.cache ++ [%{store: store, name: name, value: found}],
                  else: later.cache
                ),
              # Kept whether or not the cache is on, so that `cache: false`
              # cannot silently disable redaction.
              seen: later.seen ++ [found]
          })
        end

        found
    end
  end

  @doc "Does any provider have this secret?"
  def has(%Sekreto{} = sek, name), do: nil != tryget(sek, name)

  @doc "Does this named store have this secret?"
  def hasin(%Sekreto{} = sek, store, name), do: nil != tryfrom(sek, store, name)

  @doc "Every named secret at once. Missing ones are an error."
  def all(%Sekreto{} = sek, names) do
    Map.new(names, fn name -> {name, get(sek, name)} end)
  end

  @doc "A description of each provider, in resolution order."
  def sources(%Sekreto{} = sek) do
    Enum.map(entries(sek), fn entry -> Provider.describe(entry.provider) end)
  end

  @doc """
  The name of each store that can be named by `getfrom`, in resolution
  order and without repeats.
  """
  def stores(%Sekreto{} = sek) do
    entries(sek) |> Enum.map(& &1.store) |> Enum.uniq()
  end

  @doc """
  Replace every value this Sekreto has resolved with `[redacted]`.

  Named `redactall` because the module-level `redact/2` - the pure
  function over an explicit list of values - takes two arguments too. Works
  whether or not caching is enabled: the redaction list is kept
  independently of the read cache.
  """
  def redactall(%Sekreto{state: state}, text) do
    redact(text, Sekreto.Cell.get(state).seen)
  end

  @doc "Drop cached values, so the next `get` asks the providers again."
  def refresh(%Sekreto{state: state}) do
    Sekreto.Cell.put(state, %{Sekreto.Cell.get(state) | cache: []})
    :ok
  end

  @doc """
  Tear the chain down: every plugin instance is deactivated and unloaded,
  in reverse, releasing whatever a provider acquired at activation.
  Afterwards there are no stores, no cache and no further reads.

  What survives is redaction - every value this Sekreto ever resolved is
  still replaced in text afterwards, because a log line written after
  shutdown is exactly as public as one written before it.
  """
  def close(%Sekreto{state: state, host: host}) do
    if nil != host, do: Host.close(host)
    Sekreto.Cell.put(state, %{Sekreto.Cell.get(state) | entries: [], cache: []})
    :ok
  end

  defp entries(%Sekreto{state: state}), do: Sekreto.Cell.get(state).entries
end

# The cache and the resolved-value list are ordinary fields, so the default
# struct inspection would print every secret this chain has ever read. This
# one reaches the store names and nothing else.
defimpl Inspect, for: Sekreto do
  def inspect(sek, _opts) do
    Inspect.Algebra.concat(["Sekreto { stores: [ ", Enum.join(Sekreto.stores(sek), ", "), " ] }"])
  end
end
