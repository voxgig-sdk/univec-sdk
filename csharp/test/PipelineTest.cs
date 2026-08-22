// Direct unit tests for the operation-pipeline utilities. The generated
// entity tests exercise the happy path; these drive the error and edge
// branches (missing spec/response/result, 4xx handling, transport
// failures, feature add semantics incl. __before__/__after__/__replace__
// ordering, auth header shaping) that a normal success-path op never
// reaches. All utilities are reached through the client utility, so this
// suite is API-agnostic. C# twin of tm/go/test/pipeline_test.go. Reuses
// the Fh* helpers from FeatureTest.cs (same namespace).

using Xunit;

using Voxgig.Struct;

using UnivecSdk;
using UnivecSdk.Feature;

namespace UnivecSdk.Test;

public class PipelineTest
{
    // PlClient builds a client + isolated utility for pipeline utility tests.
    private static (UnivecSDK, Utility) PlClient(Dictionary<string, object?>? sdkopts)
    {
        var client = UnivecSDK.TestSDK(null, sdkopts);
        return (client, client.GetUtility());
    }

    private static Context PlCtx(UnivecSDK client, Utility utility,
        Dictionary<string, object?>? ctrl)
    {
        var ctxmap = new Dictionary<string, object?>
        {
            ["opname"] = "load",
            ["client"] = client,
            ["utility"] = utility,
        };
        if (ctrl != null)
        {
            ctxmap["ctrl"] = ctrl;
        }
        return utility.MakeContext(ctxmap, client.GetRootCtx());
    }

    private static string ErrCode(Action act)
    {
        try
        {
            act();
            return "";
        }
        catch (UnivecError err)
        {
            return err.Code;
        }
        catch (Exception)
        {
            return "";
        }
    }

    // --- feature order (PR #2) ----------------------------------------------

    // ResolveOpts runs makeOptions over an options.feature value (map or list)
    // and returns the derived options so __derived__.featureorder can be
    // asserted.
    private static Dictionary<string, object?> ResolveOpts(object? feature)
    {
        var (client, utility) = PlClient(null);
        var ctx = utility.MakeContext(new Dictionary<string, object?>
        {
            ["client"] = client,
            ["utility"] = utility,
            ["options"] = new Dictionary<string, object?> { ["feature"] = feature },
            ["config"] = new Dictionary<string, object?>
            {
                ["options"] = new Dictionary<string, object?>(),
            },
        }, client.GetRootCtx());
        return utility.MakeOptions(ctx);
    }

    private static string FeatureOrder(Dictionary<string, object?> opts)
    {
        var raw = StructUtils.GetPath(opts,
            StructUtils.Jt("__derived__", "featureorder")) as List<object?>
            ?? new List<object?>();
        return string.Join(",", raw.Select(x => x as string ?? ""));
    }

    [Fact]
    public void FeatureOrderMapIsTestFirst()
    {
        var o = ResolveOpts(new Dictionary<string, object?>
        {
            ["metrics"] = new Dictionary<string, object?> { ["active"] = true },
            ["test"] = new Dictionary<string, object?> { ["active"] = true },
        });
        Assert.Equal("test,metrics", FeatureOrder(o));
    }

    [Fact]
    public void FeatureOrderArrayPreservesExplicitOrder()
    {
        var o = ResolveOpts(new List<object?>
        {
            new Dictionary<string, object?> { ["name"] = "metrics", ["active"] = true },
            new Dictionary<string, object?> { ["name"] = "test", ["active"] = true },
        });
        Assert.Equal("metrics,test", FeatureOrder(o));
        // The list is normalized to a map for merge/init; opts are preserved.
        Assert.True(Equals(StructUtils.GetPath(o,
            StructUtils.Jt("feature", "metrics", "active")), true));
        Assert.True(Equals(StructUtils.GetPath(o,
            StructUtils.Jt("feature", "test", "active")), true));
    }

    [Fact]
    public void FeatureOrderMapNoTestIsSorted()
    {
        var o = ResolveOpts(new Dictionary<string, object?>
        {
            ["retry"] = new Dictionary<string, object?> { ["active"] = true },
            ["cache"] = new Dictionary<string, object?> { ["active"] = true },
        });
        Assert.Equal("cache,retry", FeatureOrder(o));
    }

    // PlEntity is a minimal fake entity for the list-wrap test.
    private class PlEntity : IEntity
    {
        public string Name = "x";
        public List<object?> Made;

        public PlEntity(string name, List<object?> made)
        {
            Name = name;
            Made = made;
        }

        public string GetName() => Name;
        public IEntity Make() => new PlEntity(Name, Made);

        public object? Data(object? data = null)
        {
            if (data != null)
            {
                Made.Add(data);
            }
            return null;
        }

        public object? Match(object? match = null) => null;

        // The deletion half of the entity contract, mirroring
        // UnivecEntityBase: `remove` marks the instance, which keeps the
        // data it held but is no longer a live record.
        private bool _deleted = false;

        public void MarkDeleted()
        {
            this._deleted = true;
        }

        public bool Deleted()
        {
            return this._deleted;
        }
    }

    // --- MakeResponse -------------------------------------------------------

    [Fact]
    public void MakeResponseGuardsMissingSpecResponseResult()
    {
        var (client, utility) = PlClient(null);

        var ctx = PlCtx(client, utility, null);
        ctx.Spec = null;
        ctx.Response = new Response(new Dictionary<string, object?>());
        ctx.Result = new Result(new Dictionary<string, object?>());
        Assert.Equal("response_no_spec", ErrCode(() => utility.MakeResponse(ctx)));

        ctx = PlCtx(client, utility, null);
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "s" });
        ctx.Response = null;
        ctx.Result = new Result(new Dictionary<string, object?>());
        Assert.Equal("response_no_response", ErrCode(() => utility.MakeResponse(ctx)));

        ctx = PlCtx(client, utility, null);
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "s" });
        ctx.Response = new Response(new Dictionary<string, object?>());
        ctx.Result = null;
        Assert.Equal("response_no_result", ErrCode(() => utility.MakeResponse(ctx)));
    }

    [Fact]
    public void MakeResponse4xxSetsResultErrAndCopiesHeaders()
    {
        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "s" });
        ctx.Response = new Response(Fh.Response(404, null,
            new Dictionary<string, object?> { ["x-a"] = "1" }));
        ctx.Result = new Result(new Dictionary<string, object?>());
        utility.MakeResponse(ctx);
        Assert.NotNull(ctx.Result!.Err);
        Assert.Equal(404, ctx.Result.Status);
        Assert.Equal("1", ctx.Result.Headers["x-a"]);
    }

    [Fact]
    public void MakeResponse2xxParsesBodyAndMarksOk()
    {
        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "s" });
        ctx.Response = new Response(Fh.Response(200,
            new Dictionary<string, object?> { ["v"] = 1 }, null));
        ctx.Result = new Result(new Dictionary<string, object?>());
        utility.MakeResponse(ctx);
        Assert.True(ctx.Result!.Ok, "expected ok result");
        var body = ctx.Result.Body as Dictionary<string, object?>;
        Assert.True(body != null && Equals(body["v"], 1),
            $"expected parsed body, got {ctx.Result.Body}");
    }

    [Fact]
    public void MakeResponseRecordsToCtrlExplain()
    {
        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, new Dictionary<string, object?>
        {
            ["explain"] = new Dictionary<string, object?>(),
        });
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "s" });
        ctx.Response = new Response(Fh.Response(200,
            new Dictionary<string, object?> { ["v"] = 2 }, null));
        ctx.Result = new Result(new Dictionary<string, object?>());
        utility.MakeResponse(ctx);
        Assert.True(ctx.Ctrl.Explain!.ContainsKey("result"),
            "expected explain.result recorded");
    }

    // --- MakeResult ----------------------------------------------------------

    [Fact]
    public void MakeResultGuardsMissingSpecResult()
    {
        var (client, utility) = PlClient(null);

        var ctx = PlCtx(client, utility, null);
        ctx.Spec = null;
        ctx.Result = new Result(new Dictionary<string, object?>());
        Assert.Equal("result_no_spec", ErrCode(() => utility.MakeResult(ctx)));

        ctx = PlCtx(client, utility, null);
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "s" });
        ctx.Result = null;
        Assert.Equal("result_no_result", ErrCode(() => utility.MakeResult(ctx)));
    }

    [Fact]
    public void MakeResultListOpWrapsResdataIntoEntities()
    {
        var (client, utility) = PlClient(null);
        var made = new List<object?>();
        var ctx = PlCtx(client, utility, null);
        ctx.Op = new Operation(new Dictionary<string, object?>
        {
            ["entity"] = "x",
            ["name"] = "list",
        });
        ctx.Entity = new PlEntity("x", made);
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "s" });
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["resdata"] = new List<object?>
            {
                new Dictionary<string, object?> { ["a"] = 1 },
                new Dictionary<string, object?> { ["a"] = 2 },
            },
        });
        var result = utility.MakeResult(ctx);
        var resdata = result.Resdata as List<object?>;
        Assert.True(resdata != null && resdata.Count == 2,
            $"expected 2 wrapped entities, got {result.Resdata}");
        Assert.Equal(2, made.Count);
    }

    [Fact]
    public void MakeResultEmptyListYieldsEmptyResdata()
    {
        var (client, utility) = PlClient(null);
        var made = new List<object?>();
        var ctx = PlCtx(client, utility, null);
        ctx.Op = new Operation(new Dictionary<string, object?>
        {
            ["entity"] = "x",
            ["name"] = "list",
        });
        ctx.Entity = new PlEntity("x", made);
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "s" });
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["resdata"] = new List<object?>(),
        });
        var result = utility.MakeResult(ctx);
        var resdata = result.Resdata as List<object?>;
        Assert.True(resdata != null && resdata.Count == 0,
            $"expected empty resdata list, got {result.Resdata}");
    }

    // --- MakeRequest ----------------------------------------------------------

    private static Utility UtilWith(UnivecSDK client, FetcherFunc fetcher)
    {
        var u = client.GetUtility();
        u.Fetcher = fetcher;
        return u;
    }

    private static Spec ReqSpec()
    {
        return new Spec(new Dictionary<string, object?>
        {
            ["base"] = "http://h",
            ["path"] = "a",
            ["method"] = "GET",
            ["headers"] = new Dictionary<string, object?>(),
            ["step"] = "s",
        });
    }

    [Fact]
    public void MakeRequestGuardsMissingSpec()
    {
        var (client, _) = PlClient(null);
        var utility = UtilWith(client, (_, _, _) => Fh.Response(200, null, null));
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = null;
        Assert.Equal("request_no_spec", ErrCode(() => utility.MakeRequest(ctx)));
    }

    [Fact]
    public void MakeRequestTransportErrorCarriedOnResponse()
    {
        var (client, _) = PlClient(null);
        var utility = UtilWith(client, (ctx2, _, _) => throw ctx2.MakeError("boom", "boom"));
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = ReqSpec();
        var resp = utility.MakeRequest(ctx);
        Assert.True(resp.Err is UnivecError pe && pe.Code == "boom",
            $"expected transport error carried, got {resp.Err}");
    }

    [Fact]
    public void MakeRequestNullTransportResultBecomesResponseError()
    {
        var (client, _) = PlClient(null);
        var utility = UtilWith(client, (_, _, _) => null);
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = ReqSpec();
        var resp = utility.MakeRequest(ctx);
        Assert.NotNull(resp.Err);
    }

    [Fact]
    public void MakeRequestNormalTransportResponseWrapped()
    {
        var (client, _) = PlClient(null);
        var utility = UtilWith(client, (_, _, _) => Fh.Response(200,
            new Dictionary<string, object?> { ["a"] = 1 }, null));
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = ReqSpec();
        var resp = utility.MakeRequest(ctx);
        Assert.Equal(200, resp.Status);
    }

    [Fact]
    public void MakeRequestRecordsFetchdefToCtrlExplain()
    {
        var (client, _) = PlClient(null);
        var utility = UtilWith(client, (_, _, _) => Fh.Response(200, null, null));
        var ctx = PlCtx(client, utility, new Dictionary<string, object?>
        {
            ["explain"] = new Dictionary<string, object?>(),
        });
        ctx.Spec = ReqSpec();
        utility.MakeRequest(ctx);
        Assert.True(ctx.Ctrl.Explain!.ContainsKey("fetchdef"),
            "expected explain.fetchdef recorded");
    }

    // --- Done / MakeError -------------------------------------------------------

    [Fact]
    public void DoneReturnsResdataOnSuccess()
    {
        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, null);
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["ok"] = true,
            ["resdata"] = new Dictionary<string, object?> { ["id"] = "i1" },
        });
        var result = utility.Done(ctx);
        var om = result as Dictionary<string, object?>;
        Assert.True(om != null && Equals(om["id"], "i1"),
            $"expected resdata, got {result}");
    }

    [Fact]
    public void DoneErrorsWhenNotOk()
    {
        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, null);
        ctx.Result = new Result(new Dictionary<string, object?> { ["ok"] = false });
        Assert.ThrowsAny<Exception>(() => utility.Done(ctx));
    }

    [Fact]
    public void MakeErrorReturnsResdataWhenThrowFalse()
    {
        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, null);
        ctx.Ctrl.Throw = false;
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["ok"] = false,
            ["resdata"] = "fallback",
        });
        var result = utility.MakeError(ctx, ctx.MakeError("test_code", "test message"));
        Assert.Equal("fallback", result);
    }

    [Fact]
    public void MakeErrorRecordsToCtrlExplain()
    {
        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, new Dictionary<string, object?>
        {
            ["explain"] = new Dictionary<string, object?>(),
        });
        ctx.Ctrl.Throw = false;
        ctx.Result = new Result(new Dictionary<string, object?> { ["ok"] = false });
        utility.MakeError(ctx, ctx.MakeError("x", "x"));
        Assert.True(ctx.Ctrl.Explain!.ContainsKey("err"),
            "expected explain.err recorded");
    }

    // --- FeatureAdd ----------------------------------------------------------

    [Fact]
    public void FeatureAddAppendsByDefault()
    {
        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, null);
        var start = client.Features.Count;
        var f = new BaseFeature();
        utility.FeatureAdd(ctx, f);
        Assert.Equal(start + 1, client.Features.Count);
        Assert.Same(f, client.Features[^1]);
    }

    [Fact]
    public void FeatureAddOrderingBeforeAfterReplace()
    {
        static BaseFeature Named(string name)
        {
            return new BaseFeature { Name = name };
        }

        var (client, utility) = PlClient(null);
        var ctx = PlCtx(client, utility, null);
        client.Features = new List<BaseFeature>();

        string Names() => string.Join(",", client.Features.Select(ef => ef.GetName()));

        utility.FeatureAdd(ctx, Named("a"));
        utility.FeatureAdd(ctx, Named("b"));
        Assert.Equal("a,b", Names());

        var before = Named("z1");
        before.AddOpts = new Dictionary<string, object?> { ["__before__"] = "b" };
        utility.FeatureAdd(ctx, before);
        Assert.Equal("a,z1,b", Names());

        var after = Named("z2");
        after.AddOpts = new Dictionary<string, object?> { ["__after__"] = "a" };
        utility.FeatureAdd(ctx, after);
        Assert.Equal("a,z2,z1,b", Names());

        var repl = Named("z3");
        repl.AddOpts = new Dictionary<string, object?> { ["__replace__"] = "z1" };
        utility.FeatureAdd(ctx, repl);
        Assert.Equal("a,z2,z3,b", Names());

        // An ordering option naming no existing feature falls back to append.
        var miss = Named("z4");
        miss.AddOpts = new Dictionary<string, object?> { ["__before__"] = "missing" };
        utility.FeatureAdd(ctx, miss);
        Assert.Equal("a,z2,z3,b,z4", Names());
    }

    // --- PrepareAuth ----------------------------------------------------------

    private static Spec AuthSpec(Dictionary<string, object?>? headers)
    {
        return new Spec(new Dictionary<string, object?>
        {
            ["headers"] = headers ?? new Dictionary<string, object?>(),
            ["step"] = "s",
        });
    }

    [Fact]
    public void PrepareAuthGuardsMissingSpec()
    {
        var (client, utility) = PlClient(new Dictionary<string, object?>
        {
            ["apikey"] = "K",
        });
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = null;
        Assert.Equal("auth_no_spec", ErrCode(() => utility.PrepareAuth(ctx)));
    }

    [Fact]
    public void PrepareAuthApikeyWithPrefixSpaceJoined()
    {
        var (client, utility) = PlClient(new Dictionary<string, object?>
        {
            ["apikey"] = "K",
            ["auth"] = new Dictionary<string, object?> { ["prefix"] = "Bearer" },
        });
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = AuthSpec(null);
        utility.PrepareAuth(ctx);
        Assert.Equal("Bearer K", ctx.Spec!.Headers["authorization"]);
    }

    [Fact]
    public void PrepareAuthRawApikeyEmptyPrefixAsIs()
    {
        var (client, utility) = PlClient(new Dictionary<string, object?>
        {
            ["apikey"] = "K",
            ["auth"] = new Dictionary<string, object?> { ["prefix"] = "" },
        });
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = AuthSpec(null);
        utility.PrepareAuth(ctx);
        Assert.Equal("K", ctx.Spec!.Headers["authorization"]);
    }

    [Fact]
    public void PrepareAuthEmptyApikeyDropsHeader()
    {
        var (client, utility) = PlClient(new Dictionary<string, object?>
        {
            ["apikey"] = "",
            ["auth"] = new Dictionary<string, object?> { ["prefix"] = "Bearer" },
        });
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = AuthSpec(new Dictionary<string, object?>
        {
            ["authorization"] = "stale",
        });
        utility.PrepareAuth(ctx);
        Assert.False(ctx.Spec!.Headers.ContainsKey("authorization"),
            "expected authorization dropped");
    }

    [Fact]
    public void PrepareAuthMissingApikeyDropsHeader()
    {
        var (client, utility) = PlClient(new Dictionary<string, object?>
        {
            ["auth"] = new Dictionary<string, object?> { ["prefix"] = "Bearer" },
        });
        var options = client.OptionsMap();
        if (options.TryGetValue("apikey", out var apikey) &&
            apikey is string s && s != "")
        {
            return; // SDK options carry a configured apikey; case not reproducible.
        }
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = AuthSpec(new Dictionary<string, object?>
        {
            ["authorization"] = "stale",
        });
        utility.PrepareAuth(ctx);
        Assert.False(ctx.Spec!.Headers.ContainsKey("authorization"),
            "expected authorization dropped");
    }

    [Fact]
    public void PrepareAuthPublicApiNoAuthBlockDropsHeader()
    {
        var (client, utility) = PlClient(new Dictionary<string, object?>
        {
            ["apikey"] = "K",
        });
        var options = client.OptionsMap();
        if (options.TryGetValue("auth", out var auth) && auth != null)
        {
            // Option validation supplies an auth shape for this SDK, so a
            // truly auth-less client cannot be constructed here.
            return;
        }
        var ctx = PlCtx(client, utility, null);
        ctx.Spec = AuthSpec(new Dictionary<string, object?>
        {
            ["authorization"] = "stale",
        });
        utility.PrepareAuth(ctx);
        Assert.False(ctx.Spec!.Headers.ContainsKey("authorization"),
            "expected authorization dropped");
    }
}
