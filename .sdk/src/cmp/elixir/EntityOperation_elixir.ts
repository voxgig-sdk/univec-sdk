
import {
  cmp, camelify,
  Fragment,
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep } = props

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.ex',
    eject: ['# EJECT-START', '# EJECT-END'],
    replace: {
      ...entrep,
      ProjectName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,
    }
  })
})


export {
  EntityOperation
}
