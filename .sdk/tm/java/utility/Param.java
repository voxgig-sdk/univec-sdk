package JAVAPACKAGE.utility;

import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.utility.struct.Struct;

final class Param {

  private Param() {}

  static Object param(Context ctx, Object paramdef) {
    Map<String, Object> point = ctx.point;
    Spec spec = ctx.spec;
    Map<String, Object> match = ctx.match;
    Map<String, Object> reqmatch = ctx.reqmatch;
    Map<String, Object> data = ctx.data;
    Map<String, Object> reqdata = ctx.reqdata;

    int pt = Struct.typify(paramdef);

    String key;
    if (0 < (Struct.T_string & pt)) {
      key = paramdef instanceof String ? (String) paramdef : "";
    }
    else {
      Object k = Struct.getprop(paramdef, "name");
      key = k instanceof String ? (String) k : "";
    }

    String akey = "";
    if (point != null) {
      Map<String, Object> alias = Helpers.toMapAny(Struct.getprop(point, "alias"));
      if (alias != null) {
        Object ak = Struct.getprop(alias, key);
        if (ak instanceof String) {
          akey = (String) ak;
        }
      }
    }

    Object val = Struct.getprop(reqmatch, key, null);

    if (val == null) {
      val = Struct.getprop(match, key, null);
    }

    if (val == null && !"".equals(akey)) {
      if (spec != null) {
        spec.alias.put(akey, key);
      }
      val = Struct.getprop(reqmatch, akey, null);
    }

    if (val == null) {
      val = Struct.getprop(reqdata, key, null);
    }

    if (val == null) {
      val = Struct.getprop(data, key, null);
    }

    if (val == null && !"".equals(akey)) {
      val = Struct.getprop(reqdata, akey, null);
      if (val == null) {
        val = Struct.getprop(data, akey, null);
      }
    }

    return val;
  }
}
