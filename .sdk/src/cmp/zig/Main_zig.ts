
import * as Path from 'node:path'

import {
  cmp, each,
  File, Content, Copy, Folder, Fragment,
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


import { Config, FeaturePlugins, BUILTIN_FEATURES } from './Config_zig'
import { Schema } from './Schema_zig'
import { Gitignore } from './Gitignore_zig'
import { MainEntity } from './MainEntity_zig'
import { Package } from './Package_zig'
import { PrepareAuth } from './PrepareAuth_zig'


const FEATURE_TESTS: Record<string, string> = {
  secrets: 'test/feature/secrets/secrets_test.zig',
}


const FEATURE_MODULES: Record<string, string> = {
  secrets: `// The secrets feature's vendored libraries (@voxgig/sekreto and
// voxgig/plugin at the shared vendor tag), as the three named modules
// upstream builds them as. Declared ONLY when the model activates the
// feature: feature/secrets.zig is the sole importer, and an inactive SDK
// never analyses it (zig compiles only what a module root reaches).
const plugin_mod = b.addModule("plugin", .{
    .root_source_file = b.path("feature/secrets/plugin/plugin.zig"),
    .target = target,
    .optimize = optimize,
});
const sekreto_mod = b.addModule("sekreto", .{
    .root_source_file = b.path("feature/secrets/sekreto/sekreto.zig"),
    .target = target,
    .optimize = optimize,
});
sekreto_mod.addImport("plugin", plugin_mod);
// Rooted at the GENERATED selection (feature/secrets/plugins.zig), never
// at upstream's full-set all.zig: the root decides which kinds compile.
const sekretoplugins_mod = b.addModule("sekretoplugins", .{
    .root_source_file = b.path("feature/secrets/plugins.zig"),
    .target = target,
    .optimize = optimize,
});
sekretoplugins_mod.addImport("sekreto", sekreto_mod);
sekretoplugins_mod.addImport("plugin", plugin_mod);
sdk_mod.addImport("sekreto", sekreto_mod);
sdk_mod.addImport("sekretoplugins", sekretoplugins_mod);
`,
}


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
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

  Copy({
    from: 'tm/' + target.name,
    // pluginExcludes: the generate-time plugin trim for an ACTIVE feature's
    // inactive groups (the model's `path` entries are target-root-relative,
    // which is this Copy's root); inactivePluginExcludes (above) for the
    // groups of a feature that is itself off.
    exclude: [
      /src\//,
      /build\.zig\.zon$/,
      ...pluginExcludes(model),
      ...inactivePluginExcludes,
    ],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // The active features that root.zig does not export statically: the
  // BUILT-IN set is in the template, so this is the gated ones (`secrets`)
  // and any bespoke feature the model adds. Config_zig names the same
  // features in make_feature, from the same list, so the two cannot drift.
  const extraFeatures = each(feature)
    .filter((f: any) => 'base' !== f.name && !BUILTIN_FEATURES.includes(f.name))
    .map((f: any) => f.name)
    .sort()

  const fragdir = Path.normalize(__dirname + '/../../../src/cmp/zig/fragment/')

  File({ name: 'build.zig' }, () => {
    Fragment({
      from: fragdir + 'Build.fragment.zig',
      replace: {
        ...props.ctx$.stdrep,

        '#FeatureModules': ({ indent }: any) => {
          for (const fname of extraFeatures) {
            const block = FEATURE_MODULES[fname]
            if (null != block) Content({ indent }, block)
          }
        },

        '#FeatureTestSteps': ({ indent }: any) => {
          for (const fname of extraFeatures) {
            const suite = FEATURE_TESTS[fname]
            if (null == suite) continue
            Content({ indent }, `// The ${fname} feature suite: part of \`zig build test\`, and alone as
// \`zig build test-${fname}\` (see FEATURE_TESTS in Main_zig).
{
    const ${fname}_mod = b.createModule(.{
        .root_source_file = b.path("${suite}"),
        .target = target,
        .optimize = optimize,
    });
    ${fname}_mod.addImport("voxgig-struct", struct_mod);
    ${fname}_mod.addImport("sdk", sdk_mod);
    ${fname}_mod.addImport("omni", omni_mod);
    const ${fname}_test = b.addTest(.{ .root_module = ${fname}_mod });
    const run_${fname} = b.addRunArtifact(${fname}_test);
    run_${fname}.has_side_effects = true;
    test_step.dependOn(&run_${fname}.step);
    const ${fname}_step = b.step("test-${fname}", "Run the ${fname} feature suite alone");
    ${fname}_step.dependOn(&run_${fname}.step);
}
`)
          }
        },
      }
    })
  })

  File({ name: 'root.zig' }, () => {
    Fragment({
      from: fragdir + 'Root.fragment.zig',
      replace: {
        ...props.ctx$.stdrep,

        '#FeatureExports': ({ indent }: any) => {
          for (const fname of extraFeatures) {
            const tname = fname.charAt(0).toUpperCase() + fname.slice(1)
            Content({ indent },
              `pub const ${tname}Feature = @import("feature/${fname}.zig").${tname}Feature;\n`)
          }
        },
      }
    })
  })

  // feature/<name>/plugins.zig: the selected plugin definitions, as the root
  // of the `sekretoplugins` module build.zig declares above (active only).
  FeaturePlugins({ target })

  // Generated core files: the client (sdk.zig) and the API config. The
  // branded error type (error.zig) is a plain template (copied above).
  Folder({ name: 'core' }, () => {

    PrepareAuth({ target })

    File({ name: 'sdk.' + target.ext }, () => {

      Fragment(
        {
          from: fragdir + 'Main.fragment.zig',
          replace: {
            ...props.ctx$.stdrep,
          }
        },

        () => {
          each(entity, (ent: ModelEntity) => {
            MainEntity({ target, entity: ent })
          })
        })
    })

    Config({ target })

    Schema({ target })
  })

})


export {
  Main
}
