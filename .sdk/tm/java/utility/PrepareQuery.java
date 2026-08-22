package JAVAPACKAGE.utility;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
final class PrepareQuery {

  private PrepareQuery() {}

  static Map<String, Object> prepareQuery(Context ctx) {
    Map<String, Object> point = ctx.point;
    Map<String, Object> reqmatch = ctx.reqmatch;
    if (reqmatch == null) {
      reqmatch = new LinkedHashMap<>();
    }

    List<Object> params = null;
    if (point != null) {
      Object p = Struct.getprop(point, "params");
      if (p instanceof List) {
        params = (List<Object>) p;
      }
    }
    if (params == null) {
      params = new ArrayList<>();
    }

    Map<String, Object> out = new LinkedHashMap<>();
    for (List<Object> item : Struct.items(reqmatch)) {
      String key = item.get(0) instanceof String ? (String) item.get(0) : "";
      Object val = item.get(1);
      if (val != null && !containsStr(params, key)) {
        out.put(key, val);
      }
    }

    return out;
  }

  private static boolean containsStr(List<Object> list, String s) {
    for (Object v : list) {
      if (v instanceof String && v.equals(s)) {
        return true;
      }
    }
    return false;
  }
}
