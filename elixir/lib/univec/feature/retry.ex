# Univec SDK retry feature
#
# Automatic retry of transient failures with exponential backoff + jitter.
# Wraps the active transport so one operation may make several attempts. A
# failure is retryable when the transport errors/raises, or responds with a
# retryable status. `sleep` is injectable for deterministic tests.

defmodule Univec.Feature.Retry do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Feature, as: F

  @statuses [408, 425, 429, 500, 502, 503, 504]

  def new do
    f = F.base("retry")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    f
  end

  def init(f, ctx, options) do
    active = F.init_common(f, ctx, options)

    if active do
      utility = S.getprop(ctx, "utility")
      inner = S.getprop(utility, "fetcher")
      S.setprop(utility, "fetcher", fn fctx, url, fd -> with_retry(f, fctx, url, fd, inner) end)
    end

    nil
  end

  defp with_retry(f, ctx, url, fetchdef, inner) do
    opts = F.opts(f)
    retries = case S.getprop(opts, "retries") do nil -> 2; v -> trunc(v) end
    min_delay = H.or_(S.getprop(opts, "minDelay"), 50)
    max_delay = H.or_(S.getprop(opts, "maxDelay"), 2000)
    factor = H.or_(S.getprop(opts, "factor"), 2)

    loop(f, ctx, url, fetchdef, inner, opts, retries, min_delay, max_delay, factor, 0)
  end

  defp loop(f, ctx, url, fetchdef, inner, opts, retries, min_delay, max_delay, factor, attempt) do
    {res, err, raised} =
      try do
        {r, e} = inner.(ctx, url, fetchdef)
        {r, e, nil}
      rescue
        e -> {nil, nil, e}
      end

    if not retryable(opts, res, err, raised) or attempt >= retries do
      if raised != nil, do: raise(raised), else: {res, err}
    else
      wait = backoff(opts, res, attempt, min_delay, max_delay, factor)
      track(f, ctx, attempt + 1, res, err, raised, wait)
      F.sleep(f, wait)
      loop(f, ctx, url, fetchdef, inner, opts, retries, min_delay, max_delay, factor, attempt + 1)
    end
  end

  defp retryable(opts, res, err, raised) do
    cond do
      raised != nil or err != nil -> true
      res == nil -> true
      true ->
        status = if S.ismap(res), do: S.getprop(res, "status"), else: nil

        if not is_number(status) or is_boolean(status) do
          false
        else
          statuses = H.or_(S.getprop(opts, "statuses"), S.jt(@statuses))
          Enum.member?(struct_list(statuses), trunc(status))
        end
    end
  end

  defp struct_list(v) do
    if S.islist(v) do
      n = S.size(v)
      if n == 0, do: [], else: Enum.map(0..(n - 1), fn i -> S.getelem(v, i) end)
    else
      v
    end
  end

  defp backoff(opts, res, attempt, min_delay, max_delay, factor) do
    ra = retry_after(res)

    if ra != nil do
      min(max_delay, ra)
    else
      base = min_delay * :math.pow(factor, attempt)
      jitter = if S.getprop(opts, "jitter") == false, do: 0, else: trunc(:rand.uniform() * min_delay)
      min(max_delay, trunc(base) + jitter)
    end
  end

  defp retry_after(res) do
    if not S.ismap(res) do
      nil
    else
      headers = S.getprop(res, "headers")

      if not S.ismap(headers) do
        nil
      else
        val = F.header_get(headers, "retry-after")

        cond do
          val == nil -> nil
          true ->
            case Float.parse(to_string(val)) do
              {n, _} -> n * 1000
              :error -> nil
            end
        end
      end
    end
  end

  defp track(f, _ctx, attempt, res, err, raised, wait) do
    client = S.getprop(f, "client")
    track = F.track_node(client, "_retry", S.jm(["attempts", 0, "retries", S.jt([])]))
    S.setprop(track, "attempts", S.getprop(track, "attempts") + 1)

    status = if S.ismap(res), do: S.getprop(res, "status"), else: nil

    error =
      cond do
        raised != nil -> Exception.message(raised)
        err != nil -> err_str(err)
        true -> nil
      end

    F.list_push(
      S.getprop(track, "retries"),
      S.jm(["attempt", attempt, "status", status, "error", error, "wait", wait])
    )
  end

  defp err_str(e) do
    cond do
      match?(%Univec.Error{}, e) -> e.msg
      is_exception(e) -> Exception.message(e)
      is_binary(e) -> e
      true -> S.stringify(e)
    end
  end
end
