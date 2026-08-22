# EJECT-START

  # Returns the updated entityname entity map (ProjectName.Types.entityname/0)
  # on success; pipeline errors surface as the error value built by
  # Utility.make_error (shape is utility-configurable), hence term().
  @spec update(map(), ProjectName.Types.entityname_update_data() | nil, map() | nil) :: term()
  def update(ent, reqdata, ctrl \\ nil) do
    ctx =
      Context.new(
        S.jm([
          "opname", "update",
          "ctrl", ctrl,
          "match", S.getprop(ent, "_match"),
          "data", S.getprop(ent, "_data"),
          "reqdata", reqdata
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
    EntityBase.op_return(ent, ctx, out)
  end

# EJECT-END
