
import * as Path from 'node:path'


import {
  Content,
  File,
  Fragment,
  Line,
  cmp,
  each,
  isAuthActive,
  resolveAuthPrefix,
  serverVariables,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
  nom,
} from '@voxgig/apidef'


import {
  clean,
  formatGoMap,
  goFeatureName,
} from './utility_go'


const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  // config.auth.prefix override -> spec-derived info.security.prefix -> 'Bearer'
  const authPrefix = resolveAuthPrefix(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  // Templated server URL: emit the spec's server-variable defaults so the
  // runtime can substitute {name} placeholders in base (see make_options).
  const svars = serverVariables(model)
  const serverBlock = 0 === svars.length ? '' :
    '\t\t\t"server": map[string]any{\n' +
    svars.map((v: any) => `\t\t\t\t${JSON.stringify(v.name)}: ${JSON.stringify(v.dflt)},\n`).join('') +
    '\t\t\t},\n'

  const authBlock = authActive
    ? `			"auth": map[string]any{
				"prefix": "${authPrefix}",
			},\n`
    : ''

  // Config is now in core/ package
  File({ name: 'config.' + target.ext }, () => {

    Content(`package core

import (
	"sync"
)

`)

    Content(`// MakeConfig builds a fresh, fully materialised config map. Every call
// rebuilds the whole structure, so prefer SharedConfig unless you need a
// private copy you intend to mutate.
func MakeConfig() map[string]any {
	return map[string]any{
		"main": map[string]any{
			"name": "${model.const.Name}",
		},
		"feature": map[string]any{
`)

    each(feature, (f: any) => {
      const fconfig = f.config || {}
      Content(`			"${f.name}": ${formatGoMap(fconfig, 3)},
`)
    })

    Content(`		},
		"options": map[string]any{
			"base": "${baseUrl}",
${serverBlock}${authBlock}			"headers": ${formatGoMap(headers, 3)},
			"entity": map[string]any{
`)

    each(entity, (entity: any) => {
      Content(`				"${entity.name}": map[string]any{},
`)
    })

    Content(`			},
		},
		"entity": ${formatGoMap(
      Object.values(entity).reduce((a: any, n: any) => (a[n.name] = clean({
        fields: n.fields,
        name: n.name,
        op: n.op,
        relations: n.relations,
      }, true), a), {}), 2)},
	}
}

var (
	sharedConfigOnce sync.Once
	sharedConfigVal  map[string]any
)

// SharedConfig returns the process-wide config, built once on first use.
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client.
//
// The returned map is shared: treat it as read-only. Callers that need to
// mutate should use MakeConfig, which always returns a fresh copy.
func SharedConfig() map[string]any {
	sharedConfigOnce.Do(func() {
		sharedConfigVal = MakeConfig()
	})
	return sharedConfigVal
}

func makeFeature(name string) Feature {
	switch name {
`)

    each(feature, (f: any) => {
      // MUST match Main_go.ts, which DECLARES these identifiers in registry.go
      // and the root init(); see goFeatureName.
      const fname = goFeatureName(f)
      if (f.name !== 'base') {
        Content(`	case "${f.name}":
		if New${fname}FeatureFunc != nil {
			return New${fname}FeatureFunc()
		}
`)
      }
    })

    Content(`	default:
		if NewBaseFeatureFunc != nil {
			return NewBaseFeatureFunc()
		}
	}
	return nil
}
`)
  })
})


export {
  Config
}
