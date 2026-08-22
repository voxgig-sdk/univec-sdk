# Univec SDK feature test
#
# Behavioural tests for the enterprise features shipped with this SDK. Each
# block runs only when its feature is present (has_feature?), driving the real
# generated feature module through the offline mini-pipeline in
# Univec.FeatureHarness — the same hook order and short-circuit rules as
# the generated entity operations — against a configurable mock transport.
# All timing goes through the harness's injectable virtual clock, so the suite
# is deterministic.

defmodule Univec.FeatureTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.FeatureHarness, as: FH

  # ---- helpers -------------------------------------------------------------

  # A feature spec node: %{"name" => .., "options" => <node>}.
  defp fspec(name, options \\ %{}) do
    S.jm(["name", name, "options", H.deep(options)])
  end

  defp harness(specs, opts \\ %{}), do: FH.new(specs, opts)

  defp has?(name), do: FH.has_feature(name)

  defp track(h, key), do: S.getprop(h.client, key)

  defp call(calls, i), do: S.getelem(calls, i)
  defp call_url(calls, i), do: S.getprop(call(calls, i), "url")
  defp fetchdef(calls, i), do: S.getprop(call(calls, i), "fetchdef")
  defp fd_headers(calls, i), do: S.getprop(fetchdef(calls, i), "headers")
  defp fd_header(calls, i, name), do: S.getprop(fd_headers(calls, i), name)
  defp fd_prop(calls, i, name), do: S.getprop(fetchdef(calls, i), name)

  # A counter-backed injectable clock returning `step` more each call.
  defp step_now(step) do
    c = S.jm(["t", 0])

    fn ->
      t = S.getprop(c, "t") + step
      S.setprop(c, "t", t)
      t
    end
  end

  test "at least the test feature is present" do
    assert has?("test")
  end

  # === station ===

  # The station adapter (installed by @voxgig/sdkgen-station) with NO open
  # station must be an inert no-op that emits nothing and fails nothing
  # (station design 3.1). Driven through the generated factory - never a
  # compile-time module reference - so this file stays green both with and
  # without the feature installed (absent, the harness simply adds no
  # feature). Bound behaviour (registration, injection, wire events) is
  # exercised by the station library's own suite and the consumer-side
  # station validation, not here.
  test "station adapter with no open station is an inert no-op" do
    h = harness([fspec("station")])
    res = FH.op(h, %{})
    assert res.ok == true

    # Inert: the transport is neither wrapped nor marked.
    assert S.getprop(h.utility, "__station_wrap__") == nil
  end

  # === netsim ===

  test "netsim fixed latency then delegate" do
    if has?("netsim") do
      clock = FH.make_clock()
      h = harness([fspec("netsim", %{"latency" => 250, "sleep" => FH.clock_sleep(clock)})])
      res = FH.op(h, %{ctrl: S.jm(["explain", S.jm([])])})
      assert res.ok == true
      assert FH.clock_time(clock) == 250
      assert S.getprop(track(h, "_netsim"), "calls") == 1
    end
  end

  test "netsim ranged latency samples within range" do
    if has?("netsim") do
      clock = FH.make_clock()

      h =
        harness([
          fspec("netsim", %{"latency" => %{"min" => 100, "max" => 300}, "seed" => 7, "sleep" => FH.clock_sleep(clock)})
        ])

      FH.op(h, %{})
      t = FH.clock_time(clock)
      assert t >= 100 and t < 300
    end
  end

  test "netsim equal min max latency is exact" do
    if has?("netsim") do
      clock = FH.make_clock()

      h =
        harness([
          fspec("netsim", %{"latency" => %{"min" => 50, "max" => 50}, "sleep" => FH.clock_sleep(clock)})
        ])

      FH.op(h, %{})
      assert FH.clock_time(clock) == 50
    end
  end

  test "netsim fail times returns a retryable status" do
    if has?("netsim") do
      h = harness([fspec("netsim", %{"failTimes" => 2, "failStatus" => 503})])
      assert S.getprop(FH.op(h, %{}).result, "status") == 503
      assert S.getprop(FH.op(h, %{}).result, "status") == 503
      assert FH.op(h, %{}).ok == true
    end
  end

  test "netsim fail every fails every nth call" do
    if has?("netsim") do
      h = harness([fspec("netsim", %{"failEvery" => 2})])
      assert FH.op(h, %{}).ok == true
      assert FH.op(h, %{}).ok == false
      assert FH.op(h, %{}).ok == true
    end
  end

  test "netsim fail rate with a seed is deterministic" do
    if has?("netsim") do
      h = harness([fspec("netsim", %{"failRate" => 1, "seed" => 5})])
      assert FH.op(h, %{}).ok == false
    end
  end

  test "netsim error times yields a connection error" do
    if has?("netsim") do
      h = harness([fspec("netsim", %{"errorTimes" => 1})])
      assert FH.op(h, %{}).error.code == "netsim_conn"
    end
  end

  test "netsim offline fails every call" do
    if has?("netsim") do
      h = harness([fspec("netsim", %{"offline" => true})])
      assert FH.op(h, %{}).error.code == "netsim_offline"
    end
  end

  test "netsim rate limit times returns 429 and retry-after" do
    if has?("netsim") do
      h = harness([fspec("netsim", %{"rateLimitTimes" => 1, "retryAfter" => 3})])
      res = FH.op(h, %{})
      assert S.getprop(res.result, "status") == 429
      assert S.getprop(S.getprop(res.result, "headers"), "retry-after") == "3"
    end
  end

  test "netsim inactive does not wrap" do
    if has?("netsim") do
      h = harness([fspec("netsim", %{"active" => false})])
      assert FH.op(h, %{}).ok == true
      assert track(h, "_netsim") == nil
    end
  end

  # === retry ===

  test "retry retries transient failures then succeeds" do
    if has?("retry") and has?("netsim") do
      clock = FH.make_clock()

      h =
        harness([
          fspec("netsim", %{"failTimes" => 2, "failStatus" => 503}),
          fspec("retry", %{"retries" => 3, "minDelay" => 10, "jitter" => false, "sleep" => FH.clock_sleep(clock)})
        ])

      assert FH.op(h, %{}).ok == true
      assert S.getprop(track(h, "_retry"), "attempts") == 2
    end
  end

  test "retry gives up after the budget" do
    if has?("retry") and has?("netsim") do
      clock = FH.make_clock()

      h =
        harness([
          fspec("netsim", %{"failTimes" => 9, "failStatus" => 500}),
          fspec("retry", %{"retries" => 2, "minDelay" => 1, "jitter" => false, "sleep" => FH.clock_sleep(clock)})
        ])

      assert S.getprop(FH.op(h, %{}).result, "status") == 500
    end
  end

  test "retry does not retry a non-retryable status" do
    if has?("retry") do
      {server, calls} = FH.recording_server(fn _n, _fd -> {FH.make_response(404), nil} end)
      h = harness([fspec("retry", %{"retries" => 3, "minDelay" => 0, "jitter" => false})], %{server: server})
      FH.op(h, %{})
      assert S.size(calls) == 1
    end
  end

  test "retry retries a transport error tuple" do
    if has?("retry") do
      clock = FH.make_clock()

      {server, calls} =
        FH.recording_server(fn n, _fd ->
          if n < 3,
            do: {nil, Univec.Error.new("boom", "boom")},
            else: {FH.make_response(200, H.deep(%{"ok" => true})), nil}
        end)

      h =
        harness([fspec("retry", %{"retries" => 2, "minDelay" => 1, "jitter" => false, "sleep" => FH.clock_sleep(clock)})],
          %{server: server})

      res = FH.op(h, %{})
      assert res.ok == true
      assert S.size(calls) == 3
    end
  end

  test "retry exhausted transport error surfaces" do
    if has?("retry") do
      clock = FH.make_clock()
      {server, calls} = FH.recording_server(fn _n, _fd -> {nil, Univec.Error.new("boom", "boom")} end)

      h =
        harness([fspec("retry", %{"retries" => 2, "minDelay" => 1, "jitter" => false, "sleep" => FH.clock_sleep(clock)})],
          %{server: server})

      res = FH.op(h, %{})
      assert res.ok == false
      assert S.size(calls) == 3
    end
  end

  test "retry honours a server retry-after" do
    if has?("retry") and has?("netsim") do
      clock = FH.make_clock()

      h =
        harness([
          fspec("netsim", %{"rateLimitTimes" => 1, "retryAfter" => 2}),
          fspec("retry", %{
            "retries" => 2,
            "minDelay" => 10,
            "maxDelay" => 60000,
            "jitter" => false,
            "sleep" => FH.clock_sleep(clock)
          })
        ])

      assert FH.op(h, %{}).ok == true
      assert FH.clock_time(clock) == 2000
    end
  end

  test "retry inactive does not wrap" do
    if has?("retry") do
      {server, calls} = FH.recording_server(fn _n, _fd -> {FH.make_response(503), nil} end)
      h = harness([fspec("retry", %{"active" => false})], %{server: server})
      FH.op(h, %{})
      assert S.size(calls) == 1
    end
  end

  # === timeout ===

  test "timeout expires a slow request" do
    if has?("timeout") do
      clock = FH.make_clock()
      sleeper = FH.clock_sleep(clock)

      server = fn _fctx, _u, _fd ->
        sleeper.(80)
        {FH.make_response(200, H.deep(%{"ok" => true})), nil}
      end

      h = harness([fspec("timeout", %{"ms" => 10, "now" => FH.clock_now(clock)})], %{server: server})
      res = FH.op(h, %{})
      assert res.error.code == "timeout"
      assert S.getprop(track(h, "_timeout"), "count") == 1
    end
  end

  test "timeout passes a fast request through" do
    if has?("timeout") do
      clock = FH.make_clock()
      h = harness([fspec("timeout", %{"ms" => 1000, "now" => FH.clock_now(clock)})])
      assert FH.op(h, %{}).ok == true
    end
  end

  test "timeout ms zero disables the timeout" do
    if has?("timeout") do
      h = harness([fspec("timeout", %{"ms" => 0})])
      assert FH.op(h, %{}).ok == true
    end
  end

  test "timeout interrupts a hanging transport" do
    if has?("timeout") do
      server = fn _fctx, _u, _fd ->
        :timer.sleep(50)
        {FH.make_response(200, H.deep(%{"ok" => true})), nil}
      end

      h = harness([fspec("timeout", %{"ms" => 10})], %{server: server})
      assert FH.op(h, %{}).error.code == "timeout"
    end
  end

  test "timeout inactive does not wrap" do
    if has?("timeout") do
      h = harness([fspec("timeout", %{"active" => false})])
      assert FH.op(h, %{}).ok == true
    end
  end

  # === ratelimit ===

  test "ratelimit throttles once the burst is spent" do
    if has?("ratelimit") do
      clock = FH.make_clock()

      h =
        harness([
          fspec("ratelimit", %{"rate" => 1, "burst" => 2, "now" => FH.clock_now(clock), "sleep" => FH.clock_sleep(clock)})
        ])

      FH.op(h, %{})
      FH.op(h, %{})
      FH.op(h, %{})
      assert S.getprop(track(h, "_ratelimit"), "throttled") == 1
      assert FH.clock_time(clock) > 0
    end
  end

  test "ratelimit burst defaults to rate and refills over time" do
    if has?("ratelimit") do
      clock = FH.make_clock()

      h =
        harness([fspec("ratelimit", %{"rate" => 2, "now" => FH.clock_now(clock), "sleep" => FH.clock_sleep(clock)})])

      FH.op(h, %{})
      FH.op(h, %{})
      FH.clock_advance(clock, 1000)
      FH.op(h, %{})
      t = track(h, "_ratelimit")
      throttled = if t == nil, do: 0, else: S.getprop(t, "throttled")
      assert throttled == 0
    end
  end

  test "ratelimit inactive does not wrap" do
    if has?("ratelimit") do
      h = harness([fspec("ratelimit", %{"active" => false})])
      assert FH.op(h, %{}).ok == true
      assert track(h, "_ratelimit") == nil
    end
  end

  # === cache ===

  test "cache serves a repeated read from cache" do
    if has?("cache") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("cache", %{"ttl" => 10000})], %{server: server})
      a = FH.op(h, %{path: "/w/1"})
      b = FH.op(h, %{path: "/w/1"})
      assert S.size(calls) == 1
      assert S.getprop(track(h, "_cache"), "hit") == 1
      assert a.data != nil and b.data != nil
    end
  end

  test "cache does not cache non-get" do
    if has?("cache") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("cache")], %{server: server})
      FH.op(h, %{op: "create", path: "/w"})
      FH.op(h, %{op: "create", path: "/w"})
      assert S.size(calls) == 2
    end
  end

  test "cache does not cache a non-2xx" do
    if has?("cache") do
      {server, calls} = FH.recording_server(fn _n, _fd -> {FH.make_response(500), nil} end)
      h = harness([fspec("cache")], %{server: server})
      FH.op(h, %{path: "/w"})
      FH.op(h, %{path: "/w"})
      assert S.size(calls) == 2
      assert S.getprop(track(h, "_cache"), "bypass") == 2
    end
  end

  test "cache refetches after the ttl" do
    if has?("cache") do
      clock = FH.make_clock()
      {server, calls} = FH.recording_server()
      h = harness([fspec("cache", %{"ttl" => 1000, "now" => FH.clock_now(clock)})], %{server: server})
      FH.op(h, %{path: "/w"})
      FH.clock_advance(clock, 1500)
      FH.op(h, %{path: "/w"})
      assert S.size(calls) == 2
    end
  end

  test "cache evicts the oldest entry past max" do
    if has?("cache") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("cache", %{"ttl" => 10000, "max" => 1})], %{server: server})
      FH.op(h, %{path: "/a"})
      FH.op(h, %{path: "/b"})
      FH.op(h, %{path: "/a"})
      assert S.size(calls) == 3
    end
  end

  test "cache inactive does not wrap" do
    if has?("cache") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("cache", %{"active" => false})], %{server: server})
      FH.op(h, %{path: "/x"})
      FH.op(h, %{path: "/x"})
      assert S.size(calls) == 2
    end
  end

  # === idempotency ===

  test "idempotency adds a key to mutating ops" do
    if has?("idempotency") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("idempotency")], %{server: server})
      FH.op(h, %{op: "create", path: "/w"})
      assert fd_header(calls, 0, "Idempotency-Key") != nil
      assert S.getprop(track(h, "_idempotency"), "issued") == 1
    end
  end

  test "idempotency adds a key based on http method" do
    if has?("idempotency") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("idempotency")], %{server: server})
      FH.op(h, %{op: "act", method: "PUT", path: "/w"})
      assert fd_header(calls, 0, "Idempotency-Key") != nil
    end
  end

  test "idempotency leaves reads untouched" do
    if has?("idempotency") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("idempotency")], %{server: server})
      FH.op(h, %{path: "/w/1"})
      assert fd_header(calls, 0, "Idempotency-Key") == nil
    end
  end

  test "idempotency preserves a caller key and custom header" do
    if has?("idempotency") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("idempotency", %{"header" => "X-Idem"})], %{server: server})
      FH.op(h, %{op: "create", path: "/w", headers: S.jm(["X-Idem", "caller-1"])})
      assert fd_header(calls, 0, "X-Idem") == "caller-1"
    end
  end

  test "idempotency injected keygen" do
    if has?("idempotency") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("idempotency", %{"keygen" => fn -> "K1" end})], %{server: server})
      FH.op(h, %{op: "create", path: "/w"})
      assert fd_header(calls, 0, "Idempotency-Key") == "K1"
    end
  end

  # === rbac ===

  test "rbac denies before any network call" do
    if has?("rbac") do
      {server, calls} = FH.recording_server()

      h =
        harness([fspec("rbac", %{"rules" => %{"widget.remove" => "admin"}, "permissions" => []})], %{server: server})

      res = FH.op(h, %{op: "remove", path: "/w/1"})
      assert res.error.code == "rbac_denied"
      assert S.size(calls) == 0
      assert S.getprop(track(h, "_rbac"), "denied") == 1
    end
  end

  test "rbac allows a held permission" do
    if has?("rbac") do
      h = harness([fspec("rbac", %{"rules" => %{"widget.remove" => "admin"}, "permissions" => ["admin"]})])
      assert FH.op(h, %{op: "remove", path: "/w/1"}).ok == true
      assert S.getprop(track(h, "_rbac"), "allowed") == 1
    end
  end

  test "rbac rule by op name and wildcard grant" do
    if has?("rbac") do
      h = harness([fspec("rbac", %{"rules" => %{"load" => "read"}, "permissions" => ["*"]})])
      assert FH.op(h, %{}).ok == true
    end
  end

  test "rbac no rule allows by default and deny blocks" do
    if has?("rbac") do
      allow = harness([fspec("rbac", %{"permissions" => []})])
      assert FH.op(allow, %{}).ok == true
      deny = harness([fspec("rbac", %{"deny" => true, "permissions" => []})])
      assert FH.op(deny, %{}).error.code == "rbac_denied"
    end
  end

  # === metrics ===

  test "metrics counts ok and err per op" do
    if has?("metrics") and has?("netsim") do
      h =
        harness([
          fspec("netsim", %{"failTimes" => 1, "failStatus" => 500}),
          fspec("metrics")
        ])

      FH.op(h, %{})
      FH.op(h, %{})
      FH.op(h, %{op: "list"})
      m = track(h, "_metrics")
      assert S.getprop(S.getprop(m, "total"), "count") == 3
      assert S.getprop(S.getprop(m, "total"), "ok") == 2
      assert S.getprop(S.getprop(m, "total"), "err") == 1
      assert S.getprop(S.getprop(S.getprop(m, "ops"), "widget.load"), "count") == 2
    end
  end

  test "metrics injected clock" do
    if has?("metrics") do
      h = harness([fspec("metrics", %{"now" => step_now(10)})])
      FH.op(h, %{})
      m = track(h, "_metrics")
      assert S.getprop(S.getprop(m, "total"), "count") == 1
      assert S.getprop(S.getprop(m, "total"), "totalMs") == 10
      assert S.getprop(S.getprop(m, "total"), "maxMs") == 10
    end
  end

  # === telemetry ===

  test "telemetry opens spans and propagates trace headers" do
    if has?("telemetry") do
      {server, calls} = FH.recording_server()
      spans = S.jt([])
      exporter = fn s -> S.setprop(spans, S.size(spans), s) end
      h = harness([fspec("telemetry", %{"exporter" => exporter})], %{server: server})
      res = FH.op(h, %{})
      assert res.ok == true
      t = track(h, "_telemetry")
      assert S.size(S.getprop(t, "spans")) == 1
      assert S.size(spans) == 1
      sent = fd_headers(calls, 0)
      span0 = S.getelem(S.getprop(t, "spans"), 0)
      assert S.getprop(span0, "traceId") == S.getprop(sent, "X-Trace-Id")
      assert String.match?(S.getprop(sent, "traceparent"), ~r/^00-.+-.+-01$/)
    end
  end

  test "telemetry records a failed span on error" do
    if has?("telemetry") and has?("netsim") do
      h =
        harness([
          fspec("netsim", %{"failTimes" => 1, "failStatus" => 500}),
          fspec("telemetry")
        ])

      FH.op(h, %{})
      t = track(h, "_telemetry")
      assert S.getprop(S.getelem(S.getprop(t, "spans"), 0), "ok") == false
      assert S.getprop(t, "active") == 0
    end
  end

  test "telemetry injected idgen and clock" do
    if has?("telemetry") do
      h = harness([fspec("telemetry", %{"idgen" => fn k -> "#{k}-X" end, "now" => fn -> 5 end})])
      FH.op(h, %{})
      span = S.getelem(S.getprop(track(h, "_telemetry"), "spans"), 0)
      assert S.getprop(span, "traceId") == "trace-X"
      assert S.getprop(span, "durationMs") == 0
    end
  end

  # === debug ===

  test "debug captures a redacted trace and honours onEntry and max" do
    if has?("debug") do
      seen = S.jt([])
      on_entry = fn e -> S.setprop(seen, S.size(seen), e) end
      h = harness([fspec("debug", %{"max" => 1, "onEntry" => on_entry})])
      FH.op(h, %{headers: S.jm(["authorization", "Bearer secret"])})
      FH.op(h, %{op: "list"})
      entries = S.getprop(track(h, "_debug"), "entries")
      assert S.size(entries) == 1
      assert S.size(seen) == 2
      assert S.getprop(S.getprop(S.getelem(seen, 0), "headers"), "authorization") == "<redacted>"
    end
  end

  test "debug captures failures" do
    if has?("debug") and has?("netsim") do
      h =
        harness([
          fspec("netsim", %{"failTimes" => 1, "failStatus" => 500}),
          fspec("debug")
        ])

      FH.op(h, %{})
      entry = S.getelem(S.getprop(track(h, "_debug"), "entries"), 0)
      assert S.getprop(entry, "ok") == false
      assert S.getprop(entry, "status") == 500
    end
  end

  test "debug injected clock and custom redact" do
    if has?("debug") do
      h = harness([fspec("debug", %{"now" => fn -> 7 end, "redact" => ["x-secret"]})])
      FH.op(h, %{headers: S.jm(["x-secret", "hide", "x-ok", "show"])})
      entry = S.getelem(S.getprop(track(h, "_debug"), "entries"), 0)
      hdrs = S.getprop(entry, "headers")
      assert S.getprop(hdrs, "x-secret") == "<redacted>"
      assert S.getprop(hdrs, "x-ok") == "show"
    end
  end

  # === audit ===

  test "audit one record per op with sink and actor" do
    if has?("audit") and has?("netsim") do
      sink = S.jt([])
      sink_fn = fn r -> S.setprop(sink, S.size(sink), r) end

      h =
        harness([
          fspec("netsim", %{"failTimes" => 1, "failStatus" => 500}),
          fspec("audit", %{"actor" => "svc", "sink" => sink_fn, "max" => 5})
        ])

      FH.op(h, %{op: "remove", path: "/w/1"})
      FH.op(h, %{ctrl: S.jm(["actor", "per-call"])})
      recs = S.getprop(track(h, "_audit"), "records")
      assert S.size(recs) == 2
      assert S.getprop(S.getelem(recs, 0), "outcome") == "error"
      assert S.getprop(S.getelem(recs, 0), "actor") == "svc"
      assert S.getprop(S.getelem(recs, 1), "actor") == "per-call"
      assert S.getprop(S.getelem(recs, 1), "outcome") == "ok"
      assert S.size(sink) == 2
    end
  end

  test "audit default actor and injected clock" do
    if has?("audit") do
      h = harness([fspec("audit", %{"now" => fn -> 42 end})])
      FH.op(h, %{})
      rec = S.getelem(S.getprop(track(h, "_audit"), "records"), 0)
      assert S.getprop(rec, "actor") == "anonymous"
      assert S.getprop(rec, "ts") == 42
    end
  end

  test "audit bounds the record list" do
    if has?("audit") do
      h = harness([fspec("audit", %{"max" => 2})])
      FH.op(h, %{})
      FH.op(h, %{})
      FH.op(h, %{})
      recs = S.getprop(track(h, "_audit"), "records")
      assert S.size(recs) == 2
      seqs = Enum.map(0..(S.size(recs) - 1), fn i -> S.getprop(S.getelem(recs, i), "seq") end)
      assert seqs == [2, 3]
    end
  end

  # === clienttrack ===

  test "clienttrack stable client id unique request ids and ua" do
    if has?("clienttrack") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("clienttrack", %{"clientName" => "Acme", "clientVersion" => "2.0.0"})], %{server: server})
      FH.op(h, %{})
      FH.op(h, %{})
      assert fd_header(calls, 0, "User-Agent") == "Acme/2.0.0"
      assert fd_header(calls, 0, "X-Client-Id") == fd_header(calls, 1, "X-Client-Id")
      assert fd_header(calls, 0, "X-Request-Id") != fd_header(calls, 1, "X-Request-Id")
      assert S.getprop(track(h, "_clienttrack"), "requests") == 2
    end
  end

  test "clienttrack does not clobber a caller user agent" do
    if has?("clienttrack") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("clienttrack")], %{server: server})
      FH.op(h, %{headers: S.jm(["User-Agent", "mine"])})
      assert fd_header(calls, 0, "User-Agent") == "mine"
    end
  end

  test "clienttrack injected idgen and fixed session" do
    if has?("clienttrack") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("clienttrack", %{"sessionId" => "S1", "idgen" => fn k -> "#{k}-1" end})], %{server: server})
      FH.op(h, %{})
      assert fd_header(calls, 0, "X-Client-Id") == "S1"
      assert fd_header(calls, 0, "X-Request-Id") == "request-1"
    end
  end

  test "clienttrack lazily creates the session id" do
    if has?("clienttrack") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("clienttrack")], %{server: server})
      FH.op(h, %{})
      assert fd_header(calls, 0, "X-Client-Id") != nil
    end
  end

  # === paging ===

  test "paging stamps page limit and reads header signals" do
    if has?("paging") do
      {server, calls} =
        FH.recording_server(fn _n, _fd ->
          {FH.make_response(
             200,
             H.deep(%{"items" => [1, 2]}),
             H.deep(%{"x-next-page" => "2", "x-total-count" => "5", "link" => "</w?page=2>; rel=\"next\""})
           ), nil}
        end)

      h = harness([fspec("paging", %{"limit" => 2})], %{server: server})
      res = FH.op(h, %{op: "list", path: "/w"})
      assert String.match?(call_url(calls, 0), ~r/[?&]page=1(&|$)/)
      assert String.match?(call_url(calls, 0), ~r/[?&]limit=2(&|$)/)
      paging = S.getprop(res.result, "paging")
      assert S.getprop(paging, "nextPage") == 2
      assert S.getprop(paging, "totalCount") == 5
      assert S.getprop(paging, "next") == "/w?page=2"
      assert S.getprop(paging, "hasMore") == true
    end
  end

  test "paging body cursor and explicit cursor request" do
    if has?("paging") do
      {server, calls} =
        FH.recording_server(fn _n, _fd ->
          {FH.make_response(200, H.deep(%{"nextCursor" => "abc", "hasMore" => true})), nil}
        end)

      h = harness([fspec("paging")], %{server: server})
      res = FH.op(h, %{op: "list", path: "/w", ctrl: S.jm(["paging", S.jm(["cursor", "xyz"])])})
      assert String.match?(call_url(calls, 0), ~r/[?&]cursor=xyz(&|$)/)
      assert S.getprop(S.getprop(res.result, "paging"), "cursor") == "abc"
      assert S.getprop(S.getprop(res.result, "paging"), "hasMore") == true
    end
  end

  test "paging non-list op is not paged" do
    if has?("paging") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("paging")], %{server: server})
      res = FH.op(h, %{path: "/w/1"})
      assert not String.match?(call_url(calls, 0), ~r/[?&]page=/)
      assert S.getprop(res.result, "paging") == nil
    end
  end

  # === streaming ===

  test "streaming streams list items" do
    if has?("streaming") do
      clock = FH.make_clock()
      {server, _calls} = FH.recording_server(fn _n, _fd -> {FH.make_response(200, H.deep(["a", "b", "c"])), nil} end)
      h = harness([fspec("streaming", %{"chunkDelay" => 5, "sleep" => FH.clock_sleep(clock)})], %{server: server})
      res = FH.op(h, %{op: "list", path: "/w"})
      assert S.getprop(res.result, "streaming") == true
      seen = S.getprop(res.result, "stream").()
      assert seen == ["a", "b", "c"]
      assert FH.clock_time(clock) == 15
      assert S.getprop(track(h, "_streaming"), "opened") == 1
    end
  end

  test "streaming batches with chunk size" do
    if has?("streaming") do
      {server, _calls} =
        FH.recording_server(fn _n, _fd -> {FH.make_response(200, H.deep([1, 2, 3, 4, 5])), nil} end)

      h = harness([fspec("streaming", %{"chunkSize" => 2})], %{server: server})
      res = FH.op(h, %{op: "list", path: "/w"})
      assert S.getprop(res.result, "stream").() == [[1, 2], [3, 4], [5]]
    end
  end

  test "streaming non-list op is not streamed" do
    if has?("streaming") do
      h = harness([fspec("streaming")])
      res = FH.op(h, %{})
      assert S.getprop(res.result, "streaming") == nil
    end
  end

  # === proxy ===

  test "proxy routes and invokes an agent factory" do
    if has?("proxy") do
      {server, calls} = FH.recording_server()
      holder = S.jm([])
      agent = fn u, _target -> S.setprop(holder, "url", u); S.jm(["a", 1]) end
      h = harness([fspec("proxy", %{"url" => "http://proxy:8080", "agent" => agent})], %{server: server})
      FH.op(h, %{})
      assert fd_prop(calls, 0, "proxy") == "http://proxy:8080"
      assert S.getprop(fd_prop(calls, 0, "dispatcher"), "a") == 1
      assert S.getprop(holder, "url") == "http://proxy:8080"
      assert S.getprop(track(h, "_proxy"), "routed") == 1
    end
  end

  test "proxy bypasses no-proxy hosts" do
    if has?("proxy") do
      {server, calls} = FH.recording_server()

      h =
        harness([fspec("proxy", %{"url" => "http://proxy:8080", "noProxy" => ["api.test"]})],
          %{server: server, base: "http://api.test"})

      FH.op(h, %{})
      assert fd_prop(calls, 0, "proxy") == nil
    end
  end

  test "proxy from env reads https proxy" do
    if has?("proxy") do
      prev = System.get_env("HTTPS_PROXY")
      System.put_env("HTTPS_PROXY", "http://env-proxy:8080")

      try do
        {server, calls} = FH.recording_server()
        h = harness([fspec("proxy", %{"fromEnv" => true})], %{server: server})
        FH.op(h, %{})
        assert fd_prop(calls, 0, "proxy") == "http://env-proxy:8080"
      after
        if prev == nil, do: System.delete_env("HTTPS_PROXY"), else: System.put_env("HTTPS_PROXY", prev)
      end
    end
  end

  test "proxy inactive or without url is a no-op" do
    if has?("proxy") do
      {server, calls} = FH.recording_server()
      h = harness([fspec("proxy", %{"active" => false})], %{server: server})
      FH.op(h, %{})
      assert fd_prop(calls, 0, "proxy") == nil

      {server2, calls2} = FH.recording_server()
      h2 = harness([fspec("proxy")], %{server: server2})
      FH.op(h2, %{})
      assert fd_prop(calls2, 0, "proxy") == nil
    end
  end

  # === composition ===

  test "cache plus netsim a hit skips the simulated failure" do
    if has?("cache") and has?("netsim") do
      h =
        harness([
          fspec("netsim", %{"failEvery" => 2}),
          fspec("cache", %{"ttl" => 10000})
        ])

      assert FH.op(h, %{path: "/w"}).ok == true
      assert FH.op(h, %{path: "/w"}).ok == true
      assert S.getprop(track(h, "_netsim"), "calls") == 1
    end
  end
end
