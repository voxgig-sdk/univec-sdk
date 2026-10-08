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
        if S.ismap(logger) or S.isfunc(logger) do
          logger
        else
          mk = fn level ->
            fn record ->
              IO.write(:stderr, "[" <> level <> "] " <> S.jsonify(record, S.jm(["indent", 0])) <> "\n")
            end
          end

          S.jm(["info", mk.("INFO"), "debug", mk.("DEBUG"), "warn", mk.("WARN"), "error", mk.("ERROR")])
        end

      S.setprop(f, "logger", logger)
    end

    nil
  end

  # A log line leaves the pipeline, so it carries the cleaned record: the
  # spec after auth holds the credential, and a logger serialises whatever it
  # is handed. `logger` is a fn of the record, or a map with an "info" fn.
  defp loghook(f, hook, ctx) do
    if F.active?(f) do
      logger = S.getprop(f, "logger")

      if logger != nil do
        op = S.getprop(ctx, "op")
        opname = if op != nil, do: S.getprop(op, "name"), else: ""

        record =
          F.clean(ctx, S.jm([
            "hook", hook,
            "op", opname,
            "spec", S.getprop(ctx, "spec"),
            "ctx", Univec.Context.to_data(ctx)
          ]))

        log_fn = if S.isfunc(logger), do: logger, else: S.getprop(logger, "info")
        if S.isfunc(log_fn), do: log_fn.(record)
      end
    end

    nil
  end
end
