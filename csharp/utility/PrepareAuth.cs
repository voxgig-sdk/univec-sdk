// Univec SDK utility: prepareAuth - shape the authorization header
// from the client options.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    private const string HeaderAuth = "authorization";
    private const string OptionApikey = "apikey";
    private const string NotFound = "__NOTFOUND__";

    // The client's auth.name option, when set, replaces the name the API declares.
    private static string PrepareAuthName(object? options) =>
        StructUtils.GetPath(options, StructUtils.Jt("auth", "name")) is string name && name != ""
            ? name.ToLowerInvariant() : HeaderAuth;

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

        var name = PrepareAuthName(options);

        // A credential left under the declared name would travel beside the renamed one.
        if (name != HeaderAuth)
        {
            headers.Remove(HeaderAuth);
        }

        var apikey = StructUtils.GetProp(options, OptionApikey, NotFound);

        var skip = apikey == null ||
            (apikey is string apikeyStr && (apikeyStr == NotFound || apikeyStr == ""));

        if (skip)
        {
            headers.Remove(name);
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
            headers[name] = authPrefix == ""
                ? apikeyVal
                : authPrefix + " " + apikeyVal;
        }

        return spec;
    }
}
