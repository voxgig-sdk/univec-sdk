

class ProjectNameError extends Error {

  isProjectNameError = true

  sdk = 'ProjectName'

  constructor(code, msg, ctx) {
    super(msg)
    this.code = code
    // Reachable for a debugger, invisible to a serialiser: the context holds
    // the live spec and options, and an error is what gets logged.
    Object.defineProperty(this, 'ctx', { value: ctx, enumerable: false, writable: true })

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


  // What makeError attached is already cleaned; the context is not part of
  // the record.
  toJSON() {
    return {
      sdk: this.sdk,
      code: this.code,
      message: this.message,
      status: this.status,
      result: this.result,
      spec: this.spec,
    }
  }

}

module.exports = {
  ProjectNameError
}

