
import { swiftTargetDir, swiftTestDir } from './utility_swift'

import {
  Content,
  File,
  cmp,
  collectDeps,
} from '@voxgig/sdkgen'


import type {
  Model,
} from '@voxgig/apidef'


// Emits Package.swift (the SwiftPM manifest; the Swift twin of Package_go's
// go.mod / Package_csharp's csproj). The library target compiles everything
// under Sources/<Name>Sdk (the copied runtime + generated sources); the test
// target compiles Tests/<Name>SdkTests. Both directories carry the API name:
// Copy does not rewrite path components, so Main_swift copies the two
// placeholder subtrees explicitly via Copy's `to` prop rather than letting a
// blanket copy ship them as ProjectNameSDK.
//
// Dependencies: the runtime itself is dependency-free (Foundation + the
// vendored struct), but declared target/feature deps flow into the manifest
// via collectDeps. SwiftPM cannot name a package by product alone, so a
// swift deps entry carries its coordinates in a documented convention:
//
//   deps: swift: {
//     'VoxgigStation': { active: true, version: '0.0.1', kind: prod,
//       url: 'https://github.com/voxgig/station-swift' }
//   }
//
//   - the entry KEY is the SwiftPM PRODUCT name (also the module the
//     generated source imports);
//   - the extra `url` field is the git repository SwiftPM resolves
//     (`.package(url:from:)`); the package identity SwiftPM derives from it
//     is the URL's last path component (minus any .git), which is what the
//     `.product(name:package:)` reference must use;
//   - `version` feeds `from:` - a plain semver (any leading range operator
//     like '>=' is stripped, since `from:` already means >=).
//
// An entry WITHOUT a `url` is not expressible in a SwiftPM manifest (no
// registry-less by-name dependencies), so it is skipped - unadorned entries
// keep today's zero-dependency output.
const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const Name = model.const.Name

  type SwiftDep = { product: string, url: string, from: string, identity: string }
  const deps: SwiftDep[] = []
  for (const d of collectDeps(model, target.name, target.deps, ctx$.log)) {
    const url = 'string' === typeof (d.raw as any)?.url ? (d.raw as any).url : ''
    if ('' === url) {
      continue
    }
    const from = (d.version || '0.0.0').replace(/^[^0-9]+/, '')
    const identity = (url.split('/').pop() || '').replace(/\.git$/, '')
    deps.push({ product: d.name, url, from, identity })
  }

  const pkgdeps = 0 === deps.length ? '' :
    '\n    dependencies: [\n' +
    deps.map((d) =>
      `        .package(url: "${d.url}", from: "${d.from}"),\n`).join('') +
    '    ],'

  const targetdeps = 0 === deps.length ? '' :
    '\n            dependencies: [\n' +
    deps.map((d) =>
      `                .product(name: "${d.product}", package: "${d.identity}"),\n`)
      .join('') +
    '            ],'

  File({ name: 'Package.swift' }, () => {
    Content(`// swift-tools-version:5.9
//
// ${Name} SDK - SwiftPM manifest. The runtime itself is dependency-free
// (Foundation + the vendored Voxgig Struct port under
// Sources/ProjectNameSDK/Struct); declared feature/target deps (if any)
// appear below.
import PackageDescription

let package = Package(
    name: "${Name}Sdk",
    products: [
        .library(name: "${Name}Sdk", targets: ["${Name}Sdk"]),
    ],${pkgdeps}
    targets: [
        .target(
            name: "${Name}Sdk",${targetdeps}
            path: "Sources/${swiftTargetDir(model)}"),
        .testTarget(
            name: "${Name}SdkTests",
            dependencies: ["${Name}Sdk"],
            path: "Tests/${swiftTestDir(model)}"),
    ]
)
`)
  })
})


export {
  Package,
}
