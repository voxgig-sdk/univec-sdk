# Univec SDK log feature
#
# Logs each pipeline hook via an injectable logger (options.logger with
# info/debug/warn/error functions), defaulting to stderr.

defmodule Univec.Feature.Log do
  alias Voxgig.Struct, as: S
  alias Univec.Feature, as: F

  @hooks ~w(PostConstruct PostConstructEntity SetData GetData SetMatch GetMatch
            PrePoint PreSpec PreRequest PreResponse PreResult)

  def new do
    f = F.base("log")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)

    Enum.each(@hooks, fn hook ->
      F.install(f, hook, fn ctx -> loghook(f, hook, ctx) end)
    end)

    f
  end

  def init(f, ctx, options) do
    active = F.init_common(f, ctx, options)

    if active do
      logger = S.getprop(F.opts(f), "logger")

      logger =
        if S.ismap(logger) do
          logger
        else
          mk = fn level ->
            fn msg -> IO.write(:stderr, "[" <> level <> "] " <> msg <> "\n") end
          end

          S.jm(["info", mk.("INFO"), "debug", mk.("DEBUG"), "warn", mk.("WARN"), "error", mk.("ERROR")])
        end

      S.setprop(f, "logger", logger)
    end

    nil
  end

  defp loghook(f, hook, ctx) do
    if F.active?(f) do
      logger = S.getprop(f, "logger")

      if logger != nil do
        op = S.getprop(ctx, "op")
        opname = if op != nil, do: S.getprop(op, "name"), else: ""
        msg = "hook=" <> hook <> " op=" <> to_string(opname)
        log_fn = S.getprop(logger, "info")
        if S.isfunc(log_fn), do: log_fn.(msg)
      end
    end

    nil
  end
end
