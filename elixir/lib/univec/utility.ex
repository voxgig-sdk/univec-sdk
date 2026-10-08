# Univec SDK utility
#
# The utility object is a struct map node whose members are closures — the
# exact registrar shape of the donor. Features wrap `utility.fetcher` (and
# may override any member) by setprop on this reference-stable node, so the
# whole pipeline observes the change. The module functions below dispatch
# through the node, preserving that override contract.

defmodule Univec.Utility do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{Context, Spec, Result, Response, Operation}
  # prepare_auth IS GENERATED, not templated: where the credential goes
  # (header | query | cookie, and under what name) is a fact about the API,
  # which apidef resolves into main.kit.info.security and a template cannot
  # express. It lives in Univec.PrepareAuth, emitted by
  # src/cmp/elixir/PrepareAuth_elixir.ts into lib/<app>/prepare_auth.ex.
  alias Univec.PrepareAuth

  @default_user_agent "Mozilla/5.0 (compatible; UnivecSDK/1.0)"

  # Content type every GraphQL-over-HTTP request uses.
  @graphql_content_type "application/json"

  # ---- construction / registration ----------------------------------------

  def new do
    u = S.jm([])
    S.setprop(u, "struct", Voxgig.Struct)
    S.setprop(u, "custom", S.jm([]))

    reg = [
      {"clean", &clean_impl/2},
      {"clean_add", &clean_add_impl/2},
      {"done", &done_impl/1},
      {"make_error", &make_error_impl/2},
      {"feature_add", &feature_add_impl/2},
      {"feature_hook", &feature_hook_impl/2},
      {"feature_init", &feature_init_impl/2},
      {"fetcher", &fetcher_impl/3},
      {"make_fetch_def", &make_fetch_def_impl/1},
      {"make_context", &Context.new/2},
      {"make_options", &make_options_impl/1},
      {"make_request", &make_request_impl/1},
      {"make_response", &make_response_impl/1},
      {"make_result", &make_result_impl/1},
      {"make_point", &make_point_impl/1},
      {"make_spec", &make_spec_impl/1},
      {"make_url", &make_url_impl/1},
      {"param", &param_impl/2},
      {"prepare_auth", &PrepareAuth.prepare_auth_impl/1},
      {"prepare_body", &prepare_body_impl/1},
      {"prepare_headers", &prepare_headers_impl/1},
      {"prepare_method", &prepare_method_impl/1},
      {"prepare_params", &prepare_params_impl/1},
      {"prepare_path", &prepare_path_impl/1},
      {"prepare_query", &prepare_query_impl/1},
      {"graphql_body", &graphql_body_impl/1},
      {"graphql_errors", &graphql_errors_impl/1},
      {"result_basic", &result_basic_impl/1},
      {"result_body", &result_body_impl/1},
      {"result_headers", &result_headers_impl/1},
      {"transform_request", &transform_request_impl/1},
      {"transform_response", &transform_response_impl/1}
    ]

    Enum.each(reg, fn {k, f} -> S.setprop(u, k, f) end)
    u
  end

  defp u(ctx, name), do: S.getprop(S.getprop(ctx, "utility"), name)

  # ---- dispatch wrappers ---------------------------------------------------

  def feature_hook(ctx, name), do: u(ctx, "feature_hook").(ctx, name)
  def feature_add(ctx, f), do: u(ctx, "feature_add").(ctx, f)
  def feature_init(ctx, f), do: u(ctx, "feature_init").(ctx, f)
  def make_point(ctx), do: u(ctx, "make_point").(ctx)
  def make_spec(ctx), do: u(ctx, "make_spec").(ctx)
  def make_request(ctx), do: u(ctx, "make_request").(ctx)
  def make_response(ctx), do: u(ctx, "make_response").(ctx)
  def make_result(ctx), do: u(ctx, "make_result").(ctx)
  def make_error(ctx, err), do: u(ctx, "make_error").(ctx, err)
  def done(ctx), do: u(ctx, "done").(ctx)
  def make_fetch_def(ctx), do: u(ctx, "make_fetch_def").(ctx)
  def make_url(ctx), do: u(ctx, "make_url").(ctx)
  def make_options(ctx), do: u(ctx, "make_options").(ctx)
  def fetcher(ctx, url, fetchdef), do: u(ctx, "fetcher").(ctx, url, fetchdef)
  def param(ctx, pd), do: u(ctx, "param").(ctx, pd)
  def clean(ctx, v), do: u(ctx, "clean").(ctx, v)
  def clean_add(ctx, v), do: u(ctx, "clean_add").(ctx, v)
  def prepare_auth(ctx), do: u(ctx, "prepare_auth").(ctx)
  def prepare_body(ctx), do: u(ctx, "prepare_body").(ctx)
  def prepare_headers(ctx), do: u(ctx, "prepare_headers").(ctx)
  def prepare_method(ctx), do: u(ctx, "prepare_method").(ctx)
  def prepare_params(ctx), do: u(ctx, "prepare_params").(ctx)
  def prepare_path(ctx), do: u(ctx, "prepare_path").(ctx)
  def prepare_query(ctx), do: u(ctx, "prepare_query").(ctx)
  def graphql_body(ctx), do: u(ctx, "graphql_body").(ctx)
  def graphql_errors(ctx), do: u(ctx, "graphql_errors").(ctx)
  def result_basic(ctx), do: u(ctx, "result_basic").(ctx)
  def result_body(ctx), do: u(ctx, "result_body").(ctx)
  def result_headers(ctx), do: u(ctx, "result_headers").(ctx)
  def transform_request(ctx), do: u(ctx, "transform_request").(ctx)
  def transform_response(ctx), do: u(ctx, "transform_response").(ctx)

  # ---- helpers -------------------------------------------------------------

  defp opts_map(client) do
    o = S.clone(S.getprop(client, "options"))
    if S.ismap(o), do: o, else: S.jm([])
  end

  defp strv(v), do: if(is_binary(v), do: v, else: "")

  # ---- clean ---------------------------------------------------------------
  #
  # Everything that leaves the pipeline passes through clean; inside it data
  # stays raw, so a hook can still read the header it must add to. See
  # docs/explanation/secret-redaction.md.

  @clean_maxdepth 32
  @clean_circular "[circular]"

  defp strof(v) do
    cond do
      is_binary(v) -> v
      is_number(v) -> to_string(v)
      is_atom(v) and v != nil -> to_string(v)
      true -> ""
    end
  end

  defp numof(v, _d) when is_number(v), do: trunc(v)
  defp numof(_v, d), do: d

  defp normkey(k), do: k |> strof() |> String.downcase() |> String.replace(~r/[-_]/, "")

  defp splitkeys(keys) do
    strof(keys)
    |> String.split(~r/\s*,\s*/)
    |> Enum.map(&normkey/1)
    |> Enum.reject(&(&1 == ""))
  end

  def splitvalues(values) do
    cond do
      S.islist(values) -> list_values(values) |> Enum.filter(&is_binary/1)
      is_list(values) -> Enum.filter(values, &is_binary/1)
      true -> strof(values) |> String.split(~r/\s*,\s*/) |> Enum.reject(&(&1 == ""))
    end
  end

  defp list_values(node) do
    if S.islist(node), do: Enum.map(H.entries(node), &elem(&1, 1)), else: []
  end

  defp count_opt(v, dflt) do
    case Float.parse(strof(v)) do
      {n, ""} when n >= 0 -> trunc(Float.floor(n))
      _ -> dflt
    end
  end

  # The derived clean block: a struct node so it lives in options.__derived__
  # and its `values` stays MUTABLE after make_options - features register
  # what they resolve later.
  def make_clean_config(cleanopts) do
    o = fn k -> if S.ismap(cleanopts), do: S.getprop(cleanopts, k), else: nil end
    mask = o.("mask")

    S.jm([
      "active", o.("active") != false,
      "keys", S.jt(splitkeys(o.("keys"))),
      "values", S.jt([]),
      "mask", if(is_binary(mask), do: mask, else: "[redacted]"),
      "hint", count_opt(o.("hint"), 0),
      "min", max(1, count_opt(o.("min"), 4))
    ])
  end

  # A context without options (make_error accepts a bare one) still masks by
  # the schema defaults.
  defp clean_config(ctx) do
    options = if S.ismap(ctx), do: S.getprop(ctx, "options"), else: nil
    derived = if S.ismap(options), do: S.getpath(options, "__derived__.clean"), else: nil

    if S.ismap(derived) do
      derived
    else
      make_clean_config(S.getprop(Univec.Schema.optspec(), "clean"))
    end
  end

  # The encoded forms a value travels in.
  defp clean_forms(value) do
    j = S.jsonify(value)

    [value, Base.encode64(value), S.escurl(value), String.slice(j, 1, String.length(j) - 2)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def clean_add_impl(ctx, value) do
    cfg = clean_config(ctx)
    minlen = numof(S.getprop(cfg, "min"), 4)

    if is_binary(value) and String.length(value) >= minlen and S.islist(S.getprop(cfg, "values")) do
      forms = Enum.filter(clean_forms(value), &(String.length(&1) >= minlen))

      # A registration reads the registry and writes a new one, so a request
      # in another process registering at once would drop it; they take turns.
      have = list_values(S.getprop(cfg, "values"))

      if Enum.any?(forms, &(&1 not in have)) do
        registering(fn -> publish(cfg, forms) end)
      end
    end

    nil
  end

  # Retried after a millisecond rather than after global's back-off sleep,
  # which grows to seconds; the lock is released if its holder dies.
  defp registering(fun) do
    case :global.trans({{__MODULE__, :clean_registry}, self()}, fun, [node()], 0) do
      :aborted ->
        Process.sleep(1)
        registering(fun)

      done ->
        done
    end
  end

  defp publish(cfg, forms) do
    have = list_values(S.getprop(cfg, "values"))
    add = Enum.reject(forms, &(&1 in have))

    # Longest first, so a value is never masked by a substring of itself.
    if add != [] do
      S.setprop(cfg, "values", S.jt(Enum.sort_by(have ++ add, &(-String.length(&1)))))
    end
  end

  defp mask_value(cfg, value) do
    hint = numof(S.getprop(cfg, "hint"), 0)
    mask = strof(S.getprop(cfg, "mask"))

    if hint > 0 and String.length(value) > 2 * hint do
      mask <> String.slice(value, -hint, hint)
    else
      mask
    end
  end

  defp clean_string(cfg, text) do
    Enum.reduce(list_values(S.getprop(cfg, "values")), text, fn value, out ->
      if is_binary(value) and String.contains?(out, value) do
        String.replace(out, value, mask_value(cfg, value))
      else
        out
      end
    end)
  end

  defp sensitive_key?(cfg, key) do
    if key == nil or is_number(key) do
      false
    else
      nk = normkey(key)
      Enum.any?(list_values(S.getprop(cfg, "keys")), fn k -> is_binary(k) and String.contains?(nk, k) end)
    end
  end

  # Every scalar under a sensitive name, at any depth and of any shape: a
  # credential mistyped as a map or a number is still a credential, and the
  # validation error that rejects it quotes it.
  def clean_add_sensitive(ctx, val) do
    clean_add_sensitive_at(ctx, clean_config(ctx), val, false, 0, [])
  end

  defp clean_add_sensitive_at(ctx, cfg, val, under, depth, seen) do
    cond do
      val == nil or depth >= @clean_maxdepth ->
        nil

      is_binary(val) ->
        if under, do: clean_add_impl(ctx, val)

      is_number(val) ->
        if under, do: clean_add_impl(ctx, number_text(val))

      val in seen ->
        nil

      S.ismap(val) or S.islist(val) ->
        Enum.each(H.entries(val), fn {k, v} ->
          clean_add_sensitive_at(ctx, cfg, v, under or sensitive_key?(cfg, k), depth + 1, [val | seen])
        end)

      is_map(val) and not is_struct(val) ->
        Enum.each(val, fn {k, v} ->
          clean_add_sensitive_at(ctx, cfg, v, under or sensitive_key?(cfg, k), depth + 1, [val | seen])
        end)

      is_list(val) ->
        Enum.each(val, fn v -> clean_add_sensitive_at(ctx, cfg, v, under, depth + 1, [val | seen]) end)

      true ->
        nil
    end

    nil
  end

  defp number_text(n) when is_float(n) and abs(n) < 9.0e15 and n == trunc(n),
    do: Integer.to_string(trunc(n))

  defp number_text(n), do: to_string(n)

  # A registered value used as a property name is masked like any other
  # string; names that mask alike take a counter, so none is lost.
  defp clean_name(cfg, out, key) do
    key = strof(key)
    name = clean_string(cfg, key)
    taken = S.keysof(out)

    if name == key or name not in taken do
      name
    else
      i = Enum.find(Stream.iterate(1, &(&1 + 1)), fn i -> (name <> "#" <> Integer.to_string(i)) not in taken end)
      name <> "#" <> Integer.to_string(i)
    end
  end

  # A masked plain-data COPY: functions dropped, cycles cut, an SDK error as
  # its code and message, and nothing shared with the live value, whose spec
  # must stay raw.
  defp clean_snapshot(cfg, val, key, depth, seen) do
    cond do
      val == nil ->
        nil

      is_binary(val) ->
        if sensitive_key?(cfg, key), do: mask_value(cfg, val), else: clean_string(cfg, val)

      is_function(val) ->
        :__drop__

      is_number(val) or is_boolean(val) or is_atom(val) ->
        if sensitive_key?(cfg, key), do: S.getprop(cfg, "mask"), else: val

      depth >= @clean_maxdepth or val in seen ->
        @clean_circular

      sensitive_key?(cfg, key) ->
        S.getprop(cfg, "mask")

      S.ismap(val) ->
        out = S.jm([])

        Enum.each(H.entries(val), fn {k, v} ->
          c = clean_snapshot(cfg, v, k, depth + 1, [val | seen])
          if c != :__drop__, do: S.setprop(out, clean_name(cfg, out, k), c)
        end)

        out

      S.islist(val) ->
        out = S.jt([])

        Enum.each(H.entries(val), fn {i, v} ->
          c = clean_snapshot(cfg, v, i, depth + 1, [val | seen])
          S.setprop(out, S.size(out), if(c == :__drop__, do: nil, else: c))
        end)

        out

      match?(%Univec.Error{}, val) ->
        S.jm(["code", clean_code(cfg, val.code), "message", clean_string(cfg, strof(val.msg))])

      is_exception(val) ->
        S.jm(["message", clean_string(cfg, Exception.message(val))])

      is_struct(val) ->
        clean_snapshot(cfg, Map.from_struct(val), key, depth, seen)

      is_map(val) ->
        out = S.jm([])

        # Sorted, so colliding masked names number the same way every run.
        Enum.each(Enum.sort_by(val, fn {k, _} -> strof(k) end), fn {k, v} ->
          c = clean_snapshot(cfg, v, k, depth + 1, [val | seen])
          if c != :__drop__, do: S.setprop(out, clean_name(cfg, out, k), c)
        end)

        out

      is_list(val) or is_tuple(val) ->
        items = if is_tuple(val), do: Tuple.to_list(val), else: val
        out = S.jt([])

        Enum.each(items, fn v ->
          c = clean_snapshot(cfg, v, nil, depth + 1, [val | seen])
          S.setprop(out, S.size(out), if(c == :__drop__, do: nil, else: c))
        end)

        out

      true ->
        clean_string(cfg, inspect(val))
    end
  end

  defp clean_field(cfg, v, key) do
    case clean_snapshot(cfg, v, key, 1, []) do
      :__drop__ -> nil
      c -> c
    end
  end

  defp clean_code(cfg, code), do: if(is_binary(code), do: clean_string(cfg, code), else: code)

  # The error is a struct, so "in place" is a copy carrying the same ctx.
  defp clean_error(cfg, err) do
    %{
      err
      | code: clean_code(cfg, err.code),
        msg: clean_string(cfg, strof(err.msg)),
        result: clean_field(cfg, err.result, "result"),
        spec: clean_field(cfg, err.spec, "spec")
    }
  end

  def clean_impl(ctx, val) do
    cfg = clean_config(ctx)

    cond do
      S.getprop(cfg, "active") == false -> val
      is_binary(val) -> clean_string(cfg, val)
      match?(%Univec.Error{}, val) -> clean_error(cfg, val)
      true -> clean_field(cfg, val, nil)
    end
  end

  # An exception is immutable, so one that never passed through make_error (a
  # hook's, a fetcher's) leaves as a copy with its string fields cleaned; one
  # whose message still quotes a secret, from a field of another type, leaves
  # as a RuntimeError carrying the cleaned message.
  def clean_exception(ctx, e) do
    cfg = clean_config(ctx)

    cond do
      S.getprop(cfg, "active") == false -> e
      match?(%Univec.Error{}, e) -> clean_error(cfg, e)
      true -> clean_foreign_exception(cfg, e)
    end
  end

  defp clean_foreign_exception(cfg, e) do
    copy =
      Enum.reduce(Map.from_struct(e), e, fn
        {k, v}, acc when is_binary(v) ->
          Map.put(acc, k, if(sensitive_key?(cfg, k), do: mask_value(cfg, v), else: clean_string(cfg, v)))

        _, acc ->
          acc
      end)

    text = Exception.message(copy)
    cleaned = clean_string(cfg, text)
    if cleaned == text, do: copy, else: RuntimeError.exception(cleaned)
  end

  # The explain map is the CALLER's node, so it is cleaned in place: what
  # they hold after the call is the cleaned record. With clean off,
  # explain.result is the live result make_error reads, so err is pruned
  # from a copy.
  def clean_explain(ctx) do
    ctrl = S.getprop(ctx, "ctrl")
    explain = if ctrl != nil, do: S.getprop(ctrl, "explain"), else: nil

    if S.ismap(explain) do
      cleaned = clean(ctx, explain)

      if S.ismap(cleaned) and cleaned != explain do
        Enum.each(S.keysof(explain), fn k -> S.delprop(explain, k) end)
        Enum.each(H.entries(cleaned), fn {k, v} -> S.setprop(explain, k, v) end)
      end

      er = S.getprop(explain, "result")
      if S.ismap(er), do: S.setprop(explain, "result", without(er, "err"))
    end

    nil
  end

  # ---- features ------------------------------------------------------------

  def feature_hook_impl(ctx, name) do
    client = S.getprop(ctx, "client")

    if client != nil do
      features = S.getprop(client, "features")

      if is_list(features) do
        Enum.each(features, fn f ->
          method = S.getprop(f, name)
          if S.isfunc(method), do: method.(ctx)
        end)
      end
    end

    nil
  end

  def feature_add_impl(ctx, f) do
    client = S.getprop(ctx, "client")
    features = S.getprop(client, "features") || []

    fopts = S.getprop(f, "_options")
    fopts = if S.ismap(fopts), do: fopts, else: S.jm([])
    before = S.getprop(fopts, "__before__")
    after_ = S.getprop(fopts, "__after__")
    replace = S.getprop(fopts, "__replace__")

    final =
      if H.truthy(before) or H.truthy(after_) or H.truthy(replace) do
        idx =
          Enum.find_index(features, fn ef ->
            name = S.getprop(ef, "name")
            before == name or after_ == name or replace == name
          end)

        case idx do
          nil ->
            features ++ [f]

          i ->
            name = S.getprop(Enum.at(features, i), "name")

            cond do
              before == name -> List.insert_at(features, i, f)
              after_ == name -> List.insert_at(features, i + 1, f)
              true -> List.replace_at(features, i, f)
            end
        end
      else
        features ++ [f]
      end

    S.setprop(client, "features", final)
    nil
  end

  def feature_init_impl(ctx, f) do
    fname = S.getprop(f, "name")
    options = S.getprop(ctx, "options")

    fopts =
      if options != nil do
        feature_opts = S.getprop(options, "feature")

        if S.ismap(feature_opts) do
          fo = S.getprop(feature_opts, fname)
          if S.ismap(fo), do: fo, else: S.jm([])
        else
          S.jm([])
        end
      else
        S.jm([])
      end

    if S.getprop(fopts, "active") == true do
      init_fn = S.getprop(f, "init")
      if S.isfunc(init_fn), do: init_fn.(ctx, fopts)
    end

    nil
  end

  # ---- make_options --------------------------------------------------------

  # Public camelCase option key -> snake_case utility member name, or nil
  # when the key is not a public name (see make_options_impl).
  defp util_member(key) when is_binary(key) do
    if String.contains?(key, "_") do
      nil
    else
      String.replace(key, ~r/([A-Z])/, "_\\1") |> String.downcase()
    end
  end

  defp util_member(_key), do: nil

  def make_options_impl(ctx) do
    options = H.or_(S.getprop(ctx, "options"), S.jm([]))

    custom_utils = S.getprop(options, "utility")

    # Utility overrides from options.
    #
    # A key naming a real utility member REPLACES it; anything else is
    # attached as a custom extra. Shelving everything in `custom` - a map
    # nothing reads - made `utility: %{"fetcher" => ...}`, the documented
    # transport seam, a silent no-op here while ts honoured it.
    #
    # Only a PUBLIC name may replace. Option keys are camelCase, as ts spells
    # them, and members here are snake_case; public names carry no underscore,
    # so an underscore means the caller named something of their own -
    # possibly the internal spelling of a real member. `make_error` must stay
    # an extension, or a non-callable would break the error path on the next
    # request.
    if S.ismap(custom_utils) do
      utility = S.getprop(ctx, "utility")

      if utility != nil do
        custom = S.getprop(utility, "custom")

        Enum.each(S.keysof(custom_utils), fn k ->
          val = S.getprop(custom_utils, k)
          member = util_member(k)

          if member != nil and member != "custom" and
               S.getprop(utility, member) != nil do
            S.setprop(utility, member, val)
          else
            S.setprop(custom, k, val)
          end
        end)
      end
    end

    # `auth` nil is the documented way to disable auth outright, and
    # prepare_auth honours it before it ever reads the apikey. It cannot
    # survive validate: a stored null reads as "no value", so the optspec's
    # `auth` default fires and the suppression silently becomes "use default
    # auth" - transmitting the credential the caller withheld. Withhold the
    # key for validate, then put the nil back. Same fix as ts/js/go
    # makeOptions.
    #
    # keysof rather than S.haskey: haskey is `getprop(...) != nil`, which
    # collapses a stored null and so cannot tell an ABSENT auth from a
    # suppressed one. keysof lists the key either way.
    auth_suppressed =
      S.ismap(options) and "auth" in S.keysof(options) and
        S.getprop(options, "auth") == nil

    opts0 = S.clone(options)
    opts0 = if S.ismap(opts0), do: opts0, else: S.jm([])
    if auth_suppressed, do: S.delprop(opts0, "auth")

    # Feature add-order. options.feature may be given as an ordered LIST of
    # {name, active, ...opts} entries (list position = add order) or a
    # {name => {opts}} map. Normalize a list to a map (so merge/validate/init
    # are unchanged) and remember the explicit order; a map defaults to
    # test-first so the `test` mock transport is the base of the wrapper chain.
    feature_raw = S.getprop(opts0, "feature")

    explicit_order =
      if S.islist(feature_raw) and S.size(feature_raw) > 0 do
        fmap = S.jm([])

        order =
          Enum.reduce(0..(S.size(feature_raw) - 1), [], fn i, acc ->
            entry = S.getelem(feature_raw, i)
            nm = if S.ismap(entry), do: S.getprop(entry, "name"), else: nil

            if is_binary(nm) do
              fopts = S.clone(entry)
              S.delprop(fopts, "name")
              S.setprop(fmap, nm, fopts)
              acc ++ [nm]
            else
              acc
            end
          end)

        S.setprop(opts0, "feature", fmap)
        order
      else
        nil
      end

    config = H.or_(S.getprop(ctx, "config"), S.jm([]))
    co = S.getprop(config, "options")
    cfgopts = if S.ismap(co), do: co, else: S.jm([])

    # THE OPTION SPEC IS GENERATED, NOT WRITTEN HERE.
    #
    # `Univec.Schema.optspec/0` is built from the model:
    # `main.kit.optspec` for the standard options, plus one entry per
    # feature this target carries, taken from that feature's own
    # `config.options` / `config.optspec`. Editing this file to add an
    # option would put it back where it was — one of twenty hand-maintained
    # copies of a schema nothing cross-checked — so add it to the model
    # instead and every ported target validates it.
    optspec = Univec.Schema.optspec()

    # The secret registry exists BEFORE validation, fed from the raw input,
    # so the constructor's own rejection of a mistyped credential is clean
    # too. A shallow merge over the schema defaults: the clean block is flat.
    cleanraw = S.jm([])
    blocks = [S.getprop(optspec, "clean"), S.getprop(cfgopts, "clean"), S.getprop(opts0, "clean")]

    Enum.each(blocks, fn src ->
      if S.ismap(src), do: Enum.each(H.entries(src), fn {k, v} -> S.setprop(cleanraw, k, v) end)
    end)

    cleancfg = make_clean_config(cleanraw)
    cleanctx = S.jm(["options", S.jm(["__derived__", S.jm(["clean", cleancfg])])])

    clean_add_sensitive(cleanctx, secret_scan(opts0, ["clean"]))

    Enum.each([cfgopts, opts0], fn src ->
      Enum.each(splitvalues(S.getpath(src, "clean.values")), fn raw -> clean_add_impl(cleanctx, raw) end)
    end)

    sys_fetch = S.getpath(opts0, "system.fetch")

    # CLONE the config side: `config` is a process-wide singleton
    # (Univec.Config.shared_config) and merge uses its nested nodes as
    # merge TARGETS, so without this one client's options (headers, server,
    # ...) are written into the shared config and inherited by every client
    # constructed afterwards.
    merged = S.merge(S.jt([S.jm([]), S.clone(cfgopts), opts0]))

    validated =
      try do
        S.validate(merged, optspec)
      rescue
        e in Voxgig.Struct.Error ->
          reraise %Voxgig.Struct.Error{message: clean_impl(cleanctx, Exception.message(e))},
                  __STACKTRACE__
      end

    opts = if S.ismap(validated), do: validated, else: S.jm([])

    # Restore the suppression the optspec default would otherwise erase.
    if auth_suppressed, do: S.setprop(opts, "auth", nil)

    # Resolve a templated base URL (e.g. https://{tenant_id}.hanko.io).
    # Every placeholder must resolve to a non-empty value: from options.server
    # (user), else the Config default. A placeholder that resolves to "" is a
    # construction ERROR in live mode - the URL cannot work - but in test mode
    # substitutes the deterministic value "test-<name>" so offline tests need
    # no configuration. The SDK constructor has no error return, so a missing
    # required variable RAISES: construction-time misconfiguration.
    base = S.getprop(opts, "base")

    if is_binary(base) and String.contains?(base, "{") do
      testmode =
        true == S.getpath(opts, "test.active") or
          true == S.getpath(opts, "feature.test.active")

      server = H.or_(S.getprop(opts, "server"), S.jm([]))
      mn = S.getpath(config, "main.name")
      sdkname = if is_binary(mn) and mn != "", do: mn, else: "SDK"

      resolved =
        Regex.replace(~r/\{([A-Za-z0-9_]+)\}/, base, fn _match, name ->
          val = S.getprop(server, name)
          val = if is_binary(val), do: val, else: ""

          cond do
            val != "" ->
              val

            testmode ->
              "test-" <> name

            true ->
              raise Univec.Error,
                code: "server_var_required",
                sdk: "Univec",
                msg:
                  "#{sdkname}: the server variable '#{name}' is required: the API " <>
                    "base URL is '#{base}' - pass %{\"server\" => %{\"#{name}\" => " <>
                    "\"...\"}} in the SDK options"
          end
        end)

      S.setprop(opts, "base", resolved)
    end

    if sys_fetch != nil do
      sysnode = S.getprop(opts, "system")

      if S.ismap(sysnode) do
        S.setprop(sysnode, "fetch", sys_fetch)
      else
        S.setprop(opts, "system", S.jm(["fetch", sys_fetch]))
      end
    end

    # Resolve the feature add-order: an explicit list order (above) wins;
    # otherwise order the map test-first, then the remaining names sorted, so
    # the outcome is deterministic and `test` is always the base transport.
    feature_order =
      case explicit_order do
        nil ->
          fmap = S.getprop(opts, "feature")
          fmap = if S.ismap(fmap), do: fmap, else: S.jm([])
          names = S.keysof(fmap)

          names =
            if Enum.member?(names, "test") do
              ["test" | Enum.reject(names, &(&1 == "test"))]
            else
              names
            end

          # Station special case, mirroring test's: its transport wrap must
          # sit immediately outside the base transport (inside retry/cache/
          # netsim), so map-form activation hoists it to just after test -
          # or first, when no test entry exists. Without this the sorted
          # default would init station last and wrap OUTSIDE the recording
          # features, turning its wire-truth events into fiction.
          if Enum.member?(names, "station") do
            rest = Enum.reject(names, &(&1 == "station"))

            at =
              case Enum.find_index(rest, &(&1 == "test")) do
                nil -> 0
                ti -> ti + 1
              end

            List.insert_at(rest, at, "station")
          else
            names
          end

        list ->
          list
      end

    derived = S.jm(["clean", cleancfg, "featureorder", S.jt(feature_order)])
    S.setprop(opts, "__derived__", derived)

    # Again over the merged result: the config's own defaults can carry one.
    clean_add_sensitive(S.jm(["options", opts]), secret_scan(opts, ["clean", "__derived__"]))

    opts
  end

  # The options to scan for secrets. The feature map is keyed by feature
  # names, not field names, so it is scanned as a list: `secrets` must not
  # make every setting of that feature a secret. Entity blocks hold entity
  # settings and seeded records, never a credential, so they are skipped, and
  # so are rbac's rules, keyed by entity and operation names.
  defp secret_scan(opts, names) do
    out = S.jm([])

    Enum.each(H.entries(opts), fn {k, v} ->
      cond do
        k in names or k == "entity" ->
          nil

        k == "feature" and (S.ismap(v) or S.islist(v)) ->
          blocks =
            Enum.map(H.entries(v), fn {fk, f} ->
              plain(f, if(S.ismap(v), do: fk, else: S.getprop(f, "name")))
            end)

          S.setprop(out, k, S.jt(blocks))

        k == "test" ->
          S.setprop(out, k, plain(v, nil))

        true ->
          S.setprop(out, k, v)
      end
    end)

    out
  end

  defp plain(node, name) do
    if name == "rbac", do: without(without(node, "entity"), "rules"), else: without(node, "entity")
  end

  defp without(node, key) do
    if S.ismap(node) do
      out = S.jm([])
      Enum.each(H.entries(node), fn {k, v} -> if k != key, do: S.setprop(out, k, v) end)
      out
    else
      node
    end
  end

  # ---- make_point ----------------------------------------------------------

  # A terminal parameter marks a record route (/boards/{id}); a
  # cross-reference ends in the relationship's name (/posts/{id}/author), and
  # failing that the shallower path wins. The same rule runs at generation
  # time, in helpers/opShape.ts — both sides must move together.
  defp parts_len(p) do
    parts = S.getprop(p, "parts")
    if S.islist(parts), do: S.size(parts), else: 0
  end

  defp terminal_param?(p) do
    parts = S.getprop(p, "parts")

    if S.islist(parts) and S.size(parts) > 0 do
      last = S.getelem(parts, S.size(parts) - 1)
      is_binary(last) and String.starts_with?(last, "{")
    else
      false
    end
  end

  defp own_point(points) do
    Enum.reduce(points, hd(points), fn cand, best ->
      ct = terminal_param?(cand)
      bt = terminal_param?(best)

      cond do
        ct != bt -> if ct, do: cand, else: best
        parts_len(cand) < parts_len(best) -> cand
        true -> best
      end
    end)
  end

  # The path parameters of a point that neither the call nor the entity gives
  # a value for, looked up as param_impl looks them up.
  defp unfilled(ctx, point) do
    parts = S.getprop(point, "parts")

    if S.islist(parts) and S.size(parts) > 0 do
      Enum.flat_map(0..(S.size(parts) - 1), fn i ->
        part = S.getelem(parts, i)

        case is_binary(part) && Regex.run(~r/\A\{([^{}\/]+)\}\z/, part) do
          [_, name] ->
            if param_value(ctx, point, name) != nil, do: [], else: [name]

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  def make_point_impl(ctx) do
    out = S.getprop(ctx, "out")
    pre = S.getprop(out, "point")

    if pre != nil do
      # A feature hook (rbac) may short-circuit by placing an error here.
      if H.is_error(pre) do
        {nil, pre}
      else
        S.setprop(ctx, "point", pre)
        {pre, nil}
      end
    else
      op = S.getprop(ctx, "op")
      options = S.getprop(ctx, "options")
      opname = S.getprop(op, "name")
      allow_op = S.getpath(options, "allow.op")
      points = S.getprop(op, "points")
      npoints = S.size(points)

      cond do
        not allowed?(allow_op, opname) ->
          {nil,
           Context.make_error(ctx, "point_op_allow",
             "Operation \"" <> opname <> "\" not allowed by SDK option allow.op value: \"" <>
               H.str_or(allow_op, "") <> "\"")}

        npoints == 0 ->
          {nil,
           Context.make_error(ctx, "point_no_points",
             "Operation \"" <> opname <> "\" has no endpoint definitions.")}

        npoints == 1 ->
          S.setprop(ctx, "point", S.getelem(points, 0))
          {S.getprop(ctx, "point"), nil}

        true ->
          input = S.getprop(op, "input")

          {reqselector, selector} =
            if input == "data" do
              {S.getprop(ctx, "reqdata"), S.getprop(ctx, "data")}
            else
              {S.getprop(ctx, "reqmatch"), S.getprop(ctx, "match")}
            end

          point =
            Enum.reduce(0..(npoints - 1), {:cont, S.getelem(points, 0)}, fn
              _i, {:halt, p} ->
                {:halt, p}

              i, {:cont, _acc} ->
                point = S.getelem(points, i)
                select_def = H.to_map(S.getprop(point, "select"))

                found1 =
                  if selector != nil and select_def != nil do
                    exist = S.getprop(select_def, "exist")

                    if S.islist(exist) do
                      Enum.reduce_while(0..max(S.size(exist) - 1, 0), true, fn ei, _ ->
                        if S.size(exist) == 0 do
                          {:halt, true}
                        else
                          ek = S.getelem(exist, ei)
                          existkey = if is_binary(ek), do: ek, else: S.stringify(ek)
                          rv = S.getprop(reqselector, existkey)
                          sv = S.getprop(selector, existkey)
                          if rv == nil and sv == nil, do: {:halt, false}, else: {:cont, true}
                        end
                      end)
                    else
                      true
                    end
                  else
                    true
                  end

                found =
                  if found1 do
                    S.getprop(reqselector, "$action") == S.getprop(select_def, "$action")
                  else
                    false
                  end

                if found, do: {:halt, point}, else: {:cont, point}
            end)

          matched? = match?({:halt, _}, point)

          # select.exist can list more than the params needed to pick a point,
          # so nothing matched. A call without an action falls back to a
          # point without one, as generation does, and only to a route the
          # call can fill.
          {point, plain} =
            if matched? do
              {elem(point, 1), nil}
            else
              all = Enum.map(0..(npoints - 1), &S.getelem(points, &1))
              plain = Enum.filter(all, &(S.getprop(H.to_map(S.getprop(&1, "select")), "$action") == nil))
              fillable = Enum.filter(plain, &(unfilled(ctx, &1) == []))
              {if(fillable == [], do: nil, else: own_point(fillable)), plain}
            end

          unmatched_action =
            if not matched? and reqselector != nil,
              do: S.getprop(reqselector, "$action"),
              else: nil

          err =
            cond do
              # A request naming an action reaches the fallback only because
              # that action's own point failed its exist test, so it is
              # unbuildable whatever we pick. Refuse it BEFORE the guard
              # below, which compares the chosen point's $action and would
              # wave the request through whenever the fallback lands on the
              # action point itself.
              unmatched_action != nil ->
                Context.make_error(ctx, "point_action_invalid",
                  "Operation \"" <> opname <> "\" action \"" <> S.stringify(unmatched_action) <> "\" is not valid.")

              plain == [] ->
                Context.make_error(ctx, "point_action_required",
                  "Operation \"" <> opname <> "\" has only action endpoints; pass $action to choose one.")

              point == nil and plain != nil ->
                Context.make_error(ctx, "point_no_match",
                  "Operation \"" <> opname <> "\" has no endpoint whose path parameters are all given (missing: " <>
                    Enum.join(unfilled(ctx, own_point(plain)), ", ") <> ").")

              reqselector != nil ->
                req_action = S.getprop(reqselector, "$action")

                if req_action != nil and point != nil do
                  point_select = H.to_map(S.getprop(point, "select"))
                  point_action = S.getprop(point_select, "$action")

                  if req_action != point_action do
                    Context.make_error(ctx, "point_action_invalid",
                      "Operation \"" <> opname <> "\" action \"" <> S.stringify(req_action) <> "\" is not valid.")
                  end
                end

              true ->
                nil
            end

          if err != nil do
            {nil, err}
          else
            S.setprop(ctx, "point", point)
            {point, nil}
          end
      end
    end
  end

  # ---- make_spec -----------------------------------------------------------

  def make_spec_impl(ctx) do
    out = S.getprop(ctx, "out")
    pre = S.getprop(out, "spec")

    if pre != nil do
      if H.is_error(pre) do
        {nil, pre}
      else
        S.setprop(ctx, "spec", pre)
        {pre, nil}
      end
    else
      point = S.getprop(ctx, "point")
      options = S.getprop(ctx, "options")
      base = strv(S.getprop(options, "base"))
      prefix = strv(S.getprop(options, "prefix"))
      suffix = strv(S.getprop(options, "suffix"))

      parts =
        if point != nil do
          pt = S.getprop(point, "parts")
          if S.islist(pt), do: pt, else: S.jt([])
        else
          S.jt([])
        end

      spec =
        Spec.new(S.jm(["base", base, "prefix", prefix, "parts", parts, "suffix", suffix, "step", "start"]))

      S.setprop(ctx, "spec", spec)
      S.setprop(spec, "method", prepare_method(ctx))

      allow_method = S.getpath(options, "allow.method")
      method = S.getprop(spec, "method")

      if not allowed?(allow_method, method) do
        {nil,
         Context.make_error(ctx, "spec_method_allow",
           "Method \"" <> H.str_or(method, "") <> "\" not allowed by SDK option allow.method value: \"" <>
             H.str_or(allow_method, "") <> "\"")}
      else
        S.setprop(spec, "params", prepare_params(ctx))
        S.setprop(spec, "query", prepare_query(ctx))
        S.setprop(spec, "headers", prepare_headers(ctx))

        if S.getprop(point, "kind") == "graphql" do
          # GraphQL addresses one endpoint: no path parts, no query string,
          # and the body carries the operation. prepare_body is skipped
          # deliberately — it only emits a body for data-input ops, whereas
          # every GraphQL op posts one, including load/list/remove.
          S.setprop(spec, "body", graphql_body(ctx))
          S.setprop(spec, "path", "")
          # prepare_query already copied the op's match arguments into the
          # query string. Those same values are bound as operation
          # variables, so leaving them would send /graphql?id=i1.
          S.setprop(spec, "query", S.jm([]))
          S.setprop(S.getprop(spec, "headers"), "content-type", @graphql_content_type)
        else
          S.setprop(spec, "body", prepare_body(ctx))
          S.setprop(spec, "path", prepare_path(ctx))
        end

        ctrl = S.getprop(ctx, "ctrl")
        explain = S.getprop(ctrl, "explain")
        if explain != nil, do: S.setprop(explain, "spec", spec)

        # Whatever prepare_auth sets in the query, under whichever name, is
        # the credential; a key it leaves as it was is the caller's.
        query = Map.new(H.entries(S.getprop(spec, "query")))

        {spec2, err} = prepare_auth(ctx)

        if err != nil do
          {nil, err}
        else
          authquery =
            for {key, val} <- H.entries(S.getprop(spec2, "query")),
                not Map.has_key?(query, key) or Map.get(query, key) != val,
                do: key

          S.setprop(spec2, "authquery", S.jt(authquery))
          S.setprop(ctx, "spec", spec2)
          {spec2, nil}
        end
      end
    end
  end

  # ---- make_request --------------------------------------------------------

  def make_request_impl(ctx) do
    out = S.getprop(ctx, "out")
    pre = S.getprop(out, "request")

    if pre != nil do
      if H.is_error(pre), do: {nil, pre}, else: {pre, nil}
    else
      spec = S.getprop(ctx, "spec")
      response = Response.new(S.jm([]))
      result = Result.new(S.jm([]))
      S.setprop(ctx, "result", result)

      if spec == nil do
        {nil, Context.make_error(ctx, "request_no_spec", "Expected context spec property to be defined.")}
      else
        {fetchdef, err} = make_fetch_def(ctx)

        if err != nil do
          S.setprop(response, "err", err)
          S.setprop(ctx, "response", response)
          S.setprop(spec, "step", "postrequest")
          {response, nil}
        else
          ctrl = S.getprop(ctx, "ctrl")
          explain = S.getprop(ctrl, "explain")
          if explain != nil, do: S.setprop(explain, "fetchdef", fetchdef)

          S.setprop(spec, "step", "prerequest")
          url = H.or_(S.getprop(fetchdef, "url"), "")
          {fetched, fetch_err} = fetcher(ctx, url, fetchdef)

          response2 =
            cond do
              fetch_err != nil ->
                S.setprop(response, "err", fetch_err)
                response

              fetched == nil ->
                Response.new(S.jm(["err", Context.make_error(ctx, "request_no_response", "response: undefined")]))

              S.ismap(fetched) ->
                Response.new(fetched)

              true ->
                S.setprop(response, "err", Context.make_error(ctx, "request_invalid_response", "response: invalid type"))
                response
            end

          S.setprop(spec, "step", "postrequest")
          S.setprop(ctx, "response", response2)
          {response2, nil}
        end
      end
    end
  end

  # ---- make_response -------------------------------------------------------

  def make_response_impl(ctx) do
    out = S.getprop(ctx, "out")
    pre = S.getprop(out, "response")

    if pre != nil do
      if H.is_error(pre), do: {nil, pre}, else: {pre, nil}
    else
      spec = S.getprop(ctx, "spec")
      result = S.getprop(ctx, "result")
      response = S.getprop(ctx, "response")

      cond do
        spec == nil ->
          {nil, Context.make_error(ctx, "response_no_spec", "Expected context spec property to be defined.")}

        response == nil ->
          {nil, Context.make_error(ctx, "response_no_response", "Expected context response property to be defined.")}

        result == nil ->
          {nil, Context.make_error(ctx, "response_no_result", "Expected context result property to be defined.")}

        true ->
          S.setprop(spec, "step", "response")

          # A body reader that raises (a non-JSON body) fails the result, as
          # in ts; it must not escape the pipeline with the raw spec still on
          # the explain record.
          try do
            result_basic(ctx)
            result_headers(ctx)
            result_body(ctx)

            # GraphQL reports failures as a top-level `errors` array under
            # HTTP 200, so result_basic's status check never sees them. Lift
            # them here, before the response transform tries to unwrap data
            # that is not there.
            graphql_errors(ctx)

            transform_response(ctx)

            if S.getprop(result, "err") == nil, do: S.setprop(result, "ok", true)
          rescue
            e -> S.setprop(result, "err", e)
          end

          ctrl = S.getprop(ctx, "ctrl")
          explain = S.getprop(ctrl, "explain")
          if explain != nil, do: S.setprop(explain, "result", result)

          {response, nil}
      end
    end
  end

  # ---- make_result ---------------------------------------------------------

  def make_result_impl(ctx) do
    out = S.getprop(ctx, "out")
    pre = S.getprop(out, "result")

    if pre != nil do
      if H.is_error(pre), do: {nil, pre}, else: {pre, nil}
    else
      op = S.getprop(ctx, "op")
      entity = S.getprop(ctx, "entity")
      spec = S.getprop(ctx, "spec")
      result = S.getprop(ctx, "result")

      cond do
        spec == nil ->
          {nil, Context.make_error(ctx, "result_no_spec", "Expected context spec property to be defined.")}

        result == nil ->
          {nil, Context.make_error(ctx, "result_no_result", "Expected context result property to be defined.")}

        true ->
          S.setprop(spec, "step", "result")
          transform_response(ctx)

          if S.getprop(op, "name") == "list" do
            resdata = S.getprop(result, "resdata")
            S.setprop(result, "resdata", S.jt([]))

            if resdata != nil and S.islist(resdata) and entity != nil do
              mod = S.getprop(entity, "_module")
              n = S.size(resdata)

              entities =
                if n == 0 do
                  []
                else
                  Enum.map(0..(n - 1), fn i ->
                    entry = S.getelem(resdata, i)
                    ent = apply(mod, :make, [entity])
                    if S.ismap(entry), do: apply(mod, :data_set, [ent, entry])
                    ent
                  end)
                end

              S.setprop(result, "resdata", S.jt(entities))
            end
          end

          ctrl = S.getprop(ctx, "ctrl")
          explain = S.getprop(ctrl, "explain")
          if explain != nil, do: S.setprop(explain, "result", result)

          {result, nil}
      end
    end
  end

  # ---- done ----------------------------------------------------------------

  def done_impl(ctx) do
    clean_explain(ctx)
    result = S.getprop(ctx, "result")

    if result != nil and S.getprop(result, "ok") == true do
      S.getprop(result, "resdata")
    else
      make_error(ctx, nil)
    end
  end

  # ---- make_error ----------------------------------------------------------

  def make_error_impl(ctx, err) do
    ctx = if ctx == nil, do: Context.new(nil, nil), else: ctx
    op = S.getprop(ctx, "op") || Operation.new(nil)
    opname0 = S.getprop(op, "name")
    opname = if opname0 == "" or opname0 == "_" or opname0 == nil, do: "unknown operation", else: opname0

    result = S.getprop(ctx, "result") || Result.new(nil)
    S.setprop(result, "ok", false)

    err = if err == nil, do: S.getprop(result, "err"), else: err
    err = if err == nil, do: Context.make_error(ctx, "unknown", "unknown error"), else: err

    errmsg =
      cond do
        match?(%Univec.Error{}, err) -> err.msg
        is_exception(err) -> Exception.message(err)
        # S.ismap, not is_map: a struct value is a {:vmap, id} TUPLE, so
        # is_map/1 is false for every heap map and this branch could never
        # fire for one. And the neutral contract spells it "message" — "msg"
        # is this port's own internal name. Between them, an error map reached
        # the stringify fallback and the SDK reported
        # "foo: {message:zed}" where every other target reports "foo: zed".
        S.ismap(err) ->
          m = S.getprop(err, "message") || S.getprop(err, "msg")
          if is_binary(m) and m != "", do: m, else: "unknown error"

        is_map(err) and not is_struct(err) and S.getprop(err, "msg") != nil -> S.getprop(err, "msg")
        is_binary(err) -> err
        true -> S.stringify(err)
      end

    msg = "UnivecSDK: " <> opname <> ": " <> (errmsg || "")
    msg = clean(ctx, msg)

    S.setprop(result, "err", nil)
    spec = S.getprop(ctx, "spec")

    clean_explain(ctx)
    ctrl = S.getprop(ctx, "ctrl")
    explain = S.getprop(ctrl, "explain")
    if explain != nil, do: S.setprop(explain, "err", S.jm(["message", msg]))

    # Cleaned COPIES of the result and spec, never the live nodes; the ctx
    # stays on the struct for a debugger and out of its Inspect form.
    sdk_err = %Univec.Error{
      code: "",
      msg: msg,
      sdk: "Univec",
      ctx: ctx,
      result: clean(ctx, result),
      spec: clean(ctx, spec)
    }

    # A hook's own error supplies the code as well as the message.
    sdk_err =
      if match?(%Univec.Error{}, err) do
        %{sdk_err | code: if(is_binary(err.code), do: clean(ctx, err.code), else: err.code)}
      else
        sdk_err
      end

    S.setprop(ctrl, "err", sdk_err)

    # Fire PreUnexpected so observability features (metrics, telemetry, audit,
    # debug) close/record error paths that never reach PreDone (e.g. a PrePoint
    # rbac short-circuit). Fires after ctrl.err is set so hooks can read the
    # error; features guard against double-recording when PreDone already fired.
    if S.getprop(ctx, "utility") != nil, do: feature_hook(ctx, "PreUnexpected")

    if S.getprop(ctrl, "throw_err") == false do
      S.getprop(result, "resdata")
    else
      raise sdk_err
    end
  end

  # ---- make_fetch_def / make_url -------------------------------------------

  def make_fetch_def_impl(ctx) do
    spec = S.getprop(ctx, "spec")

    if spec == nil do
      {nil, Context.make_error(ctx, "fetchdef_no_spec", "Expected context spec property to be defined.")}
    else
      if S.getprop(ctx, "result") == nil, do: S.setprop(ctx, "result", Result.new(nil))
      S.setprop(spec, "step", "prepare")

      {url, err} = make_url(ctx)

      if err != nil do
        {nil, err}
      else
        S.setprop(spec, "url", url)

        fetchdef =
          S.jm([
            "url", url,
            "method", S.getprop(spec, "method"),
            "headers", S.getprop(spec, "headers")
          ])

        body = S.getprop(spec, "body")
        scalar = is_binary(body) or is_number(body) or is_boolean(body)

        # A map or a list is JSON, and so is a scalar on a point that declares
        # a JSON body. Anything else goes as given.
        cond do
          body == nil ->
            :ok

          S.isnode(body) or (scalar and json_request?(S.getprop(ctx, "point"))) ->
            S.setprop(fetchdef, "body", S.jsonify(body))

          true ->
            S.setprop(fetchdef, "body", body)
        end

        {fetchdef, nil}
      end
    end
  end

  def make_url_impl(ctx) do
    spec = S.getprop(ctx, "spec")
    result = S.getprop(ctx, "result")

    cond do
      spec == nil ->
        {"", Context.make_error(ctx, "url_no_spec", "Expected context spec property to be defined.")}

      result == nil ->
        {"", Context.make_error(ctx, "url_no_result", "Expected context result property to be defined.")}

      true ->
        joined =
          S.join(
            S.jt([S.getprop(spec, "base"), S.getprop(spec, "prefix"), S.getprop(spec, "path"), S.getprop(spec, "suffix")]),
            "/",
            true
          )

        # A route the definition ends with a slash keeps it: a server such as a
        # Django REST one redirects or refuses the route without it.
        orig = S.getprop(S.getprop(ctx, "point"), "orig")
        suffix = S.getprop(spec, "suffix")

        url0 =
          if is_binary(orig) and String.ends_with?(orig, "/") and (suffix == nil or suffix == "") and
               not String.ends_with?(joined, "/"),
             do: joined <> "/",
             else: joined

        resmatch = S.jm([])

        # Sent with the request, never recorded as the entity's match.
        authquery = for {_, name} <- H.entries(S.getprop(spec, "authquery")), do: name

        url1 =
          Enum.reduce(H.entries(S.getprop(spec, "params")), url0, fn {key, val}, acc ->
            if val != nil and is_binary(key) do
              vstr = if is_binary(val), do: val, else: S.stringify(val)
              S.setprop(resmatch, key, val)
              String.replace(acc, "{" <> key <> "}", S.escurl(vstr))
            else
              acc
            end
          end)

        # A placeholder left in the route would send the request to the wrong
        # route. The base's own placeholders are server variables, resolved
        # with the options.
        base = S.getprop(spec, "base")
        base = if is_binary(base), do: String.trim_trailing(base, "/"), else: ""
        route = String.replace_prefix(url1, base, "")
        unfilled = Regex.scan(~r/\{[^{}\/]+\}/, route) |> Enum.map(&hd/1)

        {url2, _qsep} =
          Enum.reduce(H.entries(S.getprop(spec, "query")), {url1, "?"}, fn {key, val}, {acc, qsep} ->
            if val != nil and is_binary(key) do
              vstr = if is_binary(val), do: val, else: S.stringify(val)
              if key not in authquery, do: S.setprop(resmatch, key, val)
              {acc <> qsep <> S.escurl(key) <> "=" <> S.escurl(vstr), "&"}
            else
              {acc, qsep}
            end
          end)

        if unfilled != [] do
          {"", Context.make_error(ctx, "url_param_missing",
            "URL path has no value for " <> Enum.join(unfilled, ", ") <> ".")}
        else
          S.setprop(result, "resmatch", resmatch)
          {url2, nil}
        end
    end
  end

  # ---- param ---------------------------------------------------------------

  def param_impl(ctx, paramdef) do
    point = S.getprop(ctx, "point")
    spec = S.getprop(ctx, "spec")

    key =
      if is_binary(paramdef) do
        paramdef
      else
        k = S.getprop(paramdef, "name")
        if is_binary(k), do: k, else: ""
      end

    akey = param_alias(point, key)

    if spec != nil and akey != "" and S.getprop(S.getprop(ctx, "reqmatch"), key) == nil and
         S.getprop(S.getprop(ctx, "match"), key) == nil do
      S.setprop(S.getprop(spec, "alias"), akey, key)
    end

    param_value(ctx, point, key)
  end

  # The name a point gives a parameter in the call, if it renames it.
  defp param_alias(point, key) do
    alias = if point != nil, do: H.to_map(S.getprop(point, "alias")), else: nil
    ak = if alias != nil, do: S.getprop(alias, key), else: nil
    if is_binary(ak), do: ak, else: ""
  end

  # The value the call or its entity gives a point's parameter, under its name
  # or the point's alias for it.
  defp param_value(ctx, point, key) do
    akey = param_alias(point, key)
    reqmatch = S.getprop(ctx, "reqmatch")
    reqdata = S.getprop(ctx, "reqdata")
    data = S.getprop(ctx, "data")

    val = S.getprop(reqmatch, key)
    val = if val == nil, do: S.getprop(S.getprop(ctx, "match"), key), else: val
    val = if val == nil and akey != "", do: S.getprop(reqmatch, akey), else: val
    val = if val == nil, do: S.getprop(reqdata, key), else: val
    val = if val == nil, do: S.getprop(data, key), else: val

    if val == nil and akey != "" do
      v2 = S.getprop(reqdata, akey)
      if v2 == nil, do: S.getprop(data, akey), else: v2
    else
      val
    end
  end

  # The arguments a point declares in one location, query or header, each as
  # {name, wire, val}: the name it travels under and the value this call
  # passes in its match or else its data. Unlike a path parameter, the
  # entity's stored match and data never supply one.
  defp call_args(ctx, kind) do
    point = S.getprop(ctx, "point")
    defs = if point != nil, do: S.getpath(point, "args." <> kind), else: nil

    if S.islist(defs) and S.size(defs) > 0 do
      Enum.flat_map(0..(S.size(defs) - 1), fn i ->
        ad = S.getelem(defs, i)
        name = S.getprop(ad, "name")

        if is_binary(name) and name != "" do
          orig = S.getprop(ad, "orig")
          wire = if is_binary(orig) and orig != "", do: orig, else: name
          val = S.getprop(S.getprop(ctx, "reqmatch"), name)
          val = if val == nil, do: S.getprop(S.getprop(ctx, "reqdata"), name), else: val
          [{name, wire, val}]
        else
          []
        end
      end)
    else
      []
    end
  end

  # ---- media ---------------------------------------------------------------

  # The media types a point declares: `response` (the model's `rs`) for the
  # Accept header, and `body` (the model's `rb`) for the request body.

  # The data key holding a raw request body. Like `$action`, it can never be
  # a declared argument name.
  @raw_body "$body"

  def json_media?(media) do
    m =
      if(is_binary(media), do: media, else: "")
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    m == "application/json" or m == "text/json" or String.ends_with?(m, "+json")
  end

  # The declared JSON type alone, else every declared type in the model's
  # order; nil when no success response declares a body.
  def accept_of(point) do
    res = S.getprop(point, "response")
    media = S.getprop(res, "media")

    cond do
      not is_binary(media) or media == "" ->
        nil

      S.getprop(res, "kind") == "json" ->
        media

      true ->
        alts = S.getprop(res, "alternatives")
        n = if S.islist(alts), do: S.size(alts), else: 0

        others =
          if n == 0 do
            []
          else
            Enum.flat_map(0..(n - 1), fn i ->
              m = S.getprop(S.getelem(alts, i), "media")
              if is_binary(m) and m != "", do: [m], else: []
            end)
          end

        Enum.join([media | others], ", ")
    end
  end

  def raw_request?(point), do: S.getprop(S.getprop(point, "body"), "kind") == "raw"
  def json_request?(point), do: S.getprop(S.getprop(point, "body"), "kind") == "json"

  defp media_header?(headers, name) do
    Enum.any?(H.entries(headers), fn {k, _} -> is_binary(k) and String.downcase(k) == name end)
  end

  # A caller's accept wins. A declared request type replaces each JSON
  # content-type, the SDK default, and leaves any other the caller set.
  def media_headers(point, headers) do
    accept = accept_of(point)

    if accept != nil and not media_header?(headers, "accept"),
      do: S.setprop(headers, "accept", accept)

    body = S.getprop(point, "body")
    media = S.getprop(body, "media")

    if S.getprop(body, "kind") in ["raw", "json"] and is_binary(media) and media != "" do
      Enum.each(H.entries(headers), fn {k, v} ->
        if is_binary(k) and String.downcase(k) == "content-type" and json_media?(v),
          do: S.delprop(headers, k)
      end)

      if not media_header?(headers, "content-type"),
        do: S.setprop(headers, "content-type", media)
    end

    headers
  end

  # A binary, of bytes or text, sent as it is.
  def raw_body(reqdata), do: if(S.ismap(reqdata), do: S.getprop(reqdata, @raw_body), else: nil)

  # ---- prepare_* -----------------------------------------------------------

  @method_map %{
    "create" => "POST",
    "update" => "PUT",
    "load" => "GET",
    "list" => "GET",
    "remove" => "DELETE",
    "patch" => "PATCH"
  }

  # Whether a comma-separated allow option names the item: whole names, any case.
  def allowed?(names, item) when is_binary(names) and is_binary(item) and item != "" do
    want = String.upcase(item)
    names |> String.split(",") |> Enum.any?(fn name -> String.upcase(String.trim(name)) == want end)
  end

  def allowed?(_names, _item), do: false

  def prepare_method_impl(ctx) do
    opname = S.getprop(S.getprop(ctx, "op"), "name")

    # The API definition is authoritative: a POST-only or PATCH-based API
    # exposes `update` as POST or PATCH, not the PUT the op name implies.
    # Only fall back to the op-name convention when the point has no method.
    case S.getprop(S.getprop(ctx, "point"), "method") do
      m when is_binary(m) and m != "" -> String.upcase(m)
      # No GET catch-all: an unrecognised op must fall through to the
      # allow.method gate, not be silently issued as a GET.
      _ -> Map.get(@method_map, opname)
    end
  end

  def prepare_headers_impl(ctx) do
    options = opts_map(S.getprop(ctx, "client"))
    headers = S.getprop(options, "headers")

    out =
      if headers == nil do
        S.jm([])
      else
        cloned = S.clone(headers)
        if S.ismap(cloned), do: cloned, else: S.jm([])
      end

    out = media_headers(S.getprop(ctx, "point"), out)

    # A header argument replaces a default of the same name, whatever its case.
    Enum.each(call_args(ctx, "header"), fn {_name, wire, val} ->
      if val != nil do
        key = String.downcase(wire)

        Enum.each(H.entries(out), fn {k, _} ->
          if is_binary(k) and String.downcase(k) == key, do: S.delprop(out, k)
        end)

        S.setprop(out, key, S.stringify(val))
      end
    end)

    # A cookie argument travels in the cookie header, form serialized and
    # percent-encoded, replacing a cookie of the same name among those the
    # caller's headers already send.
    sent = Enum.filter(call_args(ctx, "cookie"), fn {_name, _wire, val} -> val != nil end)

    if sent != [] do
      names =
        Enum.flat_map(sent, fn {_name, wire, val} ->
          if S.ismap(val), do: Enum.map(S.keysof(val), &S.escurl/1), else: [wire]
        end)

      given =
        Enum.filter(H.entries(out), fn {k, _} -> is_binary(k) and String.downcase(k) == "cookie" end)

      kept = Enum.flat_map(given, fn {_, v} -> if is_binary(v), do: cookie_keep(v, names), else: [] end)

      Enum.each(given, fn {k, _} -> S.delprop(out, k) end)

      pairs =
        Enum.flat_map(sent, fn {_name, wire, val} ->
          case cookie_pair(wire, val) do
            "" -> []
            pair -> [pair]
          end
        end)

      if kept ++ pairs != [], do: S.setprop(out, "cookie", Enum.join(kept ++ pairs, "; "))
    end

    out
  end

  # The caller's cookie pieces with the named cookies removed: a cookie is one
  # ;-delimited piece, whatever its value holds.
  def cookie_keep(header, names) do
    header
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn cookie -> cookie == "" or cookie_name(cookie) in names end)
  end

  defp cookie_name(cookie), do: cookie |> String.split("=", parts: 2) |> hd() |> String.trim()

  # The form style of a cookie parameter: a list repeats the name, a map sends
  # its own keys, and every value is percent-encoded.
  defp cookie_pair(wire, val) do
    esc = fn v -> S.escurl(S.stringify(v)) end

    pairs =
      cond do
        S.islist(val) ->
          Enum.map(H.entries(val), fn {_i, item} -> wire <> "=" <> esc.(item) end)

        S.ismap(val) ->
          Enum.map(S.keysof(val), fn k -> S.escurl(k) <> "=" <> esc.(S.getprop(val, k)) end)

        true ->
          [wire <> "=" <> esc.(val)]
      end

    Enum.join(pairs, "; ")
  end

  def prepare_body_impl(ctx) do
    op = S.getprop(ctx, "op")

    cond do
      S.getprop(op, "input") != "data" -> nil
      raw_request?(S.getprop(ctx, "point")) -> raw_body(S.getprop(ctx, "reqdata"))
      true -> transform_request(ctx)
    end
  end

  def prepare_params_impl(ctx) do
    point = S.getprop(ctx, "point")

    params =
      if point != nil do
        args = S.getprop(point, "args")

        if S.ismap(args) do
          p = S.getprop(args, "params")
          if S.islist(p), do: p, else: S.jt([])
        else
          S.jt([])
        end
      else
        S.jt([])
      end

    out = S.jm([])
    n = S.size(params)

    if n > 0 do
      Enum.each(0..(n - 1), fn i ->
        pd = S.getelem(params, i)
        val = param(ctx, pd)

        if val != nil and S.ismap(pd) do
          name = S.getprop(pd, "name")
          if is_binary(name) and name != "", do: S.setprop(out, name, val)
        end
      end)
    end

    out
  end

  def prepare_path_impl(ctx) do
    point = S.getprop(ctx, "point")

    parts =
      if point != nil do
        p = S.getprop(point, "parts")
        if S.islist(p), do: p, else: S.jt([])
      else
        S.jt([])
      end

    S.join(parts, "/", true)
  end

  # The names in one of a point's lists of argument definitions.
  defp arg_names(nil, _path), do: []

  defp arg_names(point, path) do
    defs = S.getpath(point, path)

    if S.islist(defs) and S.size(defs) > 0 do
      Enum.map(0..(S.size(defs) - 1), fn i -> S.getprop(S.getelem(defs, i), "name") end)
    else
      []
    end
  end

  def prepare_query_impl(ctx) do
    point = S.getprop(ctx, "point")
    reqmatch = H.or_(S.getprop(ctx, "reqmatch"), S.jm([]))

    params =
      if point != nil do
        p = S.getprop(point, "params")
        if S.islist(p), do: p, else: S.jt([])
      else
        S.jt([])
      end

    param_strs =
      if S.size(params) == 0 do
        []
      else
        Enum.map(0..(S.size(params) - 1), fn i -> S.getelem(params, i) end)
      end

    # A path parameter travels in the path. The generated config lists them
    # as args.params, which prepare_params reads; params is the older list.
    # A header or cookie parameter travels in the headers, which prepare_headers
    # fills, unless a query parameter shares its name: then both are sent.
    declared = arg_names(point, "args.query")

    param_strs =
      param_strs ++
        arg_names(point, "args.params") ++
        Enum.reject(arg_names(point, "args.header") ++ arg_names(point, "args.cookie"), &(&1 in declared))

    # A query parameter travels under the name the definition gives it, its
    # orig, which the model may have renamed for the caller.
    aquery = if point != nil, do: S.getpath(point, "args.query"), else: nil

    wire =
      if S.islist(aquery) and S.size(aquery) > 0 do
        Enum.reduce(0..(S.size(aquery) - 1), %{}, fn i, acc ->
          qd = S.getelem(aquery, i)
          name = S.getprop(qd, "name")
          orig = S.getprop(qd, "orig")

          if is_binary(name) and is_binary(orig) and orig != "",
            do: Map.put(acc, name, orig),
            else: acc
        end)
      else
        %{}
      end

    out = S.jm([])

    Enum.each(H.entries(reqmatch), fn {key, val} ->
      if val != nil and is_binary(key) and key != "$action" and
           not Enum.member?(param_strs, key) do
        S.setprop(out, Map.get(wire, key, key), val)
      end
    end)

    # A create or update passes its query arguments in its data.
    Enum.each(call_args(ctx, "query"), fn {name, orig, val} ->
      if val != nil and not Enum.member?(param_strs, name), do: S.setprop(out, orig, val)
    end)

    out
  end

  # ---- graphql -------------------------------------------------------------
  #
  # GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
  # produces uses this code unchanged. The API-specific part — which
  # operations exist and what each one's document is — is model data,
  # computed once by apidef and emitted into Config.
  #
  # Two jobs:
  #
  #   graphql_body   — build %{query, variables} for a point, binding the
  #                    op's arguments to the document's declared variables.
  #
  #   graphql_errors — lift a GraphQL failure into an SDK error. GraphQL
  #                    reports failures as a top-level `errors` array under
  #                    HTTP 200, so the status-driven path in result_basic
  #                    never sees them.

  # Map a GraphQL error to the same error codes the HTTP path produces, so a
  # caller handles auth or rate limiting identically on both transports.
  # Servers put the machine-readable code in `extensions.code`; Linear-style
  # APIs use `extensions.type`.
  def graphql_error_code(gqlerr) do
    ext = S.getprop(gqlerr, "extensions")

    code = strv(S.getprop(ext, "code"))
    code = if code == "", do: strv(S.getprop(ext, "type")), else: code
    raw = String.upcase(code)

    cond do
      String.contains?(raw, "AUTH") or String.contains?(raw, "FORBIDDEN") or
          String.contains?(raw, "UNAUTHENTICATED") ->
        "request_auth"

      String.contains?(raw, "RATELIMIT") or String.contains?(raw, "RATE_LIMIT") or
          String.contains?(raw, "TOO_MANY") ->
        "request_ratelimit"

      String.contains?(raw, "BAD_USER_INPUT") or String.contains?(raw, "VALIDATION") or
          String.contains?(raw, "INVALID") ->
        "request_invalid"

      true ->
        "request_graphql"
    end
  end

  # Build the request body for a GraphQL point.
  #
  # Variables come from the op's own arguments: a named variable binds to the
  # like-named argument (`from`), and the input-object variable (empty
  # `from`) takes the request data as a whole — which is what makes a
  # generated create/update call look exactly like its REST equivalent.
  def graphql_body_impl(ctx) do
    gql = S.getprop(S.getprop(ctx, "point"), "graphql")

    if not S.ismap(gql) do
      nil
    else
      # reqmatch/reqdata hold the caller's arguments for THIS call; data/match
      # hold the entity's current state. Which pair depends on whether the op
      # takes match or data input. A named variable falls back to the current
      # state, so updating a loaded entity with just {title} still binds the
      # stored id the mutation requires.
      op = S.getprop(ctx, "op")
      datainput = S.getprop(op, "input") == "data"

      reqsrc =
        if datainput, do: S.getprop(ctx, "reqdata"), else: S.getprop(ctx, "reqmatch")

      datasrc =
        if datainput, do: S.getprop(ctx, "data"), else: S.getprop(ctx, "match")

      reqsrc = if S.ismap(reqsrc), do: reqsrc, else: S.jm([])
      datasrc = if S.ismap(datasrc), do: datasrc, else: S.jm([])

      variables = S.jm([])
      varlist = S.getprop(gql, "vars")
      n = if S.islist(varlist), do: S.size(varlist), else: 0

      if n > 0 do
        Enum.each(0..(n - 1), fn i ->
          spec = S.getelem(varlist, i)

          if S.ismap(spec) do
            name = strv(S.getprop(spec, "name"))
            from = strv(S.getprop(spec, "from"))

            cond do
              name == "" ->
                nil

              from == "" ->
                # The input object IS the request body. Strip the action
                # selector, which is an SDK-side point discriminator, not an
                # API field.
                body = S.jm([])

                Enum.each(H.entries(reqsrc), fn {key, val} ->
                  if key != "$action", do: S.setprop(body, key, val)
                end)

                S.setprop(variables, name, body)

              true ->
                # Only send variables the caller actually supplied: sending
                # an explicit null would clear a field on many APIs.
                # Explicit nil check, not `||`: a caller-supplied `false` is a
                # value, and `||` would treat it as absent and substitute the
                # current state — sending the opposite of what was asked.
                val = S.getprop(reqsrc, from)
                val = if val == nil, do: S.getprop(datasrc, from), else: val
                if val != nil, do: S.setprop(variables, name, val)
            end
          end
        end)
      end

      S.jm(["query", S.getprop(gql, "doc"), "variables", variables])
    end
  end

  # Inspect a decoded GraphQL response body and record a failure when the
  # server reported one. Returns true when an error was recorded.
  #
  # Partial data (`data` alongside `errors`) is treated as failure: the REST
  # surface has no partial-success concept, and silently returning half an
  # object would be worse than failing.
  def graphql_errors_impl(ctx) do
    result = S.getprop(ctx, "result")
    point = S.getprop(ctx, "point")

    errors = if result == nil, do: nil, else: S.getprop(S.getprop(result, "body"), "errors")

    count = if S.islist(errors), do: S.size(errors), else: 0

    if result == nil or S.getprop(point, "kind") != "graphql" or count == 0 do
      false
    else
      first = S.getelem(errors, 0)
      msg = strv(S.getprop(first, "message"))
      msg = if msg == "", do: "graphql error", else: msg
      msg = if 1 < count, do: msg <> " (+" <> Integer.to_string(count - 1) <> " more)", else: msg

      S.setprop(
        result,
        "err",
        Context.make_error(ctx, graphql_error_code(first), "graphql: " <> msg)
      )

      S.setprop(result, "ok", false)

      true
    end
  end

  # ---- result_* ------------------------------------------------------------

  def result_basic_impl(ctx) do
    response = S.getprop(ctx, "response")
    result = S.getprop(ctx, "result")

    if result != nil and response != nil do
      status = S.getprop(response, "status")
      S.setprop(result, "status", status)
      S.setprop(result, "status_text", S.getprop(response, "status_text"))

      cond do
        is_integer(status) and status >= 400 ->
          msg = "request: " <> Integer.to_string(status) <> ": " <> H.or_(S.getprop(result, "status_text"), "")
          re = S.getprop(result, "err")

          if re != nil do
            prevmsg = err_msg(re)
            S.setprop(result, "err", Context.make_error(ctx, "request_status", prevmsg <> ": " <> msg))
          else
            S.setprop(result, "err", Context.make_error(ctx, "request_status", msg))
          end

        S.getprop(response, "err") != nil ->
          S.setprop(result, "err", S.getprop(response, "err"))

        true ->
          :ok
      end
    end

    result
  end

  defp err_msg(e) do
    cond do
      match?(%Univec.Error{}, e) -> e.msg
      is_exception(e) -> Exception.message(e)
      is_binary(e) -> e
      true -> S.stringify(e)
    end
  end

  def result_body_impl(ctx) do
    response = S.getprop(ctx, "response")
    result = S.getprop(ctx, "result")

    if result != nil and response != nil do
      jf = S.getprop(response, "json_func")
      body = S.getprop(response, "body")
      if jf != nil and body != nil and S.isfunc(jf), do: S.setprop(result, "body", jf.())

      if S.getprop(response, "unreadable") == true do
        spec = S.getprop(ctx, "spec")
        sent = if spec != nil, do: S.getprop(spec, "headers")

        S.setprop(result, "err",
          unreadable_body(ctx, S.getprop(result, "status"), S.getprop(result, "headers"), body, sent,
            S.getprop(result, "err")))
      end
    end

    result
  end

  @body_preview_length 160

  # A body that is not JSON. An HTTP failure keeps its own error, with the
  # response described; otherwise the code tells a wrong content type from
  # malformed JSON.
  def unreadable_body(ctx, status, headers, text, sent, failed) do
    type = body_header(headers, "content-type")
    agent = to_string(clean(ctx, body_header(sent, "user-agent")))

    detail =
      "HTTP " <> to_string(status) <> ", content-type " <> if(type == "", do: "none", else: type) <>
        ", user-agent " <> if(agent == "", do: "transport default", else: agent) <>
        if(text == nil, do: "", else: ", body: " <> body_preview(ctx, text))

    cond do
      match?(%Univec.Error{}, failed) ->
        %{failed | msg: failed.msg <> " (" <> detail <> ")"}

      failed != nil ->
        %RuntimeError{message: err_msg(failed) <> " (" <> detail <> ")"}

      type == "" or String.contains?(String.downcase(type), "json") ->
        Context.make_error(ctx, "response_json_invalid", "response: body is not valid JSON (" <> detail <> ")")

      true ->
        Context.make_error(ctx, "response_content_type",
          "response: expected JSON, got " <> type <> " (" <> detail <> ")")
    end
  end

  defp body_header(headers, name) do
    if S.ismap(headers) do
      case Enum.find(H.entries(headers), fn {k, _v} -> String.downcase(to_string(k)) == name end) do
        {_k, v} -> to_string(v)
        nil -> ""
      end
    else
      ""
    end
  end

  # Cleaned whole: a secret the bound would split could leave its prefix.
  defp body_preview(ctx, text) do
    flat = to_string(clean(ctx, String.trim(Regex.replace(~r/\s+/, to_string(text), " "))))
    points = String.codepoints(flat)

    if length(points) > @body_preview_length,
      do: Enum.join(Enum.take(points, @body_preview_length)) <> "...",
      else: flat
  end

  def result_headers_impl(ctx) do
    response = S.getprop(ctx, "response")
    result = S.getprop(ctx, "result")

    if result != nil do
      h = if response != nil, do: S.getprop(response, "headers")

      cond do
        response != nil and h != nil and S.ismap(h) -> S.setprop(result, "headers", h)
        true -> S.setprop(result, "headers", S.jm([]))
      end
    end

    result
  end

  # ---- transform_* ---------------------------------------------------------

  # `$action` selects the point (see make_point_impl); it is never an API
  # field, so the body is a copy without it. The caller's map is left
  # untouched.
  defp strip_action(reqdata), do: omit_keys(reqdata, ["$action"])

  # A header, cookie or query argument travels where prepare_headers_impl or
  # prepare_query_impl sends it, so the body is built from the request data
  # without it, unless the point marks it as a field the body keeps.
  defp routed_arg_names(ctx) do
    (call_args(ctx, "header") ++ call_args(ctx, "cookie") ++ call_args(ctx, "query"))
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&field_arg?(ctx, &1))
  end

  defp field_arg?(ctx, name) do
    point = S.getprop(ctx, "point")

    point != nil and
      Enum.any?(["header", "cookie", "query"], fn kind ->
        defs = S.getpath(point, "args." <> kind)

        S.islist(defs) and S.size(defs) > 0 and
          Enum.any?(0..(S.size(defs) - 1), fn i ->
            ad = S.getelem(defs, i)
            name == S.getprop(ad, "name") and true == S.getprop(ad, "field")
          end)
      end)
  end

  defp omit_keys(reqdata, names) do
    if S.ismap(reqdata) and Enum.any?(names, &S.haskey(reqdata, &1)) do
      body = S.jm([])

      Enum.each(H.entries(reqdata), fn {key, val} ->
        if key not in names, do: S.setprop(body, key, val)
      end)

      body
    else
      reqdata
    end
  end

  def transform_request_impl(ctx) do
    spec = S.getprop(ctx, "spec")
    point = S.getprop(ctx, "point")
    if spec != nil, do: S.setprop(spec, "step", "reqform")

    data = omit_keys(S.getprop(ctx, "reqdata"), routed_arg_names(ctx))
    transform = H.to_map(S.getprop(point, "transform"))

    reqdata =
      if transform == nil do
        data
      else
        reqform = S.getprop(transform, "req")

        if reqform == nil do
          data
        else
          S.transform(S.jm(["reqdata", data]), reqform)
        end
      end

    strip_action(reqdata)
  end

  def transform_response_impl(ctx) do
    spec = S.getprop(ctx, "spec")
    result = S.getprop(ctx, "result")
    point = S.getprop(ctx, "point")
    if spec != nil, do: S.setprop(spec, "step", "resform")

    if result == nil or S.getprop(result, "ok") != true do
      nil
    else
      transform = H.to_map(S.getprop(point, "transform"))

      if transform == nil do
        nil
      else
        resform = S.getprop(transform, "res")

        if resform == nil do
          nil
        else
          resdata =
            S.transform(
              S.jm([
                "ok", S.getprop(result, "ok"),
                "status", S.getprop(result, "status"),
                "statusText", S.getprop(result, "status_text"),
                "headers", S.getprop(result, "headers"),
                "body", S.getprop(result, "body"),
                "err", S.getprop(result, "err"),
                "resdata", S.getprop(result, "resdata"),
                "resmatch", S.getprop(result, "resmatch")
              ]),
              resform
            )

          S.setprop(result, "resdata", resdata)
          resdata
        end
      end
    end
  end

  # ---- fetcher -------------------------------------------------------------

  def fetcher_impl(ctx, fullurl, fetchdef) do
    client = S.getprop(ctx, "client")
    mode = S.getprop(client, "mode")

    if mode != "live" do
      {nil,
       Context.make_error(ctx, "fetch_mode_block",
         "Request blocked by mode: \"" <> to_string(mode) <> "\" (URL was: \"" <> fullurl <> "\")")}
    else
      options = opts_map(client)

      if S.getpath(options, "feature.test.active") == true do
        {nil,
         Context.make_error(ctx, "fetch_test_block",
           "Request blocked as test feature is active (URL was: \"" <> fullurl <> "\")")}
      else
        sys_fetch = S.getpath(options, "system.fetch")

        cond do
          sys_fetch == nil -> default_http_fetch(fullurl, fetchdef)
          S.isfunc(sys_fetch) -> sys_fetch.(fullurl, fetchdef)
          true -> {nil, Context.make_error(ctx, "fetch_invalid", "system.fetch is not a valid function")}
        end
      end
    end
  end

  defp default_http_fetch(fullurl, fetchdef) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    method =
      H.or_(S.getprop(fetchdef, "method"), "GET") |> to_string() |> String.downcase() |> String.to_atom()

    body = S.getprop(fetchdef, "body")
    headers_node = H.or_(S.getprop(fetchdef, "headers"), S.jm([]))

    has_ua =
      Enum.any?(H.entries(headers_node), fn {k, _v} -> String.downcase(to_string(k)) == "user-agent" end)

    with_body = method in [:post, :put, :patch, :delete] and is_binary(body)
    content_type? = fn {k, _v} -> String.downcase(to_string(k)) == "content-type" end

    # :httpc takes a body's content type beside the headers, not among them.
    ctype =
      case Enum.find(H.entries(headers_node), content_type?) do
        {_k, v} -> to_string(v)
        nil -> "application/json"
      end

    pairs =
      if with_body,
        do: Enum.reject(H.entries(headers_node), content_type?),
        else: H.entries(headers_node)

    hlist0 =
      Enum.map(pairs, fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    hlist =
      if has_ua, do: hlist0, else: [{~c"User-Agent", String.to_charlist(@default_user_agent)} | hlist0]

    # The default User-Agent is recorded with the headers the request sent.
    if not has_ua, do: S.setprop(headers_node, "user-agent", @default_user_agent)

    url = String.to_charlist(fullurl)

    request =
      if with_body do
        {url, hlist, String.to_charlist(ctype), body}
      else
        {url, hlist}
      end

    # A `redirect: "manual"` annotation (set by the station feature when a
    # hosts egress policy is active - the same in-band channel go and rust
    # use) disables :httpc's automatic redirect following, so a 3xx rides
    # back as a normal response: a Location pointing off an egress
    # allowlist must never pull an automatic credentialed follow-up
    # request.
    http_opts =
      if S.getprop(fetchdef, "redirect") == "manual", do: [autoredirect: false], else: []

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_v, status, _reason}, resp_headers, resp_body}} ->
        rh =
          Enum.reduce(resp_headers, S.jm([]), fn {k, v}, acc ->
            S.setprop(acc, String.downcase(to_string(k)), to_string(v))
          end)

        body_str = if is_binary(resp_body), do: resp_body, else: to_string(resp_body)

        {json_body, unreadable} =
          if String.trim(body_str) != "" do
            case safe_json(body_str) do
              {:ok, v} -> {v, false}
              _ -> {nil, true}
            end
          else
            {nil, false}
          end

        status_text = if status < 400, do: "OK", else: "Error"

        {S.jm([
           "status", status,
           "statusText", status_text,
           "headers", rh,
           "json", fn -> json_body end,
           "body", body_str,
           "unreadable", unreadable
         ]), nil}

      {:error, reason} ->
        {nil, inspect(reason)}
    end
  end

  # Parse a JSON string into struct nodes using the vendored struct's own
  # constructors (no third-party dep). Returns {:ok, node} | :error.
  defp safe_json(str) do
    try do
      {:ok, Univec.Json.parse(str)}
    rescue
      _ -> :error
    end
  end
end
