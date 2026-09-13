
const { BaseFeature } = require('./feature/base/BaseFeature')
// #ImportFeatures


const FEATURE_CLASS = {
  // #FeatureClasses
}


// Per-feature plugin DEFINITIONS (voxgig/plugin `Definition` values), from
// the model's active plugin groups. A feature that takes a `plugins` option
// (secrets over sekreto) reads its own entry; a feature with no plugins has
// none. Named requires above make each definition statically reachable, so
// an SDK carries exactly the plugin modules its model selects — the same
// leanness the old side-effect registry imports bought, without a registry.
//
// Read by SecretsFeature through a DEFERRED require of this module: the
// requires above make the pair circular, and this file replaces
// module.exports at the end of its body, so anything reading the map at
// module load would get undefined. See tm/js/src/feature/secrets.
const FEATURE_PLUGINS = {
  // #FeaturePlugins
}


class Config {

  makeFeature(fn) {
    const fc = FEATURE_CLASS[fn]
    const fi = new fc()
    // TODO: errors etc
    return fi
  }

  // False for a feature added at runtime via options.extend (station's
  // adopt path) - the constructor uses this to skip makeFeature for names
  // no generated class backs.
  hasFeature(fn) {
    return null != FEATURE_CLASS[fn]
  }


  main = {
    name: 'Univec',
    // #MainMeta
  }


  feature = {
    // #FeatureConfigs
  }


  options = {
    base: 'BASEURL',

    'SERVERBLOCK''AUTHBLOCK'headers: 'HEADERS',

    entity: {
      // #EntityConfigs
    }
  }


  entity = 'ENTITYMAP'
}


const config = new Config()

module.exports = {
  config,
  FEATURE_PLUGINS,
}

