
import * as Path from 'node:path'

import {
  cmp, each,
  List, File, Content, Copy, Folder, Fragment, Line,
  entityClassName, entityCollection, pluginExcludes, targetFeatures,
  TEST_CONTROL_EXCLUDE
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_dart'
import { Config } from './Config_dart'
import { Gitignore } from './Gitignore_dart'
import { MainEntity } from './MainEntity_dart'
import { EntityBase } from './EntityBase_dart'
import { EntityTypes } from './EntityTypes_dart'
import { SdkError } from './SdkError_dart'


const Main = cmp(async function Main(props: any) {

  // Needs type: target object
  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  // Gated by the applicability tags, so this target never emits a hook for
  // a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  // Does the secrets feature apply here and is it switched on? Both, since
  // targetFeatures already dropped it for a target with no sekreto port.
  const secrets = null != feature.secrets

  Package({ target })

  Gitignore({})

  // Copy tm/dart files with replacements. The src/feature/* dirs exist only
  // for the feature-add copy mechanism (real feature sources live under
  // lib/feature/), so they are excluded from the generated package.
  Copy({
    from: 'tm/' + target.name,
    // pluginExcludes: the generate-time plugin trim (an INACTIVE plugin
    // group's declared files stay out of the tree - the model's `path`
    // entries are target-root-relative, which is this Copy's root). The
    // FEATURE-level trim for dart stays an add-time concern (vendor-tag
    // rollout, Decision 5), exactly as for go and py.
    //
    // It must be EXACT for dart in a way it need not be elsewhere:
    // `dart analyze` walks the whole package, so a group `path` list that
    // omits a file another vendored file imports is a hard build failure
    // rather than a silent runtime miss.
    //
    // `^src/`, ANCHORED, and the anchor is load-bearing. CopyOp seeds its
    // walk with an empty path, so an exclude names paths within the copied
    // tree - and the unanchored `/src\//` this used to be matched ANY path
    // with a `src/` segment. The vendored sekreto port keeps upstream's
    // layout, which is `sekreto/src/*.dart`, so the whole secrets core was
    // silently dropped from the generated package while the plugins beside
    // it survived: nine undefined-symbol errors from `dart analyze` and no
    // clue in the copy that anything had been excluded.
    exclude: [/^src\//, TEST_CONTROL_EXCLUDE, ...pluginExcludes(model)],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  Folder({ name: 'lib' }, () => {

    SdkError({ target })

    File({ name: model.const.Name + 'SDK.' + target.ext }, () => {

      Line(`// ${model.const.Name} ${target.Name} SDK`)
      Line(``)

      List({ item: entity }, ({ item }: any) => {
        const cls = entityClassName(item, entityCollection(model))
        return Line(`import 'entity/${cls}.dart';`)
      })

      // Re-export the generated typed models and entity classes so
      // consumers can import everything from '<Sdk>SDK.dart'.
      Line(``)
      Line(`export '${model.const.Name}Types.dart';`)
      List({ item: entity }, ({ item }: any) => {
        const cls = entityClassName(item, entityCollection(model))
        return Line(`export 'entity/${cls}.dart';`)
      })

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/dart/fragment/Main.fragment.dart'),
          replace: {
            ...props.ctx$.stdrep,

            // SECRETS. Emitted only when the feature applies to this target
            // AND the model activates it. An unconditional edit here would
            // land in every generated SDK and break the inactive-output
            // gate: a model without the feature must generate exactly as it
            // did before the migration.
            //
            // The accessor finds the feature BY NAME in the public
            // `features` list rather than through a planted `_secrets`
            // field, which is what ts and js use: a leading underscore is
            // LIBRARY-private in Dart, so a feature in its own library
            // cannot write one on the SDK at all (see the note in
            // SecretsFeature.dart).
            //
            // The LIVE Sekreto, never a clone: it holds provider and cache
            // state, so a copy would resolve into something the transport
            // never sees.
            // Indentation is baked into the string, and the marker sits at
            // column 0 in the fragment: jostraca hands the marker's own
            // indent to the handler but does not re-indent a multi-line
            // Content, so an indented marker emitted an unindented method
            // body AND left the indent behind as trailing whitespace when
            // the slot was empty. At column 0 an inactive SDK gains one
            // blank line and nothing else.
            '// #SecretsAccessor': () => secrets ?
              Content(`
  // The live sekreto chain this SDK resolves its credential through, for
  // callers who want arbitrary secrets or redaction:
  //
  //   await sdk.secrets().get('db.password')
  //   sdk.secrets().redact(logline)
  //
  // Null before the secrets feature has initialised, and in an SDK where
  // it is switched off.
  dynamic secrets() {
    for (final f in features) {
      if ('secrets' == f.name) {
        return f.sekreto();
      }
    }
    return null;
  }

`) : undefined,
          }
        },

        // Entities
        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK }
            MainEntity(entprops)
          })
        })
    })

    Config({ target })
    EntityBase({ target })
    EntityTypes({ target })

  })
})


export {
  Main
}
