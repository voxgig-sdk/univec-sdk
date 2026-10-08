import {
  cmp,
  each,
  entityCollection,
  File,
  Content,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
  targetFeatures,
} from '@voxgig/sdkgen'


// The canary sweep, the csharp twin of TestClean_ts.ts. The entity accessors
// and their operations are typed methods, so the candidates the sweep drives
// to find a usable operation are emitted from the model rather than found by
// walking the client at run time.
const TestClean = cmp(function TestClean(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const auth = {
    suppressed: isAuthSuppressed(model),
    where: resolveAuthIn(model),
    name: 'header' === resolveAuthIn(model)
      ? resolveAuthName(model).toLowerCase() : resolveAuthName(model),
    basic: isHttpBasicAuth(model),
  }

  // CostRecord is declared by the cost feature's source, which ships only
  // when the model selects the feature.
  const cost = null != targetFeatures(model, target).cost

  // Same order the ts sweep tries: list, then load, then the rest.
  const rank: Record<string, number> = { list: 0, load: 1 }
  const candidates = each(entityCollection(model))
    .filter((e: any) => false !== e.active)
    .map((e: any) => ({
      name: e.name,
      Name: e.Name,
      ops: Object.keys(e.op || {})
        .sort((a, b) => (rank[a] ?? 2) - (rank[b] ?? 2)),
    }))
    .filter((c: any) => 0 < c.ops.length)

  File({ name: 'CleanTest.' + target.ext }, () => Content(render(model.const.Name, auth, candidates, cost)))
})


function render(
  Name: string,
  auth: { suppressed: boolean, where: string, name: string, basic: boolean },
  candidates: { name: string, Name: string, ops: string[] }[],
  cost: boolean,
): string {
  const candidateLines = candidates.map((c) =>
    `        new Candidate("${c.name}", sdk => sdk.${c.Name}(null), new[] { ${c.ops.map((o) => `"${o}"`).join(', ')} }),`)
    .join('\n')

  return `// The canary sweep: every credential slot holds a distinctive value, every
// diagnostic feature this SDK ships is switched on with a capturing sink, a
// real operation runs through every outcome, and every string that leaves
// the SDK is searched for the canaries and their encoded forms. It also
// proves its own sensitivity: with clean switched off the canary MUST show.

using System.Collections;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

using Voxgig.Struct;
using Xunit;
using Xunit.Abstractions;

using ${Name}Sdk;
using ${Name}Sdk.Feature;

namespace ${Name}Sdk.Test;

public class CleanTest
{
    // Generated: the credential's wire placement is fixed when the SDK is built.
    private const bool AuthSuppressed = ${auth.suppressed ? 'true' : 'false'};
    private const string AuthWhere = ${JSON.stringify(auth.where)};
    private const string AuthName = ${JSON.stringify(auth.name)};

    private const string CanaryApikey = "CANARY-APIKEY-k9x2m7q4p1";
    private const string CanarySecret = "CANARY-SECRET-w3e8r5t2y6";
    private const string CanaryHeader = "CANARY-HEADER-z1x4c7v0b3";
    private const string CanaryValue = "CANARY-VALUE-n5m8b2v9c4";

    private const string Mask = "[redacted]";

    private readonly ITestOutputHelper _out;

    public CleanTest(ITestOutputHelper output)
    {
        _out = output;
    }

    // Every form a canary can travel in.
    private static readonly List<string> Forms = BuildForms();

    private static List<string> BuildForms()
    {
        var forms = new List<string>();
        foreach (var v in new[] { CanaryApikey, CanarySecret, CanaryHeader, CanaryValue })
        {
            forms.Add(v);
            forms.Add(Convert.ToBase64String(Encoding.UTF8.GetBytes(v)));
            forms.Add(Uri.EscapeDataString(v));
        }
        forms.Add(Convert.ToBase64String(Encoding.UTF8.GetBytes(CanaryApikey + ":" + CanarySecret)));
        return forms;
    }

    private sealed record Sink(string Name, string Text);

    private sealed record Candidate(string Name, Func<${Name}SDK, ${Name}EntityBase> Accessor, string[] Ops);

    private sealed record Target(Candidate Candidate, string Op, Dictionary<string, object?> Match);

    // Header maps keep the caller's spelling; the assertion should not care.
    private static object? Header(object? map, string name)
    {
        if (map is IDictionary dict)
        {
            foreach (DictionaryEntry kv in dict)
            {
                if (string.Equals(Convert.ToString(kv.Key), name, StringComparison.OrdinalIgnoreCase))
                {
                    return kv.Value;
                }
            }
        }
        return null;
    }

    private static List<string> Leaks(string text)
    {
        return Forms.Where(f => text.Contains(f)).ToList();
    }

    private static readonly JsonSerializerOptions FieldsJson = new()
    {
        IncludeFields = true,
        ReferenceHandler = ReferenceHandler.IgnoreCycles,
        MaxDepth = 16,
    };

    // The typed pipeline products read through their fields, so the raw spec
    // is visible when clean is off - the sensitivity check depends on it.
    private static string Render(object? val)
    {
        switch (val)
        {
            case null:
                return "null";
            case string s:
                return s;
            case Spec sp:
                return Render(new Dictionary<string, object?>
                {
                    ["method"] = sp.Method, ["url"] = sp.Url, ["path"] = sp.Path,
                    ["headers"] = sp.Headers, ["query"] = sp.Query,
                    ["params"] = sp.Params, ["body"] = sp.Body,
                });
            case Result r:
                return Render(new Dictionary<string, object?>
                {
                    ["ok"] = r.Ok, ["status"] = r.Status, ["headers"] = r.Headers,
                    ["body"] = r.Body, ["resdata"] = r.Resdata,
                    ["err"] = null == r.Err ? null : r.Err.ToString(),
                });
            case IEntity ent:
                return Render(ent.Data());
            case Context ctx:
                return Render(ctx.ToRecord());
            case IDictionary dict:
            {
                var sb = new StringBuilder("{");
                foreach (DictionaryEntry kv in dict)
                {
                    sb.Append(JsonSerializer.Serialize(Convert.ToString(kv.Key)))
                      .Append(':').Append(Render(kv.Value)).Append(',');
                }
                return sb.Append('}').ToString();
            }
            case IList list:
                return "[" + string.Join(",", list.Cast<object?>().Select(Render)) + "]";
            case Exception e:
                return e.ToString();
            default:
                try
                {
                    return JsonSerializer.Serialize(val, FieldsJson);
                }
                catch (Exception)
                {
                    return StructUtils.Jsonify(val, 0);
                }
        }
    }

    // Every default print a value has, plus the SDK's own record of it.
    private static List<Sink> FormsOf(string name, object? val)
    {
        var out_ = new List<Sink>();
        void Push(string kind, Func<string> fn)
        {
            try { out_.Add(new Sink(name + ":" + kind, fn())); } catch (Exception) { }
        }
        Push("json", () => StructUtils.Jsonify(val, 0));
        Push("string", () => Convert.ToString(val) ?? "");
        Push("render", () => Render(val));
        if (val is ${Name}Error se)
        {
            Push("message", () => se.Message);
            Push("record", () => StructUtils.Jsonify(se.ToRecord(), 0));
        }
        if (val is Exception e)
        {
            Push("message", () => e.Message);
            Push("tostring", () => e.ToString());
            Push("stack", () => e.StackTrace ?? "");
        }
        if (val is Context ctx)
        {
            Push("record", () => StructUtils.Jsonify(ctx.ToRecord(), 0));
        }
        if (val is ${Name}SDK)
        {
            // What a structured logger walking own fields would see.
            Push("fields", () => JsonSerializer.Serialize(val, FieldsJson));
        }
        return out_;
    }

    // Captures the serialised context from inside the pipeline: what a hook
    // author would hand to a logger.
    private sealed class CaptureFeature : BaseFeature
    {
        private readonly List<Sink> _sinks;

        public CaptureFeature(List<Sink> sinks)
        {
            Name = "capture";
            Version = "0.0.1";
            Active = true;
            _sinks = sinks;
        }

        public override void PreRequest(Context ctx) => _sinks.AddRange(FormsOf("ctx@PreRequest", ctx));
        public override void PreResponse(Context ctx) => _sinks.AddRange(FormsOf("ctx@PreResponse", ctx));
        public override void PreUnexpected(Context ctx) => _sinks.AddRange(FormsOf("ctx@PreUnexpected", ctx));
    }

    // A feature that throws from inside the pipeline, quoting the request it
    // saw: an exception MakeError never handled.
    private sealed class ThrowFeature : BaseFeature
    {
        private readonly bool _unexpected;

        public ThrowFeature(bool unexpected)
        {
            Name = "throwhook";
            Version = "0.0.1";
            Active = true;
            _unexpected = unexpected;
        }

        public override void PreResponse(Context ctx) =>
            throw new Exception("hook saw " + Render(ctx.Spec));

        // MakeError fires PreUnexpected, so what this throws escapes it.
        public override void PreUnexpected(Context ctx)
        {
            if (_unexpected)
            {
                throw new Exception("hook saw " + Render(ctx.Spec));
            }
        }
    }

    // A stream that succeeds, yielding the result's items.
    private sealed class StreamOkFeature : BaseFeature
    {
        public StreamOkFeature()
        {
            Name = "streamok";
            Version = "0.0.1";
            Active = true;
        }

        public override void PreDone(Context ctx)
        {
            if (null == ctx.Result)
            {
                return;
            }
            var items = ctx.Result.Resdata switch
            {
                IList list => list.Cast<object?>().ToList(),
                null => new List<object?>(),
                var one => new List<object?> { one },
            };
            ctx.Result.Stream = () => items;
        }
    }

    // A stream that fails while the caller iterates it, quoting a credential.
    private sealed class StreamThrowFeature : BaseFeature
    {
        public StreamThrowFeature()
        {
            Name = "streamthrow";
            Version = "0.0.1";
            Active = true;
        }

        public override void PreDone(Context ctx)
        {
            if (null != ctx.Result)
            {
                ctx.Result.Stream = Failing;
            }
        }

        private static IEnumerable<object?> Failing()
        {
            yield return Fail();
        }

        private static object? Fail() => throw new Exception("stream saw " + CanaryApikey);
    }

    private sealed record Scenario(string Name, Func<string, Dictionary<string, object?>, object?> Respond);

    private static Dictionary<string, object?> Response(int status, object? data,
        Dictionary<string, object?>? headers = null)
    {
        var h = new Dictionary<string, object?> { ["content-type"] = "application/json" };
        foreach (var kv in headers ?? new Dictionary<string, object?>())
        {
            h[kv.Key.ToLowerInvariant()] = kv.Value;
        }
        return new Dictionary<string, object?>
        {
            ["status"] = status,
            ["statusText"] = status < 400 ? "OK" : "ERR",
            ["json"] = (Func<object?>)(() => data),
            ["body"] = StructUtils.Jsonify(data, 0),
            ["headers"] = h,
        };
    }

    private static readonly List<Scenario> Scenarios = new()
    {
        new Scenario("ok", (_url, _def) => Response(200,
            new Dictionary<string, object?> { ["id"] = "i1", ["name"] = "n1" },
            new Dictionary<string, object?> { ["x-session-token"] = "RESP-TOKEN-a1b2c3d4e5" })),
        new Scenario("notfound", (_url, _def) => Response(404,
            new Dictionary<string, object?> { ["error"] = "no such record" })),
        new Scenario("server", (_url, _def) => Response(500,
            new Dictionary<string, object?> { ["error"] = "boom" })),
        new Scenario("transport", (url, _def) =>
            throw new Exception("socket hang up (URL was: \\"" + url + "\\")")),
        new Scenario("notjson", (_url, _def) => new Dictionary<string, object?>
        {
            ["status"] = 200,
            ["statusText"] = "OK",
            ["json"] = (Func<object?>)(() => throw new Exception("Unexpected token < in JSON")),
            ["body"] = "<html>",
            ["headers"] = new Dictionary<string, object?>(),
        }),
    };

    // Offline, as every generated suite is: the test OPTION resolves a
    // required server variable to test-<name>, and installs no transport.
    private static Dictionary<string, object?> Offline(Dictionary<string, object?> opts)
    {
        var copy = new Dictionary<string, object?>(opts);
        copy["test"] = new Dictionary<string, object?> { ["active"] = true };
        return copy;
    }

    // A client the sweep cannot build leaves nothing swept: a harness error,
    // not a leak.
    private static ${Name}SDK Construct(Dictionary<string, object?> opts)
    {
        try
        {
            return new ${Name}SDK(Offline(opts));
        }
        catch (Exception e)
        {
            throw new InvalidOperationException(
                "clean harness: the client could not be constructed, so nothing was swept: " +
                e.Message, e);
        }
    }

    private static ${Name}SDK MakeSdk(Scenario scenario, List<Sink> sinks,
        Dictionary<string, object?>? cleanopts = null, BaseFeature? extra = null,
        Dictionary<string, object?>? auth = null)
    {
        Action<Dictionary<string, object?>> Capture(string name) =>
            rec => sinks.AddRange(FormsOf(name, rec));

        var feature = new Dictionary<string, object?>();
        if (Fh.HasFeature("log"))
        {
            feature["log"] = new Dictionary<string, object?>
            {
                ["active"] = true,
                ["logger"] = (Action<string, string, Dictionary<string, object?>>)(
                    (level, _msg, attrs) => sinks.AddRange(FormsOf("log." + level, attrs))),
            };
        }
        if (Fh.HasFeature("debug"))
        {
            feature["debug"] = new Dictionary<string, object?>
            {
                ["active"] = true, ["onEntry"] = Capture("debug"),
            };
        }
        if (Fh.HasFeature("audit"))
        {
            feature["audit"] = new Dictionary<string, object?>
            {
                ["active"] = true, ["sink"] = Capture("audit"),
            };
        }
        if (Fh.HasFeature("telemetry"))
        {
            feature["telemetry"] = new Dictionary<string, object?>
            {
                ["active"] = true, ["exporter"] = Capture("telemetry"),
            };
        }
${cost ? `        if (Fh.HasFeature("cost"))
        {
            feature["cost"] = new Dictionary<string, object?>
            {
                ["active"] = true,
                ["sink"] = (Action<CostRecord>)(rec => sinks.AddRange(FormsOf("cost", rec))),
            };
        }
` : ''}        if (Fh.HasFeature("metrics"))
        {
            feature["metrics"] = new Dictionary<string, object?> { ["active"] = true };
        }
        if (Fh.HasFeature("clienttrack"))
        {
            feature["clienttrack"] = new Dictionary<string, object?> { ["active"] = true };
        }

        var clean = new Dictionary<string, object?> { ["values"] = CanaryValue };
        foreach (var kv in cleanopts ?? new Dictionary<string, object?>())
        {
            clean[kv.Key] = kv.Value;
        }

        var fetcher = (Context _ctx, string url, Dictionary<string, object?> fetchdef) =>
            scenario.Respond(url, fetchdef);

        var extend = new List<object?> { new CaptureFeature(sinks) };
        if (null != extra)
        {
            extend.Add(extra);
        }

        var opts = new Dictionary<string, object?>
        {
            ["apikey"] = CanaryApikey,
            ["secret"] = CanarySecret,
            ["headers"] = new Dictionary<string, object?> { ["X-Custom-Token"] = CanaryHeader },
            ["clean"] = clean,
            ["feature"] = feature,
            ["extend"] = extend,
            ["utility"] = new Dictionary<string, object?> { ["fetcher"] = fetcher },
        };
        if (null != auth)
        {
            opts["auth"] = auth;
        }
        return Construct(opts);
    }

    // Emitted from the model: every active entity with the operations it
    // declares, list and load first.
    private static readonly List<Candidate> Candidates = new()
    {
${candidateLines}
    };

    private static object? Invoke(${Name}EntityBase ent, string op,
        Dictionary<string, object?> match, Dictionary<string, object?>? ctrl)
    {
        var args = new Dictionary<string, object?>(match);
        return op switch
        {
            "list" => ent.List(args, ctrl),
            "load" => ent.Load(args, ctrl),
            "create" => ent.Create(args, ctrl),
            "update" => ent.Update(args, ctrl),
            "patch" => ent.Patch(args, ctrl),
            "remove" => ent.Remove(args, ctrl),
            _ => throw new InvalidOperationException("unknown operation: " + op),
        };
    }

    // Every path parameter an op's points declare, filled in.
    private static Dictionary<string, object?> Filled(${Name}SDK sdk, string entity, string op)
    {
        var filled = new Dictionary<string, object?>();
        var points = StructUtils.GetPath(sdk.GetRootCtx().Config,
            StructUtils.Jt("entity", entity, "op", op, "points")) as List<object?>;
        foreach (var point in points ?? new List<object?>())
        {
            var ps = StructUtils.GetPath(point, StructUtils.Jt("args", "params")) as List<object?>;
            foreach (var p in ps ?? new List<object?>())
            {
                if (StructUtils.GetProp(p, "name") is string pname)
                {
                    filled[pname] = "p1";
                }
            }
        }
        return filled;
    }

    // The first operation that completes against a plain 200: with no
    // arguments, else with every path parameter its points declare filled in.
    private static Target? UsableOp()
    {
        var fetcher = (Context _ctx, string _url, Dictionary<string, object?> _def) =>
            (object?)Response(200, new Dictionary<string, object?> { ["id"] = "i1" });
        var plain = Construct(new Dictionary<string, object?>
        {
            ["apikey"] = CanaryApikey,
            ["utility"] = new Dictionary<string, object?> { ["fetcher"] = fetcher },
        });
        foreach (var candidate in Candidates)
        {
            foreach (var op in candidate.Ops)
            {
                foreach (var match in new[] { new Dictionary<string, object?>(), Filled(plain, candidate.Name, op) })
                {
                    try
                    {
                        Invoke(candidate.Accessor(plain), op, match, null);
                        return new Target(candidate, op, match);
                    }
                    catch (Exception)
                    {
                        continue;
                    }
                }
            }
        }
        return null;
    }

    private const string NoOp = "no operation of this SDK completes against a plain 200; nothing to sweep";

    private static Exception? Drive(${Name}SDK sdk, Target target,
        Dictionary<string, object?> ctrl, List<Sink> sinks)
    {
        // A caller may keep the record it passed rather than read ctrl's entry.
        var held = ctrl.GetValueOrDefault("explain");
        var entity = target.Candidate.Accessor(sdk);
        object? out_ = null;
        Exception? err = null;
        try
        {
            out_ = Invoke(entity, target.Op, target.Match, ctrl);
        }
        catch (Exception e)
        {
            err = e;
        }
        if (null != err) sinks.AddRange(FormsOf("error", err));
        if (null != out_) sinks.AddRange(FormsOf("result", out_));
        // Raw, as a caller copying the match into another query reads it.
        sinks.AddRange(FormsOf("match", entity.Match()));
        if (ctrl.TryGetValue("explain", out var explain) && null != explain)
        {
            sinks.AddRange(FormsOf("explain", explain));
        }
        if (null != held && !ReferenceEquals(held, ctrl.GetValueOrDefault("explain")))
        {
            sinks.AddRange(FormsOf("explain:held", held));
        }
        return err;
    }

    private void Report(string line)
    {
        // Both: xunit shows the helper's output, the lane reads the console.
        Console.WriteLine(line);
        _out.WriteLine(line);
    }

    [Fact]
    public async Task NoCredentialLeavesTheSdkInAnyForm()
    {
        var target = UsableOp();
        if (null == target)
        {
            // xunit 2 has no runtime skip, so the skip is a printed reason.
            Report("clean: skipped: " + NoOp);
            return;
        }

        var sinks = new List<Sink>();
        var errors = new Dictionary<string, Exception>();
        var explains = new Dictionary<string, Dictionary<string, object?>>();

        var variants = new (string Name, Func<Dictionary<string, object?>> Ctrl)[]
        {
            ("throw", () => new Dictionary<string, object?>()),
            ("explain", () => new Dictionary<string, object?>
            {
                ["explain"] = new Dictionary<string, object?>(),
            }),
            ("nothrow", () => new Dictionary<string, object?>
            {
                ["throw"] = false,
                ["explain"] = new Dictionary<string, object?>(),
            }),
        };

        foreach (var scenario in Scenarios)
        {
            foreach (var variant in variants)
            {
                var sdk = MakeSdk(scenario, sinks);
                var ctrl = variant.Ctrl();
                var err = Drive(sdk, target, ctrl, sinks);
                var key = scenario.Name + "/" + variant.Name;
                if (null != err) errors[key] = err;
                if (ctrl.TryGetValue("explain", out var ex) && ex is Dictionary<string, object?> exm)
                {
                    explains[key] = exm;
                }
                sinks.AddRange(FormsOf("sdk", sdk));
            }
        }

        // A name given at run time replaces the declared one: the match leaves
        // out whichever name PrepareAuth placed.
        Drive(MakeSdk(Scenarios[0], sinks, auth: new Dictionary<string, object?> { ["name"] = "zzcred" }),
            target, new Dictionary<string, object?>(), sinks);

        // A credential mistyped as a map is rejected by validation, whose
        // message quotes the value it rejected.
        Exception? rejected = null;
        try
        {
            new ${Name}SDK(Offline(new Dictionary<string, object?>
            {
                ["apikey"] = new Dictionary<string, object?> { ["value"] = CanaryApikey },
                ["clean"] = new Dictionary<string, object?> { ["values"] = CanaryValue },
            }));
        }
        catch (Exception e)
        {
            rejected = e;
        }
        Assert.True(null != rejected, "a credential mistyped as a map should be rejected");
        sinks.AddRange(FormsOf("rejected", rejected));

        // An exception a feature hook throws, quoting the request, skips MakeError.
        foreach (var unexpected in new[] { false, true })
        {
            var hooked = MakeSdk(Scenarios[0], sinks, null, new ThrowFeature(unexpected));
            var hookerr = Drive(hooked, target, new Dictionary<string, object?>
            {
                ["explain"] = new Dictionary<string, object?>(),
            }, sinks);
            Assert.True(null != hookerr, "the throwing hook should fail the operation");
        }

        // Iterating a stream runs inside the same catch path as the operation,
        // and the explain record the caller passed is cleaned however it ends.
        foreach (var (name, extra) in new (string, BaseFeature?)[]
        {
            ("stream", new StreamThrowFeature()),
            ("stream-ok", new StreamOkFeature()),
            ("stream-plain", null),
        })
        {
            var streaming = target.Candidate.Accessor(MakeSdk(Scenarios[0], sinks, null, extra));
            var explain = new Dictionary<string, object?>();
            Exception? streamerr = null;
            try
            {
                await foreach (var _ in streaming.Stream(target.Op, new Dictionary<string, object?>
                {
                    ["reqmatch"] = new Dictionary<string, object?>(target.Match),
                }, new Dictionary<string, object?>
                {
                    ["ctrl"] = new Dictionary<string, object?> { ["explain"] = explain },
                }))
                {
                }
            }
            catch (Exception e)
            {
                streamerr = e;
            }
            Assert.True(("stream" == name) == (null != streamerr), name + ": only the failing stream throws");
            if (null != streamerr)
            {
                sinks.AddRange(FormsOf(name, streamerr));
            }
            Assert.True(0 < explain.Count, name + ": the explain record was not filled");
            sinks.AddRange(FormsOf(name + ":explain", explain));
        }

        // The raw path returns its failure rather than throwing it.
        var raw = MakeSdk(Scenarios[3], sinks).Direct(new Dictionary<string, object?> { ["path"] = "raw" });
        Assert.True(Equals(false, raw.GetValueOrDefault("ok")) && null != raw.GetValueOrDefault("err"),
            "a transport failure should fail Direct()");
        sinks.AddRange(FormsOf("direct", raw["err"]));

        // A registered value used as a map key is masked; keys that mask alike
        // are kept apart.
        var probe = MakeSdk(Scenarios[0], sinks);
        var named = probe.GetUtility().Clean(probe.GetRootCtx(), new Dictionary<string, object?>
        {
            [CanaryValue] = 1, [CanaryHeader] = 2, ["plain"] = 3,
        }) as Dictionary<string, object?> ?? new Dictionary<string, object?>();
        sinks.AddRange(FormsOf("named", named));

        // An error's code is cleaned like its message.
        var coded = probe.GetUtility().Clean(probe.GetRootCtx(),
            new ${Name}Error("code_" + CanaryValue, "coded", null));
        sinks.AddRange(FormsOf("coded", coded));

        var leaked = sinks
            .Select(s => (s.Name, Found: Leaks(s.Text)))
            .Where(s => 0 < s.Found.Count)
            .ToList();

        Report("clean: swept " + sinks.Count + " surface(s), " + leaked.Count + " leak(s)");

        Assert.True(0 == leaked.Count, "credential leaked through: " +
            string.Join("; ", leaked.Select(l => l.Name + " [" + string.Join(", ", l.Found) + "]")));

        // The positive half: the slot the credential travelled in is masked,
        // and an unregistered token in a response header is masked by name.
        Assert.True(errors.TryGetValue("notfound/throw", out var notfoundErr), "the 404 scenario must throw");
        var notfound = Assert.IsType<${Name}Error>(notfoundErr);
        Assert.Equal(404, notfound.Status);
        var spec = notfound.SpecVal as Dictionary<string, object?> ?? new Dictionary<string, object?>();
        if (!AuthSuppressed)
        {
            if ("query" == AuthWhere)
            {
                Assert.Equal(Mask, Header(spec.GetValueOrDefault("query"), AuthName));
            }
            else if ("cookie" == AuthWhere)
            {
                var cookie = Convert.ToString(Header(spec.GetValueOrDefault("headers"), "cookie")) ?? "";
                Assert.True(cookie.Contains(Mask), "cookie: " + cookie);
            }
            else
            {
                var cred = Convert.ToString(Header(spec.GetValueOrDefault("headers"), AuthName)) ?? "";
                Assert.True(cred.EndsWith(Mask), AuthName + ": " + cred);
            }
        }
        Assert.Equal(Mask, Header(spec.GetValueOrDefault("headers"), "x-custom-token"));

        Assert.True(explains.TryGetValue("ok/explain", out var explained), "the ok scenario should explain");
        var result = explained!.GetValueOrDefault("result") as Dictionary<string, object?>;
        Assert.True(null != result, "the explain record should carry the result");
        Assert.Equal(Mask, Header(result!.GetValueOrDefault("headers"), "x-session-token"));

        Assert.True(3 == named.Count && Equals(1, named.GetValueOrDefault(Mask)) &&
            Equals(2, named.GetValueOrDefault(Mask + "#1")) && Equals(3, named.GetValueOrDefault("plain")),
            "map keys: " + Render(named));
        Assert.Equal("code_" + Mask, (coded as ${Name}Error)?.Code);
    }

    [Fact]
    public void TheSweepCanSeeALeakCleanSwitchedOffShowsTheCredential()
    {
        var target = UsableOp();
        if (null == target)
        {
            Report("clean: skipped: " + NoOp);
            return;
        }

        var sinks = new List<Sink>();
        var sdk = MakeSdk(Scenarios[1], sinks, new Dictionary<string, object?> { ["active"] = false });
        var err = Drive(sdk, target, new Dictionary<string, object?>(), sinks);
        Assert.True(null != err, "the 404 scenario must throw");

        // Explaining a failure must not cost it its error.
        var explained = Drive(MakeSdk(Scenarios[1], new List<Sink>(),
                new Dictionary<string, object?> { ["active"] = false }), target,
            new Dictionary<string, object?> { ["explain"] = new Dictionary<string, object?>() }, new List<Sink>());
        Assert.True(err?.Message == explained?.Message,
            "with clean off, explain lost the error: expected " + err?.Message + ", got " + explained?.Message);

        var leaked = sinks.Where(s => 0 < Leaks(s.Text).Count).ToList();
        Assert.True(0 < leaked.Count, "with clean off, nothing showed the canary: the sweep is blind");

        if (!AuthSuppressed)
        {
            var text = Render((err as ${Name}Error)?.SpecVal);
            Assert.True(text.Contains(CanaryApikey) ||
                text.Contains(Convert.ToBase64String(Encoding.UTF8.GetBytes(CanaryApikey + ":" + CanarySecret))),
                "the raw spec should carry the credential when clean is off");
        }
    }

    // A feature's name is not a field name: only the sensitive names inside
    // its settings register. An entity block, of per-entity settings or
    // seeded records keyed by entity name and id, is not read at all, and nor
    // are rbac's rules, keyed by entity and operation names.
    [Fact]
    public void AFeatureNameDoesNotMakeItsSettingsSecret()
    {
        var sdk = Construct(new Dictionary<string, object?>
        {
            ["apikey"] = CanaryApikey,
            ["feature"] = new Dictionary<string, object?>
            {
                ["zzsecrets"] = new Dictionary<string, object?>
                {
                    ["active"] = false, ["kind"] = "PLAINSETTING-q8w2e4r6",
                },
                ["zzfeat"] = new Dictionary<string, object?>
                {
                    ["active"] = false, ["apitoken"] = "FEATTOKEN-z9y8x7w6",
                },
                ["rbac"] = new Dictionary<string, object?>
                {
                    ["active"] = false,
                    ["rules"] = new Dictionary<string, object?> { ["zztoken.load"] = "PLAINRULE-k7j5h3g1" },
                },
                ["test"] = new Dictionary<string, object?>
                {
                    ["active"] = false,
                    ["entity"] = new Dictionary<string, object?>
                    {
                        ["zztoken"] = new Dictionary<string, object?>
                        {
                            ["ZZTOKEN01"] = new Dictionary<string, object?> { ["note"] = "PLAINRECORD-t5r3e1w9" },
                        },
                    },
                },
            },
            ["entity"] = new Dictionary<string, object?>
            {
                ["zztoken"] = new Dictionary<string, object?>
                {
                    ["alias"] = new Dictionary<string, object?> { ["zzkey"] = "PLAINALIAS-m2n4b6v8" },
                },
            },
        });
        object? Cleaned(string s) => sdk.GetUtility().Clean(sdk.GetRootCtx(), s);

        Assert.Equal("kind PLAINSETTING-q8w2e4r6", Cleaned("kind PLAINSETTING-q8w2e4r6"));
        Assert.Equal("token " + Mask, Cleaned("token FEATTOKEN-z9y8x7w6"));
        Assert.Equal("record PLAINRECORD-t5r3e1w9", Cleaned("record PLAINRECORD-t5r3e1w9"));
        Assert.Equal("alias PLAINALIAS-m2n4b6v8", Cleaned("alias PLAINALIAS-m2n4b6v8"));
        Assert.Equal("rule PLAINRULE-k7j5h3g1", Cleaned("rule PLAINRULE-k7j5h3g1"));
    }

    [Fact]
    public void TheGeneratedConfigsOwnCleanBlockIsHonoured()
    {
        var utility = Construct(new Dictionary<string, object?>()).GetUtility();
        var config = new Dictionary<string, object?>
        {
            ["options"] = new Dictionary<string, object?>
            {
                ["clean"] = new Dictionary<string, object?>
                {
                    ["keys"] = "zzsens",
                    ["values"] = "CONFIG-SEEDED-1",
                },
            },
        };
        var ctx = utility.MakeContext(new Dictionary<string, object?>
        {
            ["utility"] = utility,
            ["config"] = config,
            ["options"] = new Dictionary<string, object?>
            {
                ["clean"] = new Dictionary<string, object?> { ["values"] = "CALLER-SEEDED-2" },
            },
        }, null);
        ctx.Options = utility.MakeOptions(ctx);

        Assert.Equal("a " + Mask + " b " + Mask, utility.Clean(ctx, "a CONFIG-SEEDED-1 b CALLER-SEEDED-2"));
        var masked = utility.Clean(ctx, new Dictionary<string, object?>
        {
            ["my_zzsens"] = "x",
            ["other"] = "y",
        }) as Dictionary<string, object?>;
        Assert.Equal(Mask, masked?.GetValueOrDefault("my_zzsens"));
        Assert.Equal("y", masked?.GetValueOrDefault("other"));
        Assert.Equal("CONFIG-SEEDED-1",
            StructUtils.GetPath(config, StructUtils.Jt("options", "clean", "values")));
    }

    [Fact]
    public void WithNoCleanBlockTheSchemaDefaultsApply()
    {
        var utility = Construct(new Dictionary<string, object?>()).GetUtility();
        var ctx = utility.MakeContext(new Dictionary<string, object?>
        {
            ["utility"] = utility,
            ["options"] = new Dictionary<string, object?> { ["apikey"] = "NOBLOCK-APIKEY-k3j5h7" },
        }, null);
        ctx.Options = utility.MakeOptions(ctx);

        Assert.Equal("failed with " + Mask, utility.Clean(ctx, "failed with NOBLOCK-APIKEY-k3j5h7"));
        var masked = utility.Clean(ctx, new Dictionary<string, object?>
        {
            ["x-session-token"] = "RESP-TOKEN-a1b2c3d4e5",
        }) as Dictionary<string, object?>;
        Assert.Equal(Mask, masked?.GetValueOrDefault("x-session-token"));
    }
}
`
}


export {
  TestClean
}
