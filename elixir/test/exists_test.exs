defmodule Univec.ExistsTest do
  use ExUnit.Case

  test "should create test sdk" do
    testsdk = Univec.test()
    assert testsdk != nil
  end
end
