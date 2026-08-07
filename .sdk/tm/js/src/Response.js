
const { getprop } = require('./utility/StructUtility')


class Response {
  constructor(resmap) {
    this.status = getprop(resmap, 'status', -1)
    this.statusText = getprop(resmap, 'statusText', '')
    this.headers = getprop(resmap, 'headers')
    this.json = resmap.json ? resmap.json.bind(resmap) : async () => undefined
    this.body = getprop(resmap, 'body')
    this.err = getprop(resmap, 'err')
  }
}


module.exports = {
  Response,
}
