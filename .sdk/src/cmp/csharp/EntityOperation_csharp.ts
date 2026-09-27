
import {
  cmp, camelify,
  Content, Fragment
} from '@voxgig/sdkgen'


const EntityOperation = cmp(function Operation(props: any) {
  const { model } = props.ctx$
  const { ff, opname, entity, entrep, cls } = props

  const { indent } = props

  Fragment({
    from: ff + '/Entity' + camelify(opname) + 'Op.fragment.cs',
    eject: ['// EJECT-START', '// EJECT-END'],
    indent,
    replace: {
      ...entrep,
      ProjectNameSdk: model.const.Name + 'Sdk',
      ProjectName: model.const.Name,
      EntityName: entity.Name,
      entityname: entity.name,

      EntyClass: cls,

      '#Feature-Hook': ({ name, indent }: any) =>
        Content({ indent }, `utility.FeatureHook(ctx, "${name}");
`)

    }
  })
})


export {
  EntityOperation
}
