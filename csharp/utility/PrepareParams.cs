// Univec SDK utility: prepareParams.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static Dictionary<string, object?> PrepareParamsUtil(Context ctx)
    {
        var utility = ctx.Utility!;
        var point = ctx.Point;

        List<object?>? paramdefs = null;
        if (StructUtils.GetProp(point, "args") is Dictionary<string, object?> argsMap &&
            StructUtils.GetProp(argsMap, "params") is List<object?> pl)
        {
            paramdefs = pl;
        }
        paramdefs ??= new List<object?>();

        var prepared = new Dictionary<string, object?>();
        foreach (var pd in paramdefs)
        {
            var val = utility.Param(ctx, pd);
            if (val != null && pd is Dictionary<string, object?> pdm)
            {
                var name = StructUtils.GetProp(pdm, "name") as string ?? "";
                if (name != "")
                {
                    prepared[name] = val;
                }
            }
        }

        return prepared;
    }
}
