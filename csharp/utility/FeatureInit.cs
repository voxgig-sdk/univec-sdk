// Univec SDK utility: featureInit.

using Voxgig.Struct;

using UnivecSdk.Feature;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static void FeatureInitUtil(Context ctx, BaseFeature f)
    {
        var fname = f.GetName();
        var fopts = new Dictionary<string, object?>();

        if (ctx.Options != null &&
            StructUtils.GetProp(ctx.Options, "feature") is Dictionary<string, object?> fm &&
            StructUtils.GetProp(fm, fname) is Dictionary<string, object?> fom)
        {
            fopts = fom;
        }

        if (fopts.TryGetValue("active", out var active) && active is bool ab && ab)
        {
            f.Init(ctx, fopts);
        }
    }
}
