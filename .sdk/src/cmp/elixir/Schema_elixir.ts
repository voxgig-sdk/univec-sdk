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

  # Parsed at COMPILE time and held as a literal: the spec is read on every
  # client construction and never mutated, so parsing per call would be pure
  # waste, and elixir terms are immutable so sharing carries no risk at all.
  @optspec ${Name}.Json.parse(@optspec_data)

  @entityspec ${Name}.Json.parse(@entityspec_data)

  def optspec, do: @optspec

  def entityspec, do: @entityspec
end
`)
  })

  })
})


export {
  Schema
}
