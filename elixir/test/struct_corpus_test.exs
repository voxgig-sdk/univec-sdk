# Runs the vendored struct library against the shared corpus
# (.sdk/test/test.json -> "struct"). Prints a PASS/FAIL summary and asserts
# zero failures.

defmodule Univec.StructCorpusTest do
  use ExUnit.Case

  test "vendored struct passes the shared corpus" do
    {pass, fail, failures} = Univec.StructCorpus.run()

    if fail > 0 do
      IO.puts("\n" <> Enum.join(Enum.take(failures, 40), "\n"))
    end

    IO.puts("\nSTRUCT CORPUS: PASS #{pass}  FAIL #{fail}")
    assert fail == 0
  end
end
