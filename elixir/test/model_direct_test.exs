# Model direct test (offline, mock system.fetch)

defmodule Univec.ModelDirectTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H

  # A recording live-mode SDK whose transport returns `canned`.
  defp mk(canned) do
    parent = self()

    fetch = fn url, _fetchdef ->
      send(parent, {:called, url})
      {S.jm(["status", 200, "statusText", "OK", "headers", S.jm([]), "json", fn -> canned end, "body", "mock"]), nil}
    end

    Univec.new(S.jm(["base", "http://localhost:8080", "system", S.jm(["fetch", fetch])]))
  end

  test "should direct list model" do
    canned = S.jt([S.jm(["id", "direct01"]), S.jm(["id", "direct02"])])
    sdk = mk(canned)
    res = Univec.direct(sdk, H.deep(%{"path" => "/model", "method" => "GET", "params" => %{}}))
    assert S.getprop(res, "ok") == true
    assert H.to_int(S.getprop(res, "status")) == 200
    assert S.islist(S.getprop(res, "data"))
    assert S.size(S.getprop(res, "data")) == 2
    assert_received {:called, _url}
  end
end
