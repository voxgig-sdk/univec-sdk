
import {
  cmp, camelify,
  Fragment,
  elixirTypeName, entityCollection,
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep } = props

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.ex',
    eject: ['# EJECT-START', '# EJECT-END'],
    replace: {
      ...entrep,
      // Longer keys match first, so the bare type keeps its safe name while
      // the op types beside it take the plain one.
      'ProjectName.Types.entityname/0': model.const.Name + '.Types.' +
        elixirTypeName(entity, entityCollection(model)) + '/0',
      ProjectName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,
    }
  })
})


export {
  EntityOperation
}
