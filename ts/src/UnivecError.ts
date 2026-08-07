
import { Context } from './Context'


class UnivecError extends Error {

  isUnivecError = true

  sdk = 'Univec'

  code: string
  ctx: Context

  constructor(code: string, msg: string, ctx: Context) {
    super(msg)
    this.code = code
    this.ctx = ctx
  }

}

export {
  UnivecError
}

