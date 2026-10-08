
const { getprop } = require('./utility/StructUtility')


class Response {
  constructor(resmap) {
    this.status = getprop(resmap, 'status', -1)
    this.statusText = getprop(resmap, 'statusText', '')
    this.headers = getprop(resmap, 'headers')
    this.json = readJson(resmap)
    this.body = getprop(resmap, 'body')
    this.err = getprop(resmap, 'err')
  }
}


// An empty body, such as the one an accepted delete answers with, is no
// body: parsing it as JSON would throw after the call has succeeded.
function readJson(resmap) {
  if ('function' === typeof resmap.text) {
    return async () => {
      const text = await resmap.text()
      if ('' === text.trim()) {
        return undefined
      }
      try {
        return JSON.parse(text)
      }
      catch (err) {
        err.text = text
        throw err
      }
    }
  }
  return resmap.json ? resmap.json.bind(resmap) : async () => undefined
}


module.exports = {
  Response,
}
