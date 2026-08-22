package JAVAPACKAGE.utility;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
final class PrepareParams {

  private PrepareParams() {}

  static Map<String, Object> prepareParams(Context ctx) {
    Utility utility = ctx.utility;
    Map<String, Object> point = ctx.point;

    List<Object> params = null;
    Map<String, Object> argsMap = Helpers.toMapAny(Struct.getprop(point, "args"));
    if (argsMap != null) {
      Object p = Struct.getprop(argsMap, "params");
      if (p instanceof List) {
        params = (List<Object>) p;
      }
    }
    if (params == null) {
      params = new ArrayList<>();
    }

    Map<String, Object> out = new LinkedHashMap<>();
    for (Object pd : params) {
      Object val = utility.param.apply(ctx, pd);
      if (val != null) {
        Map<String, Object> pdm = Helpers.toMapAny(pd);
        if (pdm != null) {
          Object name = Struct.getprop(pdm, "name");
          if (name instanceof String && !"".equals(name)) {
            out.put((String) name, val);
          }
        }
      }
    }

    return out;
  }
}
