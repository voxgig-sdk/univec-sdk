// Univec SDK - generated model configuration and feature
// factory. GENERATED from the API model - do not edit by hand.

namespace UnivecSdk;

public static class SdkConfig
{
    public static Dictionary<string, object?> MakeConfig()
    {
        return new Dictionary<string, object?>
        {
            ["main"] = new Dictionary<string, object?>
            {
                ["name"] = "Univec",
                ["slug"] = "univec",
                ["version"] = "0.1.1",
                ["target"] = "csharp",
            },
            ["feature"] = new Dictionary<string, object?>
            {
                ["audit"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["actor"] = "anonymous",
                        ["max"] = 1000,
                    },
                    ["transport"] = "none",
                },
                ["cache"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["max"] = 256,
                        ["methods"] = new List<object?>
                        {
                            "GET",
                        },
                        ["ttl"] = 5000,
                    },
                    ["transport"] = "wrap",
                },
                ["clienttrack"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["clientVersion"] = "0.0.1",
                    },
                    ["transport"] = "none",
                },
                ["cost"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["budget"] = 0,
                        ["currency"] = "USD",
                        ["header"] = "",
                        ["onBudget"] = "warn",
                        ["path"] = "",
                        ["perUnit"] = 0,
                        ["rates"] = new Dictionary<string, object?>(),
                        ["unit"] = 0,
                    },
                    ["transport"] = "wrap",
                },
                ["debug"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["max"] = 100,
                        ["redact"] = new List<object?>
                        {
                            "authorization",
                            "cookie",
                            "set-cookie",
                            "api-key",
                            "apikey",
                            "x-api-key",
                            "idempotency-key",
                        },
                    },
                    ["transport"] = "none",
                },
                ["idempotency"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["header"] = "Idempotency-Key",
                        ["methods"] = new List<object?>
                        {
                            "POST",
                            "PUT",
                            "PATCH",
                            "DELETE",
                        },
                        ["ops"] = new List<object?>
                        {
                            "create",
                            "update",
                            "remove",
                        },
                    },
                    ["transport"] = "none",
                },
                ["log"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = true,
                    },
                    ["transport"] = "none",
                },
                ["metrics"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                    },
                    ["transport"] = "none",
                },
                ["netsim"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["errorTimes"] = 0,
                        ["failEvery"] = 0,
                        ["failRate"] = 0,
                        ["failStatus"] = 503,
                        ["failTimes"] = 0,
                        ["latency"] = 0,
                        ["offline"] = false,
                        ["rateLimitTimes"] = 0,
                        ["retryAfter"] = 0,
                        ["seed"] = 1,
                    },
                    ["transport"] = "wrap",
                },
                ["paging"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["afterVar"] = "after",
                        ["cursorParam"] = "cursor",
                        ["firstVar"] = "first",
                        ["limitParam"] = "limit",
                        ["pageParam"] = "page",
                        ["startPage"] = 1,
                    },
                    ["transport"] = "none",
                },
                ["proxy"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["fromEnv"] = false,
                        ["noProxy"] = new List<object?>(),
                        ["url"] = "",
                    },
                    ["transport"] = "wrap",
                },
                ["ratelimit"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["burst"] = 5,
                        ["rate"] = 5,
                    },
                    ["transport"] = "wrap",
                },
                ["rbac"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["deny"] = false,
                        ["permissions"] = new List<object?>(),
                        ["rules"] = new Dictionary<string, object?>(),
                    },
                    ["transport"] = "none",
                },
                ["retry"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["factor"] = 2,
                        ["maxDelay"] = 2000,
                        ["minDelay"] = 50,
                        ["retries"] = 2,
                        ["statuses"] = new List<object?>
                        {
                            408,
                            425,
                            429,
                            500,
                            502,
                            503,
                            504,
                        },
                    },
                    ["transport"] = "wrap",
                },
                ["streaming"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["chunkDelay"] = 0,
                        ["chunkSize"] = 0,
                    },
                    ["transport"] = "none",
                },
                ["telemetry"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                    },
                    ["transport"] = "none",
                },
                ["test"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                    },
                    ["transport"] = "base",
                },
                ["timeout"] = new Dictionary<string, object?>
                {
                    ["options"] = new Dictionary<string, object?>
                    {
                        ["active"] = false,
                        ["ms"] = 30000,
                    },
                    ["transport"] = "wrap",
                },
            },
            ["options"] = new Dictionary<string, object?>
            {
                ["base"] = "https://api.univec.ai",
                ["auth"] = new Dictionary<string, object?>
                {
                    ["prefix"] = "Bearer",
                },
                ["headers"] = new Dictionary<string, object?>
                {
                    ["content-type"] = "application/json",
                },
                ["entity"] = new Dictionary<string, object?>
                {
                    ["convert"] = new Dictionary<string, object?>(),
                    ["embed"] = new Dictionary<string, object?>(),
                    ["ephemeral_key"] = new Dictionary<string, object?>(),
                    ["model"] = new Dictionary<string, object?>(),
                },
            },
            ["entity"] = new Dictionary<string, object?>
            {
                ["convert"] = new Dictionary<string, object?>
                {
                    ["fields"] = new List<object?>
                    {
                        new Dictionary<string, object?>
                        {
                            ["name"] = "bridge_model",
                            ["req"] = true,
                            ["short"] = "Embed model used to vectorise the text before translation.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "embeddings",
                            ["req"] = true,
                            ["short"] = "Translated vectors, in the target model's dimension.",
                            ["type"] = "`$ARRAY`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "source_model",
                            ["req"] = true,
                            ["short"] = "Model space the supplied vectors are currently in.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "target_model",
                            ["req"] = true,
                            ["short"] = "Model space to translate into.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "texts",
                            ["req"] = true,
                            ["short"] = "Texts to embed and translate.",
                            ["type"] = "`$ARRAY`",
                        },
                    },
                    ["name"] = "convert",
                    ["op"] = new Dictionary<string, object?>
                    {
                        ["create"] = new Dictionary<string, object?>
                        {
                            ["input"] = "data",
                            ["name"] = "create",
                            ["points"] = new List<object?>
                            {
                                new Dictionary<string, object?>
                                {
                                    ["args"] = new Dictionary<string, object?>(),
                                    ["kind"] = "http",
                                    ["method"] = "POST",
                                    ["orig"] = "/v1/convert",
                                    ["parts"] = new List<object?>
                                    {
                                        "v1",
                                        "convert",
                                    },
                                    ["select"] = new Dictionary<string, object?>(),
                                    ["transform"] = new Dictionary<string, object?>
                                    {
                                        ["req"] = "`reqdata`",
                                        ["res"] = "`body.data`",
                                    },
                                },
                                new Dictionary<string, object?>
                                {
                                    ["args"] = new Dictionary<string, object?>(),
                                    ["kind"] = "http",
                                    ["method"] = "POST",
                                    ["orig"] = "/v1/embed-bridge",
                                    ["parts"] = new List<object?>
                                    {
                                        "v1",
                                        "embed-bridge",
                                    },
                                    ["select"] = new Dictionary<string, object?>(),
                                    ["transform"] = new Dictionary<string, object?>
                                    {
                                        ["req"] = "`reqdata`",
                                        ["res"] = "`body.data`",
                                    },
                                },
                                new Dictionary<string, object?>
                                {
                                    ["args"] = new Dictionary<string, object?>(),
                                    ["kind"] = "http",
                                    ["method"] = "POST",
                                    ["orig"] = "/v1/ephemeral/convert",
                                    ["parts"] = new List<object?>
                                    {
                                        "v1",
                                        "ephemeral",
                                        "convert",
                                    },
                                    ["select"] = new Dictionary<string, object?>(),
                                    ["transform"] = new Dictionary<string, object?>
                                    {
                                        ["req"] = "`reqdata`",
                                        ["res"] = "`body.data`",
                                    },
                                },
                                new Dictionary<string, object?>
                                {
                                    ["args"] = new Dictionary<string, object?>(),
                                    ["kind"] = "http",
                                    ["method"] = "POST",
                                    ["orig"] = "/v1/ephemeral/embed-bridge",
                                    ["parts"] = new List<object?>
                                    {
                                        "v1",
                                        "ephemeral",
                                        "embed-bridge",
                                    },
                                    ["select"] = new Dictionary<string, object?>(),
                                    ["transform"] = new Dictionary<string, object?>
                                    {
                                        ["req"] = "`reqdata`",
                                        ["res"] = "`body.data`",
                                    },
                                },
                            },
                        },
                    },
                    ["relations"] = new Dictionary<string, object?>
                    {
                        ["ancestors"] = new List<object?>(),
                    },
                },
                ["embed"] = new Dictionary<string, object?>
                {
                    ["fields"] = new List<object?>
                    {
                        new Dictionary<string, object?>
                        {
                            ["name"] = "embeddings",
                            ["req"] = true,
                            ["short"] = "One vector per input text, in input order.",
                            ["type"] = "`$ARRAY`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "model",
                            ["req"] = true,
                            ["short"] = "Model that produced the vectors.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "texts",
                            ["req"] = true,
                            ["short"] = "Texts to embed.",
                            ["type"] = "`$ARRAY`",
                        },
                    },
                    ["name"] = "embed",
                    ["op"] = new Dictionary<string, object?>
                    {
                        ["create"] = new Dictionary<string, object?>
                        {
                            ["input"] = "data",
                            ["name"] = "create",
                            ["points"] = new List<object?>
                            {
                                new Dictionary<string, object?>
                                {
                                    ["args"] = new Dictionary<string, object?>(),
                                    ["kind"] = "http",
                                    ["method"] = "POST",
                                    ["orig"] = "/v1/embed",
                                    ["parts"] = new List<object?>
                                    {
                                        "v1",
                                        "embed",
                                    },
                                    ["select"] = new Dictionary<string, object?>(),
                                    ["transform"] = new Dictionary<string, object?>
                                    {
                                        ["req"] = "`reqdata`",
                                        ["res"] = "`body.data`",
                                    },
                                },
                                new Dictionary<string, object?>
                                {
                                    ["args"] = new Dictionary<string, object?>(),
                                    ["kind"] = "http",
                                    ["method"] = "POST",
                                    ["orig"] = "/v1/ephemeral/embed",
                                    ["parts"] = new List<object?>
                                    {
                                        "v1",
                                        "ephemeral",
                                        "embed",
                                    },
                                    ["select"] = new Dictionary<string, object?>(),
                                    ["transform"] = new Dictionary<string, object?>
                                    {
                                        ["req"] = "`reqdata`",
                                        ["res"] = "`body.data`",
                                    },
                                },
                            },
                        },
                    },
                    ["relations"] = new Dictionary<string, object?>
                    {
                        ["ancestors"] = new List<object?>(),
                    },
                },
                ["ephemeral_key"] = new Dictionary<string, object?>
                {
                    ["fields"] = new List<object?>
                    {
                        new Dictionary<string, object?>
                        {
                            ["name"] = "dailyLimit",
                            ["req"] = true,
                            ["short"] = "Calls permitted per day.",
                            ["type"] = "`$INTEGER`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "dailyUsed",
                            ["req"] = true,
                            ["short"] = "Calls already used today.",
                            ["type"] = "`$INTEGER`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "key",
                            ["req"] = true,
                            ["short"] = "The ephemeral API key, prefixed `eph_`.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "resetsAt",
                            ["req"] = true,
                            ["short"] = "When the daily allowance resets.",
                            ["type"] = "`$STRING`",
                        },
                    },
                    ["name"] = "ephemeral_key",
                    ["op"] = new Dictionary<string, object?>
                    {
                        ["create"] = new Dictionary<string, object?>
                        {
                            ["input"] = "data",
                            ["name"] = "create",
                            ["points"] = new List<object?>
                            {
                                new Dictionary<string, object?>
                                {
                                    ["args"] = new Dictionary<string, object?>(),
                                    ["kind"] = "http",
                                    ["method"] = "POST",
                                    ["orig"] = "/v1/ephemeral/key",
                                    ["parts"] = new List<object?>
                                    {
                                        "v1",
                                        "ephemeral",
                                        "key",
                                    },
                                    ["select"] = new Dictionary<string, object?>(),
                                    ["transform"] = new Dictionary<string, object?>
                                    {
                                        ["req"] = "`reqdata`",
                                        ["res"] = "`body.data`",
                                    },
                                },
                            },
                        },
                    },
                    ["relations"] = new Dictionary<string, object?>
                    {
                        ["ancestors"] = new List<object?>(),
                    },
                },
                ["model"] = new Dictionary<string, object?>
                {
                    ["fields"] = new List<object?>
                    {
                        new Dictionary<string, object?>
                        {
                            ["name"] = "eval",
                            ["short"] = "Retrieval-fidelity metrics for a convert model.",
                            ["type"] = "`$OBJECT`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "executionProvider",
                            ["short"] = "Hardware backend, e.g.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "modelCard",
                            ["short"] = "Convert models only: training provenance and architecture detail.",
                            ["type"] = "`$OBJECT`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "modelType",
                            ["req"] = true,
                            ["short"] = "`embed` for text-to-vector models, `convert` for space-translation models.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "name",
                            ["req"] = true,
                            ["short"] = "Model identifier used in requests.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "sequenceLen",
                            ["short"] = "Embed models only: maximum input sequence length.",
                            ["type"] = "`$INTEGER`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "sourceDim",
                            ["short"] = "Convert models only: source vector dimension.",
                            ["type"] = "`$INTEGER`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "sourceModel",
                            ["short"] = "Convert models only: the source model space.",
                            ["type"] = "`$STRING`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "targetDim",
                            ["req"] = true,
                            ["short"] = "Dimension of the produced vectors.",
                            ["type"] = "`$INTEGER`",
                        },
                        new Dictionary<string, object?>
                        {
                            ["name"] = "targetModel",
                            ["req"] = true,
                            ["short"] = "The model space produced.",
                            ["type"] = "`$STRING`",
                        },
                    },
                    ["name"] = "model",
                    ["op"] = new Dictionary<string, object?>
                    {
                        ["list"] = new Dictionary<string, object?>
                        {
                            ["input"] = "data",
                            ["name"] = "list",
                            ["points"] = new List<object?>
                            {
                                new Dictionary<string, object?>
                                {
                                    ["args"] = new Dictionary<string, object?>(),
                                    ["kind"] = "http",
                                    ["method"] = "GET",
                                    ["orig"] = "/v1/models",
                                    ["parts"] = new List<object?>
                                    {
                                        "v1",
                                        "models",
                                    },
                                    ["select"] = new Dictionary<string, object?>(),
                                    ["transform"] = new Dictionary<string, object?>
                                    {
                                        ["req"] = "`reqdata`",
                                        ["res"] = "`body.data`",
                                    },
                                },
                            },
                        },
                    },
                    ["relations"] = new Dictionary<string, object?>
                    {
                        ["ancestors"] = new List<object?>(),
                    },
                },
            },
        };
    }

    private static readonly Lazy<Dictionary<string, object?>> SharedConfigVal =
        new(MakeConfig);

    // The process-wide config, built once on first use.
    //
    // The returned dictionary is SHARED: treat it as read-only. Callers that
    // need to mutate should use MakeConfig, which always returns a fresh copy.
    public static Dictionary<string, object?> SharedConfig()
    {
        return SharedConfigVal.Value;
    }

    public static Feature.BaseFeature MakeFeature(string name)
    {
        switch (name)
        {
            case "audit":
                return new Feature.AuditFeature();
            case "cache":
                return new Feature.CacheFeature();
            case "clienttrack":
                return new Feature.ClienttrackFeature();
            case "cost":
                return new Feature.CostFeature();
            case "debug":
                return new Feature.DebugFeature();
            case "idempotency":
                return new Feature.IdempotencyFeature();
            case "log":
                return new Feature.LogFeature();
            case "metrics":
                return new Feature.MetricsFeature();
            case "netsim":
                return new Feature.NetsimFeature();
            case "paging":
                return new Feature.PagingFeature();
            case "proxy":
                return new Feature.ProxyFeature();
            case "ratelimit":
                return new Feature.RatelimitFeature();
            case "rbac":
                return new Feature.RbacFeature();
            case "retry":
                return new Feature.RetryFeature();
            case "streaming":
                return new Feature.StreamingFeature();
            case "telemetry":
                return new Feature.TelemetryFeature();
            case "test":
                return new Feature.TestFeature();
            case "timeout":
                return new Feature.TimeoutFeature();
            default:
                return new Feature.BaseFeature();
        }
    }
}
