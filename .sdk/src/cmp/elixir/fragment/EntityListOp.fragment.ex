# EJECT-START

  # Returns a list of entityname entity maps (ProjectName.Types.entityname/0)
  # on success; pipeline errors surface as the error value built by
  # Utility.make_error (shape is utility-configurable), hence term().
  @spec list(map(), ProjectName.Types.entityname_list_match() | nil, map() | nil) :: term()
  def list(ent, reqmatch \\ nil, ctrl \\ nil) do
    reqmatch = if reqmatch == nil, do: S.jm([]), else: reqmatch

    ctx =
      Context.new(
        S.jm([
          "opname", "list",
          "ctrl", ctrl,
          "match", S.getprop(ent, "_match"),
          "data", S.getprop(ent, "_data"),
          "reqmatch", reqmatch
        ]),
        S.getprop(ent, "_entctx")
      )

    post_done = fn ->
      result = S.getprop(ctx, "result")

      if result != nil do
        rm = S.getprop(result, "resmatch")
        if rm != nil, do: S.setprop(ent, "_match", rm)
      end
    end

    # `list` resolves to one ENTITY per record — make_result builds them.
    Pipeline.run_op(ctx, post_done)
  end

# EJECT-END
