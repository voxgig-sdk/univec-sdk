// Univec SDK utility: prepareAuth - shape the authorization header
// from the client options.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    private const string HeaderAuth = "authorization";
    private const string OptionApikey = "apikey";
    private const string NotFound = "__NOTFOUND__";

    internal static Spec PrepareAuthUtil(Context ctx)
    {
        var spec = ctx.Spec ?? throw ctx.MakeError("auth_no_spec",
            "Expected context spec property to be defined.");

        var headers = spec.Headers;
        var options = ctx.Client!.OptionsMap();

        // Public APIs that need no auth omit the options.auth block entirely.
        if (!options.TryGetValue("auth", out var auth) || auth == null)
        {
            headers.Remove(HeaderAuth);
            return spec;
        }

        var apikey = StructUtils.GetProp(options, OptionApikey, NotFound);

        var skip = apikey == null ||
            (apikey is string apikeyStr && (apikeyStr == NotFound || apikeyStr == ""));

        if (skip)
        {
            headers.Remove(HeaderAuth);
        }
        else
        {
            var authPrefix = "";
            if (StructUtils.GetPath(options, StructUtils.Jt("auth", "prefix")) is string ap)
            {
                authPrefix = ap;
            }
            var apikeyVal = apikey as string ?? "";
            // Empty prefix (raw apiKey credential) must not add a leading space.
            headers[HeaderAuth] = authPrefix == ""
                ? apikeyVal
                : authPrefix + " " + apikeyVal;
        }

        return spec;
    }
}
