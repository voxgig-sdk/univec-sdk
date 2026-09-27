
import {
  Content,
  File,
  cmp,
  configDefinition,
  configReprSetting,
  each,
  isAuthActive,
  isConfigData,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
  targetFeatures,
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


type SecretsBuild = {
  groups: string[],
  tlsGroups: string[],
  tls: boolean,
  stubs: string[],
  stubGroups: string[],
  plugin: string[],
  core: string[],
  helpers: string[],
  kinds: string[],
  syms: string[],
}

const SECRETS_PLUGIN_MODULES = [
  'value', 'types', 'ref', 'version', 'capability', 'resolve', 'env',
  'config', 'graph', 'order', 'export', 'depend', 'point', 'defs',
  'catalog', 'host',
].map((m) => 'feature/secrets/plugin/' + m + '.ml')

const SECRETS_CORE_MODULES = ['json', 'secret', 'provider', 'sekreto']
  .map((m) => 'feature/secrets/sekreto/' + m + '.ml')

const SECRETS_TLS_HELPERS = ['crypto', 'sigv4', 'tls', 'http', 'httpjson']
  .map((m) => 'feature/secrets/plugins/' + m + '.ml')

const SECRETS_PROC_HELPERS = ['feature/secrets/plugins/runcmd.ml']

function secretsBuild(model: Model, target: any): SecretsBuild | null {
  const feature = targetFeatures(model, target)
  if (null == (feature as any).secrets) return null

  const declared = getModelPath(model,
    `main.${KIT}.feature.secrets.plugin`,
    { required: false, only_active: false }) || {}

  const groups: string[] = []
  const tlsGroups: string[] = []
  const stubGroups: string[] = []
  const stubs = new Set<string>()
  const syms = new Set<string>()
  const kinds = new Set<string>()

  each(declared, (plugin: any) => {
    // Filter on `active` HERE rather than trusting the feature object to
    // arrive filtered (Config_go's note): getting this wrong names a
    // constructor for a module the trim just deleted.
    if (true !== plugin.active) return
    const defs: Record<string, string> = plugin.def?.[target.name] || {}
    if (0 === Object.keys(defs).length) return
    groups.push(plugin.name)
    if (true === plugin.needs?.fetch) tlsGroups.push(plugin.name)

    // `stub`, keyed by TARGET - not a filter over `path`, which is one flat
    // list across every target: ocaml's minivault_stubs.c sits beside c's
    // boru.c and hashicorp.c, and a prefix filter handed this build both of
    // them. Declared per target, so what ocaml compiles is what the model
    // says ocaml compiles.
    const own = (plugin.stub?.[target.name] || []).map((one: any) => String(one))
    if (0 < own.length) {
      stubGroups.push(plugin.name)
      for (const one of own) stubs.add(one)
    }
    for (const [sym, path] of Object.entries(defs)) {
      syms.add(sym)
      kinds.add(String(path))
    }
  })

  const tls = 0 < tlsGroups.length
  return {
    groups: groups.sort(),
    tlsGroups: tlsGroups.sort(),
    tls,
    stubs: Array.from(stubs).sort(),
    stubGroups: stubGroups.sort(),
    plugin: SECRETS_PLUGIN_MODULES,
    core: SECRETS_CORE_MODULES,
    helpers: [
      ...(tls ? SECRETS_TLS_HELPERS : []),
      ...(0 < kinds.size ? SECRETS_PROC_HELPERS : []),
    ],
    kinds: Array.from(kinds).sort(),
    syms: Array.from(syms).sort(),
  }
}


// sdk_config.ml: make_config () builds the embedded API model as a value;
// make_feature name is the N-feature-safe factory the client uses to
// instantiate features named in the options (mirrors go/rust Config).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const secrets = secretsBuild(model, target)

  const { def: config } = configDefinition(model, target.name)

  const authIn = resolveAuthIn(model)
  const authName = resolveAuthName(model)
  const authOpts = (config as any).options?.auth
  if (null != authOpts) {
    if ('header' !== authIn) {
      authOpts.in = authIn
    }
    if ('Authorization' !== authName) {
      authOpts.name = authName
    }
  }

  const configJson = JSON.stringify(config)
  const asData = isConfigData(configJson, configReprSetting(model))

  File({ name: 'sdk_config.' + target.ext }, () => {

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
`)
    }

    if (null == secrets) {
      Content(`
(* The plugin definitions the model selected, per feature: none - no
 * plugin-bearing feature is active in this SDK. *)
let feature_plugins (_name : string) = []
`)
    }
    else {
      Content(`
(* The plugin definitions the model selected for the secrets feature's
 * provider chain${0 === secrets.groups.length ? ': none - the chain can name the four built-in kinds (env, memory, dotenv, file) and a custom provider, and nothing else' : ' (plugin groups: ' + secrets.groups.join(', ') + ')'}.
 * Built, not held: every call is a fresh list, so two chains never share
 * a definition. *)
let feature_plugins (name : string) : Defs.definition list =
  match name with
  | "secrets" -> [${0 === secrets.syms.length ? '' : '\n' + secrets.syms.map((sym: string) => '      ' + sym + ' ();\n').join('') + '    '}]
  | _ -> []
`)

      if (secrets.tls) {
        Content(`
(* The token-exchange transport of last resort: the vendored sekreto HTTP
 * client (plugins/http.ml over plugins/tls.ml), compiled because a plugin
 * group needing a transport is active (${secrets.tlsGroups.join(', ')}).
 * A network failure raises sekreto's own Sekreto_error, which the feature
 * reports as the refusal. *)
let secrets_transport (url : string) (fetchdef : value) : value =
  let meth = match getp fetchdef "method" with Str s -> s | _ -> "POST" in
  let headers = match getp fetchdef "headers" with
    | Map _ as h ->
      List.filter_map (fun k -> match getp h k with Str v -> Some (k, v) | _ -> None) (keysof h)
    | _ -> [] in
  let body = match getp fetchdef "body" with Str s -> Some s | _ -> None in
  let res = Http.request meth url headers body in
  let text = res.Http.body in
  jo [("status", Num (float_of_int res.Http.status));
      ("statusText", Str (if res.Http.status >= 400 then "ERR" else "OK"));
      ("headers", empty_map ());
      ("body", Str text);
      ("json", json_thunk (try Sdk_json.json_read text with _ -> Noval))]
`)
      }
    }
    // The factory, AFTER the definitions it names: OCaml binds top to bottom.
    Content(`
let make_feature (name : string) : feature =
  match name with
`)

    const OCAML_FEATURES = [
      'audit', 'cache', 'clienttrack', 'cost', 'debug', 'idempotency', 'log',
      'metrics', 'netsim', 'paging', 'proxy', 'ratelimit', 'rbac',
      'retry', 'streaming', 'telemetry', 'test', 'timeout', 'validate',
    ]

    each(feature, (f: any) => {
      if (f.name !== 'base' && OCAML_FEATURES.includes(f.name)) {
        Content(`  | "${ocamlString(f.name)}" -> ${f.name}_feature ()
`)
      }
    })

    if (null != secrets) {
      Content(`  | "secrets" -> Secrets_feature.make ~plugins:(feature_plugins "secrets")${secrets.tls ? ' ~transport:secrets_transport' : ''} ()
`)
    }

    Content(`  | _ -> base_feature ()
`)

  })
})


export {
  Config,
  secretsBuild,
}
