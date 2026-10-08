
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


const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const name = zigModuleName(model)

  // A fetched package keeps only `.paths`: the module source, the license
  // and the docs the README links.
  File({ name: 'build.zig.zon' }, () => {
    Content(`.{
    .name = .${name},
    .version = "${packageVersion(model, target.name)}",
    .fingerprint = ${zigPackageFingerprint(name)},
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "root.zig",
        "core",
        "entity",
        "feature",
        "utility",
        "test",
        "LICENSE",
        "README.md",
        "REFERENCE.md",
    },
}
`)
  })
})


export {
  Package
}
