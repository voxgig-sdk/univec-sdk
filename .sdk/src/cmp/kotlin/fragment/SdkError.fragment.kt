package KOTLINPACKAGE.core

import KOTLINPACKAGE.utility.struct.Struct

/**
 * ProjectName SDK error. Carries the SDK error code, the operation context,
 * and cleaned copies of the result and spec at failure time.
 */
class SdkError(code: String?, msg: String, ctx: Context?) : RuntimeException(msg) {

  val sdk: String = "ProjectName"
  var code: String = code ?: ""
  var msg: String = msg

  // The HTTP status when there was a response, -1 otherwise.
  var status: Int = -1

  // Reachable for a debugger, out of every serialisation: the context holds
  // the live spec and options, and an error is what gets logged.
  @Transient
  var ctx: Context? = ctx

  @Transient
  var result: Any? = null

  @Transient
  var spec: Any? = null

  val notFound: Boolean
    get() = 404 == this.status

  override val message: String
    get() = this.msg

  // What makeError attached is already cleaned; the context is not part of
  // the record.
  fun toMap(): MutableMap<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    out["sdk"] = this.sdk
    out["code"] = this.code
    out["message"] = this.msg
    out["status"] = this.status
    out["result"] = this.result
    out["spec"] = this.spec
    return out
  }

  fun toJson(): String {
    return Struct.jsonify(this.toMap())
  }

  override fun toString(): String {
    return "ProjectNameError " + this.toJson()
  }
}
