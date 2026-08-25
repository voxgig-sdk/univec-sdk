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
end
