// Univec SDK utility: featureAdd.

using UnivecSdk.Feature;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    // FeatureAddUtil appends a feature to the client's feature list. A
    // feature can instead position itself relative to an already-added
    // feature with "__before__", "__after__" or "__replace__" (via AddOpts)
    // naming that feature - mirroring the ts featureAdd. The first match
    // wins; when no ordering option matches, the feature is appended.
    internal static void FeatureAddUtil(Context ctx, BaseFeature f)
    {
        var client = ctx.Client!;
        var features = client.Features;

        var fopts = f.AddOptions();

        if (fopts != null)
        {
            var before = fopts.TryGetValue("__before__", out var b) ? b as string : null;
            var after = fopts.TryGetValue("__after__", out var a) ? a as string : null;
            var replace = fopts.TryGetValue("__replace__", out var r) ? r as string : null;

            if (!string.IsNullOrEmpty(before) || !string.IsNullOrEmpty(after) ||
                !string.IsNullOrEmpty(replace))
            {
                for (var i = 0; i < features.Count; i++)
                {
                    var name = features[i].GetName();
                    if (before == name)
                    {
                        features.Insert(i, f);
                        return;
                    }
                    if (after == name)
                    {
                        features.Insert(i + 1, f);
                        return;
                    }
                    if (replace == name)
                    {
                        features[i] = f;
                        return;
                    }
                }
            }
        }

        features.Add(f);
    }
}
