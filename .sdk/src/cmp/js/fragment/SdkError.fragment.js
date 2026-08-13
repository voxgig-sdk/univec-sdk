

class ProjectNameError extends Error {

  isProjectNameError = true

  sdk = 'ProjectName'

  constructor(code, msg, ctx) {
    super(msg)
    this.code = code
    this.ctx = ctx

    // HTTP status of the response that caused this error, or -1 when the
    // request never got one (transport failure, client-side abort).
    //
    // PROMOTED to the top level on purpose. It used to be reachable only at
    // `err.result.status`, so every consumer wrote the same
    // `404 === e?.result?.status` branch and coupled itself to the internal
    // shape of `result`.
    this.status = -1
  }


  // `err.notFound` rather than a magic number at every call site.
  get notFound() { return 404 === this.status }

}

module.exports = {
  ProjectNameError
}

