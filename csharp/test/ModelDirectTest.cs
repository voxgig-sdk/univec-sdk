// model direct API tests (generated from the API model).

using System.Text.Json;

using Voxgig.Struct;
using Xunit;

namespace UnivecSdk.Test;

public class ModelDirectTest
{
    [Fact]
    public void DirectList()
    {
        var setup = ModelDirectSetup(new List<object?>
        {
            new Dictionary<string, object?> { ["id"] = "direct01" },
            new Dictionary<string, object?> { ["id"] = "direct02" },
        });
        var _mode = setup.Live ? "live" : "unit";
        var (_shouldSkip, _) = TestRunner.IsControlSkipped(
            "direct", "direct-list-model", _mode);
        if (_shouldSkip)
        {
            return; // skipped via sdk-test-control.json
        }
        var client = setup.Client;


        var result = client.Direct(new Dictionary<string, object?>
        {
            ["path"] = "v1/models",
            ["method"] = "GET",
            ["params"] = new Dictionary<string, object?>(),
        });
        if (setup.Live)
        {
            // Live mode is lenient: synthetic IDs frequently 4xx and the
            // list-response shape varies wildly across public APIs. Bail
            // rather than fail when the call doesn't return a usable list.
            if (!Equals(result["ok"], true))
            {
                return;
            }
            var status = Helpers.ToInt(result["status"]);
            if (status < 200 || status >= 300)
            {
                return;
            }
        }
        else
        {
            Assert.True(Equals(result["ok"], true),
                $"expected ok to be true, got {result.GetValueOrDefault("err")}");
            Assert.Equal(200, Helpers.ToInt(result["status"]));
        }

        if (!setup.Live)
        {
            var dataList = result["data"] as List<object?>;
            Assert.True(dataList != null, "expected data to be a list");
            Assert.Equal(2, dataList!.Count);

            Assert.True(setup.Calls.Count == 1,
                $"expected 1 call, got {setup.Calls.Count}");
        }
    }

    private class ModelDirectSetupResult
    {
        public UnivecSDK Client = null!;
        public List<Dictionary<string, object?>> Calls = new();
        public bool Live;
        public Dictionary<string, object?> Idmap = new();
    }

    private static ModelDirectSetupResult ModelDirectSetup(object? mockres)
    {
        TestRunner.LoadEnvLocal();

        var calls = new List<Dictionary<string, object?>>();

        var env = TestRunner.EnvOverride(new Dictionary<string, object?>
        {
            ["UNIVEC_TEST_MODEL_ENTID"] = new Dictionary<string, object?>(),
            ["UNIVEC_TEST_LIVE"] = "FALSE",
            ["UNIVEC_APIKEY"] = "NONE",
        });

        var live = Equals(env["UNIVEC_TEST_LIVE"], "TRUE");

        if (live)
        {
            var liveClient = new UnivecSDK(new Dictionary<string, object?>
            {
                ["apikey"] = env["UNIVEC_APIKEY"],
            });

            var idmap = new Dictionary<string, object?>();
            var entidRaw = env["UNIVEC_TEST_MODEL_ENTID"];
            if (entidRaw is string entidStr && entidStr.StartsWith("{"))
            {
                try
                {
                    var el = JsonSerializer.Deserialize<JsonElement>(entidStr);
                    idmap = StructRunner.ConvertElement(el)
                        as Dictionary<string, object?> ?? idmap;
                }
                catch (JsonException)
                {
                }
            }
            else if (entidRaw is Dictionary<string, object?> entidMap)
            {
                idmap = entidMap;
            }

            return new ModelDirectSetupResult
            {
                Client = liveClient,
                Calls = calls,
                Live = true,
                Idmap = idmap,
            };
        }

        Func<string, Dictionary<string, object?>, Dictionary<string, object?>> mockFetch =
            (url, init) =>
            {
                calls.Add(new Dictionary<string, object?>
                {
                    ["url"] = url,
                    ["init"] = init,
                });
                return new Dictionary<string, object?>
                {
                    ["status"] = 200,
                    ["statusText"] = "OK",
                    ["headers"] = new Dictionary<string, object?>(),
                    ["json"] = (Func<object?>)(() =>
                        mockres ?? new Dictionary<string, object?> { ["id"] = "direct01" }),
                };
            };

        var client = new UnivecSDK(new Dictionary<string, object?>
        {
            ["base"] = "http://localhost:8080",
            ["system"] = new Dictionary<string, object?>
            {
                ["fetch"] = mockFetch,
            },
        });

        return new ModelDirectSetupResult
        {
            Client = client,
            Calls = calls,
            Live = false,
            Idmap = new Dictionary<string, object?>(),
        };
    }
}
