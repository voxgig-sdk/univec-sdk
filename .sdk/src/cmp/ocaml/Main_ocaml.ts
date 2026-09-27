
import {
  cmp, each,
  File, Content, Copy, Folder,
  entityClassName,
  pluginExcludes,
  targetFeatures,
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_ocaml'
import { Config, secretsBuild } from './Config_ocaml'
import { Schema } from './Schema_ocaml'
import { Gitignore } from './Gitignore_ocaml'
import { MainEntity } from './MainEntity_ocaml'
import { SdkError } from './SdkError_ocaml'
import { PrepareAuth } from './PrepareAuth_ocaml'
import { entityModule, ocamlString } from './utility_ocaml'


const CONTAINED = ['secrets']


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: Record<string, ModelEntity> = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never names a feature
  // it has no source for. One rule, one place: helpers/applicability.
  const feature = targetFeatures(model, target)

  const containerExcludes = CONTAINED
    .filter((name: string) => null == (feature as any)[name])
    .flatMap((name: string) => [
      new RegExp('(^|/)feature/' + name + '_feature\\.ml$'),
      new RegExp('(^|/)feature/' + name + '/'),
      new RegExp('(^|/)test/feature/' + name + '/'),
    ])

  Package({ target })

  Gitignore({})

  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, /\.(cmi|cmo|cmx|cma|cmxa|o|a)$/, /a\.out$/,
      /run_sdk_test$/, /run_omni_smoke$/, /run_struct_corpus$/, /run_primary_corpus$/,
      ...containerExcludes, ...pluginExcludes(model)],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  const build = secretsBuild(model, target)
  if (null != build) {
    Folder({ name: 'feature' }, () => {
      Folder({ name: 'secrets' }, () => {
        File({ name: 'feature.mk' }, () => {
          Content(`# ${model.const.Name} SDK: the secrets feature build.
#
# GENERATED because the model activates \`secrets\` for this target
# (plugin groups: ${0 === build.groups.length ? 'none - the built-in kinds alone' : build.groups.join(', ')}).
# An SDK whose model does not has no such file, and its Makefile's optional
# include of it is a no-op: nothing of the feature is compiled. Do not
# hand-edit - change the model's plugin groups and regenerate.
#
# MODULE ORDER IS THE DEPENDENCY ORDER: the voxgig/plugin host, the sekreto
# core, the shared helpers the selected kinds open, the kinds, the feature.

FEATURE_INC = -I +unix -I feature -I feature/secrets/plugin \\
  -I feature/secrets/sekreto -I feature/secrets/plugins
FEATURE_LIB = unix.cma

SECRETS_PLUGIN = ${build.plugin.join(' \\\n  ')}

SECRETS_CORE = ${build.core.join(' \\\n  ')}

SECRETS_HELPERS =${0 === build.helpers.length ? '' : ' ' + build.helpers.join(' \\\n  ')}

SECRETS_KINDS =${0 === build.kinds.length ? '' : ' ' + build.kinds.join(' \\\n  ')}

FEATURE_SRC = $(SECRETS_PLUGIN) $(SECRETS_CORE) $(SECRETS_HELPERS) $(SECRETS_KINDS) \\
  feature/secrets_feature.ml

FEATURE_TESTS = test/feature/secrets/t_secrets.ml
`)

          const objs = [
            ...(build.tls ? ['feature/secrets/plugins/tls_stubs.o'] : []),
            ...build.stubs.map((one) => one.replace(/\.c$/, '.o')),
          ]
          const libs = [
            ...(build.tls ? ['-cclib', '-lssl'] : []),
            ...(build.tls || 0 < build.stubs.length ? ['-cclib', '-lcrypto'] : []),
          ]

          if (0 < objs.length) {
            Content(`
# THE C OBJECTS THIS CHAIN NEEDS${build.tls ? `, and the one external
# dependency behind the plugin groups that need a transport
# (${build.tlsGroups.join(', ')}): plugins/tls.ml's externals live in
# plugins/tls_stubs.c against OpenSSL` : ''}${0 < build.stubs.length ? `${build.tls ? '. ' : `,
# behind `}the mini vault's own stub (${build.stubGroups.join(', ')}), whose
# AES-256-GCM and PBKDF2 come from libcrypto` : ''}. Each stub is compiled
# here and the bytecode executables are linked \`-custom\`, and each is fed
# to the compiler from line four (past the provenance header, see above).
OCAMLLIB = $(shell $(OCAMLC) -where)
FEATURE_OBJ = ${objs.join(' ')}
FEATURE_LINK = -custom ${libs.join(' ')}
${objs.map((obj) => `
${obj}: ${obj.replace(/\.o$/, '.c')}
	@command -v $(CC) >/dev/null 2>&1 || { echo "secrets: a C compiler ($(CC)) is needed to build the C stub that this SDK's secrets plugin kinds (${build.groups.join(', ')}) run - install one, or use only the built-in provider kinds" >&2; exit 1; }
	tail -n +4 $< | $(CC) -std=c11 -O2 -Wall -Wextra -I$(OCAMLLIB) -x c - -c -o $@
`).join('')}`)
          }
          else {
            Content(`
# No active plugin group needs a transport or a C stub, so nothing is
# compiled and nothing is linked beyond the OCaml distribution.
FEATURE_OBJ =
FEATURE_LINK =
`)
          }
        })
      })
    })
  }

  Schema({ target })
  Config({ target })
  SdkError({ target })

  // sdk_prepare_auth.ml is GENERATED, not templated: WHERE the credential
  // goes (header / query / cookie, and under what name) is a fact about the
  // existing caller (the utility record, make_spec, the secrets feature's
  // re-run, the shipped suites) resolves unchanged. See PrepareAuth_ocaml.
  PrepareAuth({ target })

  // per-entity accessors (twin of the go root package + rust core/sdk.rs).
  File({ name: 'sdk_client.' + target.ext }, () => {

    Content(`(* ${model.const.Name} SDK client (generated by @voxgig/sdkgen).
 *
 * The SDK "object" is the runtime sdk_client record (see Sdk_types). These
 * constructors wire the embedded config + feature factory (Sdk_config) into
 * the API-agnostic client builders (Sdk_features.make_client_base / sdk_test).
 * Entity accessors return an entity_obj whose CRUD closures run the pipeline. *)

open Voxgig_struct
open Sdk_types
open Sdk_features

(* Construct a live client from options (Noval for defaults). *)
let make (options : value) : sdk_client =
  make_client_base
    ~config:(Sdk_config.make_config ())
    ~make_feature:Sdk_config.make_feature
    options

(* No-argument convenience constructor. *)
let make0 () : sdk_client = make Noval

(* Construct a client in test mode (in-memory mock transport). *)
let test () : sdk_client =
  sdk_test
    ~config:(Sdk_config.make_config ())
    ~make_feature:Sdk_config.make_feature
    Noval Noval

(* Test-mode client with explicit test / sdk options. *)
let test_with (testopts : value) (sdkopts : value) : sdk_client =
  sdk_test
    ~config:(Sdk_config.make_config ())
    ~make_feature:Sdk_config.make_feature
    testopts sdkopts

(* Low-level escape hatches (raw transport call / request preparation). *)
let direct (client : sdk_client) (fetchargs : value) : value =
  Sdk_features.direct client fetchargs

let graphql (client : sdk_client) (query : string) (variables : value)
    (ctrl : value) : value =
  Sdk_features.graphql client query variables ctrl

let prepare (client : sdk_client) (fetchargs : value) : value =
  Sdk_features.prepare client fetchargs
`)

    each(entity, (entity: ModelEntity) => {
      MainEntity({ target, entity })
    })

    // Entity by NAME. DELIBERATE DIVERGENCE: OCaml has no dynamic dispatch
    // over module names, so a caller that discovers entities from the config
    // rather than naming a generated accessor - the shipped feature suites
    // are templates and know no project's entity names - has no way to reach
    // one without this. The go peer is the untyped interface go-cli/go-mcp
    const names = each(entity).map((e: ModelEntity) => e.name).sort()
    if (0 === names.length) {
      Content(`
(* Entity by name: this SDK generated no entities. *)
let entity (_client : sdk_client) (_name : string) (_entopts : value) : entity_obj option =
  None
`)
    }
    else {
      Content(`
(* Entity by name (None for a name this SDK did not generate). *)
let entity (client : sdk_client) (name : string) (entopts : value) : entity_obj option =
  match name with
${names.map((name: string) => {
        const mod = entityModule(name)
        const Mod = mod.charAt(0).toUpperCase() + mod.slice(1)
        return `  | "${ocamlString(name)}" -> Some (${Mod}.make client entopts)\n`
      }).join('')}  | _ -> None
`)
    }
  })

})


export {
  Main
}
