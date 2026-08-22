package voxgig.univecsdk.core

/** Small shared conversions used across the Univec SDK runtime. */
object Helpers {

  // unsupportedOp is thrown by entity stub methods for operations the
  // underlying API spec doesn't define. The static SdkEntity interface
  // requires every CRUD method on every entity, so absent ops must still be
  // callable — they error at runtime instead of failing to compile.
  fun unsupportedOp(opname: String, entityname: String): SdkError {
    return SdkError(
      "op_unsupported",
      "operation '" + opname + "' not supported by entity '" + entityname + "'",
      null,
    )
  }

  @Suppress("UNCHECKED_CAST")
  fun toMapAny(v: Any?): MutableMap<String, Any?>? {
    if (v == null) {
      return null
    }
    if (v is MutableMap<*, *>) {
      return v as MutableMap<String, Any?>
    }
    return null
  }

  fun toInt(v: Any?): Int {
    if (v is Number) {
      return v.toInt()
    }
    return -1
  }

  fun toLong(v: Any?, def: Long): Long {
    if (v is Number) {
      return v.toLong()
    }
    return def
  }

  fun getCtxProp(m: Map<String, Any?>?, key: String): Any? {
    if (m == null) {
      return null
    }
    return m[key]
  }
}
