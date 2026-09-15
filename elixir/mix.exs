defmodule Univec.MixProject do
  use Mix.Project

  def project do
    [
      app: :univec,
      version: "0.1.2",
      elixir: "~> 1.14",
      description: "Unofficial generated elixir SDK for the UniVec public API. Not affiliated with or endorsed by the upstream API provider.",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package()
    ]
  end

  def application, do: [extra_applications: [:inets, :ssl]]

  defp deps, do: []

  # test/vendor carries the vendored @voxgig/omni engine the corpus suites
  # run through; it is a .ex tree, so mix has to be told to compile it, and
  # only under :test - a consumer's library build never sees the runner.
  defp elixirc_paths(:test), do: ["lib", "test/support", "test/vendor"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Homepage" => "https://github.com/voxgig-sdk/univec-sdk"}
    ]
  end
end
