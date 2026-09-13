
import * as Path from 'node:path'

import {
  cmp, each,
  File, Copy, Folder, Fragment,
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


import { Package } from './Package_c'
import { Config, FeaturePlugins } from './Config_c'
import { Gitignore } from './Gitignore_c'
import { MainEntity } from './MainEntity_c'
import { EntityBase } from './EntityBase_c'
import { EntityTypes } from './EntityTypes_c'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  // THE PLUGIN TRIM FOR A FEATURE THAT IS ITSELF OFF (Main_scala's
  // inactivePluginExcludes, for the same reason one target over).
  //
  // pluginExcludes(model) below walks only the model's ACTIVE features, so
  // a `secrets` declared `active: false` keeps every declared group's
  // vendored kind file in the tree. For c that is not merely untidy: the
  // Makefile decides whether to compile the plugin layer - and to link
  // OpenSSL and libcurl - from whether a KIND FILE is present under
  // feature/secrets/plugins/, so the files have to go. Every declared group
  // of an inactive feature goes, not only the groups marked inactive: a
  // feature that is off has no active plugins whatever its `plugin` map
  // says (targetFeatures drops it before Config ever reads a group). The
  // feature's own source and the vendored cores are left to the Makefile's
  // wiring gate (feature/secrets/kinds.c is generated only for an active
  // feature; without it nothing of the feature is compiled) and to
  // `target add`, which trims the whole container for a real project.
  //
  // Rooting matches pluginExcludes': c's declared paths are
  // target-root-relative, which is this Copy's root, and the other
  // targets' paths in the same list cannot match anything in a c tree.
  const feature = targetFeatures(model, target)
  const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const allfeature = getModelPath(model, `main.${KIT}.feature`,
    { required: false, only_active: false }) || {}
  const inactivePluginExcludes: RegExp[] = []
  for (const fname of Object.keys(allfeature)) {
    if (null != (feature as any)[fname]) continue
    const groups = getModelPath(model, `main.${KIT}.feature.${fname}.plugin`,
      { required: false, only_active: false }) || {}
    for (const gname of Object.keys(groups)) {
      for (const one of (groups[gname].path || [])) {
        const pat = esc(String(one))
        inactivePluginExcludes.push(new RegExp('(^|/)' +
          pat.replace(/\\\/$/, '') + (/\/$/.test(String(one)) ? '/' : '$')))
      }
    }
  }

  Package({ target })

  Gitignore({})

  // Copy tm/c files with replacements. The tm src/ subtree only stages the
  // per-feature custom-source dirs (target add), so it is excluded here.
  //
  // pluginExcludes: the generate-time plugin trim (an INACTIVE plugin
  // group's declared files stay out of the tree - the model's `path`
  // entries are target-root-relative, which is this Copy's root). c has
  // `srcfeature: false`, so the per-feature Copy in cmp/Feature.ts - where
  // pluginExcludesFor normally applies this trim - never runs for it, and
  // this whole-tree Copy is the ONLY copy the target has: without the
  // exclude an active secrets feature would ship every inactive kind, and
  // the Makefile would compile and link them all (Main_go.ts precedent).
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, ...pluginExcludes(model), ...inactivePluginExcludes],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // Generated core files: the client (client.c), the API config (config.c),
  // and the per-API header (api.h, via EntityBase). The branded error type
  // is a template (core/error.c).
  Folder({ name: 'core' }, () => {

    File({ name: 'client.c' }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/c/fragment/Main.fragment.c'),
          replace: {
            ...props.ctx$.stdrep,
          }
        },

        // Entity accessors — injected at SLOT.
        () => {
          each(entity, (entity: ModelEntity) => {
            MainEntity({ target, entity })
          })
        })
    })

    Config({ target })
  })

  // feature/<name>/kinds.c — the plugin definitions an active plugin-bearing
  // feature selected, and the Makefile's wiring gate for that feature's
  // vendored payload (see Config_c). Nothing is emitted when no such
  // feature is active.
  FeaturePlugins({ target })

  // core/api.h — the per-API public header (entity constructors + accessors).
  EntityBase({ target })

  // entity/types.h — documentary typed models (one struct per entity + op).
  EntityTypes({ target })

})


export {
  Main
}
