package KOTLINPACKAGE.core

/**
 * ProjectName SDK error. Carries the SDK error code, the operation context,
 * and cleaned copies of the result and spec at failure time.
 */
class SdkError(code: String?, msg: String, ctx: Context?) : RuntimeException(msg) {

  val sdk: String = "ProjectName"
  var code: String = code ?: ""
  var msg: String = msg

  @Transient
  var ctx: Context? = ctx

  @Transient
  var result: Any? = null

  @Transient
  var spec: Any? = null

  override val message: String
    get() = this.msg
}
