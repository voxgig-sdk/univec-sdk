package SCALAPACKAGE.core

import java.util.{Iterator => JIterator, LinkedHashMap, Map => JMap}
import java.util.function.Supplier
import SCALAPACKAGE.utility.struct.Struct

// The processed outcome of one operation.
class Result(resmap: JMap[String, Object]) {

  var ok: Boolean = false
  var status: Int = -1
  var statusText: String = ""
  var headers: JMap[String, Object] = new LinkedHashMap[String, Object]()
  var body: Object = null
  var err: RuntimeException = null
  var resdata: Object = null
  var resmatch: JMap[String, Object] = null

  // Feature extensions: pagination signals (paging feature) and the
  // incremental item iterator (streaming feature).
  var paging: JMap[String, Object] = null
  var streaming: Boolean = false
  var stream: Supplier[JIterator[Object]] = null

  locally {
    Struct.getprop(resmap, "ok") match { case b: java.lang.Boolean => ok = b.booleanValue(); case _ => }

    val s = Struct.getprop(resmap, "status")
    if (s != null) status = Helpers.toInt(s)

    Struct.getprop(resmap, "statusText") match { case st: String => statusText = st; case _ => }
    Struct.getprop(resmap, "headers") match { case h: JMap[_, _] => headers = h.asInstanceOf[JMap[String, Object]]; case _ => }

    body = Struct.getprop(resmap, "body", null)

    Struct.getprop(resmap, "err") match { case e: RuntimeException => err = e; case _ => }

    resdata = Struct.getprop(resmap, "resdata", null)

    Struct.getprop(resmap, "resmatch") match { case rm: JMap[_, _] => resmatch = rm.asInstanceOf[JMap[String, Object]]; case _ => }
  }
}
