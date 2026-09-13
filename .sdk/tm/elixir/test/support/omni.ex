# Univec SDK corpus test runner: the vendored @voxgig/omni engine driven
# through its NATIVE API (`Voxgig.Omni.Runner.make_runner/2`), presented to the
# corpus suites in the runner shape they already use (`:spec`, `:runset`,
# `:runsetflags`, `:client`). No compatibility shim is vendored: the adapter
# below IS the whole bridge, per language, per the vendor-tag rollout
# (docs/design/vendor-tag-rollout.md, Decision 4). It is the Elixir peer of
# tm/lua/test/omni.lua, tm/rb/test/omni.rb, tm/clojure/test/sdk/test/omni.clj
# and tm/swift/Tests/UnivecSDKTests/OmniResolver.swift.
#
# Five local decisions, each load-bearing:
#
# 1. TWO VALUE MODELS, converted at the subject boundary. omni's Elixir port
#    speaks IMMUTABLE native data - `ismap` is `is_map/1` minus structs,
#    `islist` is `is_list/1`, absence is the `:"$omni_absent"` atom. The SDK
#    and its vendored struct speak a MUTABLE ETS HEAP, because struct's
#    contract is that a utility MUTATES the node it is given: a node there is
#    a tagged handle - `{:vmap, id}` / `{:vlist, id}` - which is a TUPLE, so
#    omni's own predicates read every SDK node as an opaque leaf and its
#    walkers never descend into one. Neither model recognises the other, so
#    `wrapsubject` converts every argument on the way in (`tostruct`) and the
#    result on the way out (`toomni`).
#
# 2. ARGUMENT WRITEBACK VIA `runsetflags_args`. 13 struct entries assert an
#    IN-PLACE rewrite of the argument - `minor/setpath` in all 7 and
#    `merge/integrity` in all 6. The subject mutates the HEAP COPY that
#    decision 1 built, which the immutable list omni holds can never see. The
#    port carries a second entry point for exactly this (`runsetflags_args`:
#    the subject returns `{args, result}` and `checkresult` builds the `args`
#    base from what came back), so every subject goes through it and hands its
#    post-call arguments back. omni-rust, omni-cpp, omni-ocaml and omni-swift
#    use the same channel for the same reason.
#
# 3. `match: {ctx: ...}` IS RETARGETED ONTO `match: {args: {"0": ...}}`.
#    Nine primary entries assert on context state the utility WROTE, and
#    `checkresult` reads that base from `entry.ctx` - which `resolveargs`
#    froze BEFORE the subject ran. In a mutable-object port the frozen
#    reference and the live context are the same thing; on the BEAM they are
#    two values, so every such assertion would read the pre-call state. omni's
#    own args channel (decision 2) is the post-call view, and args[0] IS the
#    ctx of a ctx entry - omni itself sets `args = [entry.ctx]` - so moving
#    the assertion from `ctx` to `args.0` reads the SAME map, post-call, and
#    preserves every leaf. `retargetctx/1` does that rewrite on the spec
#    handed to the engine; nothing is dropped, weakened or skipped. This is
#    the Swift port's decision 3, for the identical value-semantics reason;
#    the upstream fix is for `run_entry` to re-point `entry["ctx"]` at the
#    returned `callargs` head, filed as a follow-up rather than worked around
#    by editing a vendored file.
#
# 4. NO-VALUE ARITY. An entry carrying none of `in`/`args`/`ctx` must reach
#    the subject as NO value, not as one null: the corpus has both
#    `{in: null, out: <T_null>}` and `{out: <T_noval>}`, and a port that
#    collapses them silently passes one of the two. omni models the absence
#    as its ABSENT sentinel; `trimabsent/1` drops trailing absents so the
#    subject receives an EMPTY argument list, which is what the corpus
#    subjects already branch on (`typify()` answers T_noval where
#    `typify(nil)` answers T_null, and `stringify/0` and `pathify/0` carry the
#    same no-arg arity).
#
# 5. NIL ON THE WAY OUT IS ABSENT. Elixir has one `nil` where the canonical
#    port has `undefined` and `null`, so a subject that returns NOTHING and
#    one that returns JSON null are indistinguishable here (the struct port
#    says so in its own header: "the canonical `undefined` and JSON `null` are
#    both `nil`"). Only the `{null: false}` groups can tell, and there the
#    corpus is lopsided: reading a top-level `nil` as ABSENT costs 4 entries
#    (named and guarded in struct_corpus_test.exs), reading it as null costs
#    43. So a TOP-LEVEL nil result becomes ABSENT; a nil stored INSIDE a
#    returned node stays a JSON null, because struct's `setprop` genuinely
#    stores it and `keysof` genuinely reports the key.
#
# The live SDK crosses both converters BY REFERENCE: a struct heap handle is a
# tuple and the provider carries `@livekey`, so neither is ever rebuilt as
# corpus data and no cyclic SDK object is ever walked.

defmodule Univec.Omni do
  alias Voxgig.Omni.Runner
  alias Voxgig.Omni.Util, as: U
  alias Voxgig.Struct, as: S

  # Marks the provider map as a LIVE object rather than corpus data, so
  # `tostruct` hands it across by reference instead of rebuilding it as a
  # struct node (which would leave every `ctx.client` reader with a heap map
  # that answers nothing).
  @livekey :__omni_live__
  @counter :__omni_cases__

  # --- omni's own vocabulary, re-exported ----------------------------------
  #
  # The corpus suites and the smoke test never reach into the vendored
  # namespaces themselves.

  def nullmark, do: U.nullmark()
  def undefmark, do: U.undefmark()
  def existsmark, do: U.existsmark()
  def absent, do: U.absent()

  def omnierror?(%Voxgig.Omni.OmniError{}), do: true
  def omnierror?(_), do: false

  def stringify(val), do: U.stringify(val)
  def deepequal(a, b), do: U.deepequal(a, b)

  # --- executed-case tally -------------------------------------------------
  #
  # omni raises on the first failure rather than tallying, so a suite that
  # passes proves nothing about HOW MUCH ran. Every subject invocation is
  # counted here and the suites assert a floor, which is what catches a
  # renamed corpus section or a spec that compiled to an empty set.

  def reset_cases, do: Process.put(@counter, 0)
  def cases, do: Process.get(@counter, 0)
  defp tally, do: Process.put(@counter, Process.get(@counter, 0) + 1)

  # --- decision 1: omni's model -> the SDK's -------------------------------

  @doc "Convert one omni value into the SDK's struct model."
  def tostruct(val) do
    cond do
      U.isabsent(val) ->
        nil

      live?(val) ->
        val

      is_map(val) and not is_struct(val) ->
        S.jm(Enum.flat_map(val, fn {key, sub} -> [to_string(key), tostruct(sub)] end))

      is_list(val) ->
        S.jt(Enum.map(val, &tostruct/1))

      true ->
        val
    end
  end

  defp live?(val), do: is_map(val) and not is_struct(val) and Map.has_key?(val, @livekey)

  # --- decision 1/5: the SDK's model -> omni's -----------------------------

  @doc """
  Convert one SDK value into omni's model.

  `top` distinguishes the RESULT position from a position inside a returned
  node: only a top-level nil becomes ABSENT (decision 5).
  """
  def toomni(val), do: toomni(val, [], true)
  def toomni(val, top) when is_boolean(top), do: toomni(val, [], top)

  defp toomni(val, seen, top) do
    cond do
      val == S.noarg() ->
        U.absent()

      is_nil(val) ->
        if top, do: U.absent(), else: nil

      S.ismap(val) ->
        if seen?(seen, val) do
          nil
        else
          inner = [val | seen]

          Enum.reduce(S.keysof(val), %{}, fn key, acc ->
            Map.put(acc, to_string(key), toomni(S.getprop(val, key), inner, false))
          end)
        end

      S.islist(val) ->
        if seen?(seen, val) do
          nil
        else
          inner = [val | seen]
          n = S.size(val)

          if n == 0 do
            []
          else
            Enum.map(0..(n - 1), fn i -> toomni(S.getelem(val, i), inner, false) end)
          end
        end

      true ->
        val
    end
  end

  # A heap handle is reference-stable, so identity is the cycle test. Cyclic
  # reaches are SDK bookkeeping (client -> root ctx -> client), never corpus
  # data; a repeat becomes nil rather than looping forever.
  defp seen?(seen, val), do: Enum.any?(seen, fn s -> s === val end)

  # --- decision 4: no-value arity ------------------------------------------

  defp trimabsent(args) do
    args |> Enum.reverse() |> Enum.drop_while(&U.isabsent/1) |> Enum.reverse()
  end

  # --- decision 2: the subject boundary ------------------------------------

  # Anything that is not a one-argument function is NOT a subject: the SDK's
  # utility map carries plain values too (`struct` answers the module itself),
  # and omni asks the provider for a subject named after the SECTION.
  defp wrapsubject(subject) when not is_function(subject, 1), do: nil

  defp wrapsubject(subject) do
    fn args ->
      tally()
      sargs = args |> trimabsent() |> Enum.map(&tostruct/1)
      res = subject.(sargs)
      # The arguments go back in NON-top position: an argument that was a
      # JSON null is still a JSON null, it is only the RESULT slot that
      # decision 5 reads as absence.
      {Enum.map(sargs, fn a -> toomni(a, false) end), toomni(res)}
    end
  end

  # --- decision 3: retarget a ctx assertion onto the args channel ----------

  defp retargetctx(testspec) do
    set = U.get(testspec, "set")

    if U.ismap(testspec) and U.islist(set) do
      Map.put(testspec, "set", Enum.map(set, &retargetentry/1))
    else
      testspec
    end
  end

  defp retargetentry(entry) do
    check = U.get(entry, "match")

    retarget? =
      U.ismap(entry) and U.ismap(check) and Map.has_key?(check, "ctx") and
        not Map.has_key?(check, "args") and
        (Map.has_key?(entry, "ctx") or Map.has_key?(entry, "args"))

    if retarget? do
      moved =
        check
        |> Map.delete("ctx")
        |> Map.put("args", %{"0" => Map.get(check, "ctx")})

      Map.put(entry, "match", moved)
    else
      entry
    end
  end

  # --- flags ---------------------------------------------------------------
  #
  # The vendored runner reads `:null` and `:name` as ATOMS; a suite may spell
  # either. Translate rather than make every call site remember.

  defp normflags(nil), do: %{}

  defp normflags(flags) when is_map(flags) do
    Map.new(flags, fn
      {key, val} when is_binary(key) -> {String.to_atom(key), val}
      {key, val} -> {key, val}
    end)
  end

  defp normflags(_), do: %{}

  # --- the provider --------------------------------------------------------
  #
  # omni reads a provider as a map of hooks; the SDK it wraps rides along
  # under `:sdk`, which is where a corpus subject reaches the live client
  # (omni stamps the provider onto every ctx/args map entry as "client").

  defp sdkprovider(client) do
    utility = Univec.get_utility(client)

    %{
      @livekey => true,
      sdk: client,
      utility: utility,
      # Subjects are handed in per-set by the corpus suites; a by-name lookup
      # is answered from the utility for anything that asks.
      subject: fn name -> wrapsubject(lookup(utility, name)) end,
      # A DEF.client entry becomes another SDK instance, rewrapped with the
      # same shape rather than a bare hook map.
      client: fn options -> sdkprovider(Univec.test(nil, tostruct(options))) end,
      # Client options may reference the runner store.
      inject: fn options, store ->
        toomni(S.inject(tostruct(options), tostruct(store)), false)
      end,
      errify: &errify/1
    }
  end

  # Read `name` off the SDK's utility: the corpus spells subjects in
  # camelCase, the Elixir utility registers them in snake_case.
  defp lookup(utility, name) when is_binary(name) do
    found = S.getprop(utility, name)
    if found == nil, do: S.getprop(utility, snake(name)), else: found
  end

  defp lookup(_utility, _name), do: nil

  defp snake(name) do
    name
    |> String.replace(~r/([A-Z])/, "_\\1")
    |> String.downcase()
  end

  # The JSON form of an error, with the SDK error's `code` carried along -
  # the stock {name,message} shape drops it, and `match: {err: {code}}` is
  # how a refusal is asserted by kind rather than by message text. The ctx
  # an SDK error carries is NOT mirrored: it reaches the client, which
  # reaches the root ctx, which reaches the client again.
  def errify(%Univec.Error{} = err) do
    %{"name" => "Error", "message" => Exception.message(err), "code" => err.code || ""}
  end

  def errify(err) when is_exception(err) do
    %{"name" => err.__struct__ |> Module.split() |> List.last(), "message" => Exception.message(err)}
  end

  def errify(err), do: %{"name" => "Error", "message" => to_string(err)}

  # --- the runner ----------------------------------------------------------

  @doc """
  The corpus runner, in the shape the suites use.

  `specref` is a path to the shared corpus JSON (relative paths resolve
  against the current working directory, as the suites' `../.sdk/...`
  constant assumes) or an already-parsed spec in omni's value model, which
  keeps the smoke test free of fixture files.

  Returns a function of the section name producing a map with `:spec`,
  `:runset`, `:runsetflags`, `:client` and `:sdk`.
  """
  def make_runner(specref, client) do
    specref =
      if is_binary(specref) and not String.starts_with?(specref, "/") do
        Path.expand(specref, File.cwd!())
      else
        specref
      end

    provider = sdkprovider(client)
    runner = Runner.make_runner(specref, provider)

    fn name ->
      runpack = runner.(name, %{})
      omniargs = runpack.runsetflags_args

      runsetflags = fn testspec, flags, subject ->
        omniargs.(retargetctx(testspec), normflags(flags), wrapsubject(subject))
      end

      %{
        spec: runpack.spec,
        client: provider,
        sdk: client,
        runsetflags: runsetflags,
        runset: fn testspec, subject -> runsetflags.(testspec, %{}, subject) end
      }
    end
  end

  @doc """
  Convert NULLMARK sentinels back into real nulls.

  NOT a delegation to omni's `nullmodifier/1`, deliberately: omni's RETURNS
  the replacement, while struct's `inject` passes this as its `modify` hook
  and expects it to WRITE `parent[key]` in place.
  """
  def null_modifier(val, key, parent, _inj) do
    cond do
      val == U.nullmark() -> S.setprop(parent, key, nil)
      is_binary(val) -> S.setprop(parent, key, String.replace(val, U.nullmark(), "null"))
      true -> :ok
    end
  end
end
