
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
