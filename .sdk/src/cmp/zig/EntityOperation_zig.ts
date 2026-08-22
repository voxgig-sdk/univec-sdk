
import {
  cmp, camelify,
  Content, Fragment
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep, cls } = props

  let { indent } = props
  if ('' === indent) {
    indent = undefined
  }

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.zig',
    eject: ['// EJECT-START', '// EJECT-END'],
    indent,
    replace: {
      ...entrep,
      ProjectName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,
      EntyClass: cls,

      '#Feature-Hook': ({ name, indent }: any) =>
        Content({ indent }, `
self.utility.feature_hook(ctx, "${name}");
`)
    }
  })
})


export {
  EntityOperation
}
