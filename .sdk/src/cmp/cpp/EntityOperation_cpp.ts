
import {
  cmp, camelify,
  Fragment
} from '@voxgig/sdkgen'


// Splices one CRUD op method into the entity class (between EJECT markers).
// The C++ runtime keeps the pipeline+hooks in EntityBase::runOp, so op
// fragments carry no hook markers.
const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep, cls } = props

  let { indent } = props
  if ('' === indent) {
    indent = undefined
  }

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.cpp',
    eject: ['// EJECT-START', '// EJECT-END'],
    indent,
    replace: {
      ...entrep,
      ProjectName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,
      EntyClass: cls,
    }
  })
})


export {
  EntityOperation
}
