# ProjectName SDK operation pipeline
#
# run_op drives one operation through the stages, firing feature hooks
# between them (the generator replaces each marker line with a
# Utility.feature_hook/2 call). An early error is delivered
# through make_error, which either raises the SDK error (default) — caught
# by the rescue clause so PreUnexpected still fires — or returns bare
# resdata when throw_err is disabled, delivered via the :sdk_ret throw.

defmodule ProjectName.Pipeline do
  alias Voxgig.Struct, as: S
  alias ProjectName.Utility

  def run_op(ctx, post_done) do
    out = S.getprop(ctx, "out")

    try do
      # #PrePoint-Hook

      {point, err} = Utility.make_point(ctx)
      S.setprop(out, "point", point)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      # #PreSpec-Hook

      {spec, err} = Utility.make_spec(ctx)
      S.setprop(out, "spec", spec)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      # #PreRequest-Hook

      {req, err} = Utility.make_request(ctx)
      S.setprop(out, "request", req)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      # #PreResponse-Hook

      {resp, err} = Utility.make_response(ctx)
      S.setprop(out, "response", resp)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      # #PreResult-Hook

      {result, err} = Utility.make_result(ctx)
      S.setprop(out, "result", result)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      # #PreDone-Hook

      post_done.()

      Utility.done(ctx)
    rescue
      e -> unexpected(ctx, e, __STACKTRACE__)
    catch
      {:sdk_ret, v} -> v
    end
  end

  # The catch path every entity call leaves through: an error a hook raised
  # never passed through make_error. Nil when the caller switched throwing off.
  def unexpected(ctx, e, st) do
    # What a hook raises here must not escape the cleaning below.
    {e, st} =
      try do
        # #PreUnexpected-Hook

        {e, st}
      rescue
        hookerr -> {hookerr, __STACKTRACE__}
      end

    Utility.clean_explain(ctx)

    if S.getprop(S.getprop(ctx, "ctrl"), "throw_err") == false do
      nil
    else
      reraise(Utility.clean_exception(ctx, e), st)
    end
  end
end
