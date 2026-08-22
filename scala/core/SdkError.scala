package voxgig.univecsdk.core

// Univec SDK error. Carries the SDK error code, the operation context,
// and cleaned copies of the result and spec at failure time.
class SdkError(code0: String, msg0: String, ctx0: Context) extends RuntimeException(msg0) {

  val sdk: String = "Univec"
  var code: String = if (code0 == null) "" else code0
  var msg: String = msg0
  @transient var ctx: Context = ctx0
  @transient var result: Object = null
  @transient var spec: Object = null

  override def getMessage: String = this.msg
}
