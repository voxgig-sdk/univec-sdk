
const { BaseFeature } = require('./feature/base/BaseFeature')
// #ImportFeatures


const FEATURE_CLASS = {
  // #FeatureClasses
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
  config
}

