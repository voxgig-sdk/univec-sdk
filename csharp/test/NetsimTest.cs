// Network-behaviour simulation over the offline mock transport. The `test`
// feature accepts an optional `net` config so unit tests can exercise slow,
// failing and offline conditions without a live server. These checks drive
// the transport through Direct(), which needs no entity, so they run for
// every generated SDK regardless of its API shape.
// C# twin of tm/go/test/netsim_test.go.

using System.Diagnostics;

using Xunit;

using UnivecSdk;

namespace UnivecSdk.Test;

public class NetsimTest
{
    [Fact]
    public void OfflineSimulationFailsRequest()
    {
        var client = UnivecSDK.TestSDK(new Dictionary<string, object?>
        {
            ["net"] = new Dictionary<string, object?> { ["offline"] = true },
        }, null);
        var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/ping" });
        Assert.True(Equals(res["ok"], false), $"offline network must fail the call");
    }

    [Fact]
    public void FailstatusSimulationSurfacesStatus()
    {
        var client = UnivecSDK.TestSDK(new Dictionary<string, object?>
        {
            ["net"] = new Dictionary<string, object?>
            {
                ["failTimes"] = 1,
                ["failStatus"] = 503,
            },
        }, null);
        var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/ping" });
        Assert.True(Equals(res["ok"], false), "expected failed call");
        Assert.Equal(503, Helpers.ToInt(res["status"]));
    }

    [Fact]
    public void LatencySimulationDelaysRequest()
    {
        var delay = 60;
        var client = UnivecSDK.TestSDK(new Dictionary<string, object?>
        {
            ["net"] = new Dictionary<string, object?> { ["latency"] = delay },
        }, null);
        var sw = Stopwatch.StartNew();
        client.Direct(new Dictionary<string, object?> { ["path"] = "/ping" });
        sw.Stop();
        // Generous lower bound to stay robust on slow CI.
        Assert.True(sw.ElapsedMilliseconds >= delay - 25,
            $"expected >= {delay - 25}ms latency, got {sw.ElapsedMilliseconds}ms");
    }

    [Fact]
    public void PlainTestSdkWorksWithoutNet()
    {
        var client = UnivecSDK.TestSDK(null, null);
        Assert.NotNull(client);
    }
}
