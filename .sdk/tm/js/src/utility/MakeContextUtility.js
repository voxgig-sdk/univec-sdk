
const { Context } = require('../Context')

function makeContext(ctxmap, basectx) {
  const ctx = new Context(ctxmap, basectx)
  return ctx
}

module.exports = {
  makeContext,
}
