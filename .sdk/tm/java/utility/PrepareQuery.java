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

    List<Object> params = new ArrayList<>();
    if (point != null) {
      Object p = Struct.getprop(point, "params");
      if (p instanceof List) {
        params.addAll((List<Object>) p);
      }
      // A path parameter travels in the path. The generated config lists them
      // as args.params, which prepareParams reads; params is the older list.
      Object pl = Struct.getpath(point, List.of("args", "params"));
      if (pl instanceof List) {
        for (Object pd : (List<Object>) pl) {
          Object name = Struct.getprop(pd, "name");
          if (name instanceof String) {
            params.add(name);
          }
        }
      }
      // A header or cookie parameter travels in the headers, which prepareHeaders
      // fills, unless a query parameter shares its name: then both are sent.
      List<Object> declared = new ArrayList<>();
      Object dl = Struct.getpath(point, List.of("args", "query"));
      if (dl instanceof List) {
        for (Object qd : (List<Object>) dl) {
          declared.add(Struct.getprop(qd, "name"));
        }
      }
      Object hl = Struct.getpath(point, List.of("args", "header"));
      if (hl instanceof List) {
        for (Object hd : (List<Object>) hl) {
          Object name = Struct.getprop(hd, "name");
          if (name instanceof String && !declared.contains(name)) {
            params.add(name);
          }
        }
      }
      Object cl = Struct.getpath(point, List.of("args", "cookie"));
      if (cl instanceof List) {
        for (Object cd : (List<Object>) cl) {
          Object name = Struct.getprop(cd, "name");
          if (name instanceof String && !declared.contains(name)) {
            params.add(name);
          }
        }
      }
    }

    // A query parameter travels under the name the definition gives it, its
    // orig, which the model may have renamed for the caller.
    Map<String, String> wire = new LinkedHashMap<>();
    if (point != null) {
      Object ql = Struct.getpath(point, List.of("args", "query"));
      if (ql instanceof List) {
        for (Object qd : (List<Object>) ql) {
          Object name = Struct.getprop(qd, "name");
          Object orig = Struct.getprop(qd, "orig");
          if (name instanceof String && orig instanceof String && !((String) orig).isEmpty()) {
            wire.put((String) name, (String) orig);
          }
        }
      }
    }

    Map<String, Object> out = new LinkedHashMap<>();
    for (List<Object> item : Struct.items(reqmatch)) {
      String key = item.get(0) instanceof String ? (String) item.get(0) : "";
      Object val = item.get(1);
      if (val != null && !"$action".equals(key) && !containsStr(params, key)) {
        out.put(wire.getOrDefault(key, key), val);
      }
    }

    // A create or update passes its query arguments in its data.
    for (Param.CallArg arg : Param.callArgs(ctx, "query")) {
      if (arg.val() != null && !containsStr(params, arg.name())) {
        out.put(arg.wire(), arg.val());
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
