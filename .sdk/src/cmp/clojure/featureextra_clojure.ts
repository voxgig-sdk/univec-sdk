
import {
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


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
