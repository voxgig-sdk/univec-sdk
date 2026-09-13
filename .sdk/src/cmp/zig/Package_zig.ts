
import {
  Content,
  File,
  cmp,
  packageVersion,
} from '@voxgig/sdkgen'


import type {
  Model,
} from '@voxgig/apidef'


import { zigModuleName, zigPackageFingerprint } from './utility_zig'


// build.zig.zon — the Zig package manifest. Zig has no central package
// registry, so there are no external registry dependencies to declare: the
// voxgig struct port is vendored in-tree (utility/voxgigstruct) and wired as a
// local module by build.zig. This generator only stamps the manifest with the
// model-derived package name (the go/rust Package generators emit go.mod /
// Cargo.toml the same way).
//
// The `.paths` allow-list mirrors the (registry-less) template: it only
// matters when packaging for a registry, which zig does not do, so it is kept
// stable.
//
// TOOLCHAIN: zig 0.16. `.name` is an ENUM LITERAL (`.solar_sdk`), and a
// `.fingerprint` is required beside it. That pairing is what a modern zig
// wants: 0.14 rejects the older plain-string form outright —
// `build.zig.zon:2:13: error: expected enum literal` — and 0.13 rejects the
// enum-literal form, so the two cannot both be supported from one generator.
// A move BACK to 0.13 would mean reverting both fields here and the CI pin in
// create-sdkgen project/standard/.github/workflows/ci.yml together.
//
// The fingerprint is derived from the package name, not random, so
// regenerating the same model does not rewrite this file — see
// zigPackageFingerprint for why, and for what zig checks.
const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const name = zigModuleName(model)

  File({ name: 'build.zig.zon' }, () => {
    Content(`.{
    .name = .${name},
    .version = "${packageVersion(model, target.name)}",
    .fingerprint = ${zigPackageFingerprint(name)},
    .dependencies = .{},
    .paths = .{
        "src",
        "test",
        "build.zig",
        "build.zig.zon",
    },
}
`)
  })
})


export {
  Package
}
