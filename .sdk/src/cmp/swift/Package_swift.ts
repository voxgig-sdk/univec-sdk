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
//
// The `Omni` target is the VENDORED corpus test engine (Tests/vendor/omni,
// @voxgig/omni at the shared tag). It has to be its own MODULE, not files
// folded into the test target: the port calls `Omni.errify` by module name,
// and its top-level `clone`/`getpath`/`walk`/`stringify`/`pathify` collide
// head-on with the struct utility's functions of the same names. It is
// declared as a .testTarget rather than a .target so `swift build` - a
// consumer's library build - never compiles the test engine; `swift test`
// builds it and the suite target depends on it.
//
// THE SECRETS FEATURE ADDS THREE MORE MODULES, and this is the same
// precedent, load-bearing rather than tidy. The vendored @voxgig/plugin
// host, the @voxgig/sekreto core and its plugins live under
// Sources/<Name>Sdk/feature/secrets/{plugin,sekreto,plugins} and are
// compiled as VoxgigPlugin, Sekreto and SekretoPlugins - upstream's own
// three-module boundary (sekreto's swift Makefile builds exactly these). A
// flat layout collides on five names: plugin's `Value` and `Point` against
// the SDK's, sekreto's `Json` against plugin's, and `dropsuffix`/`getenv`,
// which sekreto declares in BOTH src/ and plugins/ because upstream never
// compiles them as one module. So, when the feature is active for this
// target:
//
//   - three `.target`s are declared over the three directories;
//   - the SDK target gains them as dependencies and `exclude: ["feature/
//     secrets"]`, so SwiftPM does not ALSO fold the files into the SDK
//     module (`exclude:` must come AFTER `path:` in the argument list, or
//     the manifest itself fails to compile);
//   - the library product vends all four, because `SecretsFeature.sekreto()`
//     is public API returning a `Sekreto`, and a downstream package may only
//     `import Sekreto` if the product exposes it;
//   - the test target depends on Sekreto and VoxgigPlugin as well, since
//     the gated suite builds providers against Sekreto's `Provider`
//     protocol and reads the selected `Definition`s' kinds back.
//
// Keyed on swiftSecretsActive - the SAME predicate Main_swift's Copy uses
// to ship or withhold the trees - so the manifest and the tree agree by
// construction (a manifest naming a missing path fails the whole package).
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

  // The SDK target's dependency list: declared package products, then the
  // three vendored secrets modules when the feature is active.
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
