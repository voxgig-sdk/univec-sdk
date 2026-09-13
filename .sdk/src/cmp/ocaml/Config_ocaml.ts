
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


// THE SECRETS BUILD MODEL, derived from the model ONCE and read by both the
// Makefile fragment (Main_ocaml emits feature/secrets/feature.mk from it)
// and the generated config (the definitions list and the bundled transport
// below), so the two cannot disagree about which kinds are compiled.
//
// Upstream sekreto retired its self-registration registry for voxgig/plugin
// definitions: a provider kind the caller did not pass in `~plugins` is
// unknown to that Sekreto. So the model's choice of plugin groups IS the
// SDK's provider vocabulary, and the generated code names each active
// group's constructor (`def: ocaml:` in model/feature/secrets.aon -
// `Hashicorp.plugin`, the `unit -> Defs.definition` each vendored kind
// module defines) and nothing else. A symbol named here whose module the
// plugin trim removed is an "Unbound module" at compile time - a loud
// failure, which is the right kind.
//
// MODULE ORDER IS THE DEPENDENCY ORDER, written down (upstream's own
// Makefile is the source): the voxgig/plugin host, the sekreto core, the
// shared helpers, the kinds. The helpers are ungrouped in the model (see the
// ocaml note at the head of its `plugin` block) and are listed here only
// when a selected kind needs them - the transport chain (crypto, sigv4, tls,
// http, httpjson) when an active group declares `needs.fetch`, the
// child-process helper (runcmd) when any kind is on - because OCaml
// compiles exactly what it is handed: an [env, memory] chain compiles the
// two cores alone, and `secretspec` alone compiles runcmd.ml and no TLS.
//
// Null when the model does not activate `secrets` for this target. Read
// with `only_active: false` on the plugin map (pluginExcludesFor's
// subtlety: the feature object a component is handed has already been
// filtered, so a feature whose groups are all off would look like one
// with no plugin machinery).
type SecretsBuild = {
  groups: string[],
  tlsGroups: string[],
  tls: boolean,
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

    // THE PLUGIN DEFINITIONS the model selected, per feature (the ocaml
    // peer of Config_go's featurePlugins map). EMITTED UNCONDITIONALLY, so
    // every generated config answers the same question - but typed as
    // `Defs.definition list` only when the secrets feature is active: the
    // `Defs` module is part of the vendored voxgig/plugin tree, which is
    // compiled only then, so an inactive model gets the polymorphic empty
    // list instead (`'a list`, which unifies with anything a caller
    // expects). DELIBERATE DIVERGENCE from the c/lua accessors, whose
    // untyped return (void**, a table) needs no such split.
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

      // THE EXCHANGE TRANSPORT OF LAST RESORT (go's rawExchangeFetch): the
      // vendored sekreto HTTP client, which the active plugin groups
      // compile and link anyway (feature/secrets/feature.mk adds the OpenSSL binding on
      // exactly this condition). It exists so an exchange works with
      // ordinary SDK options - requiring a custom transport for the COMMON
      // case would refuse every live token purchase before a request was
      // made. Same result shape the system.fetch seam promises ({status,
      // statusText, headers, body, json()}). With no such group the feature
      // is built without it and a purchase with no options.system.fetch
      // fails with a named error (see secrets_feature.ml).
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

    // The secrets feature is the one ocaml feature that lives OUTSIDE
    // sdk_features.ml (a container: feature/secrets_feature.ml plus the
    // vendored trees), so its arm names its own module and hands it the
    // definitions the model selected and, when a plugin group needing a
    // transport is active, the bundled exchange transport. Emitted only
    // when the feature is active: the module is not compiled otherwise
    // (Main_ocaml's container gate, and the Makefile's feature/secrets/feature.mk).
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
