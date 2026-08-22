
import {
  Content,
  File,
  cmp,
  configDefinition,
  each,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  cppConfigLiterals,
} from './utility_cpp'


// core/config.hpp: makeConfig() rebuilds the embedded API model by parsing a
// chunked JSON literal with the vendored struct parser; makeFeature(name) is
// the N-feature-safe by-name factory the client uses (mirrors Config_java /
// Config_go).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const feature = getModelPath(model, `main.${KIT}.feature`)

  // The embedded config, built by the shared helper so this target's shapes
  // and identity fields stay in step with the ts reference by construction.
  // Passing target.name opts cpp into main.slug/version/target (the station
  // descriptor identity, ts/src/utility.ts configDefinition) - cpp has only
  // the data rep (one chunked JSON literal), so this is the whole #MainMeta
  // story for this target.
  const { def: configDef } = configDefinition(model, target.name)

  File({ name: 'config.' + target.ext }, () => {

    Content(`// Generated API configuration (mirrors Config_java / core/config.go).

#ifndef SDK_CORE_CONFIG_HPP
#define SDK_CORE_CONFIG_HPP

#include <memory>
#include <string>

#include "../core/struct.hpp"
#include "../core/types.hpp"
#include "../feature/base.hpp"
`)

    each(feature, (f: any) => {
      if (f.name !== 'base') {
        Content(`#include "../feature/${f.name}.hpp"
`)
      }
    })

    Content(`
namespace sdk {

inline const char* config_json() {
  return
${cppConfigLiterals(configDef)};
}

inline Value makeConfig() { return vs::parse_json(config_json()); }

// SHARED CONFIG (sdkgen rung L2).
//
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client - this is
// the difference between parsing the embedded JSON once and once per client.
//
// A function-local static in an inline function is one object across every
// translation unit, and its initialisation is thread-safe by the standard.
// Value holds shared_ptr nodes, so copying the returned Value shares the
// structure rather than duplicating it.
//
// The result is SHARED: treat it as read-only. Callers that need to mutate
// should use makeConfig, which always parses a fresh copy.
inline const Value& sharedConfig() {
  static const Value shared = makeConfig();
  return shared;
}

inline FeaturePtr makeFeature(const std::string& name) {
`)

    each(feature, (f: any) => {
      const fname = f.name.charAt(0).toUpperCase() + f.name.slice(1)
      if (f.name !== 'base') {
        Content(`  if (name == "${f.name}") return std::make_shared<${fname}Feature>();
`)
      }
    })

    Content(`  return std::make_shared<BaseFeature>();
}

} // namespace sdk

#endif // SDK_CORE_CONFIG_HPP
`)
  })
})


export {
  Config
}
