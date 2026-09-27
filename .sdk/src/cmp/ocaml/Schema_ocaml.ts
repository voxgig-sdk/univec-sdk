import {
  Content,
  File,
  cmp,
  entitySpecMap,
  optionSpec,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


import {
  ocamlString,
} from './utility_ocaml'


const Schema = cmp(async function Schema(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const optspec = optionSpec(model, target.name)
  const entityspec = entitySpecMap(model, target.name) || {}

  File({ name: 'sdk_schema.' + target.ext }, () => {

    Content(`(* ${model.const.Name} SDK: generated schemas. Do not edit.
 *
 * Built from the model: main.kit.optspec and each feature's config.options
 * for the option spec; entity fields{}.type for the entity specs.
 *
 * opt_spec_value () - the option spec make_options validates client options
 * against. entity_spec_value () - per-entity data and request specs, keyed by
 * entity name. Both parse once and memoise: the spec is read on every client
 * construction and never mutated, so a per-call parse would be pure waste.
 *
 * The returned values are SHARED: treat them as read-only. make_options
 * validates AGAINST the spec and writes into the options, never into it. *)

open Voxgig_struct

let optspec_data = "${ocamlString(JSON.stringify(optspec))}"

let entityspec_data = "${ocamlString(JSON.stringify(entityspec))}"

let optspec_memo : value option ref = ref None

let entityspec_memo : value option ref = ref None

let opt_spec_value () : value =
  match !optspec_memo with
  | Some v -> v
  | None ->
    let v = Sdk_json.json_read optspec_data in
    optspec_memo := Some v;
    v

let entity_spec_value () : value =
  match !entityspec_memo with
  | Some v -> v
  | None ->
    let v = Sdk_json.json_read entityspec_data in
    entityspec_memo := Some v;
    v
`)
  })
})


export {
  Schema
}
