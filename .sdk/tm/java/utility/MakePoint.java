package JAVAPACKAGE.utility;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.Operation;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
final class MakePoint {

  private MakePoint() {}

  // How many path segments a point has.
  private static int partsLen(Map<String, Object> point) {
    Object parts = Struct.getprop(point, "parts");
    return parts instanceof List ? ((List<Object>) parts).size() : 0;
  }

  // Does this point's path end in a parameter? A record route ends in the
  // record's identifier (/boards/{id}); a cross-reference that also returns
  // the entity ends in the relationship's name (/posts/{id}/author). That,
  // then fewest segments, is what tells the entity's own route from a
  // cross-reference. The same rule runs at generation time, in
  // helpers/opShape.ts — both sides must move together.
  private static boolean terminalParam(Map<String, Object> point) {
    Object parts = Struct.getprop(point, "parts");
    if (!(parts instanceof List)) {
      return false;
    }
    List<Object> list = (List<Object>) parts;
    if (list.isEmpty()) {
      return false;
    }
    Object last = list.get(list.size() - 1);
    return last instanceof String && ((String) last).startsWith("{");
  }

  private static final java.util.regex.Pattern PATH_PARAM =
      java.util.regex.Pattern.compile("\\{([^{}/]+)\\}");

  // The path parameters of a point that neither the call nor the entity gives
  // a value for, looked up as prepareParams looks them up.
  private static List<String> unfilled(Context ctx, Map<String, Object> point) {
    List<String> missing = new ArrayList<>();
    Object parts = Struct.getprop(point, "parts");
    if (parts instanceof List) {
      for (Object part : (List<Object>) parts) {
        java.util.regex.Matcher found = PATH_PARAM.matcher(String.valueOf(part));
        if (found.matches() && Param.paramValue(ctx, point, found.group(1)) == null) {
          missing.add(found.group(1));
        }
      }
    }
    return missing;
  }

  private static Map<String, Object> ownPoint(List<Map<String, Object>> points) {
    Map<String, Object> best = points.get(0);
    for (Map<String, Object> cand : points) {
      boolean candTerm = terminalParam(cand);
      boolean bestTerm = terminalParam(best);
      if (candTerm != bestTerm) {
        if (candTerm) {
          best = cand;
        }
      } else if (partsLen(cand) < partsLen(best)) {
        best = cand;
      }
    }
    return best;
  }

  static Map<String, Object> makePoint(Context ctx) {
    Object outPoint = ctx.out.get("point");
    if (outPoint != null) {
      // A PrePoint feature hook (e.g. rbac) may short-circuit the
      // operation by storing an error here; surface it before any
      // endpoint resolution or network activity.
      if (outPoint instanceof RuntimeException) {
        throw (RuntimeException) outPoint;
      }
      if (outPoint instanceof Map) {
        ctx.point = (Map<String, Object>) outPoint;
        return ctx.point;
      }
    }

    Operation op = ctx.op;
    Map<String, Object> options = ctx.options;

    Object allowOpRaw = Struct.getpath(options, List.of("allow", "op"));
    String allowOp = allowOpRaw instanceof String ? (String) allowOpRaw : "";
    if (!Helpers.allowed(allowOpRaw, op.name)) {
      throw ctx.makeError("point_op_allow",
          "Operation \"" + op.name
              + "\" not allowed by SDK option allow.op value: \"" + allowOp + "\"");
    }

    if (op.points.isEmpty()) {
      throw ctx.makeError("point_no_points",
          "Operation \"" + op.name + "\" has no endpoint definitions.");
    }

    if (op.points.size() == 1) {
      ctx.point = op.points.get(0);
    }
    else {
      Map<String, Object> reqselector;
      Map<String, Object> selector;

      if ("data".equals(op.input)) {
        reqselector = ctx.reqdata;
        selector = ctx.data;
      }
      else {
        reqselector = ctx.reqmatch;
        selector = ctx.match;
      }

      Map<String, Object> point = null;
      boolean matched = false;
      for (int i = 0; i < op.points.size(); i++) {
        Map<String, Object> cand = op.points.get(i);
        Map<String, Object> selectDef =
            Helpers.toMapAny(Struct.getprop(cand, "select"));
        boolean found = true;

        if (selector != null && selectDef != null) {
          Object exist = Struct.getprop(selectDef, "exist");
          if (exist instanceof List) {
            for (Object ek : (List<Object>) exist) {
              String existkey = ek instanceof String ? (String) ek : "";
              Object rv = Struct.getprop(reqselector, existkey, null);
              Object sv = Struct.getprop(selector, existkey, null);
              if (rv == null && sv == null) {
                found = false;
                break;
              }
            }
          }
        }

        if (found) {
          Object reqAction = Struct.getprop(reqselector, "$action", null);
          Object selectAction = Struct.getprop(selectDef, "$action", null);
          if (!java.util.Objects.equals(reqAction, selectAction)) {
            found = false;
          }
        }

        if (found) {
          point = cand;
          matched = true;
          break;
        }
      }

      // select.exist can list more than the params needed to pick a point, so
      // nothing matches — fall back to the entity's own route rather than
      // whichever point came last.
      if (!matched) {
        // A request naming an action reaches here only because that action's
        // own point failed its exist test, so it is unbuildable whatever we
        // pick. Refuse it BEFORE choosing a fallback: the guard below
        // compares the chosen point's $action and would wave the request
        // through whenever the fallback lands on the action point itself.
        Object unmatchedAction =
            reqselector != null ? Struct.getprop(reqselector, "$action", null) : null;
        if (unmatchedAction != null) {
          throw ctx.makeError("point_action_invalid",
              "Operation \"" + op.name
                  + "\" action \"" + Struct.stringify(unmatchedAction) + "\" is not valid.");
        }

        // A call without an action falls back to a point without one, as
        // generation does, and only to a route the call can fill.
        List<Map<String, Object>> plain = new ArrayList<>();
        for (Map<String, Object> cand : op.points) {
          Map<String, Object> candSelect = Helpers.toMapAny(Struct.getprop(cand, "select"));
          if (Struct.getprop(candSelect, "$action", null) == null) {
            plain.add(cand);
          }
        }
        if (plain.isEmpty()) {
          throw ctx.makeError("point_action_required",
              "Operation \"" + op.name
                  + "\" has only action endpoints; pass $action to choose one.");
        }
        List<Map<String, Object>> fillable = new ArrayList<>();
        for (Map<String, Object> cand : plain) {
          if (unfilled(ctx, cand).isEmpty()) {
            fillable.add(cand);
          }
        }

        if (fillable.isEmpty()) {
          throw ctx.makeError("point_no_match",
              "Operation \"" + op.name
                  + "\" has no endpoint whose path parameters are all given (missing: "
                  + String.join(", ", unfilled(ctx, ownPoint(plain))) + ").");
        }

        point = ownPoint(fillable);
      }

      if (reqselector != null) {
        Object reqAction = Struct.getprop(reqselector, "$action", null);
        if (reqAction != null && point != null) {
          Map<String, Object> pointSelect =
              Helpers.toMapAny(Struct.getprop(point, "select"));
          Object pointAction = Struct.getprop(pointSelect, "$action", null);
          if (!java.util.Objects.equals(reqAction, pointAction)) {
            throw ctx.makeError("point_action_invalid",
                "Operation \"" + op.name
                    + "\" action \"" + Struct.stringify(reqAction) + "\" is not valid.");
          }
        }
      }

      ctx.point = point;
    }

    return ctx.point;
  }
}
