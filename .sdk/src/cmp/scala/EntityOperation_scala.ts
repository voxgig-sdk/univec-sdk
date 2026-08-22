
import {
  cmp, camelify,
  Content, Fragment
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep, scalapackage, cls } = props

  let { indent } = props

  if (null != indent) {
    indent = indent.substring(1)
    if ('' == indent) {
      indent = undefined
    }
  }

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.scala',
    eject: ['// EJECT-START', '// EJECT-END'],
    indent,
    replace: {
      ...entrep,
      SCALAPACKAGE: scalapackage,
      ProjectName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,

      EntyClass: cls,

      '#Feature-Hook': ({ name, indent }: any) =>
        Content({ indent }, `
utility.featureHook(ctx, "${name}")
`)

    }
  })
})


export {
  EntityOperation
}
