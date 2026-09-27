
import {
  Content,
  File,
  cmp,
  collectDeps,
  pkgDescription,
  repoInfo,
  packageVersion,
} from '@voxgig/sdkgen'


import type {
  Model,
} from '@voxgig/apidef'


const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const Name = model.const.Name
  // Elixir app names are atoms: a hyphenated slug (`bluefin-decryptx-p2pe`)
  // is invalid (`:a-b` parses as subtraction). Snake_case it.
  const app = String(model.const.name).replace(/-/g, '_')
  const { repoUrl } = repoInfo(model)

  const entries: string[] = []
  for (const d of collectDeps(model, target.name, target.deps, ctx$.log)) {
    const atom = String(d.name).replace(/-/g, '_')
    const version = null == d.version || '' === String(d.version).trim()
      ? '>= 0.0.0'
      : mixRequirement(String(d.version).trim())
    const scope = 'dev' === (d.raw as any)?.kind ? ', only: [:dev, :test]' : ''
    entries.push(`{:${atom}, ${JSON.stringify(version)}${scope}}`)
  }

  const depsBlock = 0 === entries.length
    ? `  defp deps, do: []`
    : `  defp deps do
    [
      ${entries.join(',\n      ')}
    ]
  end`

  File({ name: 'mix.exs' }, () => {
    Content(`defmodule ${Name}.MixProject do
  use Mix.Project

  def project do
    [
      app: :${app},
      version: "${packageVersion(model, target.name)}",
      elixir: "~> 1.14",
      description: ${JSON.stringify(pkgDescription(model, target.name))},
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package()
    ]
  end

  def application, do: [extra_applications: [:inets, :ssl]]

${depsBlock}

  # test/vendor carries the vendored @voxgig/omni engine the corpus suites
  # run through; it is a .ex tree, so mix has to be told to compile it, and
  # only under :test - a consumer's library build never sees the runner.
  defp elixirc_paths(:test), do: ["lib", "test/support", "test/vendor"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Homepage" => ${JSON.stringify(repoUrl)}}
    ]
  end
end
`)
  })
})


function mixRequirement(version: string): string {
  const m = version.match(/^(>=|<=|~>|==|!=|>|<)\s*(.+)$/)
  if (null != m) {
    return m[1] + ' ' + m[2]
  }
  return '~> ' + version
}


export {
  Package
}
