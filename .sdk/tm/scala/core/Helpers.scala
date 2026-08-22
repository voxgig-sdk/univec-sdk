package SCALAPACKAGE.core

// Small shared conversions used across the Univec SDK runtime.

import java.util.{LinkedHashMap, Map => JMap}

object Helpers {

  // unsupportedOp is thrown by entity stub methods for operations the
  // underlying API spec doesn't define. The static SdkEntity contract
  // requires every CRUD method on every entity, so absent ops must still be
  // callable — they error at runtime instead of failing to compile.
  def unsupportedOp(opname: String, entityname: String): SdkError =
    new SdkError("op_unsupported",
      "operation '" + opname + "' not supported by entity '" + entityname + "'", null)

  def toMapAny(v: Object): JMap[String, Object] = v match {
    case null => null
    case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
    case _ => null
  }

  def toInt(v: Object): Int = v match {
    case n: java.lang.Number => n.intValue()
    case _ => -1
  }

  def toLong(v: Object, dflt: Long): Long = v match {
    case n: java.lang.Number => n.longValue()
    case _ => dflt
  }

  def getCtxProp(m: JMap[String, Object], key: String): Object =
    if (m == null) null else m.get(key)

  // Convenience mutable-map/list constructors (java.util for Struct interop).
  def jmap(): LinkedHashMap[String, Object] = new LinkedHashMap[String, Object]()
}
