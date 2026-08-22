# Univec SDK operation pipeline
#
# run_op drives one operation through the stages, firing feature hooks
# between them (the generator replaces each marker line with a
# Utility.feature_hook/2 call). An early error is delivered
# through make_error, which either raises the SDK error (default) — caught
# by the rescue clause so PreUnexpected still fires — or returns bare
# resdata when throw_err is disabled, delivered via the :sdk_ret throw.

defmodule Univec.Pipeline do
  alias Voxgig.Struct, as: S
  alias Univec.Utility

  def run_op(ctx, post_done) do
    out = S.getprop(ctx, "out")

    try do
      Utility.feature_hook(ctx, "PrePoint")

      {point, err} = Utility.make_point(ctx)
      S.setprop(out, "point", point)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      Utility.feature_hook(ctx, "PreSpec")

      {spec, err} = Utility.make_spec(ctx)
      S.setprop(out, "spec", spec)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      Utility.feature_hook(ctx, "PreRequest")

      {req, err} = Utility.make_request(ctx)
      S.setprop(out, "request", req)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      Utility.feature_hook(ctx, "PreResponse")

      {resp, err} = Utility.make_response(ctx)
      S.setprop(out, "response", resp)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      Utility.feature_hook(ctx, "PreResult")

      {result, err} = Utility.make_result(ctx)
      S.setprop(out, "result", result)
      if err != nil, do: throw({:sdk_ret, Utility.make_error(ctx, err)})

      Utility.feature_hook(ctx, "PreDone")

      post_done.()

      Utility.done(ctx)
    rescue
      e ->
        Utility.feature_hook(ctx, "PreUnexpected")

        reraise(e, __STACKTRACE__)
    catch
      {:sdk_ret, v} -> v
    end
  end
end
