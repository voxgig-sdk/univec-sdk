# Univec SDK concurrency test
#
# Requests in flight at once on one client, each in its own process, register
# and clean secrets through the one registry the client holds.

defmodule Univec.ConcurrencyTest do
  use ExUnit.Case

  alias Univec.Utility
  alias Voxgig.Struct, as: S

  @rounds 3
  @width 8
  @added 16
  @masked "a [redacted] b [redacted] c"

  # Runs body in @width processes, released once every one is waiting, and
  # returns what they raised.
  defp at_once(body) do
    parent = self()
    waiting = :counters.new(1, [:atomics])

    tasks =
      for n <- 0..(@width - 1) do
        Task.async(fn ->
          :counters.add(waiting, 1, 1)
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          seen = :counters.get(waiting, 1)

          try do
            body.(n)
            {seen, nil}
          rescue
            err -> {seen, err}
          end
        end)
      end

    ready =
      for _ <- tasks do
        receive do
          {:ready, pid} -> pid
        end
      end

    Enum.each(ready, &send(&1, :go))
    outcomes = Task.await_many(tasks, :infinity)

    for {seen, _} <- outcomes do
      assert @width == seen, "a process was released with #{seen} of #{@width} waiting"
    end

    for {_, err} <- outcomes, nil != err, do: err
  end

  # A live client whose transport answers at once.
  defp live_client do
    fetch = fn _url, _fetchdef ->
      {S.jm([
         "status", 200,
         "statusText", "OK",
         "headers", S.jm([]),
         "json", fn -> S.jm(["ok", true]) end
       ]), nil}
    end

    Univec.new(
      S.jm([
        "base", "http://concurrency.test/api",
        "allow", S.jm(["op", "direct"]),
        "system", S.jm(["fetch", fetch])
      ])
    )
  end

  defp register_secrets(root, round, n, registering) do
    try do
      for k <- 1..@added, do: Utility.clean_add(root, "ADDED-SECRET-#{round}-#{n}-#{k}")
    after
      :counters.sub(registering, 1, 1)
    end
  end

  defp assert_every_secret_masked(root, round) do
    for n <- 0..(div(@width, 2) - 1), k <- 1..@added do
      added = "ADDED-SECRET-#{round}-#{n}-#{k}"

      assert "[redacted]" == Utility.clean(root, added),
             "round #{round}: #{added} was registered but not masked"
    end
  end

  # A cleaner pauses between passes, so the registrars contend with each other.
  defp clean_while(root, text, registering) do
    if 0 < :counters.get(registering, 1) do
      got = Utility.clean(root, text)

      if @masked != got do
        raise "cleaned to: " <> inspect(got)
      end

      Process.sleep(1)
      clean_while(root, text, registering)
    end
  end

  # Secrets registered in some processes while others clean: every clean masks
  # what was registered before it, the longer secret whole, and no
  # registration is lost.
  test "concurrent registration keeps every secret masked" do
    for round <- 1..@rounds do
      client = Univec.test()
      root = Univec.get_root_ctx(client)
      inner = "INNER-SECRET-#{round}"
      Utility.clean_add(root, inner)
      Utility.clean_add(root, "OUTER-#{inner}-TAIL")
      text = "a #{inner} b OUTER-#{inner}-TAIL c"
      assert @masked == Utility.clean(root, text)

      registering = :counters.new(1, [:atomics])
      :counters.put(registering, 1, div(@width, 2))

      raised =
        at_once(fn n ->
          if n < div(@width, 2) do
            register_secrets(root, round, n, registering)
          else
            clean_while(root, text, registering)
          end
        end)

      assert [] == raised, "round #{round} raised: #{inspect(raised)}"
      assert_every_secret_masked(root, round)
    end
  end

  defp request_while(client, n, registering) do
    if 0 < :counters.get(registering, 1) do
      res = Univec.direct(client, S.jm(["path", "p#{n}"]))

      if true != S.getprop(res, "ok") do
        raise "a request failed: " <> inspect(S.getprop(res, "err"))
      end

      request_while(client, n, registering)
    end
  end

  # Requests on one client while secrets register on it: each request copies
  # the client's options, the registry among them.
  test "concurrent requests survive registration" do
    for round <- 1..@rounds do
      client = live_client()
      root = Univec.get_root_ctx(client)
      registering = :counters.new(1, [:atomics])
      :counters.put(registering, 1, div(@width, 2))

      raised =
        at_once(fn n ->
          if n < div(@width, 2) do
            register_secrets(root, round, n, registering)
          else
            request_while(client, n, registering)
          end
        end)

      assert [] == raised, "round #{round} raised: #{inspect(raised)}"
      assert_every_secret_masked(root, round)
    end
  end
end
