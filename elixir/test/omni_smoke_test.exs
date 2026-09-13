# Univec SDK omni runner smoke test
#
# Smoke tests for the VENDORED omni runner itself. A runner that cannot FAIL
# a bad entry would turn every corpus suite vacuously green, so the failure
# paths are pinned here, not just the happy one. (Elixir peer of ts's
# test/omni.test.ts, lua's test/omni_smoke_test.lua and py's
# test_omni_smoke.py.)
#
# The spec is built IN MEMORY, in omni's own value model (plain maps and
# lists, no OMNI block - the lenient v0 format the shared corpus uses), so
# these tests depend on no fixture file.

defmodule Univec.OmniSmokeTest do
  use ExUnit.Case

  alias Univec.Omni, as: O

  @spec_smoke %{
    "primary" => %{
      "smoke" => %{
        "basic" => %{
          "set" => [
            %{"in" => 1, "out" => 2},
            %{"in" => 41, "out" => 42}
          ]
        },
        "bad" => %{
          "set" => [
            %{"in" => 1, "out" => 999}
          ]
        },
        "err" => %{
          "set" => [
            %{"in" => 0, "err" => "zero refused"}
          ]
        },
        "argsback" => %{
          "set" => [
            %{"in" => %{"n" => 1}, "match" => %{"args" => %{"0" => %{"n" => 2}}}}
          ]
        }
      }
    }
  }

  # The subject contract the resolver presents: omni's resolved argument list,
  # in the SDK's value model.
  defp inc(args) do
    n = hd(args)
    if n == 0, do: raise(Voxgig.Struct.Error, message: "smoke: zero refused")
    n + 1
  end

  defp pack do
    runner = O.make_runner(@spec_smoke, Univec.test())
    runner.("smoke")
  end

  defp mustfail(fun, want) do
    err =
      try do
        fun.()
        flunk("expected the runner to FAIL, but it passed")
      rescue
        e -> e
      end

    assert O.omnierror?(err), "expected an omni error, got: #{inspect(err)}"

    assert String.contains?(Exception.message(err), want),
           "expected a failure containing '#{want}', got: #{Exception.message(err)}"
  end

  test "runset passes a correct subject" do
    run = pack()
    run.runset.(run.spec["basic"], &inc/1)
    assert O.cases() > 0
  end

  test "runset fails a wrong result with an omni error" do
    run = pack()
    mustfail(fn -> run.runset.(run.spec["bad"], &inc/1) end, "result mismatch")
  end

  test "an expected error is matched, and a missing expected error fails" do
    run = pack()

    # The expected error occurs: passes.
    run.runset.(run.spec["err"], &inc/1)

    # The expected error does NOT occur: must fail.
    run2 = pack()
    mustfail(fn -> run2.runset.(run2.spec["err"], fn args -> hd(args) end) end,
      "expected error did not occur")
  end

  test "an in-place argument rewrite reaches match.args" do
    run = pack()

    # The writeback channel (omni.ex decision 2): the subject MUTATES its
    # argument node, and `match: {args: ...}` must see it. A resolver that
    # dropped the channel would read the pre-call value and this passes only
    # by accident, so the negative case is pinned too.
    run.runset.(run.spec["argsback"], fn args ->
      node = hd(args)
      Voxgig.Struct.setprop(node, "n", 2)
      nil
    end)

    run2 = pack()

    mustfail(
      fn -> run2.runset.(run2.spec["argsback"], fn _args -> nil end) end,
      "match failed at args.0.n"
    )
  end
end
