package JAVAPACKAGE.core;

import java.util.Map;

/** Small shared conversions used across the Univec SDK runtime. */
@SuppressWarnings({"unchecked"})
public final class Helpers {

  private Helpers() {}

  // unsupportedOp is thrown by entity stub methods for operations the
  // underlying API spec doesn't define. The static SdkEntity interface
  // requires every CRUD method on every entity, so absent ops must still be
  // callable — they error at runtime instead of failing to compile.
  public static SdkError unsupportedOp(String opname, String entityname) {
    return new SdkError("op_unsupported",
        "operation '" + opname + "' not supported by entity '" + entityname + "'", null);
  }

  public static Map<String, Object> toMapAny(Object v) {
    if (v == null) {
      return null;
    }
    if (v instanceof Map) {
      return (Map<String, Object>) v;
    }
    return null;
  }

  public static int toInt(Object v) {
    if (v instanceof Number) {
      return ((Number) v).intValue();
    }
    return -1;
  }

  public static long toLong(Object v, long def) {
    if (v instanceof Number) {
      return ((Number) v).longValue();
    }
    return def;
  }

  static Object getCtxProp(Map<String, Object> m, String key) {
    if (m == null) {
      return null;
    }
    return m.get(key);
  }
}
