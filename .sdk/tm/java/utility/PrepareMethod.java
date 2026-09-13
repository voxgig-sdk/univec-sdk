package JAVAPACKAGE.utility;

import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.utility.struct.Struct;

final class PrepareMethod {

  private PrepareMethod() {}

  private static final Map<String, String> METHOD_MAP = Map.of(
      "create", "POST",
      "update", "PUT",
      "load", "GET",
      "list", "GET",
      "remove", "DELETE",
      "patch", "PATCH");

  static String prepareMethod(Context ctx) {
    String opname = ctx.op.name;

    // The API definition is authoritative: a POST-only or PATCH-based API
    // exposes `update` as POST or PATCH, not the PUT the op name implies.
    // Only fall back to the op-name convention when the point has no method.
    Object pm = Struct.getprop(ctx.point, "method");
    if (pm instanceof String && !((String) pm).isEmpty()) {
      return ((String) pm).toUpperCase();
    }

    // No default: an op name outside the convention resolves to NO method,
    // exactly as the ts reference (`methodMap[key]` is undefined there).
    // The silent-pass engine hid a stray "GET" fallback here; the shared
    // corpus (prepareMethod, opname "bad" -> null) pins it now.
    return METHOD_MAP.get(opname);
  }
}
