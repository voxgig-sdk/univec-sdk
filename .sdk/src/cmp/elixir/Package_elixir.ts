
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


// Generate mix.exs for the Elixir SDK. The vendored struct library has zero
// third-party runtime deps, so a bare SDK ships with none - but dependencies
// declared by the model DO flow: the target's own `deps` block plus any
// feature-declared elixir deps (e.g. the station feature's voxgig_station),
// via the shared collectDeps helper, exactly like rust/dart/go. A model with
// no deps emits the byte-identical `defp deps, do: []` it always has.
const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const Name = model.const.Name
  // Elixir app names are atoms: a hyphenated slug (`bluefin-decryptx-p2pe`)
  // is invalid (`:a-b` parses as subtraction). Snake_case it.
  const app = String(model.const.name).replace(/-/g, '_')
  const { repoUrl } = repoInfo(model)

  // Render one mix deps entry per collected dependency. Hex package names
  // share the atom alphabet, but a hyphen in a model dep name is mapped to
  // '_' rather than emitted broken. Version -> Mix requirement: an explicit
  // operator is kept (spaced, the mix convention: '>=0.0.1' -> '>= 0.0.1');
  // a bare version gets hex's customary '~>'; a target dep with no version
  // accepts anything. kind: 'dev' scopes to [:dev, :test]; 'peer'/'prod'
  // (and anything else) are runtime deps - mix has no peer notion.
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
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
