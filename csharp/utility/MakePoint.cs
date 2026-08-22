// Univec SDK utility: makePoint - endpoint resolution.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    // How many path segments a point has.
    private static int PartsLen(Dictionary<string, object?>? point)
    {
        return StructUtils.GetProp(point, "parts") is List<object?> parts ? parts.Count : 0;
    }

    // Does this point's path end in a parameter? A record route ends in the
    // record's identifier (/boards/{id}); a cross-reference that also returns
    // the entity ends in the relationship's name (/posts/{id}/author). That,
    // then fewest segments, is what tells the entity's own route from a
    // cross-reference. The same rule runs at generation time, in
    // helpers/opShape.ts — both sides must move together.
    private static bool TerminalParam(Dictionary<string, object?>? point)
    {
        if (StructUtils.GetProp(point, "parts") is not List<object?> parts || parts.Count == 0)
        {
            return false;
        }
        return parts[parts.Count - 1] is string last && last.StartsWith("{");
    }

    internal static Dictionary<string, object?>? MakePointUtil(Context ctx)
    {
        if (ctx.Out.TryGetValue("point", out var outPoint) && outPoint != null)
        {
            // A PrePoint feature hook (e.g. rbac) may short-circuit the
            // operation by storing an error here; surface it before any
            // endpoint resolution or network activity.
            if (outPoint is Exception err)
            {
                throw err;
            }
            if (outPoint is Dictionary<string, object?> tm)
            {
                ctx.Point = tm;
                return tm;
            }
        }

        var op = ctx.Op!;
        var options = ctx.Options;

        var allowOp = StructUtils.GetPath(options, StructUtils.Jt("allow", "op")) as string ?? "";
        if (!allowOp.Contains(op.Name))
        {
            throw ctx.MakeError("point_op_allow",
                "Operation \"" + op.Name +
                "\" not allowed by SDK option allow.op value: \"" + allowOp + "\"");
        }

        if (op.Points.Count == 0)
        {
            throw ctx.MakeError("point_no_points",
                "Operation \"" + op.Name + "\" has no endpoint definitions.");
        }

        if (op.Points.Count == 1)
        {
            ctx.Point = op.Points[0];
        }
        else
        {
            Dictionary<string, object?>? reqselector;
            Dictionary<string, object?>? selector;

            if (op.Input == "data")
            {
                reqselector = ctx.Reqdata;
                selector = ctx.Data;
            }
            else
            {
                reqselector = ctx.Reqmatch;
                selector = ctx.Match;
            }

            Dictionary<string, object?>? point = null;
            var matched = false;
            foreach (var candidate in op.Points)
            {
                var selectDef = Helpers.ToMapAny(StructUtils.GetProp(candidate, "select"));
                var found = true;

                if (selector != null && selectDef != null)
                {
                    if (StructUtils.GetProp(selectDef, "exist") is List<object?> existList)
                    {
                        foreach (var ek in existList)
                        {
                            var existkey = ek as string;
                            var rv = StructUtils.GetProp(reqselector, existkey);
                            var sv = StructUtils.GetProp(selector, existkey);
                            if (rv == null && sv == null)
                            {
                                found = false;
                                break;
                            }
                        }
                    }
                }

                if (found)
                {
                    var reqAction = StructUtils.GetProp(reqselector, "$action");
                    var selectAction = StructUtils.GetProp(selectDef, "$action");
                    if (!Equals(reqAction, selectAction))
                    {
                        found = false;
                    }
                }

                if (found)
                {
                    point = candidate;
                    matched = true;
                    break;
                }
            }

            // select.exist can list more than the params needed to pick a
            // point, so nothing matches — fall back to the entity's own
            // route rather than the last point.
            if (!matched)
            {
                // A request naming an action reaches here only because that
                // action's own point failed its exist test, so it is
                // unbuildable whatever we pick. Refuse it BEFORE choosing a
                // fallback: the guard below compares the chosen point's
                // $action and would wave the request through whenever the
                // fallback lands on the action point itself.
                var unmatchedAction = reqselector != null
                    ? StructUtils.GetProp(reqselector, "$action") : null;
                if (unmatchedAction != null)
                {
                    throw ctx.MakeError("point_action_invalid",
                        "Operation \"" + op.Name +
                        "\" action \"" + StructUtils.Stringify(unmatchedAction) +
                        "\" is not valid.");
                }

                point = op.Points[0];
                foreach (var candidate in op.Points)
                {
                    var candTerm = TerminalParam(candidate);
                    var bestTerm = TerminalParam(point);
                    if (candTerm != bestTerm)
                    {
                        if (candTerm)
                        {
                            point = candidate;
                        }
                    }
                    else if (PartsLen(candidate) < PartsLen(point))
                    {
                        point = candidate;
                    }
                }
            }

            if (reqselector != null)
            {
                var reqAction = StructUtils.GetProp(reqselector, "$action");
                if (reqAction != null && point != null)
                {
                    var pointSelect = Helpers.ToMapAny(StructUtils.GetProp(point, "select"));
                    var pointAction = StructUtils.GetProp(pointSelect, "$action");
                    if (!Equals(reqAction, pointAction))
                    {
                        throw ctx.MakeError("point_action_invalid",
                            "Operation \"" + op.Name +
                            "\" action \"" + StructUtils.Stringify(reqAction) +
                            "\" is not valid.");
                    }
                }
            }

            ctx.Point = point;
        }

        return ctx.Point;
    }
}
