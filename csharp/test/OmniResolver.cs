// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (Voxgig.Omni.Runner.MakeRunner(specref, provider)), presented to the
// corpus tests in the struct-runner shape they already use (run.Spec,
// run.RunSet, run.RunSetFlags, run.Client). No compat shim is vendored:
// the adapter below IS the whole bridge, per language, per the vendor-tag
// rollout (docs/design/vendor-tag-rollout.md, Decision 4). It supersedes
// the engine half of Runner.cs (TestRunner.RunSet/MatchDeep/MatchString)
// and the whole StructRunner engine (support lives on in Runner.cs).
//
// C#-specific decisions, each load-bearing:
//
// 1. CONTEXTS STAY MAPS ACROSS THE RUNNER. omni sets `entry.ctx` to the
//    contextified args[0] and `match: {ctx: ...}` assertions read THROUGH
//    it with omni's own GetPath, which walks JSON maps only. A typed
//    Context there would make every ctx assertion read "absent". So the
//    subjects receive the MAP, build the typed Context with
//    OmniResolver.OmniCtx(args[0], ...) at the call site, run the
//    utility, and write the observable ctx state back into the same map
//    with OmniSyncCtx - which is what makes the live SDK reachable
//    through ctx.Client for the generated utilities (the ts resolver
//    gets both for free from prototype delegation; maps-plus-sync is the
//    same idiom the go and java resolvers use for the same contract,
//    omni#56).
//
// 2. ZERO-ARGUMENT ENTRIES. The corpus carries entries with no `in`,
//    `args` or `ctx`, meaning "call the subject with NO argument". The
//    vendored C# port already distinguishes that case natively - such an
//    entry arrives as one `Absent.Mark` argument (C# has no `undefined`,
//    so absence is a sentinel) - which is why C# needs no novalargs spec
//    rewrite (go) and no compat shim (lua/php). The resolver's ONE
//    conversion is the sentinel swap at the call boundary: Absent.Mark ->
//    StructUtils.NONE on the way in (a whole argument only - a parsed
//    corpus value never contains one), NONE -> Absent.Mark on the way
//    out, walked, because a reader can leave NONE inside a partially
//    resolved node. Ported from omni's own csharp/compat/Struct.cs
//    (register 4.12), which this resolver replaces.
//
// 3. NUMBERS. omni's Util.Parse reads every JSON number as `double`;
//    the struct port's own loader gave `long` for anything integral, and
//    the library branches on that (`Typify` answers Integer or Decimal by
//    it). So the resolved spec is normalised ONCE, integral double ->
//    long, before any subject sees it (FixNums, the go resolver's
//    fixnums). Nothing is needed on the way out: omni's DeepEqual already
//    compares long against double numerically.
//
// 4. THE VENDORED C# PORT LACKS THE omni#54 JsonStr CYCLE GUARD the
//    TypeScript port has at this tag (voxgig/omni#64 landed the runner
//    fixes for js/go/py only). It only bites on CYCLIC values, and the
//    port's Clone/FixJson/JsonStr pass non-JSON values (a typed Context,
//    an SDK client) through without walking them - so decision 1 above
//    (JSON-only maps in entries, typed state kept out of them) is also
//    what keeps every value the runner clones or stringifies acyclic.
//    The match-clone half is absent by construction (this port never
//    cloned its match base), and the errify half (non-Error throwables)
//    cannot arise: C# subjects fail by THROWING an Exception, and the
//    Errify hook below keeps the SDK error's code for
//    `match: {err: {code: ...}}` assertions.

using System.Globalization;
using System.Runtime.CompilerServices;

using Voxgig.Omni;
using Voxgig.Struct;

// `Util` alone would resolve to the SDK's UnivecSdk.Util namespace,
// not the vendored omni Util class - alias it explicitly.
using OmniUtil = Voxgig.Omni.Util;

using UnivecSdk;

namespace UnivecSdk.Test;

public static class OmniResolver
{
    // The sentinels, under the names the corpus tests already use.
    public const string NULLMARK = Runner.NULLMARK;
    public const string UNDEFMARK = Runner.UNDEFMARK;
    public const string EXISTSMARK = Runner.EXISTSMARK;

    /// <summary>The function under test, in omni's native argument shape.</summary>
    public delegate object? Subject(params object?[] args);

    /// <summary>Resolves one named section of the spec.</summary>
    public delegate Run NamedRunner(string name, object? store = null);

    private static string SourceDir([CallerFilePath] string path = "")
        => Path.GetDirectoryName(path)!;

    /// <summary>
    /// The struct runner's makeRunner(testfile, client) signature, backed
    /// by vendored omni. `testfile` is a spec path (a relative path is
    /// absolutized against THIS file's directory, not the process working
    /// directory - dotnet test runs from bin/ - and omni's docs say a port
    /// must resolve the path itself) or an already-parsed spec value
    /// (omni's own capability), which keeps smoke tests free of fixture
    /// files.
    /// </summary>
    public static NamedRunner MakeRunner(object testfile, object? client)
    {
        var provider = SdkProvider(client);

        RunnerPack runner;
        if (testfile is string path)
        {
            if (!Path.IsPathRooted(path))
            {
                path = Path.GetFullPath(Path.Combine(SourceDir(), path));
            }
            runner = Runner.MakeRunner(path, provider);
        }
        else
        {
            runner = Runner.MakeRunner(testfile, provider);
        }

        return (name, store) => new Run(runner.Run(name, store), client);
    }

    /// <summary>
    /// What the runner returns for one named spec section - the
    /// struct-runner shape the corpus call sites consume. A failing entry
    /// throws <see cref="OmniError"/>, which fails the xUnit test with the
    /// entry named.
    /// </summary>
    public sealed class Run
    {
        /// <summary>The resolved spec section (numbers normalised, decision 3).</summary>
        public Dictionary<string, object?> Spec { get; }

        /// <summary>
        /// The SDK this runner was built with. omni's own RunPack carries
        /// the PROVIDER in that slot, which has none of the SDK's members,
        /// so the client is handed back instead (omni#56).
        /// </summary>
        public object? Client { get; }

        private readonly RunPack pack;

        internal Run(RunPack pack, object? client)
        {
            this.pack = pack;
            Client = client;
            Spec = FixNums(pack.Spec) as Dictionary<string, object?>
                ?? new Dictionary<string, object?>();
        }

        /// <summary>A named group of the resolved spec.</summary>
        public object? Set(string setname)
            => Spec.TryGetValue(setname, out var v) ? v : null;

        /// <summary>Run one set of test entries with omni's default flags.</summary>
        public void RunSet(object? testspec, Subject? subject = null)
        {
            RunSetFlags(testspec, null, subject);
        }

        /// <summary>Run one set of test entries with explicit flags.</summary>
        public void RunSetFlags(object? testspec, Dictionary<string, bool>? flags,
            Subject? subject = null)
        {
            Voxgig.Omni.Subject? wrapped = null;
            if (null != subject)
            {
                wrapped = args =>
                {
                    var sargs = new object?[args?.Length ?? 0];
                    for (var i = 0; i < sargs.Length; i++)
                    {
                        // The sentinel swap at the call boundary (decision 2).
                        sargs[i] = OmniUtil.IsAbsent(args![i]) ? StructUtils.NONE : args[i];
                    }
                    return ToOmni(subject(sargs));
                };
            }

            var omniflags = new Flags();
            if (null != flags && flags.TryGetValue("null", out var donull))
            {
                omniflags.Null = donull;
            }

            pack.RunSetFlags(testspec, omniflags, wrapped);
        }
    }

    // ------------------------------------------------------------------
    // The two value models (decisions 2 and 3)
    // ------------------------------------------------------------------

    /// <summary>
    /// This port's model -> omni's. Walked, because NONE CAN sit inside a
    /// result - a reader leaves it in a partially resolved node - and ANY
    /// list becomes a List&lt;object?&gt;: KeysOf returns a List&lt;string&gt;,
    /// which omni's IsList does not recognise. (Subject ARGUMENTS are never
    /// walked: containers must cross by identity so `match.args` sees
    /// in-place mutation, e.g. setpath.)
    /// </summary>
    internal static object? ToOmni(object? val)
    {
        if (ReferenceEquals(val, StructUtils.NONE))
        {
            return Absent.Mark;
        }

        if (null == val || val is string || val is bool || OmniUtil.IsNum(val))
        {
            return val;
        }

        if (val is IDictionary<string, object?> map)
        {
            var outmap = new Dictionary<string, object?>(map.Count);
            foreach (var pair in map)
            {
                outmap[pair.Key] = ToOmni(pair.Value);
            }
            return outmap;
        }

        // Every list shape, not just IList<object?>. A non-generic IList
        // covers List<string>, List<List<object?>> and the rest.
        if (val is System.Collections.IList list)
        {
            var outlist = new List<object?>(list.Count);
            for (var index = 0; index < list.Count; index++)
            {
                outlist.Add(ToOmni(list[index]));
            }
            return outlist;
        }

        // A non-generic dictionary (rare, but the generic pattern does not
        // catch every shape a port might hand back).
        if (val is System.Collections.IDictionary raw)
        {
            var outmap = new Dictionary<string, object?>();
            foreach (System.Collections.DictionaryEntry entry in raw)
            {
                outmap[Convert.ToString(entry.Key, CultureInfo.InvariantCulture) ?? ""] =
                    ToOmni(entry.Value);
            }
            return outmap;
        }

        return val;
    }

    /// <summary>
    /// omni's number model -> this port's: an integral JSON double becomes
    /// the long the struct port's own loader produced (decision 3). Walked
    /// copies; applied once to the resolved spec.
    /// </summary>
    internal static object? FixNums(object? val)
    {
        switch (val)
        {
            case double number:
                if (!double.IsNaN(number) && !double.IsInfinity(number) &&
                    Math.Floor(number) == number &&
                    number >= -9.2233720368547758E18 && number <= 9.2233720368547758E18)
                {
                    return (long)number;
                }
                return val;

            case IDictionary<string, object?> map:
            {
                var outmap = new Dictionary<string, object?>(map.Count);
                foreach (var pair in map)
                {
                    outmap[pair.Key] = FixNums(pair.Value);
                }
                return outmap;
            }

            case IList<object?> list:
            {
                var outlist = new List<object?>(list.Count);
                foreach (var entry in list)
                {
                    outlist.Add(FixNums(entry));
                }
                return outlist;
            }

            default:
                return val;
        }
    }

    // ------------------------------------------------------------------
    // Provider bookkeeping
    // ------------------------------------------------------------------

    // DefProviders marks the providers a spec's DEF.client block built -
    // the only ones OmniCtx lets override a call site's explicit client
    // (the base provider rides on EVERY ctx entry, and letting it win
    // would defeat sections that deliberately construct a
    // differently-optioned client). Guarded: xUnit may run tests
    // concurrently.
    private static readonly object ProviderLock = new();
    private static readonly Dictionary<Provider, object?> ProviderClients = new();
    private static readonly HashSet<Provider> DefProviders = new();

    private static void RegisterProvider(Provider provider, object? client)
    {
        lock (ProviderLock)
        {
            ProviderClients[provider] = client;
        }
    }

    private static void MarkDefProvider(Provider provider)
    {
        lock (ProviderLock)
        {
            DefProviders.Add(provider);
        }
    }

    private static object? DefProviderClient(Provider provider)
    {
        lock (ProviderLock)
        {
            return DefProviders.Contains(provider) &&
                ProviderClients.TryGetValue(provider, out var client) ? client : null;
        }
    }

    // Wrap a live client as an omni provider. No subject-by-name hook: the
    // C# Utility members are TYPED delegates (a Func taking a Context), so
    // a generic name lookup cannot produce omni's (object[]) subject
    // without a per-name adapter - and every generated call site passes
    // its subject explicitly. DEF.client entries still resolve: the Client
    // hook builds another live test SDK.
    private static Provider SdkProvider(object? client)
    {
        var provider = new Provider
        {
            // A DEF.client entry becomes another live test SDK, wrapped
            // the same way and marked as DEF-built so OmniCtx resolves it
            // back. The options arrive from omni's raw parse: normalise
            // the numbers before the SDK sees them (decision 3).
            Client = options =>
            {
                var opts = FixNums(options) as Dictionary<string, object?>
                    ?? new Dictionary<string, object?>();
                var sub = SdkProvider(UnivecSDK.TestSDK(null, opts));
                MarkDefProvider(sub);
                return sub;
            },

            // Client options may reference the runner store.
            Inject = (options, store) => StructUtils.Inject(options, store),

            // Keep the SDK error's code beside its message, so a corpus
            // `match: {err: {code: ...}}` can assert on it - the C#
            // analogue of the omni#54 errify fix (decision 4).
            Errify = err =>
            {
                if (err is UnivecError sdkerr)
                {
                    var outmap = new Dictionary<string, object?>
                    {
                        ["name"] = "UnivecError",
                        ["message"] = sdkerr.Message,
                    };
                    if (!string.IsNullOrEmpty(sdkerr.Code))
                    {
                        outmap["code"] = sdkerr.Code;
                    }
                    return outmap;
                }
                return Runner.Errify(err);
            },
        };

        RegisterProvider(provider, client);

        return provider;
    }

    // ------------------------------------------------------------------
    // Typed-context bridging (decision 1)
    // ------------------------------------------------------------------

    /// <summary>
    /// Build the typed Context a generated utility takes from the ctx MAP
    /// omni handed the subject (args[0]). The map's `client` entry - an
    /// omni provider when a DEF entry selected one - resolves back to the
    /// live SDK it wraps; otherwise the given client is used. (The engine
    /// half of the retired TestRunner.RunSet call sites did this as
    /// MakeCtxFromMap + FixCtx, per section, by hand.)
    /// </summary>
    public static Context OmniCtx(object? arg, UnivecSDK client, Utility utility)
    {
        var ctxmap = arg as Dictionary<string, object?>
            ?? new Dictionary<string, object?>();

        // Only a DEF-built client overrides the caller's: the base
        // provider is on every ctx entry, and a call site that constructed
        // a special client (a DEF.setup options set) must keep it.
        if (ctxmap.TryGetValue("client", out var p) && p is Provider prov &&
            DefProviderClient(prov) is UnivecSDK live)
        {
            client = live;
            utility = live.GetUtility();
        }

        var ctx = TestRunner.MakeCtxFromMap(ctxmap, client, utility);
        TestRunner.FixCtx(ctx, client);
        return ctx;
    }

    /// <summary>
    /// Write the OBSERVABLE state of a typed context back into the ctx map
    /// the entry holds, which is where a `match: {ctx: ...}` assertion
    /// reads. The subject mutated the typed context; the map is what the
    /// runner can walk. (The retired engine call sites did this per
    /// section, by hand, as "update entry ctx for match".)
    /// </summary>
    public static void OmniSyncCtx(object? arg, Context? ctx)
    {
        if (arg is not Dictionary<string, object?> ctxmap || null == ctx)
        {
            return;
        }

        if (null != ctx.Spec)
        {
            var spec = new Dictionary<string, object?>
            {
                ["base"] = ctx.Spec.Base,
                ["prefix"] = ctx.Spec.Prefix,
                ["suffix"] = ctx.Spec.Suffix,
                ["path"] = ctx.Spec.Path,
                ["method"] = ctx.Spec.Method,
                ["params"] = ctx.Spec.Params,
                ["query"] = ctx.Spec.Query,
                ["headers"] = ctx.Spec.Headers,
                ["step"] = ctx.Spec.Step,
                ["alias"] = ctx.Spec.Alias,
            };
            if (null != ctx.Spec.Body)
            {
                spec["body"] = ctx.Spec.Body;
            }
            if (!string.IsNullOrEmpty(ctx.Spec.Url))
            {
                spec["url"] = ctx.Spec.Url;
            }
            ctxmap["spec"] = spec;
        }

        if (null != ctx.Result)
        {
            var res = new Dictionary<string, object?>
            {
                ["ok"] = ctx.Result.Ok,
                ["status"] = ctx.Result.Status,
                ["statusText"] = ctx.Result.StatusText,
                ["headers"] = ctx.Result.Headers,
            };
            if (null != ctx.Result.Body)
            {
                res["body"] = ctx.Result.Body;
            }
            if (null != ctx.Result.Err)
            {
                res["err"] = new Dictionary<string, object?>
                {
                    ["message"] = ctx.Result.Err.Message,
                };
            }
            if (null != ctx.Result.Resdata)
            {
                res["resdata"] = ctx.Result.Resdata;
            }
            if (null != ctx.Result.Resmatch)
            {
                res["resmatch"] = ctx.Result.Resmatch;
            }
            ctxmap["result"] = res;
        }

        if (null != ctx.Response)
        {
            ctxmap["response"] = "exists";
        }
    }
}
