# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/ref.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Ref do
  @moduledoc """
  Identity: name+tag, written `name$tag` (section 4).

  The four pure functions, and the whole of what `ref` pins. They are the
  first thing a new port implements and the first corpus section it passes.

  NO REGEX. Elixir's `~r/.../` is PCRE, whose `$` matches before a final
  newline, so a `^...$` spelling would admit `"stripe\\n"` as a name - the
  hole the ruby port surfaced in python. A character walk cannot have it,
  and the four `#trailing-newline` entries pass here without the port
  having to know they exist.
  """

  alias Voxgig.Plugin.Types

  @ref_max 1024

  @doc "Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\\-/]*$`, max 1024."
  def check_name(name) when is_binary(name) do
    case String.to_charlist(name) do
      [] -> false
      [first | rest] ->
        byte_size(name) <= @ref_max and (alpha?(first) or ?@ == first) and
          Enum.all?(rest, &namechar?/1)
    end
  end

  def check_name(_), do: false

  @doc """
  Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.

  The asymmetry with a name is deliberate: a tag MAY start with a digit
  because auto-tagging assigns integer tags (`stripe$1`), and a tag admits
  neither `@` nor `/` because a name is a package specifier and a tag is
  not.
  """
  def check_tag(""), do: true

  def check_tag(tag) when is_binary(tag) do
    byte_size(tag) <= @ref_max and Enum.all?(String.to_charlist(tag), &tagchar?/1)
  end

  def check_tag(_), do: false

  defp alpha?(c), do: (?a <= c and c <= ?z) or (?A <= c and c <= ?Z)
  defp digit?(c), do: ?0 <= c and c <= ?9
  defp namechar?(c), do: alpha?(c) or digit?(c) or c in [?., ?~, ?_, ?-, ?/]
  defp tagchar?(c), do: alpha?(c) or digit?(c) or c in [?., ?~, ?_, ?-]

  @doc """
  `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both give
  tag "".
  """
  def parse_ref(str) when is_binary(str) do
    # Split on the FIRST `$`. Nothing in the grammar decides this - `$` is
    # in neither character class - so the corpus is the arbiter (section 4
    # rule 5), and it picks the split that blames the part actually at
    # fault: `a$b$c` is a good name with a bad tag, not the reverse.
    {name, tag} =
      case :binary.match(str, "$") do
        :nomatch -> {str, ""}
        {at, _} -> {binary_part(str, 0, at), binary_part(str, at + 1, byte_size(str) - at - 1)}
      end

    if not check_name(name) do
      Types.fail("plugin_bad_name", "invalid plugin name: #{name}", %{"name" => name})
    end

    if not check_tag(tag) do
      Types.fail("plugin_bad_tag", "invalid plugin tag: #{tag}", %{"name" => name, "tag" => tag})
    end

    %{"name" => name, "tag" => tag}
  end

  def parse_ref(_), do: Types.fail("plugin_bad_name", "ref must be a string")

  @doc """
  The pair -> `name$tag`. An empty tag NEVER writes the separator, which is
  the half of canonicalization `format_ref` owns: parse tolerates
  `stripe$`, format never produces it, so a round trip is idempotent.
  """
  def format_ref(name, tag) do
    tag = if is_nil(tag), do: "", else: tag

    if not check_name(name) do
      Types.fail("plugin_bad_name", "invalid plugin name: #{Types.encode(name)}",
                 %{"name" => name})
    end

    if not check_tag(tag) do
      Types.fail("plugin_bad_tag", "invalid plugin tag: #{Types.encode(tag)}",
                 %{"name" => name, "tag" => tag})
    end

    if "" == tag, do: name, else: name <> "$" <> tag
  end

  @doc """
  The canonical spelling of a ref. Section 4 rule 5: ports must
  canonicalize before comparison.
  """
  def canon_ref(str) do
    parsed = parse_ref(str)
    format_ref(parsed["name"], parsed["tag"])
  end

  @doc """
  canon_ref for the internal callers that want the input back unchanged
  when it is not well formed. NEVER use it where a bad ref must be reported
  - the corpus pins plugin_bad_name at every public entry.
  """
  def canon(str) do
    canon_ref(str)
  rescue
    Voxgig.Plugin.Error -> str
  end

  def refname(str) do
    parse_ref(str)["name"]
  rescue
    Voxgig.Plugin.Error -> str
  end
end
