
const { getprop } = require('./utility/StructUtility')


class Spec {
  constructor(specmap) {
    this.parts = getprop(specmap, 'parts', [])
    this.headers = getprop(specmap, 'headers', {})
    this.alias = getprop(specmap, 'alias', {})
    this.base = getprop(specmap, 'base', '')
    this.prefix = getprop(specmap, 'prefix', '')
    this.suffix = getprop(specmap, 'suffix', '')
    this.params = getprop(specmap, 'params', {})
    this.query = getprop(specmap, 'query', {})
    this.step = getprop(specmap, 'step', '')
    this.method = getprop(specmap, 'method', 'GET')
    this.body = getprop(specmap, 'body')
    this.url = getprop(specmap, 'url')
    this.path = getprop(specmap, 'path')
    // The query parameters prepareAuth placed: the credential, which the
    // request sends and the entity's match leaves out.
    this.authquery = getprop(specmap, 'authquery', [])
  }
}


module.exports = {
  Spec,
}
