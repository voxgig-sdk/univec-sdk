// Primary utility test suite - drives every utility on the client utility
// object against the shared corpus in ../../.sdk/test/test.json ("primary"
// section) through the VENDORED omni runner (OmniResolver over
// test/vendor/omni), plus direct checks. C# twin of
// tm/go/test/primary_utility_test.go.
//
// Subjects receive omni's native argument list: a ctx entry arrives as
// args[0], a MAP - OmniResolver.OmniCtx builds the typed Context a
// generated utility takes, and OmniResolver.OmniSyncCtx writes the
// observable ctx state back for `match: {ctx: ...}` assertions.

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
    // PENDING sections are the ones deliberately left empty in the shared
    // corpus (.sdk/test/primary/<name>.aon). Everything else MUST
    // contribute cases.
    private static readonly HashSet<string> Pending = new()
    {
        "fetcher", "makeFetchDef", "makeResult",
        "featureAdd", "featureHook", "featureInit",
    };

    // One client + one corpus runner for the whole suite (the go shape).
    private static UnivecSDK? CLIENT;
    private static Utility? UTILITY;
    private static OmniResolver.Run? RUN;
    private static readonly object RunLock = new();

    private static OmniResolver.Run Run()
    {
        lock (RunLock)
        {
            if (RUN == null)
            {
                CLIENT = UnivecSDK.TestSDK(null, null);
                UTILITY = CLIENT.GetUtility();
                RUN = OmniResolver.MakeRunner(StructRunner.TestJsonPath(), CLIENT)("primary");
                Assert.True(0 < RUN.Spec.Count,
                    "primary section not found in test.json");
            }
            return RUN;
        }
    }

    private static UnivecSDK GetClient()
    {
        Run();
        return CLIENT!;
    }

    private static Utility GetUtil()
    {
        Run();
        return UTILITY!;
    }

    // Run one corpus section, failing loudly when it would run ZERO cases.
    // A renamed section, a fixture that failed to compile, or an empty set
    // used to report PASS while running zero assertions - the whole point
    // of a shared oracle lost without a single red test. (The guard lives
    // here rather than in the runner, which is vendored verbatim; the
    // shared corpus is a v0 spec, and v0 tolerates an empty set.)
    private static void runsection(string name, OmniResolver.Subject subject)
    {
        var run = Run();
        var section = run.Spec.TryGetValue(name, out var s)
            ? s as Dictionary<string, object?> : null;
        Assert.True(null != section, "test corpus section \"" + name +
            "\" missing - check the name against .sdk/test/primary/");
        var basic = section!.TryGetValue("basic", out var b)
            ? b as Dictionary<string, object?> : null;
        var set = basic != null && basic.TryGetValue("set", out var sv)
            ? sv as List<object?> : null;
        Assert.True(null != set, "test corpus section \"" + name +
            "\" has no basic.set list - zero cases would run");
        if (0 == set!.Count && !Pending.Contains(name))
        {
            Assert.Fail("test corpus section \"" + name + "\" is EMPTY - " +
                "zero cases would run; add cases, or mark the fixture " +
                "PENDING in .sdk/test/primary/");
        }
        run.RunSet(basic, subject);
    }

    // Helper: create basic test context.
    private static Context MakeTestCtx(UnivecSDK client, Utility utility,
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
    private static Context MakeTestFullCtx(UnivecSDK client, Utility utility)
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
        var utility = GetUtil();
        Assert.NotNull(utility.Clean);
        Assert.NotNull(utility.Done);
        Assert.NotNull(utility.MakeError);
        Assert.NotNull(utility.FeatureAdd);
        Assert.NotNull(utility.FeatureHook);
        Assert.NotNull(utility.FeatureInit);
        Assert.NotNull(utility.Fetcher);
        Assert.NotNull(utility.MakeFetchDef);
        Assert.NotNull(utility.MakeContext);
        Assert.NotNull(utility.MakeOptions);
        Assert.NotNull(utility.MakeRequest);
        Assert.NotNull(utility.MakeResponse);
        Assert.NotNull(utility.MakeResult);
        Assert.NotNull(utility.MakePoint);
        Assert.NotNull(utility.MakeSpec);
        Assert.NotNull(utility.MakeUrl);
        Assert.NotNull(utility.Param);
        Assert.NotNull(utility.PrepareAuth);
        Assert.NotNull(utility.PrepareBody);
        Assert.NotNull(utility.PrepareHeaders);
        Assert.NotNull(utility.PrepareMethod);
        Assert.NotNull(utility.PrepareParams);
        Assert.NotNull(utility.PreparePath);
        Assert.NotNull(utility.PrepareQuery);
        Assert.NotNull(utility.ResultBasic);
        Assert.NotNull(utility.ResultBody);
        Assert.NotNull(utility.ResultHeaders);
        Assert.NotNull(utility.TransformRequest);
        Assert.NotNull(utility.TransformResponse);
    }

    [Fact]
    public void CleanBasic()
    {
        var ctx = MakeTestCtx(GetClient(), GetUtil(), null);
        var val = new Dictionary<string, object?>
        {
            ["key"] = "secret123",
            ["name"] = "test",
        };
        var cleaned = GetUtil().Clean(ctx, val);
        Assert.NotNull(cleaned);
    }

    [Fact]
    public void CleanCorpus()
    {
        runsection("clean", args =>
        {
            if (2 != args.Length)
            {
                throw new InvalidOperationException(
                    "clean: expected 2 args, got " + args.Length);
            }
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            return GetUtil().Clean(ctx, args[1]);
        });
    }

    [Fact]
    public void DoneBasic()
    {
        runsection("done", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            return GetUtil().Done(ctx);
        });
    }

    [Fact]
    public void MakeErrorBasic()
    {
        runsection("makeError", args =>
        {
            var ctxarg = 0 < args.Length ? args[0] : null;
            var ctx = OmniResolver.OmniCtx(ctxarg, GetClient(), GetUtil());

            Exception? err = null;
            if (1 < args.Length && args[1] is Dictionary<string, object?> errMap)
            {
                err = TestRunner.ErrFromMap(errMap);
            }

            return GetUtil().MakeError(ctx, err);
        });
    }

    [Fact]
    public void MakeErrorNoThrow()
    {
        var ctx = MakeTestFullCtx(GetClient(), GetUtil());
        ctx.Ctrl.Throw = false;
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["ok"] = false,
            ["resdata"] = new Dictionary<string, object?> { ["id"] = "safe01" },
        });

        var result = GetUtil().MakeError(ctx, ctx.MakeError("test_code", "test message"));
        var om = result as Dictionary<string, object?>;
        Assert.True(om != null && Equals(om["id"], "safe01"),
            $"expected id=safe01, got {result}");
    }

    [Fact]
    public void FeatureAddBasic()
    {
        var client = GetClient();
        var ctx = MakeTestCtx(client, GetUtil(), null);
        var startLen = client.Features.Count;

        var feature = new BaseFeature();
        GetUtil().FeatureAdd(ctx, feature);

        Assert.Equal(startLen + 1, client.Features.Count);
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
        // Concrete base: a live construction must satisfy any server
        // variables a templated base URL declares; a literal base
        // sidesteps the requirement.
        var liveClient = new UnivecSDK(new Dictionary<string, object?>
        {
            ["base"] = "http://localhost:8080",
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
        // installs the test feature). Concrete base: see FetcherLive.
        var blockedClient = new UnivecSDK(new Dictionary<string, object?>
        {
            ["base"] = "http://localhost:8080",
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
        runsection("makeContext", args =>
        {
            if (args[0] is Dictionary<string, object?> inMap)
            {
                var ctx = GetUtil().MakeContext(inMap, null);
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
        var ctx = MakeTestFullCtx(GetClient(), GetUtil());
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

        var fetchdef = GetUtil().MakeFetchDef(ctx);
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
        var ctx = MakeTestFullCtx(GetClient(), GetUtil());
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

        var fetchdef = GetUtil().MakeFetchDef(ctx);
        Assert.Equal("POST", fetchdef["method"]);
        var bodyStr = Assert.IsType<string>(fetchdef["body"]);
        Assert.Contains("\"name\"", bodyStr);
    }

    [Fact]
    public void MakeOptionsBasic()
    {
        runsection("makeOptions", args =>
        {
            var inMap = args[0] as Dictionary<string, object?>;
            var ctxmap = new Dictionary<string, object?>();
            if (inMap != null)
            {
                ctxmap["options"] = inMap.TryGetValue("options", out var o) ? o : null;
                ctxmap["config"] = inMap.TryGetValue("config", out var c) ? c : null;
            }
            var ctx = GetUtil().MakeContext(ctxmap, null);
            ctx.Client = GetClient();
            ctx.Utility = GetUtil();
            return GetUtil().MakeOptions(ctx);
        });
    }

    [Fact]
    public void MakeRequestBasic()
    {
        runsection("makeRequest", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            ctx.Options = GetClient().OptionsMap();

            GetUtil().MakeRequest(ctx);

            // Expose response/result existence for the match assertions.
            OmniResolver.OmniSyncCtx(args[0], ctx);

            return null;
        });
    }

    [Fact]
    public void MakeResponseBasic()
    {
        runsection("makeResponse", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());

            GetUtil().MakeResponse(ctx);

            OmniResolver.OmniSyncCtx(args[0], ctx);

            return null;
        });
    }

    [Fact]
    public void MakeResultBasic()
    {
        var ctx = MakeTestFullCtx(GetClient(), GetUtil());
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

        var result = GetUtil().MakeResult(ctx);
        Assert.Equal(200, result.Status);
    }

    [Fact]
    public void MakeResultNoSpec()
    {
        var ctx = MakeTestFullCtx(GetClient(), GetUtil());
        ctx.Spec = null;
        ctx.Result = new Result(new Dictionary<string, object?>
        {
            ["ok"] = true,
            ["status"] = 200,
            ["statusText"] = "OK",
            ["headers"] = new Dictionary<string, object?>(),
        });

        Assert.ThrowsAny<Exception>(() => GetUtil().MakeResult(ctx));
    }

    [Fact]
    public void MakeResultNoResult()
    {
        var ctx = MakeTestFullCtx(GetClient(), GetUtil());
        ctx.Spec = new Spec(new Dictionary<string, object?> { ["step"] = "start" });
        ctx.Result = null;

        Assert.ThrowsAny<Exception>(() => GetUtil().MakeResult(ctx));
    }

    [Fact]
    public void MakeSpecBasic()
    {
        var setupOpts = TestRunner.GetSpec(Run().Spec, "makeSpec", "DEF", "setup", "a");
        var specClient = UnivecSDK.TestSDK(null, setupOpts);
        var specUtility = specClient.GetUtility();

        runsection("makeSpec", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], specClient, specUtility);
            ctx.Options = specClient.OptionsMap();

            specUtility.MakeSpec(ctx);

            OmniResolver.OmniSyncCtx(args[0], ctx);

            return null;
        });
    }

    // A minimal IEntity: Context resolves the op through the entity
    // interface, and a literal {name: ...} map from the fixture is not one
    // - entname would be "" and every lookup would miss, reporting
    // point_no_points for all cases. TS reads the same field with getprop
    // and accepts the plain map. (The go peer is plEntity.)
    private sealed class PlEntity : IEntity
    {
        private readonly string name;

        public PlEntity(string name)
        {
            this.name = name;
        }

        public string GetName() => name;

        public IEntity Make() => new PlEntity(name);

        public object? Data(object? data = null) => null;

        public object? Match(object? match = null) => null;

        public void MarkDeleted() { }

        public bool Deleted() => false;
    }

    // Corpus-driven, like go: TS returns the error AS the value; C# throws
    // UnivecError. The corpus says `match: out: code` for both, so
    // the error is normalised to a map carrying its code here rather than
    // forking the fixture per language.
    [Fact]
    public void MakePointBasic()
    {
        runsection("makePoint", args =>
        {
            var ctxmap = args[0] as Dictionary<string, object?>
                ?? new Dictionary<string, object?>();

            if (ctxmap.TryGetValue("entity", out var em) &&
                em is Dictionary<string, object?> entityMap)
            {
                var name = entityMap.TryGetValue("name", out var n)
                    ? n as string ?? "" : "";
                ctxmap = new Dictionary<string, object?>(ctxmap)
                {
                    ["entity"] = new PlEntity(name),
                };
            }

            var ctx = OmniResolver.OmniCtx(ctxmap, GetClient(), GetUtil());
            try
            {
                return GetUtil().MakePoint(ctx);
            }
            catch (UnivecError e)
            {
                return new Dictionary<string, object?> { ["code"] = e.Code };
            }
        });
    }

    [Fact]
    public void MakeUrlBasic()
    {
        runsection("makeUrl", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            ctx.Result ??= new Result(new Dictionary<string, object?>());
            return GetUtil().MakeUrl(ctx);
        });
    }

    [Fact]
    public void OperatorBasic()
    {
        runsection("operator", args =>
        {
            var inMap = args[0] as Dictionary<string, object?>;
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
        runsection("param", args =>
        {
            if (args.Length < 2)
            {
                return null;
            }

            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            var paramdef = args[1];

            var result = GetUtil().Param(ctx, paramdef);

            // The spec alias mutation is what the match assertions read.
            OmniResolver.OmniSyncCtx(args[0], ctx);

            return result;
        });
    }

    [Fact]
    public void PrepareAuthBasic()
    {
        var setupOpts = TestRunner.GetSpec(Run().Spec, "prepareAuth", "DEF", "setup", "a");
        var authClient = UnivecSDK.TestSDK(null, setupOpts);
        var authUtility = authClient.GetUtility();

        runsection("prepareAuth", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], authClient, authUtility);

            authUtility.PrepareAuth(ctx);

            OmniResolver.OmniSyncCtx(args[0], ctx);

            return null;
        });
    }

    [Fact]
    public void PrepareBodyBasic()
    {
        runsection("prepareBody", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            return GetUtil().PrepareBody(ctx);
        });
    }

    [Fact]
    public void PrepareHeadersBasic()
    {
        runsection("prepareHeaders", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            return GetUtil().PrepareHeaders(ctx);
        });
    }

    [Fact]
    public void PrepareMethodBasic()
    {
        runsection("prepareMethod", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            // An op the API does not define resolves NO method; ts answers
            // undefined there and C# answers null - both are "no value" to
            // the corpus.
            var method = GetUtil().PrepareMethod(ctx);
            return string.IsNullOrEmpty(method) ? null : method;
        });
    }

    [Fact]
    public void PrepareParamsBasic()
    {
        runsection("prepareParams", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            return GetUtil().PrepareParams(ctx);
        });
    }

    // Was two hand-written cases that had drifted out of the shared corpus
    // (the preparePath fixture shipped as an empty `set: []`). Now driven
    // by the corpus like every other section, so all ports assert the same
    // separator / blank-segment behaviour.
    [Fact]
    public void PreparePathBasic()
    {
        runsection("preparePath", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            return GetUtil().PreparePath(ctx);
        });
    }

    [Fact]
    public void PrepareQueryBasic()
    {
        runsection("prepareQuery", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());
            return GetUtil().PrepareQuery(ctx);
        });
    }

    [Fact]
    public void ResultBasicBasic()
    {
        runsection("resultBasic", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());

            var result = GetUtil().ResultBasic(ctx);

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
        runsection("resultBody", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());

            GetUtil().ResultBody(ctx);

            OmniResolver.OmniSyncCtx(args[0], ctx);

            return null;
        });
    }

    [Fact]
    public void ResultHeadersBasic()
    {
        runsection("resultHeaders", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());

            GetUtil().ResultHeaders(ctx);

            OmniResolver.OmniSyncCtx(args[0], ctx);

            return null;
        });
    }

    [Fact]
    public void TransformRequestBasic()
    {
        runsection("transformRequest", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());

            var result = GetUtil().TransformRequest(ctx);

            // The step advance is what the match assertion reads.
            OmniResolver.OmniSyncCtx(args[0], ctx);

            return result;
        });
    }

    [Fact]
    public void TransformResponseBasic()
    {
        runsection("transformResponse", args =>
        {
            var ctx = OmniResolver.OmniCtx(args[0], GetClient(), GetUtil());

            var result = GetUtil().TransformResponse(ctx);

            OmniResolver.OmniSyncCtx(args[0], ctx);

            return result;
        });
    }
}
