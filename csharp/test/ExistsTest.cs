// Univec SDK exists test.

using Xunit;

using UnivecSdk;

namespace UnivecSdk.Test;

public class ExistsTest
{
    [Fact]
    public void TestMode()
    {
        var testsdk = UnivecSDK.TestSDK(null, null);
        Assert.NotNull(testsdk);
    }
}
