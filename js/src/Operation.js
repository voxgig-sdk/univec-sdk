
const { getprop } = require('./utility/StructUtility')

const { Point } = require('./Point')


class Operation {
  constructor(opmap) {
    this.entity = getprop(opmap, 'entity', '_')
    this.name = getprop(opmap, 'name', '_')
    this.input = getprop(opmap, 'input', '_')
    this.points = getprop(opmap, 'points', [])
  }
}


module.exports = {
  Operation,
}
