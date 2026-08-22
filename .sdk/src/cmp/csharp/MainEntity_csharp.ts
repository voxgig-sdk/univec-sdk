
import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  // Collision-free entity CLASS name (see entityClassName).
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  // C# keeps the PascalCase accessor: public members are PascalCase, so a
  // lowercase facade would not be idiomatic.
  // Idiomatic usage: client.${entity.Name}().List(null) / .Load(...).
  Content(`
    // ${entity.Name} returns a ${entity.Name} entity bound to this client.
    // Idiomatic usage: client.${entity.Name}().List(null) or
    // client.${entity.Name}().Load(new() { ["id"] = ... }).
    public ${model.const.Name}EntityBase ${entity.Name}(Dictionary<string, object?>? entopts = null)
    {
        return new global::${model.const.Name}Sdk.Entity.${cls}(this, entopts);
    }
`)

})


export {
  MainEntity
}
