
const {
  walk, size, pad, slice, clone
} = require('./StructUtility')

// Clean request data by partially hiding sensitive values.
function clean(ctx, val) {
  const options = ctx.options

  const cleankeyre = options?.__derived__?.clean?.keyre
  const hintsize = 4

  /*
  if (null != cleankeyre) {
    val = walk(clone(val), (key, subval) => {
      if (cleankeyre.exec(key) && 'string' === typeof subval) {
        const len = size(subval)
        const hint = (hintsize * 4) < len ? slice(subval, 0, hintsize) : ''
        subval = pad(hint, len, '*')
      }
      return subval
    })
  }
  */

  return val
}

module.exports = {
  clean
}
