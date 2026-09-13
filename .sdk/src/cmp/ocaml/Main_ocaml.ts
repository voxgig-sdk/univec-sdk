
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
import { Gitignore } from './Gitignore_ocaml'
import { MainEntity } from './MainEntity_ocaml'
import { SdkError } from './SdkError_ocaml'
import { entityModule, ocamlString } from './utility_ocaml'


// Features whose source is a CONTAINER under the top-level feature/ dir,
// beside the single template module (sdk_features.ml) every other ocaml
// feature lives in. Today that is `secrets`: feature/secrets_feature.ml,
// feature/secrets/ (the vendored @voxgig/sekreto port, the voxgig/plugin
// host and the provider kinds - some forty modules of key-store,
// request-signing and child-process code that an SDK which never asked for
// secrets must not ship) and its shipped suite under test/feature/secrets/.
// Anything named here is EXCLUDED from the verbatim copy unless the model
// SELECTS the feature (see the Copy below). The lua and clojure targets gate
// their containers the same way (Main_lua.ts, Main_clojure.ts).
const CONTAINED = ['secrets']


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: Record<string, ModelEntity> = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never names a feature
  // it has no source for. One rule, one place: helpers/applicability.
  const feature = targetFeatures(model, target)

  // THE feature/<name>/ CONTAINER IS GATED HERE, at generate time - the
  // top-level-container peer of the `srcFeatureExcludes` gate ts and js
  // apply to src/feature/<name>/. `target add` keeps an unselected
  // feature out of a project's tm/ in the first place (ocaml.aon has
  // `feature: { trim: true }`); this covers a feature switched off after
  // it was added, and the generator suite, which copies the whole scaffold
  // tree. An inactive feature's vendored kind files go with it - every
  // declared group's, not only the groups marked inactive, because
  // pluginExcludes below walks only ACTIVE features (Main_c's
  // inactivePluginExcludes, for the same reason one target over).
  const containerExcludes = CONTAINED
    .filter((name: string) => null == (feature as any)[name])
    .flatMap((name: string) => [
      new RegExp('(^|/)feature/' + name + '_feature\\.ml$'),
      new RegExp('(^|/)feature/' + name + '/'),
      new RegExp('(^|/)test/feature/' + name + '/'),
    ])

  Package({ target })

  Gitignore({})

  // Copy tm/ocaml verbatim with ProjectName replacement. The src/ subtree
  // only stages per-feature custom-source dirs (srcfeature: false, so unused),
  // excluded like the go/rust targets. Stray compiled artifacts and built
  // test binaries are excluded defensively. test/vendor/omni (the vendored
  // @voxgig/omni corpus engine) rides along verbatim - the replacements are
  // ProjectName-shaped and the port names nothing project-specific, so it
  // lands byte-identical to its recorded vendored.json digest.
  //
  // pluginExcludes: the generate-time plugin trim (an ACTIVE feature's
  // INACTIVE plugin group's declared files stay out of the tree). The
  // model's ocaml `path` entries are target-root-relative, which is this
  // Copy's root - helpers/featureSource documents that getting the root
  // wrong makes the trim a silent no-op. ocaml has `srcfeature: false`, so
  // the per-feature Copy in cmp/Feature.ts - where pluginExcludesFor
  // normally applies this trim - never runs for it, and this whole-tree
  // Copy is the ONLY copy the target has (Main_go.ts precedent).
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, /\.(cmi|cmo|cmx|cma|cmxa|o|a)$/, /a\.out$/,
      /run_sdk_test$/, /run_omni_smoke$/, /run_struct_corpus$/, /run_primary_corpus$/,
      ...containerExcludes, ...pluginExcludes(model)],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // THE BUILD SEAM: feature/secrets/feature.mk, GENERATED only when the
  // model activates `secrets` for this target. It is what only the model
  // knows and only a Makefile can say in OCaml - the module list in
  // DEPENDENCY ORDER (ocamlc compiles a module before anything that uses
  // it and has no link-time reordering, so a wildcard over the vendored
  // directories would not build), the -I paths, unix.cma for the dotenv
  // and file built-ins, the gated suite, and, ONLY when an active plugin
  // group declares `needs.fetch`, the OpenSSL binding: plugins/tls_stubs.c
  // compiled and linked with `-custom -cclib -lssl -cclib -lcrypto`. The
  // template Makefile includes `$(wildcard feature/*/feature.mk)` - it names
  // no feature itself - and every variable a fragment sets is empty without
  // one, so an SDK without secrets - or with the built-in
  // chain alone, or with `secretspec` alone - runs no C compiler and links
  // no OpenSSL. The shape lua's native.mk and c's kinds.c take.
  //
  // The vendored stub opens with the vendoring tool's three-line `(* *)`
  // provenance header (every file under tm/ocaml is stamped in ocaml's
  // comment syntax; the guard holds that), which a C compiler cannot
  // read - so the rule feeds the compiler from line four, as lua's does.
  // Compiler line numbers are therefore three lower than in the file.
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

          if (build.tls) {
            Content(`
# THE ONE EXTERNAL DEPENDENCY, behind the plugin groups that need a
# transport (${build.tlsGroups.join(', ')}): plugins/tls.ml's externals live in
# plugins/tls_stubs.c against OpenSSL, so the stub is compiled here and the
# bytecode executables are linked \`-custom\` with libssl and libcrypto.
# The stub is fed from line four (past the provenance header, see above).
OCAMLLIB = $(shell $(OCAMLC) -where)
FEATURE_OBJ = feature/secrets/plugins/tls_stubs.o
FEATURE_LINK = -custom -cclib -lssl -cclib -lcrypto

feature/secrets/plugins/tls_stubs.o: feature/secrets/plugins/tls_stubs.c
	@command -v $(CC) >/dev/null 2>&1 || { echo "secrets: a C compiler ($(CC)) is needed to build the OpenSSL binding that this SDK's secrets plugin kinds (${build.tlsGroups.join(', ')}) run - install one, or use only the built-in provider kinds" >&2; exit 1; }
	tail -n +4 $< | $(CC) -std=c11 -O2 -Wall -Wextra -I$(OCAMLLIB) -x c - -c -o $@
`)
          }
          else {
            Content(`
# No active plugin group needs a transport, so the OpenSSL binding is not
# compiled and nothing is linked beyond the OCaml distribution.
FEATURE_OBJ =
FEATURE_LINK =
`)
          }
        })
      })
    })
  }

  // Generated API config + branded-error re-export.
  Config({ target })
  SdkError({ target })

  // sdk_client.ml — the client constructors, direct/prepare, and the
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
    // dispatch through. None for a name this SDK did not generate.
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
