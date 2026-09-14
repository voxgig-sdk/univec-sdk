# Univec SDK secrets feature
#
# Secret access via a vendored @voxgig/sekreto provider chain, and the
# access-token exchange some APIs require on top of it. The elixir port of
# tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, elixir idiom,
# and the same structural choices go made (see tm/go/feature/secrets_feature.go).
#
# The SDK's `apikey` option keeps exactly its old meaning: an explicit
# credential given in code. This feature makes it ONE SOURCE among several
# rather than the only one: when active, the apikey is resolved through a
# sekreto chain in which the explicit option (when set) is the FIRST
# provider - a `memory` store named `options` - so an explicit value always
# wins, by sekreto's own first-hit rule rather than by special-case logic.
# When the option is unset the remaining providers (env, dotenv, a vault)
# are asked in order, and moving a credential from code to a vault becomes
# a configuration change.
#
# WHERE THE CREDENTIAL LIVES: in FEATURE STATE, never in the shared options
# map. This is go's structural deviation from the ts reference (which writes
# options.apikey), and elixir needs it for two reasons of its own. The
# options node is the client's single live struct node, read raw by every
# concurrent operation, so a feature that mutated it would race them; and
# `prepare_auth` reads a CLONE of it (`opts_map/1`), so the write would in
# any case have to land before the clone was taken, which the async chain
# cannot promise. The header the wire sees is identical, because the
# transport wrapper below rebuilds it exactly as prepare_auth does.
#
# WHERE RESOLUTION HAPPENS: at the TRANSPORT SEAM, for the same reason go
# resolves there. `direct/2` and `graphql/4` run NO feature hooks at all -
# Main.fragment.ex's `raw_request/2` builds its own ctx and calls
# `Utility.fetcher/3` directly - so a lookup that lived only in a PreSpec
# hook would leave both raw paths sending unauthenticated requests and
# never notice. The fetcher slot on the shared utility node is the ONE
# place every wire path crosses (retry.ex uses the same seam), and it is
# late-bound through `Utility.fetcher/3`, so wrapping it at init is seen by
# every holder.
#
# MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
# op proceeds, unauthenticated if nothing else supplies a credential. A
# provider ERROR (unreachable vault, bad credentials) must FAIL the op: a
# broken vault never degrades into an unauthenticated request. sekreto
# signals an error by RAISING `Sekreto.Error` and a miss by answering nil,
# so every call into the chain is wrapped here and a raise becomes the
# seam's `{nil, err}` - which is how a wrapper refuses a request. Nothing
# from sekreto is ever allowed to escape as a raise: the pipeline's
# tolerance for those is uneven (retry.ex re-raises, the raw path rescues
# only around `prepare`), and a vault outage must be a clean SDK error
# rather than a crash.
#
# EXCHANGE: some APIs will not take a long-lived credential at all. What
# the chain resolves is then a REFRESH token, which buys a short-lived
# ACCESS token from a token endpoint (`exchange.path`, relative to
# options.base); the access token is what every request carries, and when a
# response status in `exchange.statuses` (401) says it is spent the wrapper
# buys another and retries the same request once. Test mode buys nothing
# and answers with a deterministic fake token.
#
# CONCURRENCY is weaker than go's, deliberately. There is no mutex idiom
# here, and the obvious substitute - an Agent for single-flight resolution -
# would reintroduce exactly the lifetime hazard documented below. The
# resolved credential is held on the feature's own ETS-backed struct node,
# so individual reads and writes are atomic and a lost update is benign
# (both values are valid credentials); two concurrent FIRST resolutions may
# each ask the chain, and sekreto's own read cache absorbs that from the
# second hit onwards. Stated rather than discovered later.
#
# THE DEAD CELL. `Sekreto.Cell.new/1` is `Agent.start_link`, so the chain's
# state process is LINKED to whichever process built the client. A client
# constructed in a process that later exits ABNORMALLY leaves a dead Agent,
# and every later lookup exits `{:noproc, {GenServer, :call, ...}}` rather
# than raising. That is the sekreto peer of the ETS-heap staleness the
# generated Config module already guards with `usable?/1`, and it is
# handled the same way: the exit is caught, the chain is rebuilt ONCE from
# the specs init kept, and the lookup is retried. A rebuild cannot swallow
# a genuine provider error, because a provider error RAISES and never
# exits. The real fix is `Agent.start` upstream.

defmodule Univec.Feature.Secrets do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Feature, as: F

  # The elixir sekreto port has no `SpecOf` (go and py both do), so a spec
  # given as SDK option data is built here. The field lists come from the
  # structs themselves, so a field upstream adds is picked up without an
  # edit; `values` and `auth` are the two that are not scalars and are
  # handled by name below.
  @specfields Map.keys(Map.from_struct(%Sekreto.ProviderSpec{}))
  @authfields Map.keys(Map.from_struct(%Sekreto.AuthSpec{}))

  def new do
    f = F.base("secrets", "0.1.0")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    f
  end

  # Sync by feature contract: build the chain, never look anything up here.
  def init(f, ctx, options) do
    active = F.init_common(f, ctx, options)

    if active do
      client = S.getprop(ctx, "client")

      # The LIVE options node, not a clone: `auth` suppression and the
      # starting `apikey` are read from it on every request, and this
      # feature never writes to it.
      S.setprop(f, "_liveopts", S.getprop(client, "options"))

      name = H.str_or(S.getprop(options, "name"), "apikey")
      S.setprop(f, "_secretname", name)
      S.setprop(f, "_cache", S.getprop(options, "cache") != false)
      S.setprop(f, "_cred", "")
      S.setprop(f, "_refresh", "")
      S.setprop(f, "_resolved", false)

      # Exchange config, normalised once. nil when off, so every later
      # decision is a nil check rather than a repeated active test.
      xopts = H.to_map(S.getprop(options, "exchange"))

      exchange =
        if xopts != nil and S.getprop(xopts, "active") == true do
          %{
            path: H.str_or(S.getprop(xopts, "path"), "auth/token"),
            method: H.str_or(S.getprop(xopts, "method"), "POST"),
            request: H.str_or(S.getprop(xopts, "request"), "refresh_token"),
            response: H.str_or(S.getprop(xopts, "response"), "access_token"),
            statuses: statuses(S.getprop(xopts, "statuses")),
            retries: intor(S.getprop(xopts, "retries"), 1)
          }
        end

      S.setprop(f, "_exchange", exchange)

      # Construction can refuse the chain outright (an unknown kind, a bad
      # store name, a plugin group the model left off). init cannot fail
      # the client the way ts's throwing constructor does, so the failure
      # is kept and the transport gate below refuses to send - which keeps
      # a misconfigured chain fail-closed rather than silently
      # unauthenticated.
      try do
        specs = chain(f, options, xopts, exchange, name)
        plugs = plugins()
        # Kept, because the dead-cell rebuild below needs to construct the
        # SAME chain again without re-reading the options node.
        S.setprop(f, "_specs", specs)
        S.setprop(f, "_plugins", plugs)
        S.setprop(f, "_sekreto", build(specs, plugs, S.getprop(f, "_cache")))
      rescue
        err -> S.setprop(f, "_initerr", fail(err))
      catch
        :exit, reason -> S.setprop(f, "_initerr", exitfail(reason))
      end

      # Wrap the transport. The fail-closed gate needs the seam WHENEVER
      # the feature is active - not only when exchanging, as the js
      # reference does - because this port has no awaited PreSpec that can
      # reject an operation, and because the raw paths run no hooks at all.
      utility = S.getprop(ctx, "utility")
      inner = S.getprop(utility, "fetcher")
      S.setprop(utility, "fetcher", fn fctx, url, fd -> transport(f, fctx, url, fd, inner) end)
    end

    nil
  end

  # ---- public accessors ----------------------------------------------------

  # The LIVE Sekreto instance, for callers who want arbitrary secrets or
  # redaction:
  #
  #     Sekreto.get(Univec.Feature.Secrets.sekreto(client), "db.password")
  #     Sekreto.redactall(Univec.Feature.Secrets.sekreto(client), logline)
  #
  # Never a clone: sekreto holds provider state (caches, vault leases) that
  # has to stay live to be worth anything. nil when this SDK has no secrets
  # feature, or when the feature is inactive.
  def sekreto(client_or_feature) do
    f = feature(client_or_feature)
    if f == nil, do: nil, else: S.getprop(f, "_sekreto")
  end

  # The resolved credential ("" when none) - the state the transport
  # injects. Read here rather than from the options map, which this feature
  # never mutates.
  def credential(client_or_feature) do
    f = feature(client_or_feature)
    if f == nil, do: "", else: getcred(f)
  end

  # The feature node on a client, or nil. Accepts a feature node directly so
  # the accessors above work either way.
  def feature(client) do
    cond do
      client == nil ->
        nil

      S.ismap(client) and S.getprop(client, "name") == "secrets" ->
        client

      S.ismap(client) ->
        features = S.getprop(client, "features")

        if is_list(features) do
          Enum.find(features, fn fe -> S.getprop(fe, "name") == "secrets" end)
        end

      true ->
        nil
    end
  end

  # ---- the chain -----------------------------------------------------------

  defp chain(f, options, xopts, exchange, name) do
    liveopts = S.getprop(f, "_liveopts")

    # The explicit credential, when set, is the first store in the chain.
    #
    # WHICH option that is depends on the exchange. Without one, the secret
    # being resolved IS the credential the transport sends, so `apikey` is
    # it. With one, the secret is a REFRESH token and `apikey` means the
    # opposite thing - an access token the caller already holds - so the
    # explicit seat belongs to `exchange.refresh`, and apikey is left alone
    # to serve as the starting access token (see settle/2).
    explicit =
      if exchange == nil do
        S.getprop(liveopts, "apikey")
      else
        if xopts == nil, do: nil, else: S.getprop(xopts, "refresh")
      end

    first =
      if is_binary(explicit) and explicit != "" do
        [%Sekreto.ProviderSpec{
           kind: "memory",
           name: "options",
           values: [{Sekreto.envkey(name), explicit}]
         }]
      else
        []
      end

    first ++ entries(S.getprop(options, "providers"))
  end

  # Chain entries as the SDK options carry them: a live provider map handed
  # in verbatim, a ProviderSpec struct built by the caller, or spec DATA (a
  # struct node) that this port has to turn into a ProviderSpec itself.
  #
  # NEVER DROPPED. An entry that is none of those - the bare string
  # "hashicorp" where a spec map was meant - used to answer nil and be
  # rejected from the list, so the chain was quietly SHORTER than the
  # options said and the operation went out unauthenticated: fail-open,
  # from a typo. go refuses the same entry at the arm because its slice is
  # typed, and kotlin passes it through so the vendored constructor raises.
  # This port raises here instead, because passing a non-struct through to
  # this Sekreto's `declare/2` names the wrong thing ("unknown provider
  # kind: nil"); the wording is sekreto's own, and the raise lands in
  # init's rescue as `_initerr`, which the transport gate refuses on.
  defp entries(providers) do
    cond do
      S.islist(providers) ->
        n = S.size(providers)

        if n == 0 do
          []
        else
          Enum.map(0..(n - 1), fn i -> entry(S.getelem(providers, i)) end)
        end

      is_list(providers) ->
        Enum.map(providers, &entry/1)

      true ->
        []
    end
  end

  defp entry(value) do
    cond do
      is_struct(value, Sekreto.ProviderSpec) ->
        value

      # Duck-typed, exactly as Sekreto.Provider.provider?/1 is: anything
      # with a one-argument `lookup` joins the chain as it is.
      Sekreto.Provider.provider?(value) ->
        value

      S.ismap(value) ->
        providerspec(value)

      true ->
        raise Sekreto.Error,
          message: "sekreto: not a provider or a provider spec: " <> inspect(value)
    end
  end

  defp providerspec(node) do
    Enum.reduce(H.entries(node), %Sekreto.ProviderSpec{}, fn {k, v}, acc ->
      case field(k, @specfields) do
        nil -> acc
        :values -> %{acc | values: pairs(v)}
        :auth -> %{acc | auth: authspec(v)}
        :kv -> %{acc | kv: v}
        key -> Map.put(acc, key, v)
      end
    end)
  end

  defp authspec(node) do
    if not S.ismap(node) do
      nil
    else
      Enum.reduce(H.entries(node), %Sekreto.AuthSpec{}, fn {k, v}, acc ->
        case field(k, @authfields) do
          nil -> acc
          key -> Map.put(acc, key, v)
        end
      end)
    end
  end

  # A spec key as the struct's own field atom, or nil for a key the struct
  # does not have. `to_existing_atom` never creates one, so unknown option
  # keys cannot grow the atom table.
  defp field(key, allowed) do
    atom =
      try do
        String.to_existing_atom(to_string(key))
      rescue
        ArgumentError -> nil
      end

    if atom != nil and Enum.member?(allowed, atom), do: atom, else: nil
  end

  # `values` is an ORDERED list of {key, value} pairs, not a map: the port
  # is explicit that map order is meaningless on the BEAM, and the memory
  # provider answers in declaration order.
  defp pairs(node) do
    cond do
      S.ismap(node) -> Enum.map(H.entries(node), fn {k, v} -> {to_string(k), tostr(v)} end)
      is_list(node) -> node
      true -> []
    end
  end

  # The plugin DEFINITIONS the model selected for this feature, emitted by
  # Config generically from the catalogue's active `plugin.def` entries.
  # Upstream sekreto's contract since the registry was retired: a kind not
  # passed in `plugins` is unknown to this Sekreto, so the model's choice of
  # plugin groups IS the SDK's provider vocabulary.
  defp plugins do
    defs = Univec.Config.feature_plugins("secrets")
    if is_list(defs), do: defs, else: []
  end

  defp build(specs, plugs, cache) do
    Sekreto.new(specs, plugins: plugs, cache: cache)
  end

  # ---- resolution ----------------------------------------------------------

  # One resolution. A settled HIT is kept only when caching is on
  # (`cache: false` means every resolve asks the chain again); a FAILURE is
  # never kept, so a transient vault outage cannot poison the client
  # permanently - the next operation asks the chain again.
  #
  # A MISS is not kept either, however caching is set. That rule is
  # sekreto's, not this feature's: `A miss is never cached: the next read
  # asks again`, in sekreto's own source. Keeping a settled miss here would
  # override that from the layer above, and a secret provisioned after
  # startup - a mounted file, a policy granted a minute late - would never
  # be picked up for the life of the client. `cache` is about caching a
  # HIT; it was never a promise to keep saying no.
  def resolve(f) do
    initerr = S.getprop(f, "_initerr")

    cond do
      initerr != nil -> {:error, initerr}
      S.getprop(f, "_resolved") == true -> :ok
      true -> resolve_once(f)
    end
  end

  defp resolve_once(f) do
    sek = S.getprop(f, "_sekreto")

    if sek == nil do
      :ok
    else
      case tryget(f, sek, S.getprop(f, "_secretname")) do
        {:error, err} -> {:error, err}
        {:ok, found} -> settle(f, found)
      end
    end
  end

  # The one call into the chain, and the only place a sekreto raise is
  # turned into a value. A dead state Agent EXITS rather than raising, so
  # that case rebuilds the chain once and asks again; a provider error
  # raises, and is returned as an error without a rebuild.
  defp tryget(f, sek, name) do
    try do
      {:ok, Sekreto.tryget(sek, name)}
    rescue
      err -> {:error, fail(err)}
    catch
      :exit, {:noproc, _} = reason -> revive(f, name, reason)
      :exit, {:normal, _} = reason -> revive(f, name, reason)
      :exit, reason -> {:error, exitfail(reason)}
    end
  end

  defp revive(f, name, reason) do
    try do
      sek = build(S.getprop(f, "_specs"), S.getprop(f, "_plugins"), S.getprop(f, "_cache"))
      S.setprop(f, "_sekreto", sek)

      try do
        {:ok, Sekreto.tryget(sek, name)}
      rescue
        err -> {:error, fail(err)}
      catch
        :exit, _ -> {:error, exitfail(reason)}
      end
    rescue
      err -> {:error, fail(err)}
    catch
      :exit, _ -> {:error, exitfail(reason)}
    end
  end

  defp settle(f, found) do
    x = S.getprop(f, "_exchange")

    if x == nil do
      # An UNCACHED miss after an earlier hit is a revocation: the chain now
      # says no provider has the secret, so the resolved value must not keep
      # going out on the wire. (An explicit apikey OPTION is never lost here
      # - it seats FIRST in the chain as a memory provider, so the chain
      # HITS while one is set and the miss branch is unreachable.)
      S.setprop(f, "_cred", tostr(found))
      # Only a HIT is kept: see resolve/1.
      if found != nil, do: keep(f)
      :ok
    else
      # Exchanging: what the chain resolved is the REFRESH token, kept for
      # every later purchase. A miss is not fatal here - an explicit
      # `apikey` may already hold a usable access token, and the API is what
      # gets to say whether it does.
      S.setprop(f, "_refresh", tostr(found))

      cred = held(f)

      if cred != "" do
        # A starting access token was supplied. Spend it: if it is stale the
        # API answers with an expiry status and the wrapper buys another,
        # which is the same path expiry takes anyway.
        keep(f)
        :ok
      else
        # NO SUPPRESSION CHECK HERE, and that is deliberate: elixir's
        # transport/5 already returns before resolve/1 when `auth: nil`, so
        # a suppressed request never reaches this purchase at all. Every
        # other target guards the purchase itself, because their transports
        # resolve first. One rule, one place - and here that place is the
        # transport.
        case buy(f, x) do
          {:ok, _token} ->
            keep(f)
            :ok

          {:error, err} ->
            {:error, err}
        end
      end
    end
  end

  # The access token this client already holds: the resolved one, else the
  # starting `apikey` OPTION (read from the frozen options node - no feature
  # ever writes it).
  defp held(f) do
    cred = getcred(f)

    if cred != "" do
      cred
    else
      k = tostr(S.getprop(S.getprop(f, "_liveopts"), "apikey"))
      S.setprop(f, "_cred", k)
      k
    end
  end

  defp keep(f) do
    if S.getprop(f, "_cache") == true, do: S.setprop(f, "_resolved", true)
    nil
  end

  defp getcred(f), do: tostr(S.getprop(f, "_cred"))

  # ---- the transport seam --------------------------------------------------

  # Fail-closed at the ONE seam every wire path crosses. Entity ops,
  # direct/2, graphql/4 and the exchange retries all come through here, so
  # resolving HERE is what gives the raw paths - which run no feature hooks
  # at all - the same credential the entity pipeline gets. A provider ERROR
  # refuses the request with the provider's own error; never an
  # unauthenticated send.
  defp transport(f, ctx, url, fetchdef, inner) do
    x = S.getprop(f, "_exchange")

    if suppressed?(f) do
      # `auth: nil` is the documented way to send NO credential, and
      # prepare_auth honours it by removing the header. There is then
      # nothing to resolve and nothing to buy: asking the chain could only
      # fail a request that was never going to carry a credential, and
      # purchasing an access token nobody will send is a wasted exchange.
      # The header is removed again defensively, because this is the
      # function that would otherwise write it.
      reauth(f, fetchdef, "")
      inner.(ctx, url, fetchdef)
    else
      case resolve(f) do
        {:error, err} ->
          {nil, err}

        :ok ->
          # Inject the resolved credential into THIS request's header. The
          # header was built by prepare_auth from the options apikey; the
          # chain-resolved value lives in feature state instead, so the
          # wrapper writes it here - same construction, same suppression
          # rules - and the shared options node stays untouched.
          token = getcred(f)
          if token != "", do: reauth(f, fetchdef, token)

          if x == nil do
            inner.(ctx, url, fetchdef)
          else
            exchange_loop(f, ctx, url, fetchdef, inner, x, 0)
          end
      end
    end
  end

  defp suppressed?(f), do: S.getprop(S.getprop(f, "_liveopts"), "auth") == nil

  # Buy a token and try the request again when the API says the current one
  # is spent.
  #
  # The retry rewrites the authorization header IN PLACE on the fetchdef,
  # because the header was built by the synchronous prepare_auth before this
  # request left and it carries the token that just failed. Rebuilt the way
  # prepare_auth builds it, from the same options auth.prefix, so the two
  # cannot drift.
  defp exchange_loop(f, ctx, url, fetchdef, inner, x, attempt) do
    # The credential THIS attempt goes out with, captured before it leaves:
    # it is what tells a stale refusal apart from a fresh one.
    used = getcred(f)

    {res, err} = inner.(ctx, url, fetchdef)

    if err != nil or attempt >= x.retries or not spent?(x, res) do
      {res, err}
    else
      # Another request may have bought a token while this one was in
      # flight. Spend what is current before buying: a second exchange for a
      # token that is already fresh is wasted, and on a provider that
      # invalidates the previous credential on issuance it breaks the first
      # request's own retry.
      current = getcred(f)

      bought =
        if current != "" and current != used do
          {:ok, current}
        else
          buy(f, x)
        end

      case bought do
        {:ok, token} ->
          reauth(f, fetchdef, token)
          exchange_loop(f, ctx, url, fetchdef, inner, x, attempt + 1)

        {:error, _err} ->
          # The purchase failed: answer with the API's own refusal rather
          # than this one. The caller asked for data, and the refusal is the
          # more useful of the two - the exchange error is a symptom.
          {res, err}
      end
    end
  end

  defp spent?(x, res) do
    if not S.ismap(res) do
      false
    else
      status = S.getprop(res, "status")
      is_integer(status) and Enum.member?(x.statuses, status)
    end
  end

  # The credential, written the way prepare_auth writes it.
  defp reauth(f, fetchdef, token) do
    headers = if S.ismap(fetchdef), do: S.getprop(fetchdef, "headers"), else: nil

    if S.ismap(headers) do
      # Suppressed auth means NO header, the same answer prepare_auth gives.
      # Reached defensively - the transport does not resolve at all when
      # auth is suppressed - but this is the function that writes the
      # credential, so it is where the rule has to hold.
      if suppressed?(f) or token == "" do
        S.delprop(headers, "authorization")
      else
        prefix = S.getpath(S.getprop(f, "_liveopts"), "auth.prefix")
        prefix = if is_binary(prefix), do: prefix, else: ""
        S.setprop(headers, "authorization", if(prefix != "", do: prefix <> " " <> token, else: token))
      end
    end

    nil
  end

  # ---- the exchange --------------------------------------------------------

  # Buy an access token with the refresh token.
  defp buy(f, x) do
    client = S.getprop(f, "client")

    # TEST MODE BUYS NOTHING. The test feature replaces the transport so no
    # request leaves the process; an exchange here would be the one HTTP
    # call it could not stop, and it would need a live token endpoint for a
    # suite whose whole point is not needing one. A deterministic,
    # obviously-fake token instead - the same answer make_options gives a
    # required server variable, for the same reason.
    if S.getprop(client, "mode") != "live" do
      token = "test-" <> x.response
      S.setprop(f, "_cred", token)
      {:ok, token}
    else
      case buy_once(f, x) do
        {:ok, token} ->
          S.setprop(f, "_cred", token)
          {:ok, token}

        other ->
          other
      end
    end
  end

  defp buy_once(f, x) do
    refresh = tostr(S.getprop(f, "_refresh"))

    if refresh == "" do
      {:error,
       err("secrets_no_refresh",
         "secrets: no refresh token: the provider chain has no '" <>
           tostr(S.getprop(f, "_secretname")) <>
           "', and feature.secrets.exchange.refresh is unset")}
    else
      options = Univec.options_map(S.getprop(f, "client"))

      # The token endpoint is RELATIVE to the base, which already carries
      # whatever account or tenant segment the server URL declares.
      base = String.replace(tostr(S.getprop(options, "base")), ~r{/+$}, "")
      url = base <> "/" <> String.replace(x.path, ~r{^/+}, "")

      # The body is MARSHALLED, never concatenated: a refresh token (or a
      # configured request-field name) carrying a quote, backslash or
      # newline must arrive as that literal value, not as malformed JSON.
      fetchdef =
        S.jm([
          "method", x.method,
          "headers", S.jm(["content-type", "application/json"]),
          "body", S.jsonify(S.jm([x.request, refresh]), S.jm(["indent", 0]))
        ])

      sysfetch = S.getpath(options, "system.fetch")

      # Deliberately NOT the SDK transport. The transport is what this
      # feature wraps, and sending the token request back through it would
      # recurse on the first expiry - and would route the exchange through
      # the test mock, which knows nothing about it. `options.system.fetch`
      # is preferred when set, so a test can intercept the purchase.
      {res, ferr} =
        try do
          if S.isfunc(sysfetch),
            do: sysfetch.(url, fetchdef),
            else: raw_exchange_fetch(url, fetchdef)
        rescue
          e -> {nil, fail(e)}
        end

      cond do
        ferr != nil ->
          {:error, aserr(ferr, "secrets_exchange_failed")}

        not S.ismap(res) ->
          {:error, err("secrets_exchange_failed", "secrets: token exchange returned no response from " <> url)}

        true ->
          status = H.to_int(S.getprop(res, "status"))

          if status < 200 or status >= 300 do
            {:error,
             err("secrets_exchange_failed",
               "secrets: token exchange failed: " <> Integer.to_string(status) <> " from " <> url)}
          else
            token = tostr(bodyfield(res, x.response))

            if token == "" do
              {:error,
               err("secrets_exchange_failed",
                 "secrets: token exchange returned no '" <> x.response <> "' field from " <> url)}
            else
              {:ok, token}
            end
          end
      end
    end
  end

  defp bodyfield(res, name) do
    jf = S.getprop(res, "json")

    body =
      if S.isfunc(jf) do
        try do
          jf.()
        rescue
          _ -> nil
        end
      else
        S.getprop(res, "body")
      end

    if S.ismap(body), do: S.getprop(body, name), else: nil
  end

  # The token-exchange transport of last resort: plain :httpc, same result
  # shape the system.fetch seam promises. It exists so an exchange works
  # with ordinary SDK options - requiring a custom transport for the COMMON
  # case would reject every live token purchase before a request was made.
  defp raw_exchange_fetch(url, fetchdef) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    method =
      H.or_(S.getprop(fetchdef, "method"), "POST") |> to_string() |> String.downcase() |> String.to_atom()

    body = tostr(S.getprop(fetchdef, "body"))

    hlist =
      Enum.map(H.entries(H.or_(S.getprop(fetchdef, "headers"), S.jm([]))), fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    request =
      if method in [:post, :put, :patch, :delete] do
        {String.to_charlist(url), hlist, ~c"application/json", body}
      else
        {String.to_charlist(url), hlist}
      end

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_v, status, _reason}, _rh, resbody}} ->
        text = if is_binary(resbody), do: resbody, else: to_string(resbody)

        parsed =
          try do
            Univec.Json.parse(text)
          rescue
            _ -> nil
          end

        {S.jm(["status", status, "json", fn -> parsed end, "body", text]), nil}

      {:error, reason} ->
        {nil, err("secrets_exchange_failed", "secrets: token exchange transport: " <> inspect(reason))}
    end
  end

  # ---- small helpers -------------------------------------------------------

  defp statuses(v) do
    cond do
      S.islist(v) ->
        n = S.size(v)
        list = if n == 0, do: [], else: Enum.map(0..(n - 1), fn i -> S.getelem(v, i) end)
        got = list |> Enum.filter(&is_number/1) |> Enum.map(&trunc/1)
        if got == [], do: [401], else: got

      is_list(v) and v != [] ->
        v

      true ->
        [401]
    end
  end

  defp intor(v, d), do: if(is_number(v) and not is_boolean(v), do: trunc(v), else: d)

  defp tostr(v), do: if(is_binary(v), do: v, else: "")

  defp err(code, msg), do: Univec.Error.new(code, msg, nil)

  # A sekreto raise, as the SDK error the transport seam returns. The
  # PROVIDER'S OWN message is carried through verbatim: a fail-closed
  # refusal has to say which store broke, or it is indistinguishable from
  # any other failure.
  defp fail(e) do
    msg =
      cond do
        match?(%Univec.Error{}, e) -> e.msg || ""
        is_exception(e) -> Exception.message(e)
        is_binary(e) -> e
        true -> inspect(e)
      end

    err("secrets_provider", msg)
  end

  defp exitfail(reason) do
    err("secrets_provider",
      "secrets: the provider chain is no longer running: " <> inspect(reason))
  end

  # The seam's error slot carries whatever the inner transport put there -
  # an exception, or a plain string from the default HTTP path.
  defp aserr(e, code) do
    cond do
      is_exception(e) -> fail(e)
      is_binary(e) -> err(code, e)
      true -> err(code, inspect(e))
    end
  end
end
