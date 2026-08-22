# Univec SDK entity stream() test
#
# Exercises the generated entity stream(action, args, callopts) method. stream
# runs an op through the full pipeline and returns a lazy Elixir Stream over
# result items. With the streaming feature active the result carries an
# incremental iterator and stream yields from it (honouring chunkSize);
# otherwise it falls back to the materialised items, so stream always yields.
# API-agnostic: discovers a top-level list entity from the config (a list op
# point with no required params) and seeds it via the test mock.

defmodule Univec.StreamTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H

  # True when this SDK was generated with the named feature.
  defp has_feature?(name) do
    f = S.getprop(Univec.Config.make_config(), "feature")
    S.ismap(f) and S.getprop(f, name) != nil
  end

  # Discover an entity whose `list` op has a point with no required params, so
  # the seeded list needs no path parameters.
  defp find_list_entity do
    config = Univec.Config.make_config()
    entities = H.or_(H.to_map(S.getprop(config, "entity")), S.jm([]))

    Enum.find_value(S.keysof(entities), fn name ->
      points = S.getpath(config, "entity.#{name}.op.list.points")

      clean =
        S.islist(points) and S.size(points) > 0 and
          Enum.any?(0..(S.size(points) - 1), fn i ->
            params = S.getpath(S.getelem(points, i), "args.params")

            reqd =
              if S.islist(params) and S.size(params) > 0 do
                Enum.count(0..(S.size(params) - 1), fn j ->
                  S.getprop(S.getelem(params, j), "reqd") == true
                end)
              else
                0
              end

            reqd == 0
          end)

      if clean, do: name, else: nil
    end)
  end

  # Three seeded records via the test mock (the mock walk sets id to the key).
  defp seed(name) do
    S.jm([
      name,
      S.jm([
        "S1", S.jm(["id", "S1", "name", "a"]),
        "S2", S.jm(["id", "S2", "name", "b"]),
        "S3", S.jm(["id", "S3", "name", "c"])
      ])
    ])
  end

  defp entity(sdk, name), do: apply(Univec, String.to_atom(name), [sdk, nil])
  defp entmod(name), do: Module.concat([Univec.Entity, Macro.camelize(name)])

  defp do_stream(sdk, name, callopts) do
    apply(entmod(name), :stream, [entity(sdk, name), "list", S.jm([]), callopts])
    |> Enum.to_list()
  end

  test "entity stream() runs the pipeline and yields items" do
    name = find_list_entity()

    if name == nil do
      # No top-level list entity in this SDK; nothing to exercise.
      assert true
    else
      # Fallback (no streaming feature): materialised items.
      sdk = Univec.test(S.jm(["entity", seed(name)]), nil)
      items = do_stream(sdk, name, nil)
      assert length(items) == 3
      assert S.ismap(hd(items))

      # signal cancels iteration between yields.
      sdk2 = Univec.test(S.jm(["entity", seed(name)]), nil)
      counter = :counters.new(1, [])

      sig = fn ->
        :counters.add(counter, 1, 1)
        :counters.get(counter, 1) >= 2
      end

      items2 = do_stream(sdk2, name, S.jm(["signal", sig]))
      assert length(items2) == 1

      if has_feature?("streaming") do
        # Streaming feature active: yields from the streaming iterator.
        ssdk =
          Univec.test(
            S.jm(["entity", seed(name)]),
            S.jm(["feature", S.jm(["streaming", S.jm(["active", true])])])
          )

        assert length(do_stream(ssdk, name, nil)) == 3

        # chunkSize groups items into batches: 3 items / 2 -> 2 batches.
        csdk =
          Univec.test(
            S.jm(["entity", seed(name)]),
            S.jm(["feature", S.jm(["streaming", S.jm(["active", true, "chunkSize", 2])])])
          )

        assert length(do_stream(csdk, name, nil)) == 2
      end
    end
  end
end
