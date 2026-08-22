
import { cmp, Content, File } from '@voxgig/sdkgen'


// Emits elixir/test/readme_examples_test.exs — an ExUnit SYNTAX + PRESENCE
// gate over every ```elixir fenced block in the three docs that ship elixir
// examples: the repository ROOT README.md, the per-language elixir/README.md,
// and the per-language elixir/REFERENCE.md.
//
// For each block, tagged by (source doc, index), the gate PARSES it with
// `Code.string_to_quoted/1` — catching malformed examples (a missing `end`, a
// bad token, an unbalanced `%{}`). It also asserts each doc that exists ships
// at least one elixir block.
//
// SCOPE NOTE: unlike the Python/Lua gates this does NOT execute blocks in a
// seeded offline subprocess. Elixir's compile model makes running a README
// fragment against the generated `<Name>` modules substantially heavier (each
// block would need the SDK compiled and loaded, and the narrative aliases
// resolved), so this port stops at the syntax gate — a real, useful guard that
// keeps documented examples parseable as the generator evolves.
//
// The emitted Elixir avoids backticks (chr 96 via <<96>>) so this TS template
// literal stays clean; the only interpolation is the SDK module name.
const ReadmeExamplesTest = cmp(function ReadmeExamplesTest(props: any) {
  const { ctx$: { model } } = props

  const Name = model.const.Name

  File({ name: 'readme_examples_test.exs' }, () => {
    Content(`# ${Name} SDK — documentation elixir-examples syntax gate.
#
# SYNTAX + PRESENCE gate over every elixir fenced code block in three docs:
#   - the repository ROOT README.md (one directory above the elixir/ package),
#   - the per-language elixir/README.md,
#   - the per-language elixir/REFERENCE.md.
#
# Every block is parsed with Code.string_to_quoted/1 so a malformed documented
# example (missing end, unbalanced map, bad token) fails the suite. Generated
# by @voxgig/sdkgen — do not edit by hand.

defmodule ${Name}.ReadmeExamplesTest do
  use ExUnit.Case

  # The triple-backtick markdown fence, built without literal backticks.
  @fence String.duplicate(<<96>>, 3)

  @pkg_root Path.expand("..", __DIR__)
  @docs [
    {"root README", Path.expand("../README.md", @pkg_root)},
    {"elixir README.md", Path.join(@pkg_root, "README.md")},
    {"elixir REFERENCE.md", Path.join(@pkg_root, "REFERENCE.md")}
  ]

  # Return the code bodies of every elixir-tagged fenced block in \`text\`.
  # Splitting on the fence yields alternating outside/inside segments; the
  # odd-indexed ones are inside a fence. Keep only those whose info string
  # (first line) is exactly "elixir".
  defp elixir_blocks(text) do
    text
    |> String.split(@fence)
    |> Enum.with_index()
    |> Enum.filter(fn {_seg, i} -> rem(i, 2) == 1 end)
    |> Enum.map(fn {seg, _i} -> seg end)
    |> Enum.filter(fn seg ->
      [info | _] = String.split(seg, "\\n")
      String.trim(info) == "elixir"
    end)
    |> Enum.map(fn seg ->
      [_info | rest] = String.split(seg, "\\n")
      Enum.join(rest, "\\n")
    end)
  end

  # True when every opening fence in \`text\` has a matching closing fence.
  # Splitting on the fence yields (fence_count + 1) segments, so an even fence
  # count (odd segment count) means all fences are paired. An unclosed
  # \`\`\`elixir fence at EOF would otherwise leave a truncated/empty block that
  # parses cleanly and slips through the syntax gate silently.
  defp fences_balanced?(text) do
    rem(length(String.split(text, @fence)) - 1, 2) == 0
  end

  defp doc_blocks(path) do
    case File.read(path) do
      {:ok, text} -> {:present, elixir_blocks(text), fences_balanced?(text)}
      _ -> :absent
    end
  end

  test "documented elixir examples parse" do
    {failures, present, total} =
      Enum.reduce(@docs, {[], 0, 0}, fn {label, path}, {fails, present, total} ->
        case doc_blocks(path) do
          :absent ->
            {fails, present, total}

          {:present, blocks, balanced?} ->
            # An unclosed fence is a malformed doc — fail rather than silently
            # scanning past the truncated block.
            fence_fails =
              if balanced? do
                []
              else
                [label <> " has an unclosed " <> @fence <> "elixir fence (odd fence count)"]
              end

            block_fails =
              blocks
              |> Enum.with_index()
              |> Enum.flat_map(fn {block, i} ->
                case Code.string_to_quoted(block) do
                  {:ok, _ast} ->
                    []

                  {:error, reason} ->
                    [
                      label <>
                        " elixir block #" <>
                        Integer.to_string(i) <>
                        " failed to parse: " <>
                        inspect(reason) <> "\\n\\n" <> block
                    ]
                end
              end)

            {fails ++ fence_fails ++ block_fails, present + 1, total + length(blocks)}
        end
      end)

    assert failures == [], Enum.join(failures, "\\n\\n")

    # At least one doc must be present and carry at least one elixir example.
    assert present > 0, "no README/REFERENCE docs found to scan for elixir examples"
    assert total > 0, "expected at least one elixir example block across the docs"
  end
end
`)
  })
})


export {
  ReadmeExamplesTest
}
