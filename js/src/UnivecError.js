

class UnivecError extends Error {

  isUnivecError = true

  sdk = 'Univec'

  constructor(code, msg, ctx) {
    super(msg)
    this.code = code
    this.ctx = ctx
  }

}

module.exports = {
  UnivecError
}

