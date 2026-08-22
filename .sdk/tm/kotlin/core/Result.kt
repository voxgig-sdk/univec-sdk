package KOTLINPACKAGE.core

import java.util.function.Supplier

import KOTLINPACKAGE.utility.struct.Struct

/** The processed outcome of one operation. */
@Suppress("UNCHECKED_CAST")
class Result(resmap: Map<String, Any?>?) {

  var ok: Boolean = false
  var status: Int = -1
  var statusText: String = ""
  var headers: MutableMap<String, Any?> = linkedMapOf()
  var body: Any? = null
  var err: RuntimeException? = null
  var resdata: Any? = null
  var resmatch: MutableMap<String, Any?>? = null

  // Feature extensions: pagination signals (paging feature) and the
  // incremental item iterator (streaming feature).
  var paging: MutableMap<String, Any?>? = null
  var streaming: Boolean = false
  var stream: Supplier<Iterator<Any?>>? = null

  init {
    val o = Struct.getprop(resmap, "ok")
    if (o is Boolean) {
      this.ok = o
    }

    val s = Struct.getprop(resmap, "status")
    if (s is Number) {
      this.status = Helpers.toInt(s)
    }

    val st = Struct.getprop(resmap, "statusText")
    if (st is String) {
      this.statusText = st
    }

    val h = Struct.getprop(resmap, "headers")
    if (h is MutableMap<*, *>) {
      this.headers = h as MutableMap<String, Any?>
    }

    this.body = Struct.getprop(resmap, "body", null)

    val e = Struct.getprop(resmap, "err")
    if (e is RuntimeException) {
      this.err = e
    }

    this.resdata = Struct.getprop(resmap, "resdata", null)

    val rm = Struct.getprop(resmap, "resmatch")
    if (rm is MutableMap<*, *>) {
      this.resmatch = rm as MutableMap<String, Any?>
    }
  }
}
