

import { cmp, Content } from '@voxgig/sdkgen'


// Emit an entity factory function into the main SDK module (at its slot):
//   def widget(client, entopts \\ nil), do: Solardemo.Entity.Widget.new(client, entopts)
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const Name = model.const.Name

  Content(`
  @doc "Entity factory for ${entity.name}."
  def ${entity.name}(client, entopts \\\\ nil) do
    ${Name}.Entity.${entity.Name}.new(client, entopts)
  end
`)

})


export {
  MainEntity
}
