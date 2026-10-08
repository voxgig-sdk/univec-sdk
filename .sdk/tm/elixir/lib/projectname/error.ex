# Univec SDK error
#
# An exception struct so it can be `raise`d on the default (throw) path and
# also stored as a plain value inside struct nodes (e.g. ctx.out["point"]
# for the rbac short-circuit). `is_sdk_error` marks SDK-originated errors.

defmodule Univec.Error do
  defexception [:code, :msg, :sdk, :ctx, :result, :spec, is_sdk_error: true]

  @impl true
  def message(%__MODULE__{msg: msg}), do: msg || ""

  def new(code \\ "", msg \\ "", ctx \\ nil) do
    %__MODULE__{code: code, msg: msg, sdk: "Univec", ctx: ctx}
  end

  # The HTTP status, promoted so a caller can branch without reaching into
  # the result's shape; -1 when there was no response.
  def status(%__MODULE__{result: result}) do
    s = if Voxgig.Struct.ismap(result), do: Voxgig.Struct.getprop(result, "status"), else: nil
    if is_number(s), do: trunc(s), else: -1
  end

  def not_found?(%__MODULE__{} = e), do: 404 == status(e)
end

# The context holds the live spec and options, and an error is what gets
# logged: the printed form carries what make_error attached, which is already
# cleaned, and never the context. A struct node prints as its JSON, since a
# bare handle says nothing.
defimpl Inspect, for: Univec.Error do
  import Inspect.Algebra
  alias Voxgig.Struct, as: S

  def inspect(e, opts) do
    show = fn v -> if S.isnode(v), do: S.jsonify(v, S.jm(["indent", 0])), else: v end
    fields = [code: e.code, msg: e.msg, sdk: e.sdk, result: show.(e.result), spec: show.(e.spec)]
    concat(["#Univec.Error<", to_doc(fields, opts), ">"])
  end
end
