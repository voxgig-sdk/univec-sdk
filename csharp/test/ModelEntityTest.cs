// model entity test - basic flow (generated from the API model).

using System.Text.Json;

using Voxgig.Struct;
using Xunit;

namespace UnivecSdk.Test;

public class ModelEntityTest
{
    [Fact]
    public void Instance()
    {
        var testsdk = UnivecSDK.TestSDK(null, null);
        var ent = testsdk.Model();
        Assert.NotNull(ent);
    }

    [Fact]
    public void Basic()
    {
        var setup = ModelBasicSetup(null);
        // Per-op sdk-test-control.json skip - basic test exercises a flow
        // with multiple ops; skipping any op skips the whole flow.
        var _mode = setup.Live ? "live" : "unit";
        foreach (var _op in new[] { "list" })
        {
            var (_shouldSkip, _) = TestRunner.IsControlSkipped(
                "entityOp", "model." + _op, _mode);
            if (_shouldSkip)
            {
                return; // skipped via sdk-test-control.json
            }
        }
        // The basic flow consumes synthetic IDs from the fixture. In live
        // mode without an *_ENTID env override, those IDs hit the live API
        // and 4xx; set UNIVEC_TEST_MODEL_ENTID JSON to run live.
        if (setup.SyntheticOnly)
        {
            return;
        }
        var client = setup.Client;

        // Bootstrap entity data from existing test data (no create step in flow).
        var modelRef01DataRaw = StructUtils.Items(
            Helpers.ToMapAny(StructUtils.GetPath(setup.Data, "existing.model")));
        var modelRef01Data = modelRef01DataRaw.Count > 0
            ? Helpers.ToMapAny(modelRef01DataRaw[0][1])
            : null;

        // LIST
        var modelRef01Ent = client.Model();
        var modelRef01Match = new Dictionary<string, object?>();

        var modelRef01ListResult = modelRef01Ent.List(modelRef01Match, null);
        var modelRef01List = modelRef01ListResult as List<object?>;
        Assert.True(modelRef01List != null,
            $"expected list result to be a list, got {modelRef01ListResult?.GetType()}");

    }

    [Fact]
    public async Task Stream()
    {
        var setup = ModelBasicSetup(new Dictionary<string, object?>
        {
            ["feature"] = new Dictionary<string, object?>
            {
                ["streaming"] = new Dictionary<string, object?> { ["active"] = true },
            },
        });
        if (setup.Live)
        {
            return; // unit mode only - streams the seeded fixture data
        }

        var ent = setup.Client.Model();
        var match = new Dictionary<string, object?>();

        // Materialised list result for the same op.
        var listed = ent.List(match, null) as List<object?> ?? new List<object?>();

        // stream("list") yields items via the streaming feature's iterator.
        var streamed = new List<object?>();
        await foreach (var item in ent.Stream("list", match, null))
        {
            streamed.Add(item);
        }
        Assert.True(streamed.Count > 0, "expected stream to yield items");
        Assert.Equal(listed.Count, streamed.Count);

        // Fallback: with streaming inactive, stream still yields the
        // materialised items.
        var setup2 = ModelBasicSetup(null);
        var ent2 = setup2.Client.Model();
        var streamed2 = new List<object?>();
        await foreach (var item in ent2.Stream("list", match, null))
        {
            streamed2.Add(item);
        }
        Assert.Equal(listed.Count, streamed2.Count);
    }

    private static EntityTestSetup ModelBasicSetup(
        Dictionary<string, object?>? extra)
    {
        TestRunner.LoadEnvLocal();

        var entityDataFile = Path.Combine(TestRunner.TestDir(),
            "..", "..", ".sdk", "test", "entity", "model",
            "ModelTestData.json");

        var entityDataEl = JsonSerializer.Deserialize<JsonElement>(
            File.ReadAllText(entityDataFile));
        var entityData = StructRunner.ConvertElement(entityDataEl)
            as Dictionary<string, object?>
            ?? throw new InvalidOperationException(
                "failed to parse model test data");

        var options = new Dictionary<string, object?>
        {
            ["entity"] = entityData["existing"],
        };

        var client = UnivecSDK.TestSDK(options, extra);

        // Generate idmap via transform, matching the TS pattern.
        var idmap = StructUtils.Transform(
            new List<object?> { "model01", "model02", "model03" },
            new Dictionary<string, object?>
            {
                ["`$PACK`"] = new List<object?>
                {
                    "",
                    new Dictionary<string, object?>
                    {
                        ["`$KEY`"] = "`$COPY`",
                        ["`$VAL`"] = new List<object?> { "`$FORMAT`", "upper", "`$COPY`" },
                    },
                },
            });

        // Detect ENTID env override before EnvOverride consumes it. When
        // live mode is on without a real override, the basic test runs
        // against synthetic IDs from the fixture and 4xx's.
        var entidEnvRaw = Environment.GetEnvironmentVariable(
            "UNIVEC_TEST_MODEL_ENTID") ?? "";
        var idmapOverridden = entidEnvRaw != "" &&
            entidEnvRaw.Trim().StartsWith("{");

        var env = TestRunner.EnvOverride(new Dictionary<string, object?>
        {
            ["UNIVEC_TEST_MODEL_ENTID"] = idmap,
            ["UNIVEC_TEST_LIVE"] = "FALSE",
            ["UNIVEC_TEST_EXPLAIN"] = "FALSE",
            ["UNIVEC_APIKEY"] = "",
        });

        var idmapResolved = Helpers.ToMapAny(env["UNIVEC_TEST_MODEL_ENTID"])
            ?? Helpers.ToMapAny(idmap)
            ?? new Dictionary<string, object?>();

        if (Equals(env["UNIVEC_TEST_LIVE"], "TRUE"))
        {
            // 'extra ?? new ...', not a bare 'extra': Merge returns null when
            // the last entry is null, and BasicSetup is normally called with no
            // argument at all - so a bare 'extra' silently discarded the apikey
            // and server values above and handed the SDK null.
            var extraOpts = extra ?? new Dictionary<string, object?>();
            var mergedOpts = StructUtils.Merge(new List<object?>
            {
                // FIRST, so the generated fields below win: sdk-test-control.json's
                // test.client.options adds to the live client, it does not redirect it.
                TestRunner.LiveClientOptions(),
                new Dictionary<string, object?>
                {
                    ["apikey"] = env["UNIVEC_APIKEY"],
                },
                extraOpts,
            });
            client = new UnivecSDK(Helpers.ToMapAny(mergedOpts));
        }

        var live = Equals(env["UNIVEC_TEST_LIVE"], "TRUE");
        return new EntityTestSetup
        {
            Client = client,
            Data = entityData,
            Idmap = idmapResolved,
            Env = env,
            Explain = Equals(env["UNIVEC_TEST_EXPLAIN"], "TRUE"),
            Live = live,
            SyntheticOnly = live && !idmapOverridden,
            Now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        };
    }
}
