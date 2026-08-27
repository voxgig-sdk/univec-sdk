
import {
  Content,
  File,
  cmp,
  configDefinition,
  configReprSetting,
  each,
  isAuthActive,
  isConfigData,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  formatOcamlValue,
  ocamlString,
} from './utility_ocaml'


// sdk_config.ml: make_config () builds the embedded API model as a value;
// make_feature name is the N-feature-safe factory the client uses to
// instantiate features named in the options (mirrors go/rust Config).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const feature = getModelPath(model, `main.${KIT}.feature`)

  // The canonical config OBJECT and its JSON, from the shared helper. Both
  // representations render from the same `def`, so they cannot describe
  // different configs - and this target picks up `options.server` (the OpenAPI
  // server-variable defaults), which the hand-rolled build here omitted.
  // Passing target.name opts this target into the main slug/version/target
  // identity fields (read by station's descriptor - see configDefinition).
  const { def: config, json: configJson } = configDefinition(model, target.name)
  const asData = isConfigData(configJson, configReprSetting(model))

  File({ name: 'sdk_config.' + target.ext }, () => {

    // ABOVE THE THRESHOLD: emit the model as DATA.
    //
    // The literal is one nested expression the compiler type-checks as a
    // single item; a string is one token, and `Sdk_json.json_read` builds the
    // same value tree at runtime. That reader used to live only in the corpus
    // test harness - this rung is why it now lives in the runtime, and the
    // harness uses it from there rather than keeping a second copy.
    //
    // No number-type question: `json_read` yields `Num (float)` and
    // `formatOcamlValue` emits `(Num (5.))`, so both branches agree.
    if (asData) {
      Content(`(* Generated API configuration (mirrors go core/config.go).
 *
 * THE API MODEL, EMBEDDED AS DATA (sdkgen rung L1). Emitted only above a size
 * threshold, or when main.kit.config.repr pins it: for a small model the
 * literal is smaller and far easier to read when debugging.
 *
 * make_config () — the embedded API model as a voxgig struct value.
 * make_feature name — the N-feature-safe factory the client uses. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Sdk_features

let config_data = "${ocamlString(configJson)}"

let make_config () : value =
  Sdk_json.json_read config_data

let make_feature (name : string) : feature =
  match name with
`)
    }
    else {

    Content(`(* Generated API configuration (mirrors go core/config.go).
 *
 * make_config () — the embedded API model as a voxgig struct value.
 * make_feature name — the N-feature-safe factory the client uses. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Sdk_features

let make_config () : value =
  ${formatOcamlValue(config, 1)}

let make_feature (name : string) : feature =
  match name with
`)
    }

    // ONLY THE FEATURES THIS PORT ACTUALLY IMPLEMENTS. Emitting an arm for a
    // name with no `<name>_feature` in tm/ocaml/sdk_features.ml is an
    // "Unbound value" at COMPILE time — the whole SDK fails to build, not
    // just the feature. That is how the missing `cost` was found, when an SDK
    // first activated every feature; cost is implemented now, and this list
    // is the guard against the next one.
    const OCAML_FEATURES = [
      'audit', 'cache', 'clienttrack', 'cost', 'debug', 'idempotency', 'log',
      'metrics', 'netsim', 'paging', 'proxy', 'ratelimit', 'rbac',
      'retry', 'streaming', 'telemetry', 'test', 'timeout',
    ]

    each(feature, (f: any) => {
      if (f.name !== 'base' && OCAML_FEATURES.includes(f.name)) {
        Content(`  | "${ocamlString(f.name)}" -> ${f.name}_feature ()
`)
      }
    })

    Content(`  | _ -> base_feature ()
`)
  })
})


export {
  Config
}
