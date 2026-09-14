# Behavioural tests for the secrets feature (vendored @voxgig/sekreto).
#
# The contract under test: the `apikey` OPTION keeps its exact old meaning
# and always wins, because Univec.Feature.Secrets places it FIRST in the
# provider chain (a `memory` store named `options`) - explicit-beats-lookup
# falls out of sekreto's first-hit rule rather than from special-case logic.
# With the feature inactive nothing changes at all. With it active and the
# option unset, the chain (env, dotenv, a custom provider, a vault) supplies
# the credential instead.
#
# EVERY CASE BUILDS A LIVE CLIENT WITH A RECORDING `system.fetch`, and asserts
# on what that recorder saw. That is not incidental - it is the whole point.
# This feature resolves at the TRANSPORT SEAM (see the header of
# feature/secrets.ex), so `prepare/2` returns before any lookup has happened
# and a header assertion taken there would pass for an SDK with no secrets
# feature at all. And Univec.test/2 REPLACES the fetcher with the test
# feature's in-memory mock, so a counter hung off `system.fetch` is never
# reached under it: "no request was sent" and "the request failed" would both
# hold for a healthy SDK, and the pair would assert nothing. An assertion that
# cannot fail pins no rule.
#
# So each fail-closed case proves its own counter FIRST, with the same
# construction and a WORKING provider: one request must reach `system.fetch`
# carrying the resolved credential. Only then does a zero from the broken
# provider mean REFUSED rather than UNWIRED. And the failure is matched on the
# PROVIDER'S OWN message, so an unrelated failure (a missing route, a blocked
# op) cannot stand in for fail-closed.
#
# This file lives in the `feature/` container on purpose: `target add` trims
# it, along with the feature source and the vendored library, for a project
# whose model does not select `secrets`.

defmodule Univec.SecretsTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Feature.Secrets

  @envprefix "UNIVEC_TEST_SECRETS_"
  @base "http://raw.test/api"

  # ---- the recorder --------------------------------------------------------

  # A transport that records every call it is handed, so "sent" is a fact
  # about the wire rather than about a mock. ETS rather than an Agent: this
  # is the thing the fail-closed assertions count, and it must outlive
  # anything the SDK does to its own processes.
  defp recorder(opts \\ %{}) do
    t = :ets.new(:secrets_recorder, [:public, :set])
    :ets.insert(t, {:calls, []})
    :ets.insert(t, {:issued, 0})
    :ets.insert(t, {:apicall, -1})

    path = Map.get(opts, :path, "auth/token")
    tokens = Map.get(opts, :tokens, ["ACCESS01", "ACCESS02", "ACCESS03"])
    apistatus = Map.get(opts, :api, [200])
    resfield = Map.get(opts, :response, "access_token")
    tokenfail = Map.get(opts, :tokenfail, nil)

    fetch = fn url, fetchdef ->
      headers = S.getprop(fetchdef, "headers")

      auth =
        if S.ismap(headers),
          do: Univec.Feature.header_get(headers, "authorization"),
          else: nil

      [{:calls, cs}] = :ets.lookup(t, :calls)

      :ets.insert(t,
        {:calls, cs ++ [%{url: url, auth: auth, body: S.getprop(fetchdef, "body")}]})

      if String.ends_with?(url, "/" <> path) do
        [{:issued, i}] = :ets.lookup(t, :issued)
        :ets.insert(t, {:issued, i + 1})

        if tokenfail != nil and i + 1 >= tokenfail do
          {S.jm(["status", 500, "json", fn -> S.jm([]) end, "headers", S.jm([])]), nil}
        else
          token = Enum.at(tokens, min(i, length(tokens) - 1))
          {S.jm(["status", 200, "json", fn -> S.jm([resfield, token]) end, "headers", S.jm([])]), nil}
        end
      else
        [{:apicall, a}] = :ets.lookup(t, :apicall)
        a = a + 1
        :ets.insert(t, {:apicall, a})
        status = Enum.at(apistatus, min(a, length(apistatus) - 1))

        {S.jm([
           "status", status,
           "statusText", if(status < 400, do: "OK", else: "ERR"),
           "json", fn -> S.jm(["ok", status < 400]) end,
           "headers", S.jm([])
         ]), nil}
      end
    end

    %{table: t, fetch: fetch, path: path}
  end

  defp calls(r), do: :ets.lookup(r.table, :calls) |> hd() |> elem(1)

  # Only the calls that went to the API, in order - a token purchase is not
  # an API call and must never be counted as one.
  defp api(r), do: calls(r) |> Enum.reject(&String.ends_with?(&1.url, "/" <> r.path))
  defp token(r), do: calls(r) |> Enum.filter(&String.ends_with?(&1.url, "/" <> r.path))

  # What went out, for a failure message that names the leak rather than just
  # its count.
  defp wire(r) do
    calls(r) |> Enum.map_join(", ", fn c -> c.url <> " auth=" <> inspect(c.auth) end)
  end

  # ---- construction --------------------------------------------------------

  # `allow.op` is named explicitly: a project that narrows the default set
  # would otherwise turn the raw-path cases into a false RED (the control leg
  # refused before it reached the transport), and the rule under test lives
  # at the transport, downstream of the allow gate either way.
  defp sdk(r, extra) do
    opts =
      S.jm([
        "base", @base,
        "allow", S.jm(["op", "direct,graphql,list,load"]),
        "system", S.jm(["fetch", r.fetch])
      ])

    Enum.each(extra, fn {k, v} -> S.setprop(opts, k, v) end)
    Univec.new(opts)
  end

  defp secrets(fopts) do
    node = S.jm(["active", true])
    Enum.each(fopts, fn {k, v} -> S.setprop(node, k, v) end)
    S.jm(["secrets", node])
  end

  defp providers(list), do: S.jt(list)

  defp envchain(extra \\ []) do
    secrets([{"providers", providers([S.jm(["kind", "env", "prefix", @envprefix])])} | extra])
  end

  defp spec(pairs), do: S.jm(pairs)

  # ---- providers -----------------------------------------------------------

  # Live provider maps, duck-typed on `lookup/1` exactly as
  # Sekreto.Provider.provider?/1 is.
  defp working(value \\ "RAWKEY01", name \\ "apikey") do
    %{
      lookup: fn n -> if n == name, do: value, else: nil end,
      describe: fn -> "working:test" end
    }
  end

  defp broken do
    %{
      lookup: fn _n -> raise Sekreto.Error, message: "vault unreachable" end,
      describe: fn -> "broken:test" end
    }
  end

  # ---- assertions ----------------------------------------------------------

  # The authorization header carries the SPEC's credential prefix, which a
  # TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
  # `Bearer <token>`, an apiKey scheme the raw token. So assert on the
  # CREDENTIAL and let the prefix be whatever this SDK's API declares -
  # pinning the whole header value passes only for a prefix-less API, and
  # this file ships to every project that selects the feature.
  defp credential_is(header, token) do
    got = if is_binary(header), do: header, else: ""

    assert got == token or String.ends_with?(got, " " <> token),
           "expected the Authorization header to carry " <> token <> ", got: " <> inspect(header)
  end

  defp auth_is(call, token), do: credential_is(if(call == nil, do: nil, else: call.auth), token)

  # Does this options value CARRY the token - bare, or under the spec's
  # prefix? The negative half of credential_is, for the assertions that pin
  # where a credential must NOT be.
  defp credential?(value, token) do
    is_binary(value) and (value == token or String.ends_with?(value, " " <> token))
  end

  defp err_message(res) do
    e = S.getprop(res, "err")

    cond do
      is_exception(e) -> Exception.message(e)
      is_binary(e) -> e
      true -> inspect(e)
    end
  end

  setup do
    System.delete_env(@envprefix <> "APIKEY")
    System.delete_env(@envprefix <> "REFRESH_TOKEN")
    System.delete_env(@envprefix <> "API_TOKEN")

    on_exit(fn ->
      System.delete_env(@envprefix <> "APIKEY")
      System.delete_env(@envprefix <> "REFRESH_TOKEN")
      System.delete_env(@envprefix <> "API_TOKEN")
    end)

    :ok
  end

  describe "secrets" do
    test "inactive: the apikey option behaves exactly as before" do
      r = recorder()
      client = sdk(r, [{"apikey", "OPTKEY01"}])

      assert S.getprop(Univec.direct(client, S.jm(["path", "/thing"])), "ok") == true
      assert length(api(r)) == 1
      auth_is(hd(api(r)), "OPTKEY01")

      # No feature, no instance: the accessor is the only way in.
      assert Secrets.feature(client) == nil
      assert Secrets.sekreto(client) == nil
    end

    test "inactive: no apikey means no authorization header" do
      r = recorder()
      client = sdk(r, [])
      Univec.direct(client, S.jm(["path", "/thing"]))

      assert hd(api(r)).auth == nil
    end

    test "active: the apikey option still wins over the chain" do
      System.put_env(@envprefix <> "APIKEY", "ENVKEY01")

      r = recorder()
      client = sdk(r, [{"apikey", "OPTKEY01"}, {"feature", envchain()}])
      Univec.direct(client, S.jm(["path", "/thing"]))

      auth_is(hd(api(r)), "OPTKEY01")

      # The explicit option is a real store, not a special case: a directed
      # read names it like any other.
      assert Sekreto.getfrom(Secrets.sekreto(client), "options", "apikey") == "OPTKEY01"
    end

    # The three ways an apikey can be "not given", pinned together because
    # they are easy to conflate and only one of them is a suppression.
    #
    # make_options normalises an omitted apikey to "" before features
    # initialise, so by init time omitted and explicit-empty are
    # indistinguishable - both defer to the chain, deliberately.

    test "active: an OMITTED apikey defers to the chain" do
      System.put_env(@envprefix <> "APIKEY", "ENVKEY01")

      r = recorder()
      Univec.direct(sdk(r, [{"feature", envchain()}]), S.jm(["path", "/thing"]))

      auth_is(hd(api(r)), "ENVKEY01")
    end

    test "active: an explicitly EMPTY apikey also defers to the chain" do
      System.put_env(@envprefix <> "APIKEY", "ENVKEY01")

      r = recorder()
      Univec.direct(sdk(r, [{"apikey", ""}, {"feature", envchain()}]), S.jm(["path", "/thing"]))

      auth_is(hd(api(r)), "ENVKEY01")
    end

    # `auth: nil` - the documented way to disable auth outright, which
    # prepare_auth honours before it ever reads the apikey.
    #
    # This needs an explicit guard because struct 0.3.2 nearly removed it in
    # silence: a stored null began reading as "no value", so the optspec's
    # default auth map fired instead and the suppression became "use default
    # auth" - transmitting a credential the caller explicitly asked not to
    # send. make_options now captures suppliedness BEFORE validate and
    # restores the nil after it.
    test "active: auth nil suppresses the credential, chain or no chain" do
      System.put_env(@envprefix <> "APIKEY", "ENVKEY01")

      r = recorder()
      client = sdk(r, [{"auth", nil}, {"feature", envchain()}])
      Univec.direct(client, S.jm(["path", "/thing"]))

      # Nothing on the wire, even though the chain would have resolved.
      assert length(api(r)) == 1
      assert hd(api(r)).auth == nil

      # The suppression survives option validation rather than being replaced
      # by the optspec's default auth map.
      assert S.getprop(Univec.options_map(client), "auth") == nil
    end

    test "active: auth nil suppresses an EXPLICIT apikey too" do
      r = recorder()

      client =
        sdk(r, [{"apikey", "OPTKEY01"}, {"auth", nil}, {"feature", envchain()}])

      Univec.direct(client, S.jm(["path", "/thing"]))

      assert hd(api(r)).auth == nil
    end

    test "active: custom provider maps are accepted verbatim" do
      asked = :ets.new(:asked, [:public, :set])
      :ets.insert(asked, {:names, []})

      custom = %{
        lookup: fn n ->
          [{:names, ns}] = :ets.lookup(asked, :names)
          :ets.insert(asked, {:names, ns ++ [n]})
          "CUSTOM01"
        end,
        describe: fn -> "custom:test" end
      }

      r = recorder()

      Univec.direct(
        sdk(r, [{"feature", secrets([{"providers", providers([custom])}])}]),
        S.jm(["path", "/thing"])
      )

      auth_is(hd(api(r)), "CUSTOM01")
      assert (:ets.lookup(asked, :names) |> hd() |> elem(1)) == ["apikey"]
    end

    test "active: a miss everywhere leaves the header off and the request still goes" do
      r = recorder()
      client = sdk(r, [{"feature", envchain()}])

      assert S.getprop(Univec.direct(client, S.jm(["path", "/thing"])), "ok") == true
      assert length(api(r)) == 1
      assert hd(api(r)).auth == nil
      assert Secrets.credential(client) == ""
    end

    # WHERE THE CREDENTIAL LIVES: in feature state, NEVER in the shared
    # options map. That is the structural choice the header of
    # feature/secrets.ex spends two paragraphs on - the options node is the
    # client's single live struct node, read raw by every concurrent
    # operation, so a feature that wrote into it would race them - and
    # nothing else here would notice it being undone: publish the resolved
    # token into `_liveopts` before `reauth` and every case above stays
    # green, because the wire sees the same header either way.
    #
    # So this pins the map itself, on BOTH sides of a resolution, and the
    # control leg comes first: the request must reach the transport exactly
    # once carrying the credential, or an unchanged map proves nothing (an
    # unwired feature leaves it unchanged too).
    test "active: a resolved credential lives in feature state, never in the options map" do
      r = recorder()
      client = sdk(r, [{"feature", secrets([{"providers", providers([working()])}])}])

      # What the map holds BEFORE anything is resolved. make_options
      # normalises an omitted apikey to "", and that is what must survive.
      before = S.getprop(Univec.options_map(client), "apikey")
      refute credential?(before, "RAWKEY01")

      assert S.getprop(Univec.direct(client, S.jm(["path", "/thing"])), "ok") == true

      # CONTROL: resolved, injected, sent - exactly once.
      assert length(api(r)) == 1,
             "the control request never reached system.fetch, so this test cannot" <>
               " observe whether the credential was resolved at all"

      auth_is(hd(api(r)), "RAWKEY01")
      assert Secrets.credential(client) == "RAWKEY01", "the feature state holds the credential"

      # THE RULE. The public clone, and the live node behind it - the one
      # prepare_auth clones on every request and the feature keeps as
      # `_liveopts` - both unchanged, and neither carrying the token.
      after_ = S.getprop(Univec.options_map(client), "apikey")

      assert after_ == before,
             "resolving the credential changed options.apikey from " <>
               inspect(before) <> " to " <> inspect(after_) <>
               " - the credential must live in feature state, not in the shared options map"

      refute credential?(after_, "RAWKEY01"),
             "the resolved credential was published into the options map"

      live = S.getprop(S.getprop(client, "options"), "apikey")

      assert live == before,
             "the LIVE options node was written: " <> inspect(live)

      # And a second request, which must be answered from feature state
      # rather than from a map the first one populated.
      Univec.direct(client, S.jm(["path", "/again"]))
      assert length(api(r)) == 2
      auth_is(Enum.at(api(r), 1), "RAWKEY01")
      assert S.getprop(Univec.options_map(client), "apikey") == before
    end

    # sekreto's miss-vs-error invariant: a MISS falls through to the next
    # provider, an ERROR does not. A broken vault must never degrade into an
    # unauthenticated request.
    #
    # THE RAW PATHS RUN NO FEATURE HOOKS AT ALL. If resolution lived only in
    # a hook these would send unauthenticated and never notice; they are
    # covered because the wrapper sits on the fetcher slot, which
    # raw_request/2 reaches through the same late-bound Utility.fetcher/3.

    test "active: a provider ERROR fails direct() rather than sending" do
      # THE RULE, asserted first so a regression reports the leak itself.
      r = recorder()
      res = Univec.direct(
        sdk(r, [{"feature", secrets([{"providers", providers([broken()])}])}]),
        S.jm(["path", "/thing"]))

      assert api(r) == [],
             "a request must not go out unauthenticated because a provider broke," <>
               " but one reached the transport: " <> wire(r)

      assert S.getprop(res, "ok") == false
      assert err_message(res) =~ "vault unreachable"

      # CONTROL, which makes that empty list mean REFUSED rather than
      # UNWIRED: the same construction with a WORKING provider must reach the
      # same transport, once, carrying the credential.
      c = recorder()
      ok = Univec.direct(
        sdk(c, [{"feature", secrets([{"providers", providers([working()])}])}]),
        S.jm(["path", "/thing"]))

      assert S.getprop(ok, "ok") == true, "the control request failed: " <> inspect(ok)

      assert length(api(c)) == 1,
             "the control request never reached system.fetch, so this test cannot" <>
               " observe a request going out at all"

      auth_is(hd(api(c)), "RAWKEY01")
    end

    test "active: a provider ERROR fails graphql() rather than sending" do
      r = recorder()
      res = Univec.graphql(
        sdk(r, [{"feature", secrets([{"providers", providers([broken()])}])}]),
        "{ thing }", S.jm([]))

      assert api(r) == [],
             "a graphql request must not go out unauthenticated," <>
               " but one reached the transport: " <> wire(r)

      assert S.getprop(res, "ok") == false
      assert err_message(res) =~ "vault unreachable"

      c = recorder()
      ok = Univec.graphql(
        sdk(c, [{"feature", secrets([{"providers", providers([working()])}])}]),
        "{ thing }", S.jm([]))

      assert S.getprop(ok, "ok") == true, "the control request failed: " <> inspect(ok)

      assert length(api(c)) == 1,
             "the control request never reached system.fetch, so this test cannot" <>
               " observe a request going out at all"

      auth_is(hd(api(c)), "RAWKEY01")
    end

    # THE ENTITY PATH, which DOES run the hook pipeline - the other half of
    # the seam. Resolution is at the transport for both, so one rule covers
    # them; this proves it rather than assuming it.
    #
    # The entity is discovered from the SDK's own config rather than named,
    # because this file is a TEMPLATE: it ships to every project, and no
    # project's entity names are known here.
    test "active: a provider ERROR fails an ENTITY op rather than sending" do
      r = recorder()
      client = sdk(r, [{"feature", secrets([{"providers", providers([broken()])}])}])

      case list_op(client) do
        nil ->
          # An SDK with no listable entity has no entity path to exercise.
          :ok

        op ->
          # The op FAILS - that is the point - and by default an entity op
          # raises rather than returning its error, so the refusal is caught
          # here and matched on the PROVIDER'S OWN message. An unrelated
          # failure (a blocked op, a missing route) must not stand in for
          # fail-closed.
          assert opfail(op) =~ "vault unreachable",
                 "the entity op did not fail with the provider's own error: " <> opfail(op)

          assert api(r) == [],
                 "an entity op must not go out unauthenticated because a provider" <>
                   " broke, but one reached the transport: " <> wire(r)

          c = recorder()
          control = sdk(c, [{"feature", secrets([{"providers", providers([working()])}])}])

          # The control op itself may fail on the stub's response shape -
          # irrelevant here. What matters is that the request reached the
          # transport carrying the resolved credential.
          opfail(list_op(control))

          assert length(api(c)) == 1,
                 "the control entity op never reached system.fetch, so this test" <>
                   " cannot observe a request going out at all"

          auth_is(hd(api(c)), "RAWKEY01")
      end
    end

    # A MALFORMED chain entry is a refusal, not a shorter chain. `providers:
    # ["hashicorp"]` - the bare kind where a spec map was meant - is neither
    # a provider nor a spec, and the feature used to DROP it silently: the
    # chain was then empty, every provider "missed", and the request went
    # out unauthenticated. Fail-open from a typo. Now the entry raises with
    # sekreto's own wording at init, that error is held as the init failure,
    # and the transport gate refuses every path on it - entity, direct AND
    # graphql - because the gate sits on the fetcher slot the raw paths
    # (which run no feature hooks at all) reach through Utility.fetcher/3.
    #
    # The control leg comes FIRST, with the same construction and a WORKING
    # provider, so that an empty recorder means REFUSED rather than UNWIRED.
    test "active: a malformed providers entry refuses every path rather than being dropped" do
      # CONTROL: a well-formed chain reaches the transport once, credentialed.
      c = recorder()
      control = sdk(c, [{"feature", secrets([{"providers", providers([working()])}])}])
      assert S.getprop(Univec.direct(control, S.jm(["path", "/thing"])), "ok") == true

      assert length(api(c)) == 1,
             "the control request never reached system.fetch, so this test cannot" <>
               " observe a request going out at all"

      auth_is(hd(api(c)), "RAWKEY01")

      # THE RULE, on all three wire paths, with NO apikey so a dropped entry
      # would leave nothing to send and the leak would be an unauthenticated
      # request rather than a wrong credential.
      r = recorder()
      client = sdk(r, [{"feature", secrets([{"providers", providers(["hashicorp"])}])}])

      direct = Univec.direct(client, S.jm(["path", "/thing"]))
      assert S.getprop(direct, "ok") == false, "direct() went out on a malformed chain"

      assert err_message(direct) =~ "not a provider or a provider spec",
             "direct() did not fail with sekreto's own refusal: " <> err_message(direct)

      assert err_message(direct) =~ "hashicorp",
             "the refusal does not name the offending entry: " <> err_message(direct)

      gql = Univec.graphql(client, "{ thing }", S.jm([]))
      assert S.getprop(gql, "ok") == false, "graphql() went out on a malformed chain"
      assert err_message(gql) =~ "not a provider or a provider spec"

      case list_op(client) do
        nil ->
          # An SDK with no listable entity has no entity path to exercise;
          # the two raw paths above still hold the rule.
          :ok

        op ->
          assert opfail(op) =~ "not a provider or a provider spec",
                 "the entity op did not fail with sekreto's own refusal: " <> opfail(op)
      end

      assert api(r) == [],
             "a request must not go out because a malformed entry was dropped from" <>
               " the chain, but one reached the transport: " <> wire(r)

      assert token(r) == []
    end

    # A settled failure must not be held. Holding one meant a transient vault
    # outage poisoned the client permanently: every later operation kept
    # failing with the original error long after the vault recovered.
    test "active: a provider recovers after a transient failure" do
      n = :counters.new(1, [])

      flaky = %{
        lookup: fn _ ->
          :counters.add(n, 1, 1)

          if :counters.get(n, 1) == 1 do
            raise Sekreto.Error, message: "vault unreachable"
          else
            "RECOVERED01"
          end
        end,
        describe: fn -> "flaky:test" end
      }

      r = recorder()
      client = sdk(r, [{"feature", secrets([{"providers", providers([flaky])}])}])

      first = Univec.direct(client, S.jm(["path", "/one"]))
      assert S.getprop(first, "ok") == false, "the first attempt should surface the outage"
      assert api(r) == []

      second = Univec.direct(client, S.jm(["path", "/two"]))
      assert S.getprop(second, "ok") == true, "the second attempt should recover"
      assert length(api(r)) == 1
      auth_is(hd(api(r)), "RECOVERED01")
    end

    # `cache: false` is documented as "every resolve asks the chain again".
    # Keeping the settled result made that a lie.
    test "active: cache false asks the chain on every request" do
      n = :counters.new(1, [])

      counting = %{
        lookup: fn _ ->
          :counters.add(n, 1, 1)
          "KEY" <> Integer.to_string(:counters.get(n, 1))
        end,
        describe: fn -> "counting:test" end
      }

      r = recorder()

      client =
        sdk(r, [{"feature", secrets([{"cache", false}, {"providers", providers([counting])}])}])

      Univec.direct(client, S.jm(["path", "/one"]))
      Univec.direct(client, S.jm(["path", "/two"]))

      assert :counters.get(n, 1) > 1,
             "the chain was asked once and cached, despite cache: false"

      auth_is(Enum.at(api(r), 0), "KEY1")
      auth_is(Enum.at(api(r), 1), "KEY2")
    end

    # A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
    # feature used to override from the layer above.
    #
    # DEFAULT caching here, which is the whole point: `cache: true` is about
    # holding a HIT (the test below pins that half), and keeping the settled
    # resolution after a miss meant the chain was never asked again for the
    # life of the client. A secret provisioned after startup (a mounted
    # file, a vault policy granted a minute late) was invisible forever.
    test "active: a cached MISS is re-asked, so a late secret is picked up" do
      n = :counters.new(1, [])
      present = :counters.new(1, [])

      late = %{
        lookup: fn _ ->
          :counters.add(n, 1, 1)
          if :counters.get(present, 1) > 0, do: "LATEKEY01", else: nil
        end,
        describe: fn -> "late:test" end
      }

      r = recorder()
      client = sdk(r, [{"feature", secrets([{"providers", providers([late])}])}])

      Univec.direct(client, S.jm(["path", "/one"]))
      assert Enum.at(api(r), 0).auth == nil,
             "the chain has nothing yet, so no credential should go out"

      asked = :counters.get(n, 1)
      assert asked > 0

      # The secret is provisioned while the client is live.
      :counters.add(present, 1, 1)

      Univec.direct(client, S.jm(["path", "/two"]))

      assert :counters.get(n, 1) > asked,
             "the MISS was cached: a secret that appears later can never be picked up"

      auth_is(Enum.at(api(r), 1), "LATEKEY01")
    end

    test "active: caching on asks the chain once" do
      n = :counters.new(1, [])
      counting = %{
        lookup: fn _ -> :counters.add(n, 1, 1); "CACHED01" end,
        describe: fn -> "counting:test" end
      }

      r = recorder()
      client = sdk(r, [{"feature", secrets([{"providers", providers([counting])}])}])

      Univec.direct(client, S.jm(["path", "/one"]))
      Univec.direct(client, S.jm(["path", "/two"]))

      assert :counters.get(n, 1) == 1
      assert length(api(r)) == 2
      auth_is(Enum.at(api(r), 1), "CACHED01")
    end

    test "active: the secret name is configurable" do
      System.put_env(@envprefix <> "API_TOKEN", "TOKKEY01")

      r = recorder()
      Univec.direct(sdk(r, [{"feature", envchain([{"name", "api.token"}])}]),
        S.jm(["path", "/thing"]))

      auth_is(hd(api(r)), "TOKKEY01")
    end

    test "active: sekreto is live for arbitrary secrets and redaction" do
      r = recorder()

      client =
        sdk(r, [{"feature",
          secrets([{"providers",
            providers([spec(["kind", "memory", "values", S.jm(["DB_PASSWORD", "dbpass01"])])])}])}])

      sek = Secrets.sekreto(client)
      assert Sekreto.get(sek, "db.password") == "dbpass01"

      assert Sekreto.redactall(sek, "the password is dbpass01, keep it safe") ==
               "the password is [redacted], keep it safe"
    end

    # THE PROVIDER VOCABULARY IS NON-EMPTY.
    #
    # Upstream sekreto retired its self-registration registry: a kind that
    # was not passed in `plugins:` is unknown to that Sekreto. The generated
    # Config.feature_plugins/1 is what passes them, so an SDK whose model
    # selects a plugin group but whose config emitted no definitions would
    # carry the plugin MODULES and refuse every one of their kinds at
    # runtime - while every test that used only built-in kinds stayed green.
    #
    # Conditional on the module being present, because this file ships to
    # projects that select the feature without the `vault` plugin group.
    test "active: a selected plugin kind is in the SDK vocabulary" do
      if Code.ensure_loaded?(Sekreto.Plugins.Hashicorp) do
        # Construction is where an unknown kind is refused, so the chain
        # building at all IS the regression check. The memory store comes
        # FIRST so sekreto's first-hit rule answers from it and the vault is
        # never contacted - the kind has to be declarable, not reachable.
        r = recorder()

        client =
          sdk(r, [{"feature",
            secrets([{"providers", providers([
              spec(["kind", "memory", "values", S.jm(["APIKEY", "VOCAB01"])]),
              spec(["kind", "hashicorp", "addr", "https://vault.test", "token", "x"])
            ])}])}])

        assert S.getprop(Univec.direct(client, S.jm(["path", "/thing"])), "ok") == true
        auth_is(hd(api(r)), "VOCAB01")
      end
    end

    # ELIXIR-ONLY. sekreto keeps per-chain state in an Agent started with
    # `Agent.start_link`, so it is LINKED to whichever process built the
    # client. A client constructed in a process that later exits ABNORMALLY
    # leaves a dead Agent, and the next lookup EXITS with `:noproc` rather
    # than raising - which is neither a miss nor a provider error, and would
    # crash the calling process instead of failing the operation. The feature
    # catches that exit and rebuilds the chain once.
    test "active: a dead provider cell is rebuilt rather than crashing the op" do
      r = recorder()
      parent = self()

      spawn(fn ->
        client =
          sdk(r, [{"feature",
            secrets([{"providers",
              providers([spec(["kind", "memory", "values", S.jm(["APIKEY", "CELLKEY01"])])])}])}])

        send(parent, {:client, client})
        Process.sleep(20)
        exit(:boom)
      end)

      client = receive do
        {:client, c} -> c
      after
        2000 -> flunk("the builder process never handed the client back")
      end

      # Wait for the owner's exit to take the Agent with it, and prove it
      # did: without a dead cell this test asserts nothing.
      cell = S.getprop(Secrets.feature(client), "_sekreto").state
      wait_dead(cell, 100)
      refute Process.alive?(cell), "the provider cell did not die, so this test is inert"

      res = Univec.direct(client, S.jm(["path", "/thing"]))

      assert S.getprop(res, "ok") == true,
             "a dead provider cell must not fail the operation: " <> inspect(res)

      assert length(api(r)) == 1
      auth_is(hd(api(r)), "CELLKEY01")
    end
  end

  # ACCESS-TOKEN EXCHANGE.
  #
  # The shape these tests pin: what the chain resolves is a REFRESH token,
  # which is POSTed to a token endpoint for a short-lived ACCESS token; the
  # access token is what the Authorization header carries; and when the API
  # answers 401 the client buys another and tries the same request again,
  # once.
  #
  # A LIVE client throughout. Test mode is deliberately excluded here - it
  # buys nothing, which is the subject of its own test at the end.
  describe "secrets exchange" do
    @refresh "REFRESH01"

    defp exchange_sdk(r, xextra \\ [], extra \\ []) do
      x = S.jm(["active", true])
      Enum.each(xextra, fn {k, v} -> S.setprop(x, k, v) end)

      fopts =
        secrets([
          {"name", "refresh_token"},
          {"providers", providers([S.jm(["kind", "env", "prefix", @envprefix])])},
          {"exchange", x}
        ])

      sdk(r, [{"feature", fopts} | extra])
    end

    test "the refresh token buys an access token, and the request carries it" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder()
      Univec.direct(exchange_sdk(r), S.jm(["path", "/thing"]))

      assert length(token(r)) == 1, "expected exactly one token purchase"

      assert S.getprop(Univec.Json.parse(hd(token(r)).body), "refresh_token") == @refresh,
             "the refresh token is sent in the request field"

      assert length(api(r)) == 1
      auth_is(hd(api(r)), "ACCESS01")
    end

    test "an explicit exchange.refresh wins over the chain" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", "FROMCHAIN")

      r = recorder()
      Univec.direct(exchange_sdk(r, [{"refresh", "EXPLICIT01"}]), S.jm(["path", "/thing"]))

      assert S.getprop(Univec.Json.parse(hd(token(r)).body), "refresh_token") == "EXPLICIT01"
    end

    # The exchange side of the same invariant: the ACCESS token the purchase
    # buys is held in feature state too. `buy/2` is a second writer of the
    # credential, so the rule is pinned at this seam as well as at the plain
    # resolution above.
    test "a bought access token lives in feature state, never in the options map" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder()
      client = exchange_sdk(r)
      before = S.getprop(Univec.options_map(client), "apikey")

      Univec.direct(client, S.jm(["path", "/thing"]))

      # CONTROL: bought once, sent once, carrying what was bought.
      assert length(token(r)) == 1, "expected exactly one token purchase"
      assert length(api(r)) == 1
      auth_is(hd(api(r)), "ACCESS01")
      assert Secrets.credential(client) == "ACCESS01"

      after_ = S.getprop(Univec.options_map(client), "apikey")

      assert after_ == before,
             "the token purchase changed options.apikey from " <> inspect(before) <>
               " to " <> inspect(after_)

      refute credential?(after_, "ACCESS01"),
             "the bought access token was published into the options map"

      refute credential?(after_, @refresh),
             "the refresh token was published into the options map"
    end

    test "one purchase serves many requests" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder()
      client = exchange_sdk(r)
      Univec.direct(client, S.jm(["path", "/one"]))
      Univec.direct(client, S.jm(["path", "/two"]))
      Univec.direct(client, S.jm(["path", "/three"]))

      assert length(token(r)) == 1, "a token still working must not be re-bought"
      assert length(api(r)) == 3
    end

    test "a 401 buys another token and retries the SAME request" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder(%{api: [401, 200]})
      res = Univec.direct(exchange_sdk(r), S.jm(["path", "/thing"]))

      assert length(token(r)) == 2, "expected a second token purchase"
      assert length(api(r)) == 2, "expected the request to be retried"

      auth_is(Enum.at(api(r), 0), "ACCESS01")
      # The retry must carry the NEW token, not the spent one.
      auth_is(Enum.at(api(r), 1), "ACCESS02")

      assert S.getprop(res, "ok") == true, "the caller sees the successful retry"
    end

    test "the retry happens once, not in a loop" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      # Every API call is refused: a second 401 on a token bought moments ago
      # is a real failure, and spinning on it would hang instead of failing.
      r = recorder(%{api: [401]})
      Univec.direct(exchange_sdk(r), S.jm(["path", "/thing"]))

      assert length(api(r)) == 2, "exactly one retry"
      assert length(token(r)) == 2
    end

    test "a status outside exchange.statuses is not an expiry" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder(%{api: [403]})
      Univec.direct(exchange_sdk(r), S.jm(["path", "/thing"]))

      assert length(api(r)) == 1, "403 is not in the default statuses"
      assert length(token(r)) == 1
    end

    test "exchange.statuses is configurable" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder(%{api: [403, 200]})
      Univec.direct(exchange_sdk(r, [{"statuses", S.jt([403])}]), S.jm(["path", "/thing"]))

      assert length(api(r)) == 2, "403 was declared an expiry"
    end

    test "the endpoint and the request and response field names are configurable" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder(%{response: "token", path: "oauth/grant"})

      client =
        exchange_sdk(r, [
          {"path", "oauth/grant"},
          {"request", "grant"},
          {"response", "token"}
        ])

      Univec.direct(client, S.jm(["path", "/thing"]))

      assert length(token(r)) == 1

      assert String.ends_with?(hd(token(r)).url, "/oauth/grant"),
             "the token endpoint is relative to base: " <> hd(token(r)).url

      assert S.getprop(Univec.Json.parse(hd(token(r)).body), "grant") == @refresh
      auth_is(hd(api(r)), "ACCESS01")
    end

    test "an explicit apikey is spent before anything is bought" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      # A caller who already holds an access token should use it; expiry is
      # what moves them onto the exchange, and the API is what says so.
      r = recorder()
      Univec.direct(exchange_sdk(r, [], [{"apikey", "HELDTOKEN01"}]), S.jm(["path", "/thing"]))

      assert token(r) == [], "nothing needed buying"
      auth_is(hd(api(r)), "HELDTOKEN01")
    end

    test "a held apikey that has expired falls through to the exchange" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder(%{api: [401, 200]})
      Univec.direct(exchange_sdk(r, [], [{"apikey", "STALETOKEN01"}]), S.jm(["path", "/thing"]))

      auth_is(Enum.at(api(r), 0), "STALETOKEN01")
      auth_is(Enum.at(api(r), 1), "ACCESS01")
    end

    test "no refresh token anywhere is an error, not an unauthenticated call" do
      r = recorder()
      res = Univec.direct(exchange_sdk(r), S.jm(["path", "/thing"]))

      assert S.getprop(res, "ok") == false, "expected a failure, got: " <> inspect(res)
      assert err_message(res) =~ "no refresh token"

      assert api(r) == [],
             "a request must not go out unauthenticated because the chain was empty: " <> wire(r)
    end

    test "a failing token endpoint surfaces the API refusal, not a spin" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      # The first purchase succeeds; the second (after the 401) does not.
      r = recorder(%{api: [401], tokenfail: 2})
      res = Univec.direct(exchange_sdk(r), S.jm(["path", "/thing"]))

      assert res != nil, "the caller got an answer rather than a hang"
      assert length(api(r)) == 1, "no retry after a failed purchase"
    end

    test "auth nil suppresses the credential and buys nothing" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      # `auth: nil` is the documented way to send no credential at all. A
      # refusal of a deliberately unauthenticated request is not an expired
      # token: buying one and retrying would transmit exactly the credential
      # the caller suppressed.
      r = recorder(%{api: [401]})
      Univec.direct(exchange_sdk(r, [], [{"auth", nil}]), S.jm(["path", "/thing"]))

      assert length(api(r)) == 1, "a suppressed request must not be retried"
      assert hd(api(r)).auth == nil, "no credential may be sent when auth is suppressed"
      assert token(r) == [], "a suppressed request must not buy a token either"
    end

    test "exchange off leaves the feature exactly as it was" do
      System.put_env(@envprefix <> "APIKEY", "PLAINKEY01")

      r = recorder()
      Univec.direct(sdk(r, [{"feature", envchain()}]), S.jm(["path", "/thing"]))

      assert token(r) == []
      auth_is(hd(api(r)), "PLAINKEY01")
    end

    test "test mode buys nothing and needs no token endpoint" do
      System.put_env(@envprefix <> "REFRESH_TOKEN", @refresh)

      r = recorder()

      client =
        Univec.test(S.jm([]), S.jm([
          "base", @base,
          "allow", S.jm(["op", "direct,graphql,list,load"]),
          "system", S.jm(["fetch", r.fetch]),
          "feature",
          secrets([
            {"name", "refresh_token"},
            {"providers", providers([S.jm(["kind", "env", "prefix", @envprefix])])},
            {"exchange", S.jm(["active", true])}
          ])
        ]))

      Univec.direct(client, S.jm(["path", "/thing"]))

      assert calls(r) == [], "test mode must not do IO"

      # A deterministic placeholder, so offline suites need no configuration.
      assert Secrets.credential(client) == "test-access_token"
    end
  end

  # ---- template helpers ----------------------------------------------------

  # A callable `list` op for SOME entity this SDK generates, or nil.
  #
  # SEARCH for a usable op rather than taking the first entity and hoping: an
  # API's first entity by name need not have a `list`, and a template cannot
  # know which does.
  defp list_op(client) do
    ents = S.getprop(Univec.Config.make_config(), "entity")

    if not S.ismap(ents) do
      nil
    else
      Enum.find_value(S.keysof(ents), fn name ->
        if S.ismap(S.getpath(ents, name <> ".op.list")) do
          factory = existing_atom(name)

          if factory != nil and
               Enum.member?(Univec.__info__(:functions), {factory, 2}) do
            ent = apply(Univec, factory, [client, nil])
            mod = S.getprop(ent, "_module")

            if mod != nil and Code.ensure_loaded?(mod) and function_exported?(mod, :list, 3) do
              fn -> apply(mod, :list, [ent, nil, nil]) end
            end
          end
        end
      end)
    end
  end

  # Run an entity op and answer with its failure MESSAGE ("" when it
  # succeeded). An entity op raises by default rather than returning its
  # error, so a fail-closed assertion has to reach the message through the
  # raise.
  defp opfail(op) do
    out = op.()
    if is_exception(out), do: Exception.message(out), else: ""
  rescue
    e -> Exception.message(e)
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp wait_dead(_pid, 0), do: :ok

  defp wait_dead(pid, n) do
    if Process.alive?(pid) do
      Process.sleep(10)
      wait_dead(pid, n - 1)
    else
      :ok
    end
  end
end
