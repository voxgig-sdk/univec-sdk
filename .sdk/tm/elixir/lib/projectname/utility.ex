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
      {"prepare_auth", &prepare_auth_impl/1},
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

  # ---- clean / features ----------------------------------------------------

  def clean_impl(_ctx, val), do: val

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

    opts0 = S.clone(options)
    opts0 = if S.ismap(opts0), do: opts0, else: S.jm([])

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

    optspec =
      H.deep(%{
        "apikey" => "",
        "base" => "http://localhost:8000",
        "prefix" => "",
        "suffix" => "",
        "auth" => %{"prefix" => ""},
        "headers" => %{"`$CHILD`" => "`$STRING`"},
        "allow" => %{
          "method" => "GET,PUT,POST,PATCH,DELETE,OPTIONS",
          "op" => "create,update,load,list,remove,command,direct,graphql"
        },
        "entity" => %{"`$CHILD`" => %{"`$OPEN`" => true, "active" => false, "alias" => %{}}},
        "feature" => %{"`$CHILD`" => %{"`$OPEN`" => true, "active" => false}},
        "utility" => %{},
        # Feature INSTANCES supplied at construction (the station adopt
        # path): consumed by the constructor's extend loop, so they are
        # struct feature nodes, not data - `$ANY` accepts them verbatim.
        # Without this entry the seam is dead: the constructor reads
        # options.extend, but validate rejected the key.
        "extend" => "`$ANY`",
        "system" => %{},
        "test" => %{"active" => false, "entity" => %{"`$OPEN`" => true}},
        "clean" => %{"keys" => "key,token,id"},
        # Server-variable values for a templated base URL (OpenAPI server
        # variables): {name} placeholders in "base" are substituted from this
        # map at construction. Spec defaults arrive via the generated config;
        # user values override them. Mirrors go's make_options optspec - elixir
        # was the only target validating options that did not accept it, so a
        # spec with a templated server URL failed validation outright.
        "server" => %{"`$CHILD`" => ""}
      })

    sys_fetch = S.getpath(opts0, "system.fetch")

    # CLONE the config side: `config` is a process-wide singleton
    # (Univec.Config.shared_config) and merge uses its nested nodes as
    # merge TARGETS, so without this one client's options (headers, server,
    # ...) are written into the shared config and inherited by every client
    # constructed afterwards.
    merged = S.merge(S.jt([S.jm([]), S.clone(cfgopts), opts0]))
    validated = S.validate(merged, optspec)
    opts = if S.ismap(validated), do: validated, else: S.jm([])

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

    ck = S.getpath(opts, "clean.keys")
    clean_keys = if is_binary(ck), do: ck, else: "key,token,id"

    keyre =
      clean_keys
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&S.escre/1)
      |> Enum.join("|")

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

    derived = S.jm(["clean", S.jm([])])
    if keyre != "", do: S.setprop(derived, "clean", S.jm(["keyre", keyre]))
    S.setprop(derived, "featureorder", S.jt(feature_order))
    S.setprop(opts, "__derived__", derived)

    opts
  end

  # ---- make_point ----------------------------------------------------------

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
      allow_op = H.or_(S.getpath(options, "allow.op"), "")
      points = S.getprop(op, "points")
      npoints = S.size(points)

      cond do
        is_binary(allow_op) and not String.contains?(allow_op, opname) ->
          {nil,
           Context.make_error(ctx, "point_op_allow",
             "Operation \"" <> opname <> "\" not allowed by SDK option allow.op value: \"" <> allow_op <> "\"")}

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

          point =
            if matched? do
              elem(point, 1)
            else
              # select.exist can list more than the params needed to pick a
              # point, so nothing matched. Fall back to the entity's own
              # route: a terminal parameter marks a record route
              # (/boards/{id}) where a cross-reference ends in the
              # relationship's name (/posts/{id}/author), and failing that
              # the shallower path wins. The same rule runs at generation
              # time, in helpers/opShape.ts — both sides must move together.
              parts_len = fn p ->
                parts = S.getprop(p, "parts")
                if S.islist(parts), do: S.size(parts), else: 0
              end

              terminal_param? = fn p ->
                parts = S.getprop(p, "parts")

                if S.islist(parts) and S.size(parts) > 0 do
                  last = S.getelem(parts, S.size(parts) - 1)
                  is_binary(last) and String.starts_with?(last, "{")
                else
                  false
                end
              end

              Enum.reduce(0..(npoints - 1), S.getelem(points, 0), fn i, best ->
                cand = S.getelem(points, i)
                ct = terminal_param?.(cand)
                bt = terminal_param?.(best)

                cond do
                  ct != bt -> if ct, do: cand, else: best
                  parts_len.(cand) < parts_len.(best) -> cand
                  true -> best
                end
              end)
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

      allow_method = H.or_(S.getpath(options, "allow.method"), "")
      method = S.getprop(spec, "method")

      if is_binary(allow_method) and not String.contains?(allow_method, method) do
        {nil,
         Context.make_error(ctx, "spec_method_allow",
           "Method \"" <> method <> "\" not allowed by SDK option allow.method value: \"" <> allow_method <> "\"")}
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

        {spec2, err} = prepare_auth(ctx)

        if err != nil do
          {nil, err}
        else
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

          result_basic(ctx)
          result_headers(ctx)
          result_body(ctx)

          # GraphQL reports failures as a top-level `errors` array under HTTP
          # 200, so result_basic's status check never sees them. Lift them
          # here, before the response transform tries to unwrap data that is
          # not there.
          graphql_errors(ctx)

          transform_response(ctx)

          if S.getprop(result, "err") == nil, do: S.setprop(result, "ok", true)

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
    ctrl = S.getprop(ctx, "ctrl")
    explain = S.getprop(ctrl, "explain")

    if explain != nil do
      S.setprop(ctrl, "explain", clean(ctx, explain))
      ex = S.getprop(ctrl, "explain")
      er = if S.ismap(ex), do: S.getprop(ex, "result")
      if S.ismap(er), do: S.delprop(er, "err")
    end

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

    ctrl = S.getprop(ctx, "ctrl")
    explain = S.getprop(ctrl, "explain")
    if explain != nil, do: S.setprop(explain, "err", S.jm(["message", msg]))

    sdk_err = %Univec.Error{
      code: "",
      msg: msg,
      sdk: "Univec",
      ctx: ctx,
      result: clean(ctx, result),
      spec: clean(ctx, spec)
    }

    sdk_err = if match?(%Univec.Error{}, err), do: %{sdk_err | code: err.code}, else: sdk_err

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

        cond do
          body == nil -> :ok
          S.ismap(body) -> S.setprop(fetchdef, "body", S.jsonify(body))
          true -> S.setprop(fetchdef, "body", body)
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
        url0 =
          S.join(
            S.jt([S.getprop(spec, "base"), S.getprop(spec, "prefix"), S.getprop(spec, "path"), S.getprop(spec, "suffix")]),
            "/",
            true
          )

        resmatch = S.jm([])

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

        {url2, _qsep} =
          Enum.reduce(H.entries(S.getprop(spec, "query")), {url1, "?"}, fn {key, val}, {acc, qsep} ->
            if val != nil and is_binary(key) do
              vstr = if is_binary(val), do: val, else: S.stringify(val)
              S.setprop(resmatch, key, val)
              {acc <> qsep <> S.escurl(key) <> "=" <> S.escurl(vstr), "&"}
            else
              {acc, qsep}
            end
          end)

        S.setprop(result, "resmatch", resmatch)
        {url2, nil}
    end
  end

  # ---- param ---------------------------------------------------------------

  def param_impl(ctx, paramdef) do
    point = S.getprop(ctx, "point")
    spec = S.getprop(ctx, "spec")
    match = S.getprop(ctx, "match")
    reqmatch = S.getprop(ctx, "reqmatch")
    data = S.getprop(ctx, "data")
    reqdata = S.getprop(ctx, "reqdata")

    key =
      if is_binary(paramdef) do
        paramdef
      else
        k = S.getprop(paramdef, "name")
        if is_binary(k), do: k, else: ""
      end

    akey =
      if point != nil do
        alias = H.to_map(S.getprop(point, "alias"))

        if alias != nil do
          ak = S.getprop(alias, key)
          if is_binary(ak), do: ak, else: ""
        else
          ""
        end
      else
        ""
      end

    val = S.getprop(reqmatch, key)
    val = if val == nil, do: S.getprop(match, key), else: val

    val =
      if val == nil and akey != "" do
        if spec != nil, do: S.setprop(S.getprop(spec, "alias"), akey, key)
        S.getprop(reqmatch, akey)
      else
        val
      end

    val = if val == nil, do: S.getprop(reqdata, key), else: val
    val = if val == nil, do: S.getprop(data, key), else: val

    val =
      if val == nil and akey != "" do
        v2 = S.getprop(reqdata, akey)
        if v2 == nil, do: S.getprop(data, akey), else: v2
      else
        val
      end

    val
  end

  # ---- prepare_* -----------------------------------------------------------

  @method_map %{
    "create" => "POST",
    "update" => "PUT",
    "load" => "GET",
    "list" => "GET",
    "remove" => "DELETE",
    "patch" => "PATCH"
  }

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

    if headers == nil do
      S.jm([])
    else
      out = S.clone(headers)
      if S.ismap(out), do: out, else: S.jm([])
    end
  end

  def prepare_body_impl(ctx) do
    op = S.getprop(ctx, "op")
    if S.getprop(op, "input") == "data", do: transform_request(ctx), else: nil
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

    out = S.jm([])

    Enum.each(H.entries(reqmatch), fn {key, val} ->
      if val != nil and is_binary(key) and not Enum.member?(param_strs, key) do
        S.setprop(out, key, val)
      end
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

  def prepare_auth_impl(ctx) do
    spec = S.getprop(ctx, "spec")

    if spec == nil do
      {nil, Context.make_error(ctx, "auth_no_spec", "Expected context spec property to be defined.")}
    else
      headers = S.getprop(spec, "headers")
      options = opts_map(S.getprop(ctx, "client"))

      if S.getprop(options, "auth") == nil do
        S.delprop(headers, "authorization")
        {spec, nil}
      else
        apikey = S.getprop(options, "apikey", "__NOTFOUND__")

        if (is_binary(apikey) and apikey == "__NOTFOUND__") or apikey == nil or apikey == "" do
          S.delprop(headers, "authorization")
        else
          ap = S.getpath(options, "auth.prefix")
          auth_prefix = if is_binary(ap), do: ap, else: ""
          apikey_val = if is_binary(apikey), do: apikey, else: ""
          hv = if auth_prefix != "", do: auth_prefix <> " " <> apikey_val, else: apikey_val
          S.setprop(headers, "authorization", hv)
        end

        {spec, nil}
      end
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
    end

    result
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

  def transform_request_impl(ctx) do
    spec = S.getprop(ctx, "spec")
    point = S.getprop(ctx, "point")
    if spec != nil, do: S.setprop(spec, "step", "reqform")

    transform = H.to_map(S.getprop(point, "transform"))

    if transform == nil do
      S.getprop(ctx, "reqdata")
    else
      reqform = S.getprop(transform, "req")

      if reqform == nil do
        S.getprop(ctx, "reqdata")
      else
        S.transform(S.jm(["reqdata", S.getprop(ctx, "reqdata")]), reqform)
      end
    end
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

    hlist0 =
      Enum.map(H.entries(headers_node), fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    hlist =
      if has_ua, do: hlist0, else: [{~c"User-Agent", String.to_charlist(@default_user_agent)} | hlist0]

    url = String.to_charlist(fullurl)

    request =
      if method in [:post, :put, :patch, :delete] and is_binary(body) do
        {url, hlist, ~c"application/json", body}
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

        json_body =
          if String.length(body_str) > 0 do
            case safe_json(body_str) do
              {:ok, v} -> v
              _ -> nil
            end
          else
            nil
          end

        status_text = if status < 400, do: "OK", else: "Error"

        {S.jm([
           "status", status,
           "statusText", status_text,
           "headers", rh,
           "json", fn -> json_body end,
           "body", body_str
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
