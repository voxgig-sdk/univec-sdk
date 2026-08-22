# Univec SDK feature factory

defmodule Univec.Features do
  def make_feature(name) do
    case name do
      "test" -> Univec.Feature.Test.new()
      _ -> Univec.Feature.new()
    end
  end
end
