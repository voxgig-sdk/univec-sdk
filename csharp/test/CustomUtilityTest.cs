// Custom utility overrides supplied via options.utility land on the client
// utility's Custom map. C# twin of tm/go/test/custom_utility_test.go.

using Xunit;

using UnivecSdk;

namespace UnivecSdk.Test;

public class CustomUtilityTest
{
    private static Func<Dictionary<string, object?>> Util(string tag)
    {
        return () => new Dictionary<string, object?> { ["util"] = tag };
    }

    [Fact]
    public void Basic()
    {
        var names = new[]
        {
            "auth", "body", "contextify", "done", "error", "findparam",
            "fullurl", "headers", "method", "operator", "params", "query",
            "reqform", "request", "resbasic", "resbody", "resform",
            "resheaders", "response", "result", "spec",
        };

        var utilityOpt = new Dictionary<string, object?>();
        foreach (var name in names)
        {
            utilityOpt[name] = Util(name.ToUpperInvariant());
        }

        var client = UnivecSDK.TestSDK(null, new Dictionary<string, object?>
        {
            ["apikey"] = "APIKEY01",
            ["utility"] = utilityOpt,
        });

        var u = client.GetUtility();

        foreach (var name in names)
        {
            Assert.True(u.Custom.ContainsKey(name),
                $"expected custom utility \"{name}\" to exist");
            var fn = Assert.IsType<Func<Dictionary<string, object?>>>(u.Custom[name]);
            var result = fn();
            Assert.Equal(name.ToUpperInvariant(), result["util"]);
        }
    }
}
