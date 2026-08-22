package SCALAPACKAGE.core

import java.util.{Map => JMap}
import java.util.function.Supplier
import SCALAPACKAGE.utility.struct.Struct

// A transport-level response (thin wrapper over the fetcher's map shape).
class Response(resmap: JMap[String, Object]) {

  var status: Int = -1
  var statusText: String = ""
  var headers: Object = null
  var jsonFunc: Supplier[Object] = null
  var body: Object = null
  var err: RuntimeException = null

  locally {
    val s = Struct.getprop(resmap, "status")
    if (s != null) status = Helpers.toInt(s)

    Struct.getprop(resmap, "statusText") match { case st: String => statusText = st; case _ => }

    headers = Struct.getprop(resmap, "headers", null)

    Struct.getprop(resmap, "json") match {
      case jf: Supplier[_] => jsonFunc = jf.asInstanceOf[Supplier[Object]]
      case _ =>
    }

    body = Struct.getprop(resmap, "body", null)

    Struct.getprop(resmap, "err") match {
      case e: RuntimeException => err = e
      case _ =>
    }
  }
}
