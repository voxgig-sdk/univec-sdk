
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


  main = {
    name: 'Univec',
  }


  feature = {
    // #FeatureConfigs
  }


  options = {
    base: 'https://api.univec.ai',

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

