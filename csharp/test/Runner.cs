// Univec SDK test runner - shared infrastructure for the generated
// test suites (C# twin of tm/go/test/runner_test.go).

using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.RegularExpressions;

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
        if (Environment.GetEnvironmentVariable("UNIVEC_TEST_LIVE") == "TRUE" ||
            Environment.GetEnvironmentVariable("UNIVEC_TEST_OVERRIDE") == "TRUE")
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

        var explain = Environment.GetEnvironmentVariable("UNIVEC_TEST_EXPLAIN");
        if (!string.IsNullOrEmpty(explain))
        {
            m["UNIVEC_TEST_EXPLAIN"] = explain;
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

    // --- runset ---------------------------------------------------------------

    public delegate object? RunSubject(Dictionary<string, object?> entry);

    public static void RunSet(Dictionary<string, object?>? testspec, RunSubject subject)
    {
        if (testspec == null ||
            !testspec.TryGetValue("set", out var setRaw) ||
            setRaw is not List<object?> set)
        {
            return;
        }

        for (var i = 0; i < set.Count; i++)
        {
            if (set[i] is not Dictionary<string, object?> entry)
            {
                continue;
            }

            var mark = entry.TryGetValue("mark", out var m) && m != null
                ? $" (mark={m})" : "";

            object? result = null;
            Exception? err = null;
            try
            {
                result = subject(entry);
            }
            catch (Exception ex)
            {
                err = ex;
            }

            var expectedErr = entry.TryGetValue("err", out var ee) ? ee : null;

            if (err != null)
            {
                if (expectedErr != null)
                {
                    var errMsg = err.Message;
                    if (expectedErr is string expStr)
                    {
                        Assert.True(MatchString(expStr, errMsg),
                            $"entry {i}{mark}: error mismatch: got \"{errMsg}\"," +
                            $" want contains \"{expStr}\"");
                    }
                    // err: true means any error is acceptable.
                    if (entry.TryGetValue("match", out var ms) &&
                        ms is Dictionary<string, object?> matchSpecErr)
                    {
                        var resultMap = new Dictionary<string, object?>
                        {
                            ["in"] = entry.TryGetValue("in", out var inv) ? inv : null,
                            ["out"] = JsonNormalize(result),
                            ["err"] = new Dictionary<string, object?>
                            {
                                ["message"] = err.Message,
                            },
                        };
                        MatchDeep(i, mark, matchSpecErr, resultMap, "");
                    }
                    continue;
                }
                Assert.Fail($"entry {i}{mark}: unexpected error: {err}");
                continue;
            }

            if (expectedErr != null)
            {
                Assert.Fail($"entry {i}{mark}: expected error containing" +
                    $" \"{expectedErr}\" but got result: {JsonStr(result)}");
                continue;
            }

            var matched = false;
            if (entry.TryGetValue("match", out var msRaw) &&
                msRaw is Dictionary<string, object?> matchSpec)
            {
                var resultMap = new Dictionary<string, object?>
                {
                    ["in"] = entry.TryGetValue("in", out var inv) ? inv : null,
                    ["out"] = JsonNormalize(result),
                };
                if (entry.TryGetValue("args", out var args) && args != null)
                {
                    resultMap["args"] = args;
                }
                else if (entry.TryGetValue("in", out var inv2) && inv2 != null)
                {
                    resultMap["args"] = new List<object?> { inv2 };
                }
                if (entry.TryGetValue("ctx", out var ctxData) && ctxData != null)
                {
                    resultMap["ctx"] = ctxData;
                }
                MatchDeep(i, mark, matchSpec, resultMap, "");
                matched = true;
            }

            var expectedOut = entry.TryGetValue("out", out var eo) ? eo : null;
            if (expectedOut == null && matched)
            {
                continue;
            }
            if (expectedOut != null)
            {
                var normResult = JsonNormalize(result);
                var normExpected = JsonNormalize(expectedOut);
                Assert.True(DeepEqual(normResult, normExpected),
                    $"entry {i}{mark}: output mismatch:\n  got:  {JsonStr(normResult)}" +
                    $"\n  want: {JsonStr(normExpected)}");
            }
        }
    }

    // JsonNormalize converts an arbitrary value graph into the canonical
    // loose object model: maps/lists recursively, all integral numbers to
    // long. Non-JSON values (delegates, SDK objects) pass through as-is.
    public static object? JsonNormalize(object? val)
    {
        switch (val)
        {
            case null:
                return null;
            case Dictionary<string, object?> map:
            {
                var norm = new Dictionary<string, object?>();
                foreach (var kv in map)
                {
                    norm[kv.Key] = JsonNormalize(kv.Value);
                }
                return norm;
            }
            case List<object?> list:
                return list.Select(JsonNormalize).ToList();
            case System.Collections.IList ilist:
            {
                var norm = new List<object?>();
                foreach (var item in ilist)
                {
                    norm.Add(JsonNormalize(item));
                }
                return norm;
            }
            case int n:
                return (long)n;
            case short n:
                return (long)n;
            case byte n:
                return (long)n;
            case float f:
                return f == Math.Floor(f) ? (long)f : (double)f;
            case double d:
                return d == Math.Floor(d) ? (long)d : d;
            default:
                return val;
        }
    }

    public static string JsonStr(object? val)
    {
        try
        {
            return StructUtils.Jsonify(val, -1);
        }
        catch (Exception)
        {
            return val?.ToString() ?? "null";
        }
    }

    public static bool DeepEqual(object? a, object? b)
    {
        return StructRunner.DeepEqual(a, b);
    }

    public static void MatchDeep(int entryIdx, string mark, object? check,
        object? baseval, string path)
    {
        if (check == null)
        {
            return;
        }

        if (check is Dictionary<string, object?> checkMap)
        {
            foreach (var kv in checkMap)
            {
                var childPath = path + "." + kv.Key;
                object? childBase = null;
                if (baseval is Dictionary<string, object?> baseMap &&
                    baseMap.TryGetValue(kv.Key, out var bv))
                {
                    childBase = bv;
                }
                MatchDeep(entryIdx, mark, kv.Value, childBase, childPath);
            }
        }
        else if (check is List<object?> checkList)
        {
            for (var i = 0; i < checkList.Count; i++)
            {
                var childPath = $"{path}[{i}]";
                object? childBase = null;
                if (baseval is List<object?> baseList && i < baseList.Count)
                {
                    childBase = baseList[i];
                }
                MatchDeep(entryIdx, mark, checkList[i], childBase, childPath);
            }
        }
        else
        {
            if (check is string checkStr)
            {
                if (checkStr == "__EXISTS__")
                {
                    Assert.True(baseval != null,
                        $"entry {entryIdx}{mark}: match {path}: expected value" +
                        " to exist but got null");
                    return;
                }
                if (checkStr == "__UNDEF__")
                {
                    Assert.True(baseval == null,
                        $"entry {entryIdx}{mark}: match {path}: expected null" +
                        $" but got {baseval}");
                    return;
                }
            }

            var normCheck = JsonNormalize(check);
            var normBase = JsonNormalize(baseval);

            if (!DeepEqual(normCheck, normBase))
            {
                if (check is string cs && cs != "" &&
                    MatchString(cs, StructUtils.Stringify(baseval)))
                {
                    return;
                }
                Assert.Fail($"entry {entryIdx}{mark}: match {path}:" +
                    $" got {JsonStr(normBase)}, want {JsonStr(normCheck)}");
            }
        }
    }

    // MatchString checks if val matches pattern. If pattern is /regex/, use
    // a regex; otherwise do a case-insensitive contains.
    public static bool MatchString(string pattern, string val)
    {
        if (pattern.Length >= 2 && pattern[0] == '/' && pattern[^1] == '/')
        {
            try
            {
                return Regex.IsMatch(val, pattern[1..^1]);
            }
            catch (ArgumentException)
            {
                return false;
            }
        }
        return val.ToLowerInvariant().Contains(pattern.ToLowerInvariant());
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
