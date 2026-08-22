# EJECT-START

  # Returns the removed entityname entity map (ProjectName.Types.entityname/0)
  # on success; pipeline errors surface as the error value built by
  # Utility.make_error (shape is utility-configurable), hence term().
  @spec remove(map(), ProjectName.Types.entityname_remove_match() | nil, map() | nil) :: term()
  def remove(ent, reqmatch \\ nil, ctrl \\ nil) do
    reqmatch = if reqmatch == nil, do: S.jm([]), else: reqmatch

    ctx =
      Context.new(
        S.jm([
          "opname", "remove",
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
        rd = S.getprop(result, "resdata")
        if rd != nil, do: S.setprop(ent, "_data", H.or_(H.to_map(S.clone(rd)), S.jm([])))
      end
    end

    out = Pipeline.run_op(ctx, post_done)
    ent = EntityBase.op_return(ent, ctx, out)
    # A removed entity keeps its data but is no longer a live record.
    if ent == out, do: out, else: EntityBase.mark_deleted(ent)
  end

# EJECT-END
