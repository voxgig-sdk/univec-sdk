
import {
  cmp, camelify,
  Content, Fragment
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep, javapackage, cls } = props

  let { indent } = props

  if (null != indent) {
    indent = indent.substring(1)
    if ('' == indent) {
      indent = undefined
    }
  }

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.java',
    eject: ['// EJECT-START', '// EJECT-END'],
    indent,
    replace: {
      ...entrep,
      JAVAPACKAGE: javapackage,
      ProjectName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,

      // Class tokens are decoupled from the EntityName data-type token so
      // the class can be renamed independently (collision handling).
      EntyClass: cls,

      '#Feature-Hook': ({ name, indent }: any) =>
        Content({ indent }, `
utility.featureHook.apply(ctx, "${name}");
`)

    }
  })
})


export {
  EntityOperation
}
