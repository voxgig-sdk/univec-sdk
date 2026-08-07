
const { getprop } = require('./utility/StructUtility')


class Point {
  constructor(altmap) {
    this.args = getprop(altmap, 'args', { params: [] })
    this.rename = getprop(altmap, 'rename', { params: {} })
    this.method = getprop(altmap, 'method', '')
    this.orig = getprop(altmap, 'orig', '')
    this.parts = getprop(altmap, 'parts', [])
    this.params = getprop(altmap, 'params', [])
    this.select = getprop(altmap, 'select')
    this.active = getprop(altmap, 'active', false)
    this.relations = getprop(altmap, 'relations', [])
    this.alias = getprop(altmap, 'alias', {})
    this.transform = getprop(altmap, 'transform', { req: undefined, res: undefined })
  }
}


module.exports = {
  Point,
}
