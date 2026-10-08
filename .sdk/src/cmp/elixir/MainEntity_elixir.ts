

import { cmp, Content, elixirAccessor, entityCollection } from '@voxgig/sdkgen'


// Emit an entity factory function into the main SDK module (at its slot):
//   def widget(client, entopts \\ nil), do: Solardemo.Entity.Widget.new(client, entopts)
// A reserved word (`end`) is not a function name: see elixirAccessor.
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const Name = model.const.Name
  const accessor = elixirAccessor(entity, entityCollection(model))

  Content(`
  @doc "Entity factory for ${entity.name}."
  def ${accessor}(client, entopts \\\\ nil) do
    ${Name}.Entity.${entity.Name}.new(client, entopts)
  end
`)

})


export {
  MainEntity
}
