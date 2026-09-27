import {
  Content,
  File,
  cmp,
  configDefinition,
  configReprSetting,
  isConfigData,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


import {
  formatHsValue,
  hsString,
} from './utility_haskell'


// The full set of feature constructors in SdkFeatures (name -> <name>Feature).
const FEATURE_NAMES = [
  'log', 'test', 'retry', 'timeout', 'ratelimit', 'cache', 'idempotency',
  'paging', 'streaming', 'proxy', 'telemetry', 'metrics', 'debug', 'audit',
  'clienttrack', 'rbac', 'netsim',
]


// SdkConfig.hs: makeConfig builds the embedded API model as a struct Value;
// makeFeature(name) is the N-feature-safe factory the client uses to
// instantiate features named in the options.
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  // The same config as an OBJECT, built by the shared helper so this target's
  // literal and the data that replaces it above the threshold are the same
  // config by construction. The JSON is what the threshold is measured on -
  // emitted source size varies by language, the model does not.
  const { def: configDef, json: configJson } = configDefinition(model)
  const asData = isConfigData(configJson, configReprSetting(model))

  const configBody = asData
    ? `-- THE API MODEL, EMBEDDED AS DATA (sdkgen rung L1).
--
-- Emitted only above a size threshold, or when \`main.kit.config.repr\` pins
-- it: for a small model the CV literal is smaller and far easier to read when
-- debugging.
configData :: String
configData = ${hsString(configJson)}

makeConfig :: IO Value
makeConfig = jsonRead configData`
    : `makeConfig :: IO Value
makeConfig = buildCV ${formatHsValue(configDef)}`

  File({ name: 'SdkConfig.' + target.ext }, () => {

    Content(`-- Generated API configuration (make_config) and the feature factory.

module SdkConfig (makeConfig, makeFeature) where

import VoxgigStruct (Value)
import ${asData ? 'SdkJson (jsonRead)' : 'SdkHelpers (CV (..), buildCV)'}
import SdkTypes (Feature)
import qualified SdkFeatures as F

${configBody}

makeFeature :: String -> IO Feature
makeFeature name = case name of
`)

    for (const fname of FEATURE_NAMES) {
      Content(`  "${fname}" -> F.${fname}Feature\n`)
    }

    Content(`  _ -> F.baseFeature\n`)
  })
})


export {
  Config
}
