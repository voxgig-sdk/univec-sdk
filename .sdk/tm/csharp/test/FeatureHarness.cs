// Offline feature-test harness: a faithful miniature of the real operation
// pipeline (same hook order and short-circuit rules as the generated entity
// op code) driven against a configurable mock transport, with no live server
// and no API-specific fixtures. C# twin of tm/go/test/feature_harness_test.go.
//
// SEPARATE FROM FeatureTest.cs ON PURPOSE. `target add` drops the
// cross-feature suite when a project trims its feature set (it constructs
// every shipped feature by name), but PipelineTest.cs uses these Fh* helpers
// too - leaving them in FeatureTest.cs took the whole test assembly down
// with it.

using System.Text.RegularExpressions;

using Voxgig.Struct;
using Xunit;

using UnivecSdk;
using UnivecSdk.Feature;

namespace UnivecSdk.Test;

// --- harness ----------------------------------------------------------------

// FhClock is a deterministic virtual clock: Now() advances only when
// Sleep(ms) is called, so timing-based features can be asserted without
// real delays.
internal class FhClock
{
    public long T;
    public long Now() => T;
    public void Sleep(int ms) => T += ms;
    public void Advance(int ms) => T += ms;
}

// FhRecorder is a mock transport recording every call, replying via an
// optional Reply func (default: 200 with a call counter).
internal class FhRecorder
{
    public List<Dictionary<string, object?>> Calls = new();
    public Func<int, Dictionary<string, object?>, object?>? Reply;

    public object? Fetch(Context ctx, string url, Dictionary<string, object?> fetchdef)
    {
        Calls.Add(new Dictionary<string, object?>
        {
            ["url"] = url,
            ["fetchdef"] = fetchdef,
        });
        if (Reply != null)
        {
            return Reply(Calls.Count, fetchdef);
        }
        return Fh.Response(200, new Dictionary<string, object?>
        {
            ["ok"] = true,
            ["n"] = Calls.Count,
        }, null);
    }

    public Dictionary<string, object?> Headers(int i)
    {
        var fetchdef = Calls[i]["fetchdef"] as Dictionary<string, object?>;
        return fetchdef?["headers"] as Dictionary<string, object?>
            ?? new Dictionary<string, object?>();
    }

    public Dictionary<string, object?> Fetchdef(int i)
    {
        return Calls[i]["fetchdef"] as Dictionary<string, object?>
            ?? new Dictionary<string, object?>();
    }

    public string Url(int i)
    {
        return Calls[i]["url"] as string ?? "";
    }
}

internal class FhOpSpec
{
    public string Entity = "";
    public string Op = "";
    public string Method = "";
    public string Path = "";
    public Dictionary<string, object?>? Query;
    public Dictionary<string, object?>? Headers;
    public object? Body;
    public Dictionary<string, object?>? Ctrl;
}

internal class FhOpResult
{
    public bool Ok;
    public object? Data;
    public Exception? Err;
    public Result? Result;
    public Context? Ctx;
}

// FhHarness wires features (in init order) to a mock transport and a mini
// operation pipeline.
internal class FhHarness
{
    public UnivecSDK Client = null!;
    public Utility Utility = null!;
    public Context Rootctx = null!;
    public string Base = "http://api.test";

    private static string FhDefaultMethod(string op)
    {
        return op switch
        {
            "create" => "POST",
            "update" => "PATCH",
            "remove" => "DELETE",
            _ => "GET",
        };
    }

    private static string FhBuildUrl(Spec spec)
    {
        var keys = spec.Query.Where(kv => kv.Value != null)
            .Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal).ToList();
        var qs = string.Join("&", keys.Select(k =>
            Uri.EscapeDataString(k) + "=" +
            Uri.EscapeDataString(StructUtils.Stringify(spec.Query[k]))));
        var url = spec.Base + spec.Path;
        if (qs != "")
        {
            url += "?" + qs;
        }
        return url;
    }

    // Op runs one operation through the mini pipeline (mirrors the generated
    // entity op code: hook, short-circuit, make*, hook, ...).
    public FhOpResult Op(FhOpSpec o)
    {
        var entity = o.Entity == "" ? "widget" : o.Entity;
        var opname = o.Op == "" ? "load" : o.Op;
        var method = o.Method == "" ? FhDefaultMethod(opname) : o.Method;
        var ctrl = o.Ctrl ?? new Dictionary<string, object?>();

        var ctx = Utility.MakeContext(new Dictionary<string, object?>
        {
            ["opname"] = opname,
            ["ctrl"] = ctrl,
        }, Rootctx);
        ctx.Op = new Operation(new Dictionary<string, object?>
        {
            ["entity"] = entity,
            ["name"] = opname,
        });

        Utility.FeatureHook(ctx, "PostConstructEntity");

        Utility.FeatureHook(ctx, "PrePoint");
        if (ctx.Out.TryGetValue("point", out var pointOut) && pointOut is Exception perr)
        {
            return Fail(ctx, perr);
        }

        Utility.FeatureHook(ctx, "PreSpec");
        var path = o.Path == "" ? "/" + entity : o.Path;
        var headers = new Dictionary<string, object?>(o.Headers
            ?? new Dictionary<string, object?>());
        var query = new Dictionary<string, object?>(o.Query
            ?? new Dictionary<string, object?>());
        ctx.Spec = new Spec(new Dictionary<string, object?>
        {
            ["method"] = method,
            ["base"] = Base,
            ["path"] = path,
            ["headers"] = headers,
            ["query"] = query,
            ["step"] = "start",
        });
        if (o.Body != null)
        {
            ctx.Spec.Body = o.Body;
        }

        Utility.FeatureHook(ctx, "PreRequest");
        ctx.Spec.Url = FhBuildUrl(ctx.Spec);

        var fetchdef = new Dictionary<string, object?>
        {
            ["url"] = ctx.Spec.Url,
            ["method"] = ctx.Spec.Method,
            ["headers"] = ctx.Spec.Headers,
        };
        if (ctx.Spec.Body != null)
        {
            fetchdef["body"] = ctx.Spec.Body;
        }

        object? response = null;
        Exception? fetchErr = null;
        if (ctx.Out.TryGetValue("request", out var reqOut) && reqOut != null)
        {
            response = reqOut;
        }
        else
        {
            try
            {
                response = Utility.Fetcher(ctx, ctx.Spec.Url, fetchdef);
            }
            catch (Exception ex)
            {
                fetchErr = ex;
            }
        }
        if (response is Dictionary<string, object?> rm)
        {
            ctx.Response = new Response(rm);
        }

        Utility.FeatureHook(ctx, "PreResponse");
        FhPopulateResult(ctx, response, fetchErr);
        Utility.FeatureHook(ctx, "PreResult");
        Utility.FeatureHook(ctx, "PreDone");

        if (ctx.Result != null && ctx.Result.Ok)
        {
            return new FhOpResult
            {
                Ok = true,
                Data = ctx.Result.Resdata,
                Result = ctx.Result,
                Ctx = ctx,
            };
        }

        Exception err;
        if (ctx.Result?.Err != null)
        {
            err = ctx.Result.Err;
        }
        else
        {
            err = ctx.MakeError("op_failed", "operation failed");
        }
        return Fail(ctx, err);
    }

    private FhOpResult Fail(Context ctx, Exception err)
    {
        ctx.Ctrl.Err = err;
        Utility.FeatureHook(ctx, "PreUnexpected");
        return new FhOpResult
        {
            Ok = false,
            Err = err,
            Result = ctx.Result,
            Ctx = ctx,
        };
    }

    private static void FhPopulateResult(Context ctx, object? response, Exception? fetchErr)
    {
        var result = new Result(new Dictionary<string, object?>());
        ctx.Result = result;

        if (fetchErr != null)
        {
            result.Err = fetchErr;
            return;
        }

        if (response is not Dictionary<string, object?> rm)
        {
            result.Err = ctx.MakeError("request_no_response", "response: undefined");
            return;
        }

        var resp = new Response(rm);
        result.Status = resp.Status;
        result.StatusText = resp.StatusText;
        if (resp.Headers is Dictionary<string, object?> hm)
        {
            result.Headers = hm;
        }
        if (resp.JsonFunc != null)
        {
            result.Body = resp.JsonFunc();
        }
        result.Resdata = result.Body;

        if (result.Status >= 400)
        {
            result.Err = ctx.MakeError("request_status",
                $"request: {result.Status}: {result.StatusText}");
        }
        else if (resp.Err != null)
        {
            result.Err = resp.Err;
        }
        if (result.Err == null)
        {
            result.Ok = true;
        }
    }
}

internal static class Fh
{
    // HasFeature is true when this SDK was generated with the named feature.
    public static bool HasFeature(string name)
    {
        var config = SdkConfig.MakeConfig();
        return config.TryGetValue("feature", out var fraw) &&
            fraw is Dictionary<string, object?> fm &&
            fm.TryGetValue(name, out var f) && f != null;
    }

    public static bool SkipWithout(params string[] names)
    {
        return names.Any(name => !HasFeature(name));
    }

    // Response builds a transport-shaped response the pipeline understands.
    public static Dictionary<string, object?> Response(int status, object? data,
        Dictionary<string, object?>? headers)
    {
        var h = new Dictionary<string, object?>();
        if (headers != null)
        {
            foreach (var kv in headers)
            {
                h[kv.Key.ToLowerInvariant()] = kv.Value;
            }
        }
        return new Dictionary<string, object?>
        {
            ["status"] = status,
            ["statusText"] = status >= 400 ? "ERR" : "OK",
            ["body"] = "not-used",
            ["json"] = (Func<object?>)(() => data),
            ["headers"] = h,
        };
    }

    // Make constructs the harness: a real (test-mode) client, an isolated
    // utility whose fetcher is the mock server, and the requested features
    // initialised against it. Fires PostConstruct once wiring is complete.
    public static FhHarness Make(FetcherFunc? server,
        params (BaseFeature f, Dictionary<string, object?>? options)[] features)
    {
        var client = UnivecSDK.TestSDK(null, null);
        client.Features = new List<BaseFeature>();

        var utility = client.GetUtility();
        if (server == null)
        {
            var rec = new FhRecorder();
            server = rec.Fetch;
        }
        utility.Fetcher = server;

        var rootctx = utility.MakeContext(new Dictionary<string, object?>
        {
            ["client"] = client,
            ["utility"] = utility,
        }, client.GetRootCtx());

        foreach (var (f, options) in features)
        {
            var fopts = new Dictionary<string, object?> { ["active"] = true };
            if (options != null)
            {
                foreach (var kv in options)
                {
                    fopts[kv.Key] = kv.Value;
                }
            }
            f.Init(rootctx, fopts);
            client.Features.Add(f);
        }

        utility.FeatureHook(rootctx, "PostConstruct");

        return new FhHarness
        {
            Client = client,
            Utility = utility,
            Rootctx = rootctx,
        };
    }

    // ErrCode extracts the SDK error code, "" otherwise.
    public static string ErrCode(Exception? err)
    {
        return err is UnivecError se ? se.Code : "";
    }
}
