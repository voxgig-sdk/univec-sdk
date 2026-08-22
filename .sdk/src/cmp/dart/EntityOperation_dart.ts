
import {
  cmp, camelify,
  Content, Fragment
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep } = props

  let { indent } = props

  indent = indent.substring(2)
  if ('' == indent) {
    indent = undefined
  }

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.dart',
    eject: ['// EJECT-START', '// EJECT-END'],
    indent,
    replace: {
      ...entrep,
      SdkName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,
      '#Feature-Hook': ({ name, indent }: any) =>
        Content({ indent }, `
fres = featureHook(ctx, '${name}');
if (fres is Future) {
  await fres;
}
`)

    }
  })
})


export {
  EntityOperation
}
