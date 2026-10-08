
const { getprop } = require('./utility/StructUtility')


class Control {
  constructor(ctrlmap) {
    this.throw = getprop(ctrlmap, 'throw')
    this.err = getprop(ctrlmap, 'err')
    this.explain = getprop(ctrlmap, 'explain')
    this.signal = getprop(ctrlmap, 'signal')
  }
}


module.exports = {
  Control,
}
