import {
  Content,
  File,
  Folder,
  cmp,
  entitySpecMap,
  optionSpec,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


import {
  elixirString,
} from './utility_elixir'


const Schema = cmp(async function Schema(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model
  const Name = model.const.Name

  const optspec = optionSpec(model, target.name)
  const entityspec = entitySpecMap(model, target.name) || {}

  Folder({ name: 'lib' }, () => {

  File({ name: 'schema.ex' }, () => {
    Content(`# ${Name} ${target.Name} SDK: generated schemas. Do not edit.
#
# Generated from the model: \`main.kit.optspec\` and each feature's
# \`config.options\` for OPTSPEC; entity \`fields{}.type\` for ENTITYSPEC.

defmodule ${Name}.Schema do
  @optspec_data ${elixirString(JSON.stringify(optspec))}

  @entityspec_data ${elixirString(JSON.stringify(entityspec))}

  # Parsed once per VM and held in :persistent_term. The parse yields struct
  # nodes, which are handles into this VM's heap, so a compile-time literal
  # would point into the heap of whichever VM compiled the module.
  def optspec, do: memo(:optspec, @optspec_data)

  def entityspec, do: memo(:entityspec, @entityspec_data)

  defp memo(name, data) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        spec = ${Name}.Json.parse(data)
        :persistent_term.put(key, spec)
        spec

      spec ->
        spec
    end
  end
end
`)
  })

  })
})


export {
  Schema
}
