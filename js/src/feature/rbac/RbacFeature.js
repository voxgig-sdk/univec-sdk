

const { BaseFeature } = require('../base/BaseFeature')


// Client-side role/permission enforcement. Before an operation resolves its
// endpoint, the required permission for that entity+operation is checked
// against the permissions the client holds; a disallowed call is
// short-circuited with an `rbac_denied` error and never touches the
// network. Required permissions come from `rules` (keyed by
// `<entity>.<op>`, `<op>`, or `*`); the default when no rule matches is
// controlled by `deny` (default: allow when unspecified). Held permissions
// are the `permissions` list (a `*` grants everything).
class RbacFeature extends BaseFeature {
  version = '0.0.1'
  name = 'rbac'
  active = true

  _client
  _options = {}
  _granted = {}


  init(ctx, options) {
    this._client = ctx.client
    this._options = options || {}
    this.active = options.active

    this._granted = {}
    const perms = this._options.permissions || []
    for (const p of perms) {
      this._granted[p] = true
    }
  }


  PrePoint(ctx) {
    if (!this.active) {
      return
    }

    const required = this._required(ctx)
    if (null == required) {
      // No rule: honour the default policy.
      if (true === this._options.deny) {
        return this._reject(ctx, '<default-deny>')
      }
      return
    }

    if (this._granted['*'] || this._granted[required]) {
      this._track(ctx, required, true)
      return
    }

    return this._reject(ctx, required)
  }


  _required(ctx) {
    const rules = this._options.rules || {}
    const entity = (ctx.entity && ctx.entity.name) || (ctx.op && ctx.op.entity) || ''
    const opname = (ctx.op && ctx.op.name) || ''

    if (null != rules[entity + '.' + opname]) {
      return rules[entity + '.' + opname]
    }
    if (null != rules[opname]) {
      return rules[opname]
    }
    if (null != rules['*']) {
      return rules['*']
    }
    return null
  }


  _reject(ctx, required) {
    this._track(ctx, required, false)
    const err = ctx.error('rbac_denied',
      'Permission "' + required + '" required for operation "' +
      ((ctx.op && ctx.op.name) || '?') + '"')
    // Short-circuit endpoint resolution; the pipeline surfaces this error.
    ctx.out.point = err
    return err
  }


  _track(ctx, required, allowed) {
    const client = this._client
    if (null == client._rbac) {
      client._rbac = { allowed: 0, denied: 0, last: undefined }
    }
    client._rbac[allowed ? 'allowed' : 'denied']++
    client._rbac.last = { required, allowed, op: ctx.op && ctx.op.name }
  }
}


module.exports = {
  RbacFeature
}
