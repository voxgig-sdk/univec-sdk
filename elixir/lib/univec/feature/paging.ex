# Univec SDK paging feature
#
# Pagination support for list operations. On the way out (PreRequest) it
# stamps page/limit (or a cursor) into the request query; on the way back
# (PreResult) it reads the server's pagination signals — a `Link: rel="next"`
# header, `X-Page`/`X-Next-Page`/`X-Total-Count` headers, or
# `next`/`cursor`/`nextCursor`/`hasMore` fields in the body — and records them
# on `ctx.result.paging`. A per-call cursor/page supplied via ctrl paging
# takes priority (used by auto-iteration). Parameter names
# (`pageParam`/`limitParam`/`cursorParam`), `startPage` and page size
# (`limit`) are configurable.

defmodule Univec.Feature.Paging do
  alias Voxgig.Struct, as: S
  alias Univec.Feature, as: F

  @next_re ~r/<([^>]+)>\s*;\s*rel="?next"?/i

  def new do
    f = F.base("paging")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    F.install(f, "PreRequest", fn ctx -> pre_request(f, ctx) end)
    F.install(f, "PreResult", fn ctx -> pre_result(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    F.init_common(f, ctx, options)
    nil
  end

  defp pre_request(f, ctx) do
    if F.active?(f) and is_list_op(f, ctx) do
      spec = S.getprop(ctx, "spec")

      if spec != nil do
        query =
          case S.getprop(spec, "query") do
            nil ->
              q = S.jm([])
              S.setprop(spec, "query", q)
              q

            q ->
              q
          end

        opts = F.opts(f)
        page_param = por(S.getprop(opts, "pageParam"), "page")
        limit_param = por(S.getprop(opts, "limitParam"), "limit")
        cursor_param = por(S.getprop(opts, "cursorParam"), "cursor")

        # A per-call cursor/page from ctrl takes priority (auto-iteration).
        ctrl = S.getprop(ctx, "ctrl")
        paging = if ctrl != nil, do: S.getprop(ctrl, "paging"), else: nil
        paging = if S.ismap(paging), do: paging, else: S.jm([])

        # GraphQL paginates through operation VARIABLES, not the query
        # string. This hook runs after make_spec, so spec.body already holds
        # the { query, variables } envelope, and before make_fetch_def
        # serialises it.
        if "graphql" == S.getprop(S.getprop(ctx, "point"), "kind") do
          graphql_pre_request(f, ctx, paging)
        else
          cond do
            S.getprop(paging, "cursor") != nil ->
              S.setprop(query, cursor_param, S.getprop(paging, "cursor"))

            S.getprop(query, page_param) == nil ->
              page = S.getprop(paging, "page")
              page = if page == nil, do: por(S.getprop(opts, "startPage"), 1), else: page
              S.setprop(query, page_param, page)

            true ->
              nil
          end

          limit = S.getprop(opts, "limit")

          if limit != nil and S.getprop(query, limit_param) == nil do
            S.setprop(query, limit_param, limit)
          end
        end
      end
    end

    nil
  end

  # Relay pagination: the cursor is the `after` variable (or whatever the model
  # named it), and the page size is `first`.
  defp graphql_pre_request(f, ctx, paging) do
    opts = F.opts(f)
    point = S.getprop(ctx, "point")
    body = S.getprop(S.getprop(ctx, "spec"), "body")

    if S.ismap(body) do
      variables =
        case S.getprop(body, "variables") do
          v when not is_nil(v) ->
            if S.ismap(v) do
              v
            else
              nv = S.jm([])
              S.setprop(body, "variables", nv)
              nv
            end

          _ ->
            nv = S.jm([])
            S.setprop(body, "variables", nv)
            nv
        end

      after_var = por(S.getprop(opts, "afterVar"), "after")
      first_var = por(S.getprop(opts, "firstVar"), "first")

      # Only bind variables the operation actually declares, or the server
      # rejects the document.
      varlist = S.getpath(point, "graphql.vars")

      declared =
        if S.islist(varlist) and S.size(varlist) > 0 do
          Enum.reduce(0..(S.size(varlist) - 1), MapSet.new(), fn i, acc ->
            case S.getprop(S.getelem(varlist, i), "name") do
              nil -> acc
              name -> MapSet.put(acc, name)
            end
          end)
        else
          MapSet.new()
        end

      cursor = S.getprop(paging, "cursor")

      if cursor != nil and MapSet.member?(declared, after_var) do
        S.setprop(variables, after_var, cursor)
      end

      limit = S.getprop(opts, "limit")

      if limit != nil and S.getprop(variables, first_var) == nil and
           MapSet.member?(declared, first_var) do
        S.setprop(variables, first_var, limit)
      end
    end

    nil
  end

  defp pre_result(f, ctx) do
    if F.active?(f) and is_list_op(f, ctx) do
      result = S.getprop(ctx, "result")

      if result != nil do
        headers = S.getprop(result, "headers")
        headers = if headers == nil, do: S.jm([]), else: headers
        body = S.getprop(result, "body")

        page = num(F.header_get(headers, "x-page"))
        total_count = num(F.header_get(headers, "x-total-count"))
        next_page = num(F.header_get(headers, "x-next-page"))

        # Link: <...>; rel="next"
        link = F.header_get(headers, "link")

        next_from_link =
          if link != nil do
            case Regex.run(@next_re, to_string(link)) do
              [_, url] -> url
              _ -> nil
            end
          else
            nil
          end

        {next_val, cursor_val, has_more} =
          if S.ismap(body) do
            n =
              case S.getprop(body, "next") do
                nil -> next_from_link
                bnext -> por(next_from_link, bnext)
              end

            c =
              cond do
                S.getprop(body, "nextCursor") != nil -> S.getprop(body, "nextCursor")
                S.getprop(body, "cursor") != nil -> S.getprop(body, "cursor")
                true -> nil
              end

            hm =
              case S.getprop(body, "hasMore") do
                v when is_boolean(v) -> v
                _ -> false
              end

            {n, c, hm}
          else
            {next_from_link, nil, false}
          end

        # Relay connections carry the cursor in pageInfo, at the path the
        # model recorded for this op. `explicit_more` is set when the server
        # states hasMore outright, rather than leaving it to be inferred from
        # the presence of a cursor.
        gqlpage = S.getpath(S.getprop(ctx, "point"), "graphql.page")

        {cursor_val, has_more, explicit_more} =
          if S.ismap(gqlpage) and S.ismap(body) do
            # `connpath` locates the connection object inside the response
            # envelope (data.<field>); the cursor/more paths are relative
            # to it.
            connpath = S.getprop(gqlpage, "connpath")

            conn =
              if is_binary(connpath) and connpath != "" do
                por(S.getpath(body, connpath), body)
              else
                body
              end

            cursorpath = S.getprop(gqlpage, "cursor")

            c =
              if is_binary(cursorpath) and cursorpath != "" do
                por(S.getpath(conn, cursorpath), cursor_val)
              else
                cursor_val
              end

            morepath = S.getprop(gqlpage, "more")

            case (is_binary(morepath) and morepath != "" and S.getpath(conn, morepath)) do
              v when is_boolean(v) ->
                {c, v, true}

              _ ->
                # No usable relay `more` path, but a top-level body hasMore is
                # still an outright statement — keep it explicit, or cursor
                # inference below would flip an explicit false to true.
                {c, has_more, is_boolean(S.getprop(body, "hasMore"))}
            end
          else
            {cursor_val, has_more, is_boolean(S.getprop(body, "hasMore"))}
          end

        # Cursor presence only INFERS another page. When the server stated the
        # answer outright — relay's `hasNextPage: false`, or a body `hasMore`
        # — that wins: a final page normally carries both an end cursor and
        # hasNextPage false, and inferring from the cursor there would send
        # the caller back for a page that does not exist, forever.
        has_more =
          if explicit_more do
            has_more
          else
            has_more or next_val != nil or cursor_val != nil or next_page != nil
          end

        paging =
          S.jm([
            "page", page,
            "totalCount", total_count,
            "nextPage", next_page,
            "next", next_val,
            "cursor", cursor_val,
            "hasMore", has_more
          ])

        S.setprop(result, "paging", paging)
        S.setprop(S.getprop(f, "client"), "_paging", S.jm(["last", paging]))
      end
    end

    nil
  end

  defp is_list_op(f, ctx) do
    ops = opt_list(S.getprop(F.opts(f), "ops"), ["list"])
    op = S.getprop(ctx, "op")
    opname = if op != nil, do: S.getprop(op, "name"), else: nil
    opname in ops
  end

  # Parse a numeric header value: int when integral, float otherwise, nil when
  # not a full number (mirrors Python float()/int() with ValueError -> None).
  defp num(val) do
    if val == nil do
      nil
    else
      s = String.trim(to_string(val))

      case Float.parse(s) do
        {n, ""} -> if n == trunc(n), do: trunc(n), else: n
        _ -> nil
      end
    end
  end

  # Python `v or default`: falsy = nil, false, 0, 0.0, "".
  defp por(v, d) do
    if v == nil or v == false or v == 0 or v == "", do: d, else: v
  end

  # Struct list node -> plain Elixir list; nil/empty -> default.
  defp opt_list(v, default) do
    cond do
      v == nil -> default
      S.islist(v) and S.isempty(v) -> default
      S.islist(v) -> Enum.map(0..(S.size(v) - 1), fn i -> S.getelem(v, i) end)
      true -> default
    end
  end
end
