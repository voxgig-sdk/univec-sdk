
import {
  Content,
  File,
  cmp,
  packageVersion,
} from '@voxgig/sdkgen'


import type {
  Model,
} from '@voxgig/apidef'


import { zigModuleName } from './utility_zig'


// build.zig.zon — the Zig package manifest. Zig has no central package
// registry, so there are no external registry dependencies to declare: the
// voxgig struct port is vendored in-tree (utility/voxgigstruct) and wired as a
// local module by build.zig. This generator only stamps the manifest with the
// model-derived package name (the go/rust Package generators emit go.mod /
// Cargo.toml the same way).
//
// The `.paths` allow-list mirrors the (registry-less) template: it only
// matters when packaging for a registry, which zig does not do, so it is kept
// stable. `.name` is a plain string here rather than the newer enum-literal +
// fingerprint form.
//
// TOOLCHAIN PIN: the string form REQUIRES zig <= 0.13. Zig 0.14 rejects it
// outright — `build.zig.zon:2:13: error: expected enum literal` — so the
// generated SDK will not build at all on a newer toolchain. The consumer CI
// job pins 0.13.0 to match (create-sdkgen
// project/standard/.github/workflows/ci.yml). Moving to a newer zig means
// changing BOTH: `.name = .${name}` plus a `.fingerprint` here, and the CI
// pin there.
const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const name = zigModuleName(model)

  File({ name: 'build.zig.zon' }, () => {
    Content(`.{
    .name = "${name}",
    .version = "${packageVersion(model, target.name)}",
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
