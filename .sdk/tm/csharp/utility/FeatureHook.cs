// Univec SDK utility: featureHook - dispatch a named hook to every
// feature. Reflection-based (like the go port) so custom features may
// implement arbitrary hook names beyond the BaseFeature set.

using System.Reflection;

using UnivecSdk.Feature;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static void FeatureHookUtil(Context ctx, string name)
    {
        var client = ctx.Client;
        if (client?.Features == null)
        {
            return;
        }

        // Snapshot: a hook may mutate the feature list.
        foreach (var f in client.Features.ToList())
        {
            CallFeatureMethod(f, name, ctx);
        }
    }

    private static void CallFeatureMethod(BaseFeature f, string name, Context ctx)
    {
        var m = f.GetType().GetMethod(name,
            BindingFlags.Public | BindingFlags.Instance,
            new[] { typeof(Context) });
        m?.Invoke(f, new object[] { ctx });
    }
}
