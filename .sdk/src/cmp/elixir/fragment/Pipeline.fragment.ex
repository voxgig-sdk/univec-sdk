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
      e ->
        # #PreUnexpected-Hook

        reraise(e, __STACKTRACE__)
    catch
      {:sdk_ret, v} -> v
    end
  end
end
