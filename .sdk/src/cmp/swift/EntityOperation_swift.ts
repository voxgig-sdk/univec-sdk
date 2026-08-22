
import {
  cmp, camelify,
  Content, Fragment
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep, cls } = props

  // The op markers sit inside the class body; the captured indent (2-space
  // class-member indent) is applied to the whole spliced EJECT region, which
  // is written at column 0.
  const { indent } = props

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.swift',
    eject: ['// EJECT-START', '// EJECT-END'],
    indent,
    replace: {
      ...entrep,
      ProjectName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,

      EntyClass: cls,

      '#Feature-Hook': ({ name, indent }: any) =>
        Content({ indent }, `utility.featureHook(ctx, "${name}")
`)
    }
  })
})


export {
  EntityOperation
}
