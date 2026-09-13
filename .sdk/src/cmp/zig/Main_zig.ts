
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
import { Gitignore } from './Gitignore_zig'
import { MainEntity } from './MainEntity_zig'
import { Package } from './Package_zig'


// Which features ship a zig test suite under test/feature/<name>/, and the
// file build.zig must NAME to run it. zig has no test auto-discovery: a
// suite the build file does not list exists and never runs. A map rather
// than a convention because the file has to EXIST - `zig build` fails the
// whole build on a test path it cannot find - so this may only name suites
// the templates actually carry.
//
// The suite sits under test/feature/<name>/ so that it belongs to the
// feature (helpers/featureSource), exactly as go's tm/go/test/feature/
// secrets/ and rust's tests/feature/secrets/ do; and it is wired only for
// a feature that is ACTIVE for this target, which is when its build modules
// (below) exist for the suite to reach.
//
// Each suite gets its OWN build step (`zig build test-<name>`) as well as a
// place in the all-tests `test` step: the corpus suites need a project's
// compiled `.sdk/test/test.json` beside the SDK, so a checker that has the
// feature but no corpus (sdkgen's own generatedcompile lane) can still run
// the feature suite alone and read its count.
const FEATURE_TESTS: Record<string, string> = {
  secrets: 'test/feature/secrets/secrets_test.zig',
}


// The GATED features' build modules: what a feature's `@import("<name>")`
// lines resolve to, declared only when the feature is active. Each entry is
// the block of build.zig statements that wires one feature; `secrets` is
// the first and, today, the only one.
//
// Upstream's own three-module boundary (sekreto's zig Makefile builds
// exactly these): `plugin` (voxgig/plugin, rooted at its consumer root),
// `sekreto` (the core, which imports `plugin` by name and nothing under
// plugins/), and `sekretoplugins`, rooted at the GENERATED
// feature/secrets/plugins.zig (Config_zig FeaturePlugins) so that only the
// selected kinds are compiled. The sdk module gets `sekreto` and
// `sekretoplugins`; the feature file reaches `plugin` through
// `sekreto.plugin`, so it needs no import of its own.
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

  // THE PLUGIN TRIM FOR AN INACTIVE FEATURE (the scala shape, for the same
  // reason). pluginExcludes(model) walks only the model's ACTIVE features,
  // which is right for a target whose feature trim is on: an inactive
  // feature's whole tree is already gone at `target add`. zig's feature trim
  // is OFF (model/target/zig.aon `feature: { trim: false }` - root.zig's
  // built-in exports are static), so an inactive feature's tree is all still
  // here, and its provider plugins are the part that costs the most. EVERY
  // declared group of an inactive feature goes, not just the groups marked
  // inactive: a feature that is off has no active plugins whatever its
  // `plugin` map says, because targetFeatures drops the feature before
  // Config ever reads a group. What stays is the two vendored cores and the
  // ungrouped httpjson/sigv4 helpers - dead files zig never analyses, since
  // build.zig declares no module rooted in them (FEATURE_MODULES).
  //
  // Rooting matches pluginExcludes': zig's declared paths are
  // target-root-relative, which is this Copy's root, and the other targets'
  // paths in the same list cannot match anything in a zig tree.
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

  // build.zig.zon — the package manifest, stamped with the model package name.
  Package({ target })

  Gitignore({})

  // Copy tm/zig files with replacements. The tm src/ subtree only stages the
  // per-feature custom-source dirs (target add), so it is excluded here
  // exactly like the go/rust targets. build.zig.zon is generated by Package
  // (above), so it is excluded from the verbatim copy. The SDK source lives at
  // the tree root (core/, feature/, utility/, entity/, test/) — Zig's
  // idiomatic src/ is not used, to keep the exclude rule identical to the
  // reference targets.
  //
  // build.zig and root.zig are NOT in tm/zig any more: both carry
  // model-driven slots (a gated feature's build modules, test step and root
  // export) and are emitted below from src/cmp/zig/fragment/, the way
  // core/sdk.zig always was.
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

  // build.zig: the template with its two slots filled - a gated feature's
  // modules after the sdk module, and its test suite as a step of its own
  // that the all-tests step also depends on. Both empty for a model that
  // activates no gated feature, which leaves the file byte-identical to the
  // fragment minus the marker lines.
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

  // root.zig: the module root, with the gated features' type exports
  // appended to the static built-in ones.
  File({ name: 'root.zig' }, () => {
    Fragment({
      from: fragdir + 'Root.fragment.zig',
      replace: {
        ...props.ctx$.stdrep,

        '#FeatureExports': ({ indent }: any) => {
          for (const fname of extraFeatures) {
            // MUST match Config_zig's make_feature spelling of the type.
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

    File({ name: 'sdk.' + target.ext }, () => {

      Fragment(
        {
          from: fragdir + 'Main.fragment.zig',
          replace: {
            ...props.ctx$.stdrep,
          }
        },

        // Entity accessors - injected at SLOT
        () => {
          each(entity, (ent: ModelEntity) => {
            MainEntity({ target, entity: ent })
          })
        })
    })

    Config({ target })
  })

})


export {
  Main
}
