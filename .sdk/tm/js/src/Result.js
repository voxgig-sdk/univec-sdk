
const { getprop } = require('./utility/StructUtility')


class Result {
  constructor(resmap) {
    this.ok = getprop(resmap, 'ok', false)
    this.status = getprop(resmap, 'status', -1)
    this.statusText = getprop(resmap, 'statusText', '')
    this.headers = getprop(resmap, 'headers', {})
    this.body = getprop(resmap, 'body')
    this.err = getprop(resmap, 'err')
    this.resdata = getprop(resmap, 'resdata')
    this.resmatch = getprop(resmap, 'resmatch')
  }
}


module.exports = {
  Result,
}
