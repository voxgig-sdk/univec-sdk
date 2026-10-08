// Univec SDK - generated schemas. GENERATED from the API model -
// do not edit by hand.
//
// Built from the model: `main.kit.optspec` and each feature's
// `config.options` for Optspec; entity `fields{}.type` for Entityspec.

namespace UnivecSdk;

public static class SdkSchema
{
    // Built ONCE, on first use. The spec is read on every client construction
    // and never mutated, so rebuilding it per call would be pure waste — and
    // a shared dictionary is safe for the same reason the spec is a constant:
    // MakeOptions validates AGAINST it and writes into the options, never
    // into the spec.
    //
    // A static field initializer, so the CLR's type initializer gives the
    // once-only, thread-safe guarantee with no locking on the read path.

    /// <summary>The option spec MakeOptions validates client options against.</summary>
    public static readonly Dictionary<string, object?> Optspec =
        new Dictionary<string, object?>
        {
            ["allow"] = new Dictionary<string, object?>
            {
                ["method"] = "GET,PUT,POST,PATCH,DELETE,OPTIONS",
                ["op"] = "create,update,patch,load,list,remove,command,direct,graphql",
            },
            ["apikey"] = "",
            ["auth"] = new Dictionary<string, object?>
            {
                ["basic"] = false,
                ["in"] = "",
                ["name"] = "",
                ["prefix"] = "",
            },
            ["base"] = "http://localhost:8000",
            ["clean"] = new Dictionary<string, object?>
            {
                ["active"] = true,
                ["hint"] = "0",
                ["keys"] = "key,secret,token,password,passwd,authorization,cookie,credential,signature",
                ["mask"] = "[redacted]",
                ["min"] = "4",
                ["values"] = "",
            },
            ["entity"] = new Dictionary<string, object?>
            {
                ["`$CHILD`"] = new Dictionary<string, object?>
                {
                    ["`$OPEN`"] = true,
                    ["active"] = false,
                    ["alias"] = new Dictionary<string, object?>(),
                },
            },
            ["extend"] = "`$ANY`",
            ["headers"] = new Dictionary<string, object?>
            {
                ["`$CHILD`"] = "`$STRING`",
            },
            ["prefix"] = "",
            ["secret"] = "",
            ["server"] = new Dictionary<string, object?>
            {
                ["`$CHILD`"] = "",
            },
            ["suffix"] = "",
            ["system"] = new Dictionary<string, object?>
            {
                ["fetch"] = "`$ANY`",
            },
            ["test"] = new Dictionary<string, object?>
            {
                ["active"] = false,
                ["entity"] = new Dictionary<string, object?>
                {
                    ["`$OPEN`"] = true,
                },
            },
            ["utility"] = new Dictionary<string, object?>(),
            ["feature"] = new Dictionary<string, object?>
            {
                ["`$CHILD`"] = new Dictionary<string, object?>
                {
                    ["`$OPEN`"] = true,
                    ["active"] = false,
                },
                ["audit"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["actor"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["max"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["now"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                        ["sink"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["cache"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["max"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["methods"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                        ["ttl"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["now"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["clienttrack"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["clientVersion"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            "`$NIL`",
                        },
                        ["clientName"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            "`$NIL`",
                        },
                        ["headers"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$MAP`",
                            "`$NIL`",
                        },
                        ["idgen"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                        ["sessionId"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["cost"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["budget"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["currency"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["header"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["onBudget"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["path"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["perUnit"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["rates"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$MAP`",
                            "`$NIL`",
                        },
                        ["unit"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["actor"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            "`$NIL`",
                        },
                        ["sink"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["debug"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["max"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["redact"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                        ["now"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                        ["onEntry"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["idempotency"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["header"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["methods"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                        ["ops"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                        ["keygen"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["log"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["level"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            "`$NIL`",
                        },
                        ["logger"] = "`$ANY`",
                    },
                    "`$NIL`",
                },
                ["metrics"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["now"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["netsim"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["errorTimes"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["failEvery"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["failRate"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["failStatus"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["failTimes"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["latency"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$MAP`",
                            "`$NIL`",
                        },
                        ["offline"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["rateLimitTimes"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["retryAfter"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["seed"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["sleep"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["paging"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["afterVar"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["cursorParam"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["firstVar"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["limitParam"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["pageParam"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["startPage"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["limit"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["ops"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["proxy"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["fromEnv"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["noProxy"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                        ["url"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["agent"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["ratelimit"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["burst"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["rate"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["now"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                        ["sleep"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["rbac"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["deny"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["permissions"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                        ["rules"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$MAP`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["retry"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["factor"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["maxDelay"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["minDelay"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["retries"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["statuses"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                        ["jitter"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["sleep"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["secrets"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["cache"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["exchange"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$MAP`",
                            "`$NIL`",
                        },
                        ["name"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$STRING`",
                            new List<object?>
                            {
                                "`$EXACT`",
                                "",
                            },
                            "`$NIL`",
                        },
                        ["providers"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["streaming"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["chunkDelay"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["chunkSize"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["ops"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$LIST`",
                            "`$NIL`",
                        },
                        ["sleep"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["telemetry"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["exporter"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                        ["headers"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$MAP`",
                            "`$NIL`",
                        },
                        ["idgen"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                        ["now"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["test"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["entity"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$MAP`",
                            "`$NIL`",
                        },
                        ["net"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$MAP`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
                ["timeout"] = new List<object?>
                {
                    "`$ONE`",
                    new Dictionary<string, object?>
                    {
                        ["`$OPEN`"] = true,
                        ["active"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$BOOLEAN`",
                            "`$NIL`",
                        },
                        ["ms"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$NUMBER`",
                            "`$NIL`",
                        },
                        ["clearTimer"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                        ["now"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                        ["setTimer"] = new List<object?>
                        {
                            "`$ONE`",
                            "`$FUNCTION`",
                            "`$NIL`",
                        },
                    },
                    "`$NIL`",
                },
            },
        };

    /// <summary>Per-entity data and request specs, keyed by entity name.</summary>
    public static readonly Dictionary<string, object?> Entityspec =
        new Dictionary<string, object?>();
}
