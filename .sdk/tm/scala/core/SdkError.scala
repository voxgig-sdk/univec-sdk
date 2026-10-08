package SCALAPACKAGE.core

import java.util.{LinkedHashMap, Map => JMap}
import SCALAPACKAGE.utility.struct.Struct

// Univec SDK error. Carries the SDK error code, the operation context,
// and cleaned copies of the result and spec at failure time.
class SdkError(code0: String, msg0: String, ctx0: Context) extends RuntimeException(msg0) {

  val sdk: String = "Univec"
  var code: String = if (code0 == null) "" else code0
  var msg: String = msg0

  // The HTTP status when there was a response, -1 otherwise.
  var status: Int = -1

  // Reachable for a debugger, out of every serialisation: the context holds
  // the live spec and options, and an error is what gets logged.
  @transient var ctx: Context = ctx0
  @transient var result: Object = null
  @transient var spec: Object = null

  def notFound: Boolean = 404 == this.status

  override def getMessage: String = this.msg

  // What makeError attached is already cleaned; the context is not part of
  // the record.
  def toMap(): JMap[String, Object] = {
    val out = new LinkedHashMap[String, Object]()
    out.put("sdk", this.sdk)
    out.put("code", this.code)
    out.put("message", this.msg)
    out.put("status", java.lang.Integer.valueOf(this.status))
    out.put("result", this.result)
    out.put("spec", this.spec)
    out
  }

  def toJson(): String = Struct.jsonify(this.toMap())

  override def toString: String = "UnivecError " + this.toJson()
}
