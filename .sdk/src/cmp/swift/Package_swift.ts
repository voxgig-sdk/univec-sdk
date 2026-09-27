import { swiftSecretsActive, swiftTargetDir, swiftTestDir } from './utility_swift'

import {
  Content,
  File,
  cmp,
  collectDeps,
} from '@voxgig/sdkgen'


import type {
  Model,
} from '@voxgig/apidef'


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

  const secrets = swiftSecretsActive(model, target)
  const srcdir = `Sources/${swiftTargetDir(model)}`

  const sdkdeps: string[] = deps.map((d) =>
    `.product(name: "${d.product}", package: "${d.identity}")`)
  if (secrets) {
    sdkdeps.push('"Sekreto"', '"SekretoPlugins"', '"VoxgigPlugin"')
  }

  const targetdeps = 0 === sdkdeps.length ? '' :
    '\n            dependencies: [\n' +
    sdkdeps.map((d) => `                ${d},\n`).join('') +
    '            ],'

  // `exclude:` AFTER `path:` - SwiftPM's argument order, not a style choice.
  const sdkpath = secrets
    ? `\n            path: "${srcdir}",\n            exclude: ["feature/secrets"]),`
    : `\n            path: "${srcdir}"),`

  const secretsTargets = !secrets ? '' :
    `        .target(
            name: "VoxgigPlugin",
            path: "${srcdir}/feature/secrets/plugin"),
        .target(
            name: "Sekreto",
            dependencies: ["VoxgigPlugin"],
            path: "${srcdir}/feature/secrets/sekreto"),
        .target(
            name: "SekretoPlugins",
            dependencies: ["Sekreto", "VoxgigPlugin"],
            path: "${srcdir}/feature/secrets/plugins"),
`

  const products = secrets
    ? `["${Name}Sdk", "Sekreto", "SekretoPlugins", "VoxgigPlugin"]`
    : `["${Name}Sdk"]`

  const testdeps = secrets
    ? `["${Name}Sdk", "Omni", "Sekreto", "VoxgigPlugin"]`
    : `["${Name}Sdk", "Omni"]`

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
    // The deployment floor. Without it SwiftPM assumes the oldest macOS the
    // toolchain still targets, and the SDK's AsyncStream-based streaming
    // (EntityBase) fails to compile on macOS with "'AsyncStream' is only
    // available in macOS 10.15 or newer" - linux has no such floor, which
    // is why the generator's own linux runs never saw it. Found by the
    // secrets lane, the first lane to build a full generated swift SDK on
    // the macos CI leg.
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "${Name}Sdk", targets: ${products}),
    ],${pkgdeps}
    targets: [
${secretsTargets}        .target(
            name: "${Name}Sdk",${targetdeps}${sdkpath}
        .testTarget(
            name: "Omni",
            path: "Tests/vendor/omni"),
        .testTarget(
            name: "${Name}SdkTests",
            dependencies: ${testdeps},
            path: "Tests/${swiftTestDir(model)}"),
    ]
)
`)
  })
})


export {
  Package,
}
