
import {
  cmp, camelify,
  Fragment
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep } = props

  // The op slots sit at top level (Clojure defns), so no indentation is
  // applied — the marker is a literal key with no captured indent group.
  let { indent } = props
  if ('' === indent) {
    indent = undefined
  }

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.clj',
    eject: ['; EJECT-START', '; EJECT-END'],
    indent,
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
