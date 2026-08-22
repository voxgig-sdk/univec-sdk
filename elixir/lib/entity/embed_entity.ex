# Univec SDK Embed entity
#
# Per-entity module. Generic construction/data/match operations delegate to
# EntityBase; each active op (load/list/create/update/remove) builds a ctx
# and drives it through Univec.Pipeline.run_op.

defmodule Univec.Entity.Embed do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{EntityBase, Context, Pipeline}

  def new(client, entopts \\ nil) do
    EntityBase.construct(__MODULE__, client, "embed", entopts)
  end

  def get_name(ent), do: EntityBase.get_name(ent)
  def make(ent), do: EntityBase.make(ent)
  def data_set(ent, args \\ nil), do: EntityBase.data_set(ent, args)
  def data_get(ent), do: EntityBase.data_get(ent)
  def match_set(ent, args \\ nil), do: EntityBase.match_set(ent, args)
  def match_get(ent), do: EntityBase.match_get(ent)

  # Streaming operation (see EntityBase.stream): runs `action` through the
  # pipeline and returns a lazy Stream over result items.
  def stream(ent, action, args \\ nil, callopts \\ nil),
    do: EntityBase.stream(ent, action, args, callopts)

  

  

  
  # Returns the created embed entity map (Univec.Types.embed/0)
  # on success; pipeline errors surface as the error value built by
  # Utility.make_error (shape is utility-configurable), hence term().
  @spec create(map(), Univec.Types.embed_create_data() | nil, map() | nil) :: term()
  def create(ent, reqdata, ctrl \\ nil) do
    ctx =
      Context.new(
        S.jm([
          "opname", "create",
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
        rd = S.getprop(result, "resdata")
        if rd != nil, do: S.setprop(ent, "_data", H.or_(H.to_map(S.clone(rd)), S.jm([])))
      end
    end

    out = Pipeline.run_op(ctx, post_done)
    EntityBase.op_return(ent, ctx, out)
  end



  

  
end
