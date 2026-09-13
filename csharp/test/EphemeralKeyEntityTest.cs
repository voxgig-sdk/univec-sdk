// ephemeral_key entity test - basic flow (generated from the API model).

using System.Text.Json;

using Voxgig.Struct;
using Xunit;

namespace UnivecSdk.Test;

public class EphemeralKeyEntityTest
{
    [Fact]
    public void Instance()
    {
        var testsdk = UnivecSDK.TestSDK(null, null);
        var ent = testsdk.EphemeralKey();
        Assert.NotNull(ent);
    }

    [Fact]
    public void Basic()
    {
        var setup = EphemeralKeyBasicSetup(null);
        // Per-op sdk-test-control.json skip - basic test exercises a flow
        // with multiple ops; skipping any op skips the whole flow.
        var _mode = setup.Live ? "live" : "unit";
        foreach (var _op in new[] { "create" })
        {
            var (_shouldSkip, _) = TestRunner.IsControlSkipped(
                "entityOp", "ephemeral_key." + _op, _mode);
            if (_shouldSkip)
            {
                return; // skipped via sdk-test-control.json
            }
        }
        // The basic flow consumes synthetic IDs from the fixture. In live
        // mode without an *_ENTID env override, those IDs hit the live API
        // and 4xx; set UNIVEC_TEST_EPHEMERAL_KEY_ENTID JSON to run live.
        if (setup.SyntheticOnly)
        {
            return;
        }
        var client = setup.Client;

        // CREATE
        var ephemeralKeyRef01Ent = client.EphemeralKey();
        var ephemeralKeyRef01Data = Helpers.ToMapAny(StructUtils.GetProp(
            StructUtils.GetPath(setup.Data, StructUtils.Jt("new", "ephemeral_key")),
            "ephemeral_key_ref01"));

        var ephemeralKeyRef01DataResult = ephemeralKeyRef01Ent.Create(ephemeralKeyRef01Data, null);
        ephemeralKeyRef01Data = Helpers.ToMapAny(ephemeralKeyRef01DataResult is IEntity ce ? ce.Data() : ephemeralKeyRef01DataResult);
        Assert.True(ephemeralKeyRef01Data != null, "expected create result to be a map");

    }

    private static EntityTestSetup EphemeralKeyBasicSetup(
        Dictionary<string, object?>? extra)
    {
        TestRunner.LoadEnvLocal();

        var entityDataFile = Path.Combine(TestRunner.TestDir(),
            "..", "..", ".sdk", "test", "entity", "ephemeral_key",
            "EphemeralKeyTestData.json");

        var entityDataEl = JsonSerializer.Deserialize<JsonElement>(
            File.ReadAllText(entityDataFile));
        var entityData = StructRunner.ConvertElement(entityDataEl)
            as Dictionary<string, object?>
            ?? throw new InvalidOperationException(
                "failed to parse ephemeral_key test data");

        var options = new Dictionary<string, object?>
        {
            ["entity"] = entityData["existing"],
        };

        var client = UnivecSDK.TestSDK(options, extra);

        // Generate idmap via transform, matching the TS pattern.
        var idmap = StructUtils.Transform(
            new List<object?> { "ephemeral_key01", "ephemeral_key02", "ephemeral_key03" },
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
            "UNIVEC_TEST_EPHEMERAL_KEY_ENTID") ?? "";
        var idmapOverridden = entidEnvRaw != "" &&
            entidEnvRaw.Trim().StartsWith("{");

        var env = TestRunner.EnvOverride(new Dictionary<string, object?>
        {
            ["UNIVEC_TEST_EPHEMERAL_KEY_ENTID"] = idmap,
            ["UNIVEC_TEST_LIVE"] = "FALSE",
            ["UNIVEC_TEST_EXPLAIN"] = "FALSE",
            ["UNIVEC_APIKEY"] = "",
        });

        var idmapResolved = Helpers.ToMapAny(env["UNIVEC_TEST_EPHEMERAL_KEY_ENTID"])
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
