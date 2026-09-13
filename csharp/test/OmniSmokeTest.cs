// Smoke tests for the vendored omni runner itself: a runner that cannot
// FAIL a bad entry would turn every corpus suite vacuously green, so pin
// the failure paths, not just the happy one. (The C# peer of
// tm/ts/test/omni.test.ts and tm/go/test/omnismoke_test.go.)

using Xunit;

using Voxgig.Omni;

using UnivecSdk;

namespace UnivecSdk.Test;

public class OmniSmokeTest
{
    // A minimal in-memory spec: no fixture file, no OMNI block (lenient
    // v0, like the shared corpus).
    private static Dictionary<string, object?> SmokeSpec()
    {
        return new Dictionary<string, object?>
        {
            ["primary"] = new Dictionary<string, object?>
            {
                ["smoke"] = new Dictionary<string, object?>
                {
                    ["basic"] = new Dictionary<string, object?>
                    {
                        ["set"] = new List<object?>
                        {
                            new Dictionary<string, object?> { ["in"] = 1, ["out"] = 2 },
                            new Dictionary<string, object?> { ["in"] = 41, ["out"] = 42 },
                        },
                    },
                    ["bad"] = new Dictionary<string, object?>
                    {
                        ["set"] = new List<object?>
                        {
                            new Dictionary<string, object?> { ["in"] = 1, ["out"] = 999 },
                        },
                    },
                    ["err"] = new Dictionary<string, object?>
                    {
                        ["set"] = new List<object?>
                        {
                            new Dictionary<string, object?> { ["in"] = 0, ["err"] = "zero refused" },
                        },
                    },
                },
            },
        };
    }

    private static object? SmokeInc(params object?[] args)
    {
        var n = Convert.ToInt64(args[0]);
        if (0 == n)
        {
            throw new InvalidOperationException("smoke: zero refused");
        }
        return n + 1;
    }

    private static OmniResolver.Run SmokeRun()
    {
        var runner = OmniResolver.MakeRunner(SmokeSpec(),
            UnivecSDK.TestSDK(null, null));
        var run = runner("smoke");
        Assert.NotNull(run.Spec);
        return run;
    }

    [Fact]
    public void RunsetPassesACorrectSubject()
    {
        var run = SmokeRun();
        run.RunSet(run.Set("basic"), SmokeInc);
    }

    [Fact]
    public void RunsetFailsAWrongResult()
    {
        var run = SmokeRun();

        var err = Assert.Throws<OmniError>(() =>
            run.RunSet(run.Set("bad"), SmokeInc));

        Assert.True(err.Message.Contains("result mismatch"),
            "expected a result mismatch failure, got: " + err.Message);
    }

    [Fact]
    public void ExpectedErrorIsMatchedAndAMissingOneFails()
    {
        var run = SmokeRun();

        // The erroring subject satisfies the expected-error entry.
        run.RunSet(run.Set("err"), SmokeInc);

        // A subject that does NOT raise must fail that same entry.
        var err = Assert.Throws<OmniError>(() =>
            run.RunSet(run.Set("err"), args => args[0]));

        Assert.True(err.Message.Contains("expected error did not occur"),
            "expected an expected-error failure, got: " + err.Message);
    }
}
