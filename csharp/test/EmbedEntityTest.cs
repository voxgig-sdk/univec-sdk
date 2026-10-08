// embed entity test - basic flow (generated from the API model).

using System.Text.Json;

using UnivecSdk.Feature;
using Voxgig.Struct;
using Xunit;

namespace UnivecSdk.Test;

public class EmbedEntityTest
{
    // main.kit.test.live.strict is true (the default is true): a live
    // request that fails, or a live test missing an input it needs,
    // fails the test.
    // An account with no record for a test to read skips it either way.
    private const bool LIVE_STRICT = true;

    [Fact]
    public void Instance()
    {
        var testsdk = UnivecSDK.TestSDK(null, null);
        var ent = testsdk.Embed();
        Assert.NotNull(ent);
    }

    [Fact]
    public void Basic()
    {
        var setup = EmbedBasicSetup(null);
        // Per-op sdk-test-control.json skip - basic test exercises a flow
        // with multiple ops; skipping any op skips the whole flow.
        var _mode = setup.Live ? "live" : "unit";
        foreach (var _op in new[] { "create" })
        {
            var (_shouldSkip, _) = TestRunner.IsControlSkipped(
                "entityOp", "embed." + _op, _mode);
            if (_shouldSkip)
            {
                return; // skipped via sdk-test-control.json
            }
        }
        var client = setup.Client;

        // CREATE
        var embedRef01Ent = client.Embed();
        var embedRef01Data = Helpers.ToMapAny(StructUtils.GetProp(
            StructUtils.GetPath(setup.Data, StructUtils.Jt("new", "embed")),
            "embed_ref01"));

        var embedRef01DataResult = embedRef01Ent.Create(embedRef01Data, null);
        embedRef01Data = Helpers.ToMapAny(embedRef01DataResult is IEntity ce ? ce.Data() : embedRef01DataResult);
        Assert.True(embedRef01Data != null, "expected create result to be a map");

    }

    [Fact]
    public void Validate()
    {
        if (!Fh.HasFeature("validate"))
        {
            Console.WriteLine("skip: feature not present in this SDK: validate");
            return;
        }
        var client = UnivecSDK.TestSDK(null,
            new Dictionary<string, object?> { ["feature"] = new Dictionary<string, object?> { ["validate"] = new Dictionary<string, object?> { ["active"] = true } } });
        var err = Assert.ThrowsAny<UnivecError>(() => client.Embed().Create(
            new Dictionary<string, object?> { ["embeddings"] = "x", ["model"] = 1, ["texts"] = "x" }, null));
        Assert.Equal("validate_failed", err.Code);
    }

    private static EntityTestSetup EmbedBasicSetup(
        Dictionary<string, object?>? extra)
    {
        TestRunner.LoadEnvLocal();

        var entityDataFile = Path.Combine(TestRunner.TestDir(),
            "..", "..", ".sdk", "test", "entity", "embed",
            "EmbedTestData.json");

        var entityDataEl = JsonSerializer.Deserialize<JsonElement>(
            File.ReadAllText(entityDataFile));
        var entityData = StructRunner.ConvertElement(entityDataEl)
            as Dictionary<string, object?>
            ?? throw new InvalidOperationException(
                "failed to parse embed test data");

        var options = new Dictionary<string, object?>
        {
            ["entity"] = entityData["existing"],
        };

        var client = UnivecSDK.TestSDK(options, extra);

        // Generate idmap via transform, matching the TS pattern.
        var idmap = StructUtils.Transform(
            new List<object?> { "embed01", "embed02", "embed03" },
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

        // Whether *_ENTID supplied the idmap, read before EnvOverride consumes
        // it: without it, the ids a live flow binds are the fixture's synthetic ones.
        var entidEnvRaw = Environment.GetEnvironmentVariable(
            "UNIVEC_TEST_EMBED_ENTID") ?? "";
        var idmapOverridden = entidEnvRaw != "" &&
            entidEnvRaw.Trim().StartsWith("{");

        var env = TestRunner.EnvOverride(new Dictionary<string, object?>
        {
            ["UNIVEC_TEST_EMBED_ENTID"] = idmap,
            ["UNIVEC_TEST_LIVE"] = "FALSE",
            ["UNIVEC_TEST_EXPLAIN"] = "FALSE",
            ["UNIVEC_APIKEY"] = "",
        });

        var idmapResolved = Helpers.ToMapAny(env["UNIVEC_TEST_EMBED_ENTID"])
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
