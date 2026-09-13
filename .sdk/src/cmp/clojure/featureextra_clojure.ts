
import {
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


// FEATURES WHOSE CLOJURE SOURCE LIVES OUTSIDE src/sdk/features.clj.
//
// Every ordinary feature is one arm of the hand-written `make-feature`
// factory in that single module. A feature that vendors a LIBRARY cannot
// be: `secrets` carries a whole @voxgig/sekreto port, and that port has to
// be droppable for a project that did not ask for it. So its
// implementation lives in the gated feature container instead
// (`feature/secrets/sdk/feature/secrets.clj`, namespace
// `sdk.feature.secrets`) and the generated config wires it in.
//
// The container is ALSO a classpath root. Clojure resolves
// `(require 'voxgig.sekreto.chain)` to `voxgig/sekreto/chain.clj` searched
// from each `:paths` entry - never by relative import - so the directory
// holding `voxgig/` must itself be on the classpath. Package_clojure adds
// `feature/<name>` to `:paths` for exactly the entries below that are
// active. (`test/vendor/omni` is the same rule, already in that file.)
//
// A map rather than a convention because both halves are decisions:
// WHICH namespace the container publishes, and WHAT the constructor is
// called. A new one is added here, and nowhere else.
const EXTRA: Record<string, { ns: string, ctor: string }> = {
  secrets: { ns: 'sdk.feature.secrets', ctor: 'secrets-feature' },
}


type ExtraFeature = {
  // Feature name, as the model and make-feature spell it.
  name: string
  // The namespace the feature container publishes.
  ns: string
  // The constructor var in it, taking the feature's plugin definitions.
  ctor: string
  // The classpath root the container needs (target-root-relative).
  path: string
}


// The extra features this model actually selects, applicability included.
// Sorted, so the emitted requires and maps are byte-stable.
function extraFeatures(model: Model, target: any): ExtraFeature[] {
  const active = targetFeatures(model, target)

  return Object.keys(EXTRA).sort()
    .filter((name: string) => null != active[name])
    .map((name: string) => ({
      name,
      ns: EXTRA[name].ns,
      ctor: EXTRA[name].ctor,
      path: 'feature/' + name,
    }))
}


// The plugin DEFINITIONS the model selected, per feature.
//
// `def.clojure` keys are FULLY-QUALIFIED vars
// (`voxgig.sekreto.plugins.aws/awssecrets`); the namespace is the part
// before the `/`, and one namespace may export several definitions (aws
// exports two). Emitted as `(:require [<ns> :as p-<tail>])` plus
// `p-<tail>/<var>` references, so an INACTIVE group leaves no require and
// no reference - which is what makes the generate-time file trim safe.
//
// `only_active: false` is NOT used here, deliberately: this reads the
// ACTIVE plugins, because these become references to files that must
// exist. The trim (pluginExcludes, in Main_clojure) reads the unfiltered
// map instead. Getting that backwards emits a require for a namespace the
// trim just deleted.
function pluginRequires(model: Model, target: any): {
  requires: { ns: string, alias: string }[],
  plugins: Record<string, string[]>,
} {
  const feature = targetFeatures(model, target)

  const aliases: Record<string, string> = {}
  const plugins: Record<string, string[]> = {}

  for (const fname of Object.keys(feature).sort()) {
    const syms: string[] = []

    const pmap = getModelPath(model,
      `main.${KIT}.feature.${fname}.plugin`, { required: false }) || {}

    for (const pname of Object.keys(pmap).sort()) {
      const plugin = pmap[pname]
      if (false === plugin?.active || null == plugin?.active) continue

      for (const sym of Object.keys(plugin.def?.clojure || {}).sort()) {
        const cut = String(sym).lastIndexOf('/')
        if (0 > cut) continue
        const ns = String(sym).slice(0, cut)
        const varname = String(sym).slice(cut + 1)
        const alias = 'p-' + ns.split('.').pop()
        aliases[ns] = alias
        syms.push(alias + '/' + varname)
      }
    }

    if (0 < syms.length) {
      plugins[fname] = Array.from(new Set(syms)).sort()
    }
  }

  const requires = Object.keys(aliases).sort()
    .map((ns: string) => ({ ns, alias: aliases[ns] }))

  return { requires, plugins }
}


export type {
  ExtraFeature,
}

export {
  extraFeatures,
  pluginRequires,
}
