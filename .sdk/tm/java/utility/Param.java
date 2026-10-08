package JAVAPACKAGE.utility;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.utility.struct.Struct;

final class Param {

  private Param() {}

  static Object param(Context ctx, Object paramdef) {
    int pt = Struct.typify(paramdef);

    String key;
    if (0 < (Struct.T_string & pt)) {
      key = paramdef instanceof String ? (String) paramdef : "";
    }
    else {
      Object k = Struct.getprop(paramdef, "name");
      key = k instanceof String ? (String) k : "";
    }

    String akey = alias(ctx.point, key);
    if (ctx.spec != null && !"".equals(akey)
        && Struct.getprop(ctx.reqmatch, key, null) == null
        && Struct.getprop(ctx.match, key, null) == null) {
      ctx.spec.alias.put(akey, key);
    }

    return paramValue(ctx, ctx.point, key);
  }

  // The name a point gives a parameter in the call, if it renames it.
  private static String alias(Map<String, Object> point, String key) {
    if (point != null) {
      Map<String, Object> alias = Helpers.toMapAny(Struct.getprop(point, "alias"));
      if (alias != null) {
        Object ak = Struct.getprop(alias, key);
        if (ak instanceof String) {
          return (String) ak;
        }
      }
    }
    return "";
  }

  // The value the call or its entity gives a point's parameter, under its
  // name or the point's alias for it.
  static Object paramValue(Context ctx, Map<String, Object> point, String key) {
    String akey = alias(point, key);

    Object val = Struct.getprop(ctx.reqmatch, key, null);

    if (val == null) {
      val = Struct.getprop(ctx.match, key, null);
    }

    if (val == null && !"".equals(akey)) {
      val = Struct.getprop(ctx.reqmatch, akey, null);
    }

    if (val == null) {
      val = Struct.getprop(ctx.reqdata, key, null);
    }

    if (val == null) {
      val = Struct.getprop(ctx.data, key, null);
    }

    if (val == null && !"".equals(akey)) {
      val = Struct.getprop(ctx.reqdata, akey, null);
      if (val == null) {
        val = Struct.getprop(ctx.data, akey, null);
      }
    }

    return val;
  }

  // One argument a point declares, with the name it travels under and the
  // value the call passes for it.
  record CallArg(String name, String wire, Object val) {}

  // The arguments a point declares in one location, query or header, each
  // with the name it travels under and the value this call passes in its
  // match or else its data. Unlike a path parameter, the entity's stored
  // match and data never supply one.
  @SuppressWarnings("unchecked")
  static List<CallArg> callArgs(Context ctx, String kind) {
    List<CallArg> out = new ArrayList<>();
    Object defs = ctx.point == null ? null : Struct.getpath(ctx.point, List.of("args", kind));
    if (defs instanceof List) {
      for (Object ad : (List<Object>) defs) {
        Object name = Struct.getprop(ad, "name", null);
        if (!(name instanceof String) || ((String) name).isEmpty()) {
          continue;
        }
        Object orig = Struct.getprop(ad, "orig", null);
        String wire = orig instanceof String && !((String) orig).isEmpty() ? (String) orig : (String) name;
        Object val = ctx.reqmatch == null ? null : Struct.getprop(ctx.reqmatch, name, null);
        if (val == null && ctx.reqdata != null) {
          val = Struct.getprop(ctx.reqdata, name, null);
        }
        out.add(new CallArg((String) name, wire, val));
      }
    }
    return out;
  }
}
