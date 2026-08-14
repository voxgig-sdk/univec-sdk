
const { getprop } = require('./utility/StructUtility')


class Point {
  constructor(altmap) {
    this.args = getprop(altmap, 'args', { params: [] })
    // Transport this point speaks: 'http' (default) or 'graphql'. GraphQL
    // points carry their operation document in `graphql` and address the
    // single endpoint, so method is always POST and parts is empty.
    this.kind = getprop(altmap, 'kind', 'http')
    this.graphql = getprop(altmap, 'graphql')
    this.rename = getprop(altmap, 'rename', { params: {} })
    this.method = getprop(altmap, 'method', '')
    this.orig = getprop(altmap, 'orig', '')
    this.parts = getprop(altmap, 'parts', [])
    this.params = getprop(altmap, 'params', [])
    this.select = getprop(altmap, 'select')
    // Absent in config means ACTIVE: emission drops `active: true` as a default
    // (sdkgen L0), so only an explicit `active: false` turns a point off.
    this.active = getprop(altmap, 'active', true)
    this.relations = getprop(altmap, 'relations', [])
    this.alias = getprop(altmap, 'alias', {})
    this.transform = getprop(altmap, 'transform', { req: undefined, res: undefined })
  }
}


module.exports = {
  Point,
}
