// Primary utility test suite - drives every utility on the client utility
// object, partly via the shared corpus in ../../.sdk/test/test.json
// ("primary" section) and partly via direct checks. C# twin of
// tm/go/test/primary_utility_test.go.

using Xunit;

using UnivecSdk;
using UnivecSdk.Feature;

namespace UnivecSdk.Test;

// Helper: test hook feature for the featureHook test.
internal class TestHookFeature : BaseFeature
{
    public Action? HookFn;

    public void TestHook(Context ctx)
    {
        HookFn?.Invoke();
    }
}

// Helper: test init feature for the featureInit test.
internal class TestInitFeature : BaseFeature
{
    public Action? InitFn;

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        InitFn?.Invoke();
    }
}

public class PrimaryUtilityTest
{
    private readonly Dictionary<string, object?> _primary;
    private readonly UnivecSDK _client;
    private readonly Utility _utility;

    public PrimaryUtilityTest()
    {
        var spec = TestRunner.LoadTestSpec();
        _primary = TestRunner.GetSpec(spec, "primary")
            ?? throw new InvalidOperationException("primary section not found in test.json");
        _client = UnivecSDK.TestSDK(null, null);
        _utility = _client.GetUtility();
    }

    // Helper: create basic test context.
    private Context MakeTestCtx(UnivecSDK client, Utility utility,
        Dictionary<string, object?>? overrides)
    {
        var ctxmap = new Dictionary<string, object?>
        {
            ["opname"] = "load",
            ["client"] = client,
            ["utility"] = utility,
        };
        if (overrides != null)
        {
            foreach (var kv in overrides)
            {
                ctxmap[kv.Key] = kv.Value;
            }
        }
        return utility.MakeContext(ctxmap, client.GetRootCtx());
    }

    // Helper: create full test context with point and match.
    private Context MakeTestFullCtx(UnivecSDK client, Utility utility)
    {
        var ctx = MakeTestCtx(client, utility, null);
        ctx.Point = new Dictionary<string, object?>
        {
            ["parts"] = new List<object?> { "items", "{id}" },
            ["args"] = new Dictionary<string, object?>
            {
                ["params"] = new List<object?>
                {
                    new Dictionary<string, object?>
                    {
                        ["name"] = "id",
                        ["reqd"] = true,
                    },
                },
            },
            ["params"] = new List<object?> { "id" },
            ["alias"] = new Dictionary<string, object?>(),
            ["select"] = new Dictionary<string, object?>(),
            ["active"] = true,
            ["transform"] = new Dictionary<string, object?>(),
        };
        ctx.Match = new Dictionary<string, object?> { ["id"] = "item01" };
        ctx.Reqmatch = new Dictionary<string, object?> { ["id"] = "item01" };
        return ctx;
    }

    [Fact]
    public void Exists()
    {
        Assert.NotNull(_utility.Clean);
        Assert.NotNull(_utility.Done);
        Assert.NotNull(_utility.MakeError);
        Assert.NotNull(_utility.FeatureAdd);
        Assert.NotNull(_utility.FeatureHook);
        Assert.NotNull(_utility.FeatureInit);
        Assert.NotNull(_utility.Fetcher);
        Assert.NotNull(_utility.MakeFetchDef);
        Assert.NotNull(_utility.MakeContext);
        Assert.NotNull(_utility.MakeOptions);
        Assert.NotNull(_utility.MakeRequest);
        Assert.NotNull(_utility.MakeResponse);
        Assert.NotNull(_utility.MakeResult);
        Assert.NotNull(_utility.MakePoint);
        Assert.NotNull(_utility.MakeSpec);
        Assert.NotNull(_utility.MakeUrl);
        Assert.NotNull(_utility.Param);
        Assert.NotNull(_utility.PrepareAuth);
        Assert.NotNull(_utility.PrepareBody);
        Assert.NotNull(_utility.PrepareHeaders);
        Assert.NotNull(_utility.PrepareMethod);
        Assert.NotNull(_utility.PrepareParams);
        Assert.NotNull(_utility.PreparePath);
        Assert.NotNull(_utility.PrepareQuery);
        Assert.NotNull(_utility.ResultBasic);
        Assert.NotNull(_utility.ResultBody);
        Assert.NotNull(_utility.ResultHeaders);
        Assert.NotNull(_utility.TransformRequest);
        Assert.NotNull(_utility.TransformResponse);
    }

    [Fact]
    public void CleanBasic()
    {
        var ctx = MakeTestCtx(_client, _utility, null);
        var val = new Dictionary<string, object?>
        {
            ["key"] = "secret123",
            ["name"] = "test",
        };
        var cleaned = _utility.Clean(ctx, val);
        Assert.NotNull(cleaned);
    }

    [Fact]
    public void DoneBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "done", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            TestRunner.FixCtx(ctx, _client);
            return _utility.Done(ctx);
        });
    }

    [Fact]
    public void MakeErrorBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "makeError", "basic"), entry =>
        {
            var args = entry.TryGetValue("args", out var a)
                ? a as List<object?> : null;
            args ??= new List<object?> { new Dictionary<string, object?>() };
            if (args.Count == 0)
            {
                args = new List<object?> { new Dictionary<string, object?>() };
            }

            var ctxmap = args[0] as Dictionary<string, object?>
                ?? new Dictionary<string, object?>();
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            TestRunner.FixCtx(ctx, _client);

            Exception? err = null;
            if (args.Count > 1 && args[1] is Dictionary<string, object?> errMap)
            {
                err = TestRunner.ErrFromMap(errMap);
            }

            return _utility.MakeError(ctx, err);
        });
    }

    [Fact]
    public void MakeErrorNoThrow()
    {
        var ctx = MakeTestFullCtx(_client, _utility);
        ctx.Ctrl.Throw = false;
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["ok"] = false,
            ["resdata"] = new Dictionary<string, object?> { ["id"] = "safe01" },
        });

        var result = _utility.MakeError(ctx, ctx.MakeError("test_code", "test message"));
        var om = result as Dictionary<string, object?>;
        Assert.True(om != null && Equals(om["id"], "safe01"),
            $"expected id=safe01, got {result}");
    }

    [Fact]
    public void FeatureAddBasic()
    {
        var ctx = MakeTestCtx(_client, _utility, null);
        var startLen = _client.Features.Count;

        var feature = new BaseFeature();
        _utility.FeatureAdd(ctx, feature);

        Assert.Equal(startLen + 1, _client.Features.Count);
    }

    [Fact]
    public void FeatureHookBasic()
    {
        var hookClient = UnivecSDK.TestSDK(null, null);
        var hookUtility = hookClient.GetUtility();
        var ctx = MakeTestCtx(hookClient, hookUtility, null);

        var called = false;
        var hookFeature = new TestHookFeature { HookFn = () => called = true };
        hookClient.Features = new List<BaseFeature> { hookFeature };

        hookUtility.FeatureHook(ctx, "TestHook");
        Assert.True(called, "expected TestHook to be called");
    }

    [Fact]
    public void FeatureInitBasic()
    {
        var initClient = UnivecSDK.TestSDK(null, null);
        var initUtility = initClient.GetUtility();
        var ctx = MakeTestCtx(initClient, initUtility, null);
        ctx.Options!["feature"] = new Dictionary<string, object?>
        {
            ["initfeat"] = new Dictionary<string, object?> { ["active"] = true },
        };

        var initCalled = false;
        var feature = new TestInitFeature
        {
            Name = "initfeat",
            Active = true,
            InitFn = () => initCalled = true,
        };

        initUtility.FeatureInit(ctx, feature);
        Assert.True(initCalled, "expected init to be called");
    }

    [Fact]
    public void FeatureInitInactive()
    {
        var initClient = UnivecSDK.TestSDK(null, null);
        var initUtility = initClient.GetUtility();
        var ctx = MakeTestCtx(initClient, initUtility, null);
        ctx.Options!["feature"] = new Dictionary<string, object?>
        {
            ["nofeat"] = new Dictionary<string, object?> { ["active"] = false },
        };

        var initCalled = false;
        var feature = new TestInitFeature
        {
            Name = "nofeat",
            Active = false,
            InitFn = () => initCalled = true,
        };

        initUtility.FeatureInit(ctx, feature);
        Assert.False(initCalled, "expected init NOT to be called for inactive feature");
    }

    [Fact]
    public void FetcherLive()
    {
        var calls = new List<Dictionary<string, object?>>();
        var liveClient = new UnivecSDK(new Dictionary<string, object?>
        {
            ["system"] = new Dictionary<string, object?>
            {
                ["fetch"] = (Func<string, Dictionary<string, object?>, Dictionary<string, object?>>)
                    ((url, fetchdef) =>
                    {
                        calls.Add(new Dictionary<string, object?>
                        {
                            ["url"] = url,
                            ["init"] = fetchdef,
                        });
                        return new Dictionary<string, object?>
                        {
                            ["status"] = 200,
                            ["statusText"] = "OK",
                        };
                    }),
            },
        });
        var liveUtility = liveClient.GetUtility();
        var ctx = liveUtility.MakeContext(new Dictionary<string, object?>
        {
            ["opname"] = "load",
            ["client"] = liveClient,
            ["utility"] = liveUtility,
        }, null);

        var fetchdef = new Dictionary<string, object?>
        {
            ["method"] = "GET",
            ["headers"] = new Dictionary<string, object?>(),
        };
        liveUtility.Fetcher(ctx, "http://example.com/test", fetchdef);
        Assert.Single(calls);
        Assert.Equal("http://example.com/test", calls[0]["url"]);
    }

    [Fact]
    public void FetcherBlockedTestMode()
    {
        // Create a live SDK then set mode to test (not using TestSDK, which
        // installs the test feature).
        var blockedClient = new UnivecSDK(new Dictionary<string, object?>
        {
            ["system"] = new Dictionary<string, object?>
            {
                ["fetch"] = (Func<string, Dictionary<string, object?>, Dictionary<string, object?>>)
                    ((url, fetchdef) => new Dictionary<string, object?>()),
            },
        });
        blockedClient.Mode = "test";

        var blockedUtility = blockedClient.GetUtility();
        var ctx = blockedUtility.MakeContext(new Dictionary<string, object?>
        {
            ["opname"] = "load",
            ["client"] = blockedClient,
            ["utility"] = blockedUtility,
        }, null);

        var fetchdef = new Dictionary<string, object?>
        {
            ["method"] = "GET",
            ["headers"] = new Dictionary<string, object?>(),
        };
        var err = Assert.ThrowsAny<Exception>(() =>
            blockedUtility.Fetcher(ctx, "http://example.com/test", fetchdef));
        Assert.Contains("blocked", err.Message);
    }

    [Fact]
    public void MakeContextBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "makeContext", "basic"), entry =>
        {
            if (entry.TryGetValue("in", out var inRaw) &&
                inRaw is Dictionary<string, object?> inMap)
            {
                var ctx = _utility.MakeContext(inMap, null);
                var result = new Dictionary<string, object?>
                {
                    ["id"] = ctx.Id,
                };
                if (ctx.Op != null)
                {
                    result["op"] = new Dictionary<string, object?>
                    {
                        ["name"] = ctx.Op.Name,
                        ["input"] = ctx.Op.Input,
                    };
                }
                return result;
            }
            return null;
        });
    }

    [Fact]
    public void MakeFetchDefBasic()
    {
        var ctx = MakeTestFullCtx(_client, _utility);
        ctx.Spec = new Spec(new Dictionary<string, object?>
        {
            ["base"] = "http://localhost:8080",
            ["prefix"] = "/api",
            ["path"] = "items/{id}",
            ["suffix"] = "",
            ["params"] = new Dictionary<string, object?> { ["id"] = "item01" },
            ["query"] = new Dictionary<string, object?>(),
            ["headers"] = new Dictionary<string, object?>
            {
                ["content-type"] = "application/json",
            },
            ["method"] = "GET",
            ["step"] = "start",
        });
        ctx.Result = new Result(new Dictionary<string, object?>());

        var fetchdef = _utility.MakeFetchDef(ctx);
        Assert.Equal("GET", fetchdef["method"]);
        var url = fetchdef["url"] as string ?? "";
        Assert.Contains("/api/items/item01", url);
        Assert.Equal("application/json",
            (fetchdef["headers"] as Dictionary<string, object?>)?["content-type"]);
        Assert.False(fetchdef.ContainsKey("body") && fetchdef["body"] != null,
            "expected no body");
    }

    [Fact]
    public void MakeFetchDefWithBody()
    {
        var ctx = MakeTestFullCtx(_client, _utility);
        ctx.Spec = new Spec(new Dictionary<string, object?>
        {
            ["base"] = "http://localhost:8080",
            ["prefix"] = "",
            ["path"] = "items",
            ["suffix"] = "",
            ["params"] = new Dictionary<string, object?>(),
            ["query"] = new Dictionary<string, object?>(),
            ["headers"] = new Dictionary<string, object?>(),
            ["method"] = "POST",
            ["step"] = "start",
            ["body"] = new Dictionary<string, object?> { ["name"] = "test" },
        });
        ctx.Result = new Result(new Dictionary<string, object?>());

        var fetchdef = _utility.MakeFetchDef(ctx);
        Assert.Equal("POST", fetchdef["method"]);
        var bodyStr = Assert.IsType<string>(fetchdef["body"]);
        Assert.Contains("\"name\"", bodyStr);
    }

    [Fact]
    public void MakeOptionsBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "makeOptions", "basic"), entry =>
        {
            var inMap = entry.TryGetValue("in", out var i)
                ? i as Dictionary<string, object?> : null;
            inMap ??= new Dictionary<string, object?>();
            var ctx = _utility.MakeContext(new Dictionary<string, object?>
            {
                ["options"] = inMap.TryGetValue("options", out var o) ? o : null,
                ["config"] = inMap.TryGetValue("config", out var c) ? c : null,
            }, null);
            ctx.Client = _client;
            ctx.Utility = _utility;
            return _utility.MakeOptions(ctx);
        });
    }

    [Fact]
    public void MakeRequestBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "makeRequest", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            ctx.Options = _client.OptionsMap();

            _utility.MakeRequest(ctx);

            // Update entry ctx for match checking.
            if (ctxmap != null)
            {
                if (ctx.Response != null)
                {
                    ctxmap["response"] = "exists";
                }
                if (ctx.Result != null)
                {
                    ctxmap["result"] = "exists";
                }
            }

            return null;
        });
    }

    [Fact]
    public void MakeResponseBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "makeResponse", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            TestRunner.FixCtx(ctx, _client);

            _utility.MakeResponse(ctx);

            // Update entry ctx for match checking with result data.
            if (ctxmap != null && ctx.Result != null)
            {
                ctxmap["result"] = new Dictionary<string, object?>
                {
                    ["ok"] = ctx.Result.Ok,
                    ["status"] = ctx.Result.Status,
                    ["statusText"] = ctx.Result.StatusText,
                    ["headers"] = ctx.Result.Headers,
                    ["body"] = ctx.Result.Body,
                };
            }

            return null;
        });
    }

    [Fact]
    public void MakeResultBasic()
    {
        var ctx = MakeTestFullCtx(_client, _utility);
        ctx.Spec = new Spec(new Dictionary<string, object?>
        {
            ["base"] = "http://localhost:8080",
            ["prefix"] = "/api",
            ["path"] = "items/{id}",
            ["suffix"] = "",
            ["params"] = new Dictionary<string, object?> { ["id"] = "item01" },
            ["query"] = new Dictionary<string, object?>(),
            ["headers"] = new Dictionary<string, object?>(),
            ["method"] = "GET",
            ["step"] = "start",
        });
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["ok"] = true,
            ["status"] = 200,
            ["statusText"] = "OK",
            ["headers"] = new Dictionary<string, object?>(),
            ["resdata"] = new Dictionary<string, object?>
            {
                ["id"] = "item01",
                ["name"] = "Test",
            },
        });

        var result = _utility.MakeResult(ctx);
        Assert.Equal(200, result.Status);
    }

    [Fact]
    public void MakeResultNoSpec()
    {
        var ctx = MakeTestFullCtx(_client, _utility);
        ctx.Spec = null;
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["ok"] = true,
            ["status"] = 200,
            ["statusText"] = "OK",
            ["headers"] = new Dictionary<string, object?>(),
        });

        Assert.ThrowsAny<Exception>(() => _utility.MakeResult(ctx));
    }

    [Fact]
    public void MakeResultNoResult()
    {
        var ctx = MakeTestFullCtx(_client, _utility);
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "start" });
        ctx.Result = null;

        Assert.ThrowsAny<Exception>(() => _utility.MakeResult(ctx));
    }

    [Fact]
    public void MakeSpecBasic()
    {
        var setupOpts = TestRunner.GetSpec(_primary, "makeSpec", "DEF", "setup", "a");
        var specClient = UnivecSDK.TestSDK(null, setupOpts);
        var specUtility = specClient.GetUtility();

        TestRunner.RunSet(TestRunner.GetSpec(_primary, "makeSpec", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, specClient, specUtility);
            ctx.Options = specClient.OptionsMap();

            _utility.MakeSpec(ctx);

            // Update entry ctx for match.
            if (ctxmap != null && ctx.Spec != null)
            {
                ctxmap["spec"] = new Dictionary<string, object?>
                {
                    ["base"] = ctx.Spec.Base,
                    ["prefix"] = ctx.Spec.Prefix,
                    ["suffix"] = ctx.Spec.Suffix,
                    ["method"] = ctx.Spec.Method,
                    ["params"] = ctx.Spec.Params,
                    ["query"] = ctx.Spec.Query,
                    ["headers"] = ctx.Spec.Headers,
                    ["step"] = ctx.Spec.Step,
                };
            }

            return null;
        });
    }

    [Fact]
    public void MakePointBasic()
    {
        var ctx = MakeTestCtx(_client, _utility, null);
        var point = new Dictionary<string, object?>
        {
            ["parts"] = new List<object?> { "items", "{id}" },
            ["args"] = new Dictionary<string, object?>
            {
                ["params"] = new List<object?>(),
            },
            ["params"] = new List<object?>(),
            ["alias"] = new Dictionary<string, object?>(),
            ["select"] = new Dictionary<string, object?>(),
            ["active"] = true,
            ["transform"] = new Dictionary<string, object?>(),
        };
        ctx.Op!.Points = new List<Dictionary<string, object?>> { point };

        _utility.MakePoint(ctx);
        Assert.NotNull(ctx.Point);
    }

    [Fact]
    public void MakeUrlBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "makeUrl", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            ctx.Result ??= new Result(new Dictionary<string, object?>());
            return _utility.MakeUrl(ctx);
        });
    }

    [Fact]
    public void OperatorBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "operator", "basic"), entry =>
        {
            var inMap = entry.TryGetValue("in", out var i)
                ? i as Dictionary<string, object?> : null;
            var op = new Operation(inMap ?? new Dictionary<string, object?>());
            return new Dictionary<string, object?>
            {
                ["entity"] = op.Entity,
                ["name"] = op.Name,
                ["input"] = op.Input,
                ["points"] = op.Points.Cast<object?>().ToList(),
            };
        });
    }

    [Fact]
    public void ParamBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "param", "basic"), entry =>
        {
            var args = entry.TryGetValue("args", out var a)
                ? a as List<object?> : null;
            if (args == null || args.Count < 2)
            {
                return null;
            }

            var ctxmap = args[0] as Dictionary<string, object?>
                ?? new Dictionary<string, object?>();
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            var paramdef = args[1];

            var result = _utility.Param(ctx, paramdef);

            // Copy spec alias back to entry ctx for matching.
            if (entry.TryGetValue("match", out var msRaw) &&
                msRaw is Dictionary<string, object?> matchSpec &&
                matchSpec.TryGetValue("ctx", out var cmRaw) &&
                cmRaw is Dictionary<string, object?> ctxMatch &&
                ctxMatch.TryGetValue("spec", out var smRaw) &&
                smRaw is Dictionary<string, object?> specMatch &&
                specMatch.ContainsKey("alias") &&
                ctx.Spec != null)
            {
                if (entry.TryGetValue("ctx", out var ec) &&
                    ec is Dictionary<string, object?> entryCtx)
                {
                    entryCtx["spec"] = new Dictionary<string, object?>
                    {
                        ["alias"] = ctx.Spec.Alias,
                    };
                }
                else
                {
                    entry["ctx"] = new Dictionary<string, object?>
                    {
                        ["spec"] = new Dictionary<string, object?>
                        {
                            ["alias"] = ctx.Spec.Alias,
                        },
                    };
                }
            }

            return result;
        });
    }

    [Fact]
    public void PrepareAuthBasic()
    {
        var setupOpts = TestRunner.GetSpec(_primary, "prepareAuth", "DEF", "setup", "a");
        var authClient = UnivecSDK.TestSDK(null, setupOpts);
        var authUtility = authClient.GetUtility();

        TestRunner.RunSet(TestRunner.GetSpec(_primary, "prepareAuth", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, authClient, authUtility);
            TestRunner.FixCtx(ctx, authClient);

            _utility.PrepareAuth(ctx);

            // Update entry ctx for match.
            if (ctxmap != null && ctx.Spec != null)
            {
                ctxmap["spec"] = new Dictionary<string, object?>
                {
                    ["headers"] = ctx.Spec.Headers,
                };
            }

            return null;
        });
    }

    [Fact]
    public void PrepareBodyBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "prepareBody", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            TestRunner.FixCtx(ctx, _client);
            return _utility.PrepareBody(ctx);
        });
    }

    [Fact]
    public void PrepareHeadersBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "prepareHeaders", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            return _utility.PrepareHeaders(ctx);
        });
    }

    [Fact]
    public void PrepareMethodBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "prepareMethod", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            return _utility.PrepareMethod(ctx);
        });
    }

    [Fact]
    public void PrepareParamsBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "prepareParams", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            return _utility.PrepareParams(ctx);
        });
    }

    // Was two hand-written cases that had drifted out of the shared corpus
    // (the preparePath fixture shipped as an empty `set: []`). Now driven by
    // the corpus like every other section, so all ports assert the same
    // separator / blank-segment behaviour.
    [Fact]
    public void PreparePathBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "preparePath", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            return _utility.PreparePath(ctx);
        });
    }

    [Fact]
    public void PrepareQueryBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "prepareQuery", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            return _utility.PrepareQuery(ctx);
        });
    }

    [Fact]
    public void ResultBasicBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "resultBasic", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);
            TestRunner.FixCtx(ctx, _client);

            var result = _utility.ResultBasic(ctx);

            var res = new Dictionary<string, object?>
            {
                ["status"] = result.Status,
                ["statusText"] = result.StatusText,
            };
            if (result.Err != null)
            {
                res["err"] = new Dictionary<string, object?>
                {
                    ["message"] = result.Err.Message,
                };
            }

            return res;
        });
    }

    [Fact]
    public void ResultBodyBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "resultBody", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);

            _utility.ResultBody(ctx);

            if (ctxmap != null && ctx.Result != null)
            {
                ctxmap["result"] = new Dictionary<string, object?>
                {
                    ["body"] = ctx.Result.Body,
                };
            }

            return null;
        });
    }

    [Fact]
    public void ResultHeadersBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "resultHeaders", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);

            _utility.ResultHeaders(ctx);

            if (ctxmap != null && ctx.Result != null)
            {
                ctxmap["result"] = new Dictionary<string, object?>
                {
                    ["headers"] = ctx.Result.Headers,
                };
            }

            return null;
        });
    }

    [Fact]
    public void TransformRequestBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "transformRequest", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);

            var result = _utility.TransformRequest(ctx);

            // Update entry ctx for match (step changed).
            if (ctxmap != null && ctx.Spec != null &&
                ctxmap.TryGetValue("spec", out var smRaw) &&
                smRaw is Dictionary<string, object?> specMap)
            {
                specMap["step"] = ctx.Spec.Step;
            }

            return result;
        });
    }

    [Fact]
    public void TransformResponseBasic()
    {
        TestRunner.RunSet(TestRunner.GetSpec(_primary, "transformResponse", "basic"), entry =>
        {
            var ctxmap = entry.TryGetValue("ctx", out var c)
                ? c as Dictionary<string, object?> : null;
            var ctx = TestRunner.MakeCtxFromMap(ctxmap, _client, _utility);

            var result = _utility.TransformResponse(ctx);

            if (ctxmap != null && ctx.Spec != null &&
                ctxmap.TryGetValue("spec", out var smRaw) &&
                smRaw is Dictionary<string, object?> specMap)
            {
                specMap["step"] = ctx.Spec.Step;
            }

            return result;
        });
    }
}
