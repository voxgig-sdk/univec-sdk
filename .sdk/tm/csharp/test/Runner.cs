// Univec SDK test-runner SUPPORT (vendor-tag rollout): env overrides,
// the sdk-test-control.json skip machinery, live pacing, the
// ../../.sdk/test/test.json spec loader, and ctx/entity conversion
// helpers. The corpus ENGINE that used to live beside them
// (RunSet/MatchDeep/MatchString) is retired: both corpora now run on the
// vendored omni runner through OmniResolver.cs. The class names are
// unchanged so the emitted TestEntity/TestDirect call sites
// (TestRunner.IsControlSkipped, StructRunner.ConvertElement, ...) need no
// churn - the go split's zero-churn rule, class-scoped.

using System.Runtime.CompilerServices;
using System.Text.Json;

using Voxgig.Struct;
using Xunit;

using UnivecSdk;

// Env-var driven tests (proxy fromEnv, live overrides) require serial
// execution; determinism beats speed here.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace UnivecSdk.Test;

public class EntityTestSetup
{
    public UnivecSDK Client = null!;
    public Dictionary<string, object?> Data = new();
    public Dictionary<string, object?> Idmap = new();
    public Dictionary<string, object?> Env = new();
    public bool Explain;
    public bool Live;
    public bool SyntheticOnly;
    public long Now;
}

// Support-only remnant of the retired struct corpus runner: the shared
// spec path, the JSON loader and the loose deep-equality the feature and
// entity tests compare with. The engine half (RunSet/RunSetFull/FixJson)
// is superseded by OmniResolver over the vendored omni port.
public static class StructRunner
{
    private static string SourceDir([CallerFilePath] string path = "")
        => Path.GetDirectoryName(path)!;

    // The shared SDK test spec lives at <sdk-project>/.sdk/test/test.json,
    // i.e. ../../.sdk/test/test.json relative to this test folder.
    public static string TestJsonPath()
    {
        return Path.GetFullPath(
            Path.Combine(SourceDir(), "..", "..", ".sdk", "test", "test.json"));
    }

    // Convert a JsonElement tree into native C# types.
    public static object? ConvertElement(JsonElement el)
    {
        return el.ValueKind switch
        {
            JsonValueKind.Object => el.EnumerateObject()
                .ToDictionary(p => p.Name, p => ConvertElement(p.Value)),
            JsonValueKind.Array  => el.EnumerateArray()
                .Select(ConvertElement)
                .ToList<object?>(),
            JsonValueKind.String => el.GetString(),
            JsonValueKind.Number => el.TryGetInt64(out long l) ? (object?)l : el.GetDouble(),
            JsonValueKind.True   => (object?)true,
            JsonValueKind.False  => (object?)false,
            JsonValueKind.Null   => null,
            _                    => null,
        };
    }

    // Deep structural equality (numbers are compared by value, ignoring
    // int/long/double; NONE compares equal to null).
    public static bool DeepEqual(object? a, object? b)
    {
        // NONE (TS undefined) compares equal to null for test comparison.
        bool aNone = ReferenceEquals(a, StructUtils.NONE);
        bool bNone = ReferenceEquals(b, StructUtils.NONE);
        if (aNone) a = null;
        if (bNone) b = null;
        if (a == null && b == null) return true;
        if (a == null || b == null) return false;

        // Numeric equivalence across int/long/double.
        if (IsNumeric(a) && IsNumeric(b))
            return ToDouble(a) == ToDouble(b);

        if (a is bool ab && b is bool bb) return ab == bb;
        if (a is string sa && b is string sb) return sa == sb;

        if (a is Dictionary<string, object?> am && b is Dictionary<string, object?> bm)
        {
            if (am.Count != bm.Count) return false;
            foreach (var kv in am)
            {
                if (!bm.TryGetValue(kv.Key, out object? bv)) return false;
                if (!DeepEqual(kv.Value, bv)) return false;
            }
            return true;
        }

        // Handle any IList (List<object?>, List<string>, List<List<object?>>, etc.)
        if (a is System.Collections.IList al && b is System.Collections.IList bl)
        {
            if (al.Count != bl.Count) return false;
            for (int i = 0; i < al.Count; i++)
                if (!DeepEqual(al[i], bl[i])) return false;
            return true;
        }

        return a.Equals(b);
    }

    private static bool IsNumeric(object? v) =>
        v is int or long or double or float or short or byte;

    public static bool IsNumericValue(object? v) => IsNumeric(v);

    private static double ToDouble(object? v) => v switch
    {
        int    i => i,
        long   l => l,
        double d => d,
        float  f => f,
        _        => 0,
    };

    public static double ToDoubleVal(object? v) => ToDouble(v);
}

public static class TestRunner
{
    private static bool _envLocalLoaded;
    private static readonly object EnvLock = new();

    private static string SourceDir([CallerFilePath] string path = "")
        => Path.GetDirectoryName(path)!;

    public static string TestDir() => SourceDir();

    public static void LoadEnvLocal()
    {
        lock (EnvLock)
        {
            if (_envLocalLoaded)
            {
                return;
            }
            _envLocalLoaded = true;

            var envFile = Path.Combine(SourceDir(), "..", "..", ".env.local");
            if (!File.Exists(envFile))
            {
                return;
            }
            foreach (var rawline in File.ReadAllLines(envFile))
            {
                var line = rawline.Trim();
                if (line == "" || line.StartsWith("#"))
                {
                    continue;
                }
                var parts = line.Split('=', 2);
                if (parts.Length == 2)
                {
                    Environment.SetEnvironmentVariable(parts[0].Trim(), parts[1].Trim());
                }
            }
        }
    }

    public static Dictionary<string, object?> EnvOverride(Dictionary<string, object?> m)
    {
        if (Environment.GetEnvironmentVariable("PROJECTENV_TEST_LIVE") == "TRUE" ||
            Environment.GetEnvironmentVariable("PROJECTENV_TEST_OVERRIDE") == "TRUE")
        {
            foreach (var key in m.Keys.ToList())
            {
                var envval = Environment.GetEnvironmentVariable(key);
                if (!string.IsNullOrEmpty(envval))
                {
                    envval = envval.Trim();
                    if (envval.StartsWith("{"))
                    {
                        try
                        {
                            var el = JsonSerializer.Deserialize<JsonElement>(envval);
                            m[key] = StructRunner.ConvertElement(el);
                            continue;
                        }
                        catch (JsonException)
                        {
                            // fall through to raw string
                        }
                    }
                    m[key] = envval;
                }
            }
        }

        var explain = Environment.GetEnvironmentVariable("PROJECTENV_TEST_EXPLAIN");
        if (!string.IsNullOrEmpty(explain))
        {
            m["PROJECTENV_TEST_EXPLAIN"] = explain;
        }

        return m;
    }

    // --- sdk-test-control.json ---------------------------------------------

    private static Dictionary<string, object?>? _testControl;

    // LoadTestControl reads sdk-test-control.json from this test dir; caches
    // after first read. Returns an empty-skip default if the file is missing
    // or invalid so tests never crash on a bad config.
    public static Dictionary<string, object?> LoadTestControl()
    {
        if (_testControl != null)
        {
            return _testControl;
        }
        var ctrlPath = Path.Combine(SourceDir(), "sdk-test-control.json");
        var def = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["test"] = new Dictionary<string, object?>
            {
                ["skip"] = new Dictionary<string, object?>
                {
                    ["live"] = new Dictionary<string, object?>
                    {
                        ["direct"] = new List<object?>(),
                        ["entityOp"] = new List<object?>(),
                    },
                    ["unit"] = new Dictionary<string, object?>
                    {
                        ["direct"] = new List<object?>(),
                        ["entityOp"] = new List<object?>(),
                    },
                },
            },
        };
        try
        {
            var el = JsonSerializer.Deserialize<JsonElement>(File.ReadAllText(ctrlPath));
            _testControl = StructRunner.ConvertElement(el) as Dictionary<string, object?> ?? def;
        }
        catch (Exception)
        {
            _testControl = def;
        }
        return _testControl;
    }

    // LiveClientOptions returns the extra SDK options every LIVE client is
    // constructed with, read from sdk-test-control.json `test.client.options`.
    //
    // The generated live client knows two things: the base URL (from the
    // spec) and the credential (from the environment). Everything else about
    // how a particular API wants to be talked to - which features to switch
    // on, and with what settings - is a property of THAT API, known to the
    // project and to nothing in the toolchain.
    //
    // Merged UNDER the generated fields, so the suite's own
    // base/apikey/server values win: this ADDS to the live client, it does
    // not redirect it.
    //
    // Reserved fields are stripped HERE rather than at each merge site: the
    // generated dictionary only names a field when the model calls for one,
    // so a "base" in this block would face no competing value and would
    // silently redirect the whole suite - credential included - to another
    // host.
    private static readonly string[] LiveReserved =
        { "base", "prefix", "suffix", "server", "apikey", "secret" };

    public static Dictionary<string, object?> LiveClientOptions()
    {
        var ctrl = LoadTestControl();
        if (!ctrl.TryGetValue("test", out var testRaw) ||
            testRaw is not Dictionary<string, object?> test ||
            !test.TryGetValue("client", out var clientRaw) ||
            clientRaw is not Dictionary<string, object?> client ||
            !client.TryGetValue("options", out var optsRaw) ||
            optsRaw is not Dictionary<string, object?> opts)
        {
            return new Dictionary<string, object?>();
        }

        var out_ = new Dictionary<string, object?>();
        foreach (var kv in opts)
        {
            if (Array.IndexOf(LiveReserved, kv.Key) < 0)
            {
                out_[kv.Key] = kv.Value;
            }
        }
        return out_;
    }

    // IsControlSkipped checks sdk-test-control.json for a skip entry.
    // Returns (skip, reason).
    public static (bool, string) IsControlSkipped(string kind, string name, string mode)
    {
        var ctrl = LoadTestControl();
        if (ctrl["test"] is not Dictionary<string, object?> test ||
            !test.TryGetValue("skip", out var skipRaw) ||
            skipRaw is not Dictionary<string, object?> skip ||
            !skip.TryGetValue(mode, out var modeRaw) ||
            modeRaw is not Dictionary<string, object?> modeMap ||
            !modeMap.TryGetValue(kind, out var itemsRaw) ||
            itemsRaw is not List<object?> items)
        {
            return (false, "");
        }
        foreach (var raw in items)
        {
            if (raw is not Dictionary<string, object?> item)
            {
                continue;
            }
            var reason = item.TryGetValue("reason", out var r) ? r as string ?? "" : "";
            if (kind == "direct" &&
                item.TryGetValue("test", out var t) && t as string == name)
            {
                return (true, reason);
            }
            if (kind == "entityOp")
            {
                var ent = item.TryGetValue("entity", out var e) ? e as string ?? "" : "";
                var op = item.TryGetValue("op", out var o) ? o as string ?? "" : "";
                if (ent + "." + op == name)
                {
                    return (true, reason);
                }
            }
        }
        return (false, "");
    }

    // LiveDelayMs returns the configured per-test live delay in ms; default 500.
    public static int LiveDelayMs()
    {
        var ctrl = LoadTestControl();
        if (ctrl["test"] is Dictionary<string, object?> test &&
            test.TryGetValue("live", out var liveRaw) &&
            liveRaw is Dictionary<string, object?> live &&
            live.TryGetValue("delayMs", out var v))
        {
            var n = UnivecSdk.Helpers.ToInt(v);
            if (n >= 0)
            {
                return n;
            }
        }
        return 500;
    }

    // --- test.json spec ------------------------------------------------------

    private static Dictionary<string, object?>? _testSpec;

    public static Dictionary<string, object?> LoadTestSpec()
    {
        if (_testSpec != null)
        {
            return _testSpec;
        }
        var el = JsonSerializer.Deserialize<JsonElement>(
            File.ReadAllText(StructRunner.TestJsonPath()));
        _testSpec = StructRunner.ConvertElement(el) as Dictionary<string, object?>
            ?? new Dictionary<string, object?>();
        return _testSpec;
    }

    public static Dictionary<string, object?>? GetSpec(
        Dictionary<string, object?>? spec, params string[] keys)
    {
        object? cur = spec;
        foreach (var key in keys)
        {
            if (cur is Dictionary<string, object?> m)
            {
                cur = m.TryGetValue(key, out var v) ? v : null;
            }
            else
            {
                return null;
            }
        }
        return cur as Dictionary<string, object?>;
    }

    // --- context factories ------------------------------------------------

    // MakeCtxFromMap creates a Context from a JSON test entry's ctx or args map.
    public static Context MakeCtxFromMap(Dictionary<string, object?>? ctxmap,
        UnivecSDK? client, Utility? utility)
    {
        ctxmap ??= new Dictionary<string, object?>();

        var ctx = new Context(ctxmap, null);

        if (client != null)
        {
            ctx.Client = client;
            ctx.Utility = utility;
        }
        if (ctx.Options == null && client != null)
        {
            ctx.Options = client.OptionsMap();
        }

        // Handle spec from JSON map (Context expects a Spec, JSON gives map).
        if (ctxmap.TryGetValue("spec", out var specRaw) &&
            specRaw is Dictionary<string, object?> specMap)
        {
            ctx.Spec = new Spec(specMap);
        }

        // Handle result from JSON map.
        if (ctxmap.TryGetValue("result", out var resRaw) &&
            resRaw is Dictionary<string, object?> resMap)
        {
            ctx.Result = new Result(resMap);
            if (resMap.TryGetValue("err", out var errRaw) &&
                errRaw is Dictionary<string, object?> errMap &&
                errMap.TryGetValue("message", out var msgRaw) &&
                msgRaw is string msg)
            {
                ctx.Result.Err = new UnivecError("", msg, null);
            }
        }

        // Handle response from JSON map.
        if (ctxmap.TryGetValue("response", out var respRaw) &&
            respRaw is Dictionary<string, object?> respMap)
        {
            ctx.Response = new Response(respMap);
            if (respMap.TryGetValue("body", out var body) && body != null)
            {
                var bodyCopy = body;
                ctx.Response.JsonFunc = () => bodyCopy;
            }
            if (respMap.TryGetValue("headers", out var headersRaw) &&
                headersRaw is Dictionary<string, object?> headers)
            {
                var lowerHeaders = new Dictionary<string, object?>();
                foreach (var kv in headers)
                {
                    lowerHeaders[kv.Key.ToLowerInvariant()] = kv.Value;
                }
                ctx.Response.Headers = lowerHeaders;
            }
        }

        return ctx;
    }

    public static void FixCtx(Context ctx, UnivecSDK client)
    {
        if (ctx.Client != null && ctx.Options == null)
        {
            ctx.Options = ctx.Client.OptionsMap();
        }
    }

    // ErrFromMap creates an error from a JSON map like
    // {"message": "...", "code": "..."}.
    public static Exception? ErrFromMap(Dictionary<string, object?>? m)
    {
        if (m == null)
        {
            return null;
        }
        var msg = m.TryGetValue("message", out var msgRaw) ? msgRaw as string : null;
        if (string.IsNullOrEmpty(msg))
        {
            return null;
        }
        var code = m.TryGetValue("code", out var codeRaw) ? codeRaw as string ?? "" : "";
        return new UnivecError(code, msg, null);
    }

    // EntityListToData extracts data maps from a list of entity objects.
    public static List<object?> EntityListToData(List<object?> list)
    {
        var outlist = new List<object?>();
        foreach (var item in list)
        {
            if (item is IEntity ent)
            {
                if (ent.Data() is Dictionary<string, object?> dm)
                {
                    outlist.Add(dm);
                }
            }
            else if (item is Dictionary<string, object?> m)
            {
                outlist.Add(m);
            }
        }
        return outlist;
    }
}
