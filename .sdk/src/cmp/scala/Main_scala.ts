
import * as Path from 'node:path'

import {
  cmp, each,
  File, Content, Copy, Folder, Fragment,
  targetFeatures,
  pluginExcludes,
  TEST_CONTROL_EXCLUDE
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_scala'
import { Config } from './Config_scala'
import { Gitignore } from './Gitignore_scala'
import { MainEntity } from './MainEntity_scala'
import { EntityBase } from './EntityBase_scala'
import { EntityTypes } from './EntityTypes_scala'
import { scalaPackage } from './utility_scala'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  // The Scala package root for every runtime piece (like GOMODULE for go).
  const scalapackage = scalaPackage(model)

  // THE PLUGIN TRIM, over the WHOLE model rather than its active half.
  //
  // pluginExcludes(model) walks only the model's ACTIVE features
  // (helpers/featureSource), which is right for a target whose feature trim
  // is on: an inactive feature's whole tree is already gone at `target add`,
  // so it has no plugin files left to exclude. Scala's feature trim is OFF
  // (see the Copy below), so the opposite holds - an inactive feature's tree
  // is all still here, and its plugins are the part of it that costs the
  // most. Before this, a scala SDK whose model never mentioned `secrets`
  // shipped and compiled all nine vendored provider clients: the one trim
  // the target has walked straight past the feature that owns them.
  //
  // EVERY declared group of an inactive feature goes, not just the groups
  // marked inactive. A feature that is off has no active plugins whatever
  // its `plugin` map says - `main: kit: feature: secrets: { active: false
  // plugin: vault: active: true }` selects nothing, because targetFeatures
  // drops the feature before Config ever reads a group - so shipping vault's
  // files for it would leave a provider client in the tree that nothing in
  // the SDK can reach. That is why this reads the declared paths directly
  // rather than reusing pluginExcludesFor, whose rule (exclude the groups
  // marked `active: false`) is the right one only for a LIVE feature.
  //
  // Rooting matches pluginExcludes': scala's declared paths are
  // target-root-relative, which is this Copy's root, and the other targets'
  // paths in the same list cannot match anything in a scala tree.
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

  // Copy tm/scala files with replacements. SCALAPACKAGE is the package-root
  // token used throughout the templates (package/import statements);
  // ProjectName carries the SDK name into vendored template strings.
  Copy({
    from: 'tm/' + target.name,
    // The generate-time plugin trim, in both halves: pluginExcludes for an
    // ACTIVE feature's inactive groups, inactivePluginExcludes (above) for
    // the groups of a feature that is itself off. An inactive group's
    // declared files stay out of the tree - the model's `path` entries are
    // target-root-relative, which is this Copy's root.
    //
    // Scala's FEATURE-level trim is off (model/target/scala.aon `feature: {
    // trim: false }`, because the cross-feature tests are fused into one
    // sdktest/SdkTestMain.scala, which constructs fifteen feature classes by
    // name), so this is the ONLY trim the target has, and what it does NOT
    // reach is worth stating rather than leaving to be discovered: every
    // feature's own source ships to every scala SDK whatever the model says,
    // secrets included, so a secrets-off SDK still carries SecretsFeature,
    // the vendored sekreto and voxgig/plugin cores, and the two UNGROUPED
    // plugin files (plugins/Sigv4.scala's HMAC-SHA256 signer and
    // plugins/Httpjson.scala's fetch + ProcessBuilder helpers, which belong
    // to no group because four and eight kinds respectively compile against
    // them). What it DOES reach is the nine provider clients, and they are
    // the bulk: measured on a feature-off SDK, 26 files rather than 35.
    exclude: [
      /src\//,
      TEST_CONTROL_EXCLUDE,
      ...pluginExcludes(model),
      ...inactivePluginExcludes,
    ],
    replace: {
      ...props.ctx$.stdrep,
      ProjectName: model.const.Name,
      SCALAPACKAGE: scalapackage,
    }
  })

  // Shared entity runtime (entity/EntityBase.scala).
  EntityBase({ target })

  // Generate the client class and config in core/.
  Folder({ name: 'core' }, () => {

    File({ name: model.const.Name + 'SDK.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/scala/fragment/Main.fragment.scala'),
          replace: {
            ...props.ctx$.stdrep,
            SCALAPACKAGE: scalapackage,
            ProjectName: model.const.Name,
          }
        },

        // Entities - injected at SLOT
        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK, scalapackage }
            MainEntity(entprops)
          })
        })
    })

    Config({ target })

    // Generate the typed reference-model file (<Name>Types.scala) beside the
    // other generated core files. Documentation/DX shapes only — not wired
    // into the loose-object-model op signatures.
    EntityTypes({ target, scalapackage })
  })

})


export {
  Main
}
