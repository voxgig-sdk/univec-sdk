// Univec SDK utility: makeResult - final result shaping; list results
// are wrapped into entity instances.

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static Result MakeResultUtil(Context ctx)
    {
        if (ctx.Out.TryGetValue("result", out var outRes) && outRes is Result cached)
        {
            return cached;
        }

        var utility = ctx.Utility!;
        var op = ctx.Op!;
        var entity = ctx.Entity;
        var spec = ctx.Spec;
        var result = ctx.Result;

        if (spec == null)
        {
            throw ctx.MakeError("result_no_spec",
                "Expected context spec property to be defined.");
        }
        if (result == null)
        {
            throw ctx.MakeError("result_no_result",
                "Expected context result property to be defined.");
        }

        spec.Step = "result";

        utility.TransformResponse(ctx);

        if (op.Name == "list")
        {
            var resdata = result.Resdata;
            result.Resdata = new List<object?>();

            if (resdata is List<object?> list && list.Count > 0 && entity != null)
            {
                var entities = new List<object?>();
                foreach (var entry in list)
                {
                    var ent = entity.Make();
                    if (entry is Dictionary<string, object?> entryMap)
                    {
                        ent.Data(entryMap);
                    }
                    entities.Add(ent);
                }
                result.Resdata = entities;
            }
        }

        if (ctx.Ctrl.Explain != null)
        {
            ctx.Ctrl.Explain["result"] = result;
        }

        return result;
    }
}
