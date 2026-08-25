
import {
  Content,
  File,
  cmp,
  configDefinition,
  configReprSetting,
  each,
  isAuthActive,
  isConfigData,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  cStringLiteral,
  clean,
  formatCValue,
} from './utility_c'


// core/config.c: make_config() builds the embedded API model as a Value;
// make_feature(name) is the N-feature-safe factory the client uses to
// instantiate features named in the options (mirrors Config_rust).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  const authPrefix = resolveAuthPrefix(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  // The same config as an OBJECT, built by the shared helper so this target's
  // literal and the data that replaces it above the threshold are the same
  // config by construction. The JSON is what the threshold is measured on -
  // emitted source size varies by language, the model does not. Passing
  // target.name opts this target into the main slug/version/target identity
  // fields (read by station's descriptor - see configDefinition).
  const { def: configDef, json: configJson } = configDefinition(model, target.name)
  const asData = isConfigData(configJson, configReprSetting(model))

  // The feature block comes from configDefinition's def, not from f.config,
  // so the literal carries each feature's `transport` role (station design
  // §8.4) beside its options and cannot drift from the data rep.
  const featureConfig: any = {}
  each(feature, (f: any) => {
    featureConfig[f.name] = configDef.feature[f.name] || {}
  })

  const entityOptions: any = {}
  each(entity, (ent: any) => {
    entityOptions[ent.name] = {}
  })

  const options: any = {
    base: baseUrl,
    headers,
    entity: entityOptions,
  }
  if (authActive) {
    options.auth = { prefix: authPrefix }
  }

  const entityConfig = Object.values(entity || {}).reduce((a: any, n: any) => (
    a[n.name] = clean({
      fields: n.fields,
      name: n.name,
      op: n.op,
      relations: n.relations,
    }, true), a), {})

  const config = {
    // main from configDefinition's def, not re-derived here, so the literal
    // rep and the data rep cannot disagree on identity (the Config_ts
    // #MainMeta discipline): name plus slug/version/target.
    main: configDef.main,
    feature: featureConfig,
    options,
    entity: entityConfig,
  }

  File({ name: 'config.c' }, () => {

    // ABOVE THE THRESHOLD: emit the model as DATA.
    //
    // The literal is a single nested `cmap(...)`/`clist(...)` expression. For a
    // real model that is one function whose expression nests hundreds of
    // thousands of calls deep - the shape that makes a C compiler's parser and
    // register allocator quadratic, and the reason gcc can be seen taking
    // minutes on a generated config. A string constant is one token, and
    // `json_parse` (declared in sdk.h, reached through api.h) builds the same
    // voxgig_value tree at runtime.
    if (asData) {
      Content(`// Generated API configuration (mirrors core/config.go).

#include "api.h"

#include <string.h>

// THE API MODEL, EMBEDDED AS DATA (sdkgen rung L1).
//
// Emitted only above a size threshold, or when \`main.kit.config.repr\` pins
// it: for a small model the cmap() literal is smaller and far easier to read
// when debugging.
static const char CONFIG_DATA[] =
${cStringLiteral(configJson)};

voxgig_value* make_config(void) {
  return json_parse(CONFIG_DATA);
}

// SHARED CONFIG (sdkgen rung L2).
//
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client. Above the
// size threshold make_config re-parses the whole embedded JSON, so this is the
// difference between parsing the model once and once per client.
//
// Deliberately never freed: it lives for the life of the process, like any
// other program-lifetime singleton.
static voxgig_value* shared_config_val = NULL;

// The process-wide config, built once on first use.
//
// The returned value is SHARED: treat it as read-only. Callers that need to
// mutate should use make_config, which always returns a fresh copy.
voxgig_value* shared_config(void) {
  if (NULL == shared_config_val) {
    shared_config_val = make_config();
  }
  return shared_config_val;
}
`)
    }
    else {

    Content(`// Generated API configuration (mirrors core/config.go).

#include "api.h"

#include <string.h>

voxgig_value* make_config(void) {
  return ${formatCValue(config, 1)};
}

// SHARED CONFIG (sdkgen rung L2).
//
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client. Above the
// size threshold make_config re-parses the whole embedded JSON, so this is the
// difference between parsing the model once and once per client.
//
// Deliberately never freed: it lives for the life of the process, like any
// other program-lifetime singleton.
static voxgig_value* shared_config_val = NULL;

// The process-wide config, built once on first use.
//
// The returned value is SHARED: treat it as read-only. Callers that need to
// mutate should use make_config, which always returns a fresh copy.
voxgig_value* shared_config(void) {
  if (NULL == shared_config_val) {
    shared_config_val = make_config();
  }
  return shared_config_val;
}
`)
    }

    // Dispatch to the features the MODEL declares, and only those.
    //
    // This used to merge in a hardcoded list of every feature the C target
    // ships, on the reasoning that the runtime templates
    // (tm/c/feature/*.c) are always present. `target add` now trims feature
    // source to the model's selection, so that reasoning is false: a
    // reference to `feature_timeout_new` for an undeclared feature is an
    // unresolved symbol at LINK time — the whole test suite fails to link,
    // which is how this was found. Sorted for byte-stability.
    const featureNames = new Set<string>()
    each(feature, (f: any) => {
      if (f.name && f.name !== 'base') featureNames.add(f.name)
    })
    const sortedNames = Array.from(featureNames).sort()

    // Constructor prototypes for every declared feature. sdk.h declares the
    // BUNDLED set, but an externally-installed feature (e.g. station, whose
    // source arrives by package overlay) is not in sdk.h — and without a
    // prototype its make_feature arm is an implicit int-returning
    // declaration: a warning that happens to link on gcc 13, a hard error on
    // gcc 14+/clang 15+. Redeclaring the bundled ones is identical-prototype
    // C, which is legal and keeps this a single sorted list.
    Content(`
`)
    for (const fname of sortedNames) {
      Content(`Feature* feature_${fname}_new(void);
`)
    }

    Content(`
Feature* make_feature(const char* name) {
`)
    for (const fname of sortedNames) {
      Content(`  if (strcmp(name, "${fname}") == 0) return feature_${fname}_new();
`)
    }

    Content(`  return feature_base_new();
}
`)
  })
})


export {
  Config
}
