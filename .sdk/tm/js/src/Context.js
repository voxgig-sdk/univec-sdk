
const { inspect } = require('node:util')

const { UnivecError } = require('./UnivecError')

const { getprop, setprop, getpath } = require('./utility/StructUtility')

const { Operation } = require('./Operation')
const { Response } = require('./Response')
const { Result } = require('./Result')
const { Spec } = require('./Spec')


// TODO: move to own file
class Context {

  id = 'C' + ('' + Math.random()).substring(2, 10)

  // Store the output of each operation step.
  out = {}

  // Store for the current operation.
  current = new WeakMap()


  ctrl = {}
  meta = {}

  client
  utility

  op
  point

  config
  entopts
  options

  opmap

  response
  result
  spec

  data
  reqdata
  match
  reqmatch

  entity

  // Shared persistent store.
  shared


  constructor(ctxmap, basectx) {
    this.client = getprop(ctxmap, 'client', getprop(basectx, 'client'))
    this.utility = getprop(ctxmap, 'utility', getprop(basectx, 'utility'))

    this.ctrl = getprop(ctxmap, 'ctrl', getprop(basectx, 'ctrl', this.ctrl))
    this.meta = getprop(ctxmap, 'meta', getprop(basectx, 'meta', this.meta))

    this.config = getprop(ctxmap, 'config', getprop(basectx, 'config'))
    this.entopts = getprop(ctxmap, 'entopts', getprop(basectx, 'entopts'))
    this.options = getprop(ctxmap, 'options', getprop(basectx, 'options'))

    this.entity = getprop(ctxmap, 'entity', getprop(basectx, 'entity'))
    this.shared = getprop(ctxmap, 'shared', getprop(basectx, 'shared'))
    this.opmap = getprop(ctxmap, 'opmap', getprop(basectx, 'opmap'))

    this.data = getprop(ctxmap, 'data', {})
    this.reqdata = getprop(ctxmap, 'reqdata', {})
    this.match = getprop(ctxmap, 'match', {})
    this.reqmatch = getprop(ctxmap, 'reqmatch', {})

    this.point = getprop(ctxmap, 'point', getprop(basectx, 'point'))
    this.spec = getprop(ctxmap, 'spec', getprop(basectx, 'spec'))
    this.result = getprop(ctxmap, 'result', getprop(basectx, 'result'))
    this.response = getprop(ctxmap, 'response', getprop(basectx, 'response'))

    const opname = getprop(ctxmap, 'opname')
    this.op = this.resolveOp(opname)
  }


  resolveOp(opname) {
    let op = getprop(this.opmap, opname)

    if (null == op && null != opname) {
      const entname = getprop(this.entity, 'name', '')
      const opcfg = getpath(this.config, ['entity', entname, 'op', opname])
      let input = 'match'

      if ('update' === opname || 'create' === opname) {
        input = 'data'
      }

      op = new Operation({
        entity: entname,
        name: opname,
        input,
        points: getprop(opcfg, 'points', [])
      })

      setprop(this.opmap, opname, op)
    }

    return op
  }


  error(code, msg) {
    return new UnivecError(code, msg, this)
  }


  toJSON() {
    return {
      id: this.id,
      op: this.op,
      spec: this.spec,
      entity: this.entity,
      result: this.result,
      response: this.response,
      meta: this.meta,
    }
  }

  toString() {
    return 'Context ' + this.utility?.struct.jsonify(this.toJSON())
  }

  [inspect.custom]() {
    return this.toString()
  }

}


module.exports = {
  Context,
}
