package KOTLINPACKAGE.core

import java.util.function.Supplier

import KOTLINPACKAGE.utility.struct.Struct

/** A transport-level response (thin wrapper over the fetcher's map shape). */
@Suppress("UNCHECKED_CAST")
class Response(resmap: Map<String, Any?>?) {

  var status: Int = -1
  var statusText: String = ""
  var headers: Any? = null
  var jsonFunc: Supplier<Any?>? = null
  var body: Any? = null
  var err: RuntimeException? = null

  init {
    val s = Struct.getprop(resmap, "status")
    if (s is Number) {
      this.status = Helpers.toInt(s)
    }

    val st = Struct.getprop(resmap, "statusText")
    if (st is String) {
      this.statusText = st
    }

    this.headers = Struct.getprop(resmap, "headers", null)

    val jf = Struct.getprop(resmap, "json")
    if (jf is Supplier<*>) {
      this.jsonFunc = jf as Supplier<Any?>
    }

    this.body = Struct.getprop(resmap, "body", null)

    val e = Struct.getprop(resmap, "err")
    if (e is RuntimeException) {
      this.err = e
    }
  }
}
