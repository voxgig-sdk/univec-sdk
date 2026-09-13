// Univec SDK utility: prepareMethod.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    private static readonly Dictionary<string, string> MethodMap = new()
    {
        ["create"] = "POST",
        ["update"] = "PUT",
        ["load"] = "GET",
        ["list"] = "GET",
        ["remove"] = "DELETE",
        ["patch"] = "PATCH",
    };

    internal static string PrepareMethodUtil(Context ctx)
    {
        var opname = ctx.Op!.Name;

        // The API definition is authoritative: a POST-only or PATCH-based API
        // exposes `update` as POST or PATCH, not the PUT the op name implies.
        // Only fall back to the op-name convention when the point has no method.
        if (StructUtils.GetProp(ctx.Point, "method") is string pm && "" != pm)
        {
            return pm.ToUpperInvariant();
        }

        // No default: an op name outside the convention resolves to NO
        // method, exactly as the ts reference (`methodMap[key]` is
        // undefined there). The silent-pass engine hid a stray "GET"
        // fallback here; the shared corpus (prepareMethod, opname "bad"
        // -> null) pins it now.
        return MethodMap.TryGetValue(opname, out var m) ? m : null!;
    }
}
