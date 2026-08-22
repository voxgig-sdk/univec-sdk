
import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { zigVarName } from './utility_zig'


// Entity accessor method on the SDK client, injected at the Main fragment
// SLOT (inside `pub const ProjectNameSDK = struct`). Idiomatic usage:
//   client.planet(sdk.Value{ .null = {} }).list(...)
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)
  const method = zigVarName(entity.name)
  const mod = zigVarName(entity.name)

  // `self: *@This()` refers to the enclosing SDK struct without needing the
  // (un-substituted) project name — SLOT content is emitted, not Copy-replaced.
  Content(`
    /// ${entity.Name} entity bound to this client.
    pub fn ${method}(self: *@This(), entopts: Value) *@import("../entity/${mod}.zig").${cls} {
        return @import("../entity/${mod}.zig").${cls}.new(self, entopts);
    }
`)

})


export {
  MainEntity
}
