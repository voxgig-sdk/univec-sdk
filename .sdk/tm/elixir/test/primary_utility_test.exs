# Univec SDK primary-utility test
#
# Drives the SHARED language-neutral corpus (.sdk/test/test.json -> "primary")
# through this SDK's request-shaping utilities, so the cases cannot drift from
# the reference implementation. Each section is looked up with getSpec and
# executed with runset, as the ts/js reference harness does.
#
# This suite used to MIRROR the corpus by hand: it asserted a handful of
# behaviours it had transcribed, so a corpus case that changed — or one that
# was added — went unnoticed here. Driving the corpus is what makes elixir a
# FULL parity target rather than a mirrored one.

defmodule Univec.PrimaryUtilityTest do
  use ExUnit.Case

  test "primary utilities pass the shared corpus" do
    {pass, fail, failures} = Univec.StructCorpus.run_primary()

    if fail > 0 do
      IO.puts("\n" <> Enum.join(Enum.take(failures, 40), "\n"))
    end

    IO.puts("\nPRIMARY CORPUS: PASS #{pass}  FAIL #{fail}")

    # A run that executes nothing is not a pass. The corpus is the point.
    assert pass > 0, "the primary corpus executed no cases"
    assert fail == 0
  end
end
