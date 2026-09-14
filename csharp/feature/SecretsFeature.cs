// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The csharp port of
// tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, C# idiom,
// and structurally go's port (tm/go/feature/secrets_feature.go) rather than
// ts's, for the two reasons spelled out below.
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider - a `memory` store named `options` - so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
// When the option is unset, the remaining providers (env, dotenv, a vault)
// are asked in order, and moving a credential from code to a vault becomes
// a configuration change.
//
// WHY THE CREDENTIAL LIVES IN FEATURE STATE, not in the options map.
// `_rootctx.Options = _options` (Main.fragment.cs) is ONE shared
// Dictionary, and PrepareAuth reads it on every operation
// (`ctx.Client.OptionsMap()`). A Dictionary<K,V> is no more thread-safe
// than a Go map, so a feature that wrote the resolved value there would
// race every concurrent operation - and readers would see a torn map, not
// a stale value. So the resolved credential is held HERE and injected into
// each request at the transport seam; the options map stays frozen after
// construction and every raw read on it is safe. The header the wire sees
// is identical, because the wrapper rebuilds it exactly the way PrepareAuth
// does, from the same options.auth.prefix.
//
// WHY RESOLUTION HAPPENS AT THE TRANSPORT, not in the PreSpec hook.
// `Direct()` and `Graphql()` both funnel through RawRequest, and the
// fragment says it plainly: "like Direct, this bypasses the feature
// pipeline - no retry, ratelimit or paging features apply". NO feature
// hooks run there. The transport delegate is the one seam every wire path
// crosses, so resolving there is what gives the raw paths the same
// credential - and the same fail-closed refusal - as the entity pipeline.
// The header is rewritten AFTER PrepareAuth built it, so the transport is
// exactly early enough.
//
// ONE VISIBLE CONSEQUENCE, worth knowing before it surprises someone:
// UnivecSDK.Prepare() returns the fetchdef WITHOUT crossing the
// transport, so its authorization header is the one PrepareAuth built from
// the apikey OPTION - never the chain-resolved credential. Prepare is a
// what-would-I-send inspector; what is actually sent is what Direct,
// Graphql and the entity ops put on the wire, and those all cross the seam.
// (ts can answer differently because its prepare() awaits the feature's own
// resolve; a void C# hook has no equivalent.)
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
// vault never degrades into an unauthenticated request. C# feature hooks
// are void and cannot fail an operation from PreSpec the way ts's awaited
// hook rejection can - so, like go, the transport is wrapped WHENEVER the
// feature is active and the wrapper refuses to send while resolution
// stands failed. An exception out of the transport becomes `response.Err`
// on the entity path (MakeRequest.cs) and `{ ok: false, err }` on the raw
// path (Main.fragment.cs), so both wire paths honour it.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when a
// response status in `exchange.statuses` (401) says it is spent the wrapper
// buys another and retries the same request once. Concurrent purchases
// share the one in-flight exchange; test mode buys nothing and answers with
// a deterministic fake token.
//
// A NOTE ON THE VENDORED TREES. Upstream sekreto ships its core and its
// plugins as TWO assemblies, and the header of the vendored Sekreto.cs
// still asserts that boundary ("THE CORE REFERENCES NO PLUGIN, IN ANY
// FORM"). Vendoring compiles both into this one SDK assembly, so the
// msbuild reference graph no longer enforces it. Nothing breaks, but the
// model's plugin trim (feature.secrets.plugin.<group>.active) is now the
// only thing keeping a generated SDK lean.

using System.Text.Json;

using Voxgig.Struct;

using Voxgig.Sekreto;

using UnivecSdk.Util;

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class SecretsFeature : BaseFeature
{
    private UnivecSDK? _client;

    // The LIVE options map (root ctx options). READ ONLY: this feature
    // never writes it (see the header).
    private Dictionary<string, object?>? _liveopts;

    private string _secretname = "apikey";
    private bool _cache = true;
    private Sekreto? _sek;

    // A chain this feature could not even BUILD (an unknown provider kind,
    // a provider that refused its own configuration). Init cannot throw -
    // it runs inside the SDK constructor - so the failure is held and the
    // transport gate refuses with it, which keeps a misconfigured chain
    // fail-closed rather than silently unauthenticated.
    private Exception? _initerr;

    private SecretsExchange? _exchange;
    private string _refresh = "";

    // The state lock. It guards `_cred`, `_refresh`, `_resolving` and
    // `_buying` - AND it serialises every call into Sekreto, which is not
    // internally thread-safe (Resolve() appends to plain List<T> caches
    // with no lock of its own). Only the owner of an in-flight resolution
    // runs ResolveOnce, so at most one thread is ever inside the chain.
    private readonly object _mu = new();
    private SecretsCall? _resolving;
    private SecretsBuy? _buying;

    // The RESOLVED credential - what the transport injects.
    private string _cred = "";

    public SecretsFeature()
    {
        Version = "0.1.0";
        Name = "secrets";
        Active = true;
    }

    // Init is sync by feature contract: build the chain, never look
    // anything up here.
    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _liveopts = ctx.Options;
        Active = FoptBool(options, "active", false);

        if (!Active)
        {
            return;
        }

        // WRAP FIRST, BUILD SECOND. Everything below can fail, and a
        // failure has to be reported by the gate - which does not exist
        // until the wrap is installed. Installing it afterwards (as the go
        // port does) means a chain that failed to BUILD leaves no gate at
        // all, and every request goes out unauthenticated: fail-open in the
        // one place this feature exists to close.
        var inner = ctx.Utility!.Fetcher;
        ctx.Utility.Fetcher = (ctx2, url, fetchdef) => Transport(ctx2, url, fetchdef, inner);

        _secretname = FoptStr(options, "name", "apikey");
        _cache = FoptBool(options, "cache", true);

        // Exchange config, normalised once. Null when off, so every later
        // decision is a null check.
        var xopts = FoptMap(options, "exchange");
        if (FoptBool(xopts, "active", false))
        {
            var statuses = new List<int>();
            foreach (var s in FoptList(xopts, "statuses") ?? new List<object?>())
            {
                statuses.Add(Helpers.ToInt(s));
            }
            if (0 == statuses.Count)
            {
                statuses.Add(401);
            }
            _exchange = new SecretsExchange
            {
                Path = FoptStr(xopts, "path", "auth/token"),
                Method = FoptStr(xopts, "method", "POST"),
                Request = FoptStr(xopts, "request", "refresh_token"),
                Response = FoptStr(xopts, "response", "access_token"),
                Statuses = statuses,
                Retries = FoptInt(xopts, "retries", 1),
            };
        }

        // The explicit credential, when set, is the first store in the
        // chain.
        //
        // WHICH option that is depends on the exchange. Without one, the
        // secret being resolved IS the credential the transport sends, so
        // `apikey` is it. With one, the secret is a REFRESH token and
        // `apikey` means the opposite thing - an access token the caller
        // already holds - so the explicit seat belongs to
        // `exchange.refresh`, and apikey is left alone to serve as the
        // starting access token (see ResolveOnce).
        var seat = null == _exchange
            ? StructUtils.GetProp(_liveopts, "apikey") as string ?? ""
            : FoptStr(xopts, "refresh", "");

        var specs = new List<object>();

        if ("" != seat)
        {
            string key;
            try
            {
                key = Names.EnvKey(_secretname);
            }
            catch (Exception ex)
            {
                // An invalid secret name. TryGet would refuse it too, so
                // holding the error here only makes the refusal EARLY and
                // specific instead of arriving on the first request.
                _initerr = ex;
                return;
            }

            specs.Add(new Dictionary<string, object>
            {
                ["kind"] = "memory",
                ["name"] = "options",
                ["values"] = new Dictionary<string, object> { [key] = seat },
            });
        }

        foreach (var p in FoptList(options, "providers") ?? new List<object?>())
        {
            if (p is IProvider live)
            {
                // A provider already built joins the chain as it is -
                // Sekreto's constructor takes a live IProvider directly.
                specs.Add(live);
                continue;
            }
            // ANYTHING ELSE GOES THROUGH AS IT IS, converted but not
            // filtered. A malformed entry is a configuration mistake, and
            // sekreto already refuses one by name ("sekreto: unknown
            // provider kind: ..."), which lands in `_initerr` and closes
            // the gate. Dropping it here instead would leave a client whose
            // chain is quietly one provider shorter than its options say -
            // the silent half of a fail-open.
            specs.Add(SpecValue(p)!);
        }

        // The plugin DEFINITIONS the model selected for this feature,
        // emitted by Config_csharp from the catalogue's active `plugin.def`
        // entries. Upstream sekreto's contract since the registry was
        // retired: a kind not passed in Plugins is unknown to this Sekreto,
        // so the model's choice of plugin groups IS the SDK's provider
        // vocabulary.
        var plugs = new List<Voxgig.Plugin.Definition>();
        foreach (var d in SdkConfig.FeaturePlugins(Name))
        {
            if (d is Voxgig.Plugin.Definition def)
            {
                plugs.Add(def);
            }
        }

        try
        {
            _sek = new Sekreto(new SekretoOptions
            {
                Providers = specs,
                Plugins = plugs,
                Cache = _cache,
            });
        }
        catch (Exception ex)
        {
            _initerr = ex;
        }
    }

    // The LIVE Sekreto instance, for callers who want arbitrary secrets or
    // redaction. There is no client-side accessor (ts has `sdk.secrets()`;
    // this target's client class emits none), so a caller reaches it the
    // way the tests do - through the feature list:
    //
    //   var sf = client.Features.OfType<SecretsFeature>().FirstOrDefault();
    //   sf?.GetSekreto()?.Get("db.password");
    //   sf?.GetSekreto()?.Redact(logline);
    //
    // Never a clone: sekreto holds provider state (caches, vault leases)
    // that has to stay live to be worth anything.
    //
    // NAMED `GetSekreto`, not `Sekreto`, for the reason the client class
    // documents at its head: a member whose simple name is also a TYPE name
    // shadows that type in expression position, and `Sekreto` is the return
    // type here. Same rule as GetUtility()/GetRootCtx().
    //
    // NOT THREAD-SAFE for the caller. Sekreto mutates its own caches on
    // every lookup with no lock; this feature serialises its own calls
    // (see `_mu`), but a caller holding the instance is on their own.
    public Sekreto? GetSekreto()
    {
        return _sek;
    }

    // Credential exposes the resolved credential (empty when none) - the
    // state the transport injects. Tests and callers read it here rather
    // than from the options map, which this feature never mutates.
    public string Credential()
    {
        lock (_mu)
        {
            return _cred;
        }
    }

    // NO PreSpec OVERRIDE, deliberately, though the model declares the hook.
    //
    // The hook is where ts and js resolve, because there they can write the
    // resolved value into the live options and let the synchronous
    // prepareAuth read it. csharp writes nothing (see the header), so a
    // PreSpec resolution would buy nothing the transport does not already
    // do - and it would COST. A C# hook is `void` and cannot fail an
    // operation, so its failure would have to be swallowed; the transport
    // then resolves again, and since a FAILED resolution is deliberately
    // never cached, one flaky provider gets asked TWICE per operation and
    // an outage that should refuse the request instead recovers inside it.
    // (Found by the transient-failure test below, which went green on a
    // request that should never have gone out.) It would also make `cache:
    // false` mean two chain reads per request rather than one. The
    // transport is the only seam this feature needs, and it is the only one
    // that covers Direct and Graphql.

    // ---------------------------------------------------------------
    // Resolution.

    // One resolution, shared by every concurrent caller. A settled HIT is
    // kept only when caching is on (`cache: false` means every resolve
    // asks the chain again); a FAILURE is always cleared, so a transient
    // vault outage never poisons the client permanently - the next
    // operation asks the chain again.
    //
    // A MISS is cleared too, however caching is set. That rule is
    // sekreto's, not this feature's: `A miss is never cached: the next read
    // asks again`, in sekreto's own source. Keeping a settled miss here
    // would override that from the layer above, and a secret provisioned
    // after startup - a mounted file, a policy granted a minute late -
    // would never be picked up for the life of the client. `cache` is about
    // caching a HIT; it was never a promise to keep saying no.
    private void Resolve()
    {
        if (null != _initerr)
        {
            throw _initerr;
        }

        SecretsCall call;
        var owner = false;

        lock (_mu)
        {
            if (null != _resolving)
            {
                call = _resolving;
            }
            else
            {
                call = new SecretsCall();
                _resolving = call;
                owner = true;
            }
        }

        if (!owner)
        {
            call.Done.Wait();
            if (null != call.Err)
            {
                throw call.Err;
            }
            return;
        }

        Exception? err = null;
        var hit = false;
        try
        {
            hit = ResolveOnce();
        }
        catch (Exception ex)
        {
            err = ex;
        }

        lock (_mu)
        {
            call.Err = err;
            if (null != err || !_cache || !hit)
            {
                _resolving = null;
            }
        }
        call.Done.Set();

        if (null != err)
        {
            throw err;
        }
    }

    // Resolve once, reporting whether a credential came out of it. That
    // bool is the whole of what Resolve() needs to tell a cacheable HIT
    // from a miss it must not keep.
    private bool ResolveOnce()
    {
        if (null == _sek)
        {
            return false;
        }

        // TryGet returns null on a MISS and THROWS on a provider error -
        // sekreto's invariant, and the whole of this feature's fail-closed
        // behaviour rides on the difference.
        var found = _sek.TryGet(_secretname);

        if (null == _exchange)
        {
            lock (_mu)
            {
                // An UNCACHED miss after an earlier hit is a revocation:
                // the chain now says no provider has the secret, so the
                // resolved value must not keep going out on the wire. (An
                // explicit apikey OPTION is never lost here - it seats
                // FIRST in the chain as a memory provider, so the chain
                // HITS while one is set and this branch is unreachable.)
                _cred = found ?? "";
            }
            return null != found;
        }

        // Exchanging: what the chain resolved is the REFRESH token, kept
        // for every later purchase. A miss is not fatal here - an explicit
        // `apikey` may already hold a usable access token, and the API is
        // what gets to say whether it does.
        string apikey;
        lock (_mu)
        {
            _refresh = found ?? "";
            apikey = _cred;
        }

        if ("" == apikey)
        {
            // A starting access token supplied as the OPTION: read from
            // the frozen options map (no feature ever writes it).
            apikey = StructUtils.GetProp(_liveopts, "apikey") as string ?? "";
            lock (_mu)
            {
                _cred = apikey;
            }
        }

        if ("" != apikey)
        {
            // A starting access token was supplied. Spend it: if it is
            // stale the API answers with an expiry status and the transport
            // wrapper buys another, which is the same path expiry takes
            // anyway.
            return true;
        }

        // `auth: null` is the documented way to send NO credential, and a
        // purchase is a credential-bearing call: the refresh token goes to
        // the token endpoint in the request body. WithRefresh honours
        // suppression for the RETRY, but it runs after this - by then the
        // refresh token has already left the process, and no later check
        // can call it back. The suppression has to be honoured here, before
        // the first purchase, or it only ever half-held.
        if (AuthSuppressed())
        {
            return false;
        }

        Buy();

        return true;
    }

    // ---------------------------------------------------------------
    // The transport seam.

    private object? Transport(Context ctx, string url,
        Dictionary<string, object?> fetchdef, FetcherFunc inner)
    {
        // Fail-closed, at the ONE seam every wire path crosses. Entity ops,
        // Direct, Graphql and the exchange retries all come through this
        // wrapper. Resolve() is shared and cached: concurrent callers join
        // the in-flight attempt, a cached success is free, and with `cache:
        // false` the chain is asked once per REQUEST, which is that
        // option's meaning. A provider ERROR refuses the request with the
        // PROVIDER'S OWN error - never an unauthenticated send.
        Resolve();

        // Inject the resolved credential into THIS request's header. The
        // header was built by PrepareAuth from the options apikey; the
        // chain-resolved value lives in feature state instead, so the
        // wrapper writes it here - same construction, same suppression
        // rules - and the shared options map stays untouched.
        var token = Credential();
        if ("" != token)
        {
            Reauth(fetchdef, token);
        }

        if (null == _exchange)
        {
            return inner(ctx, url, fetchdef);
        }

        return WithRefresh(ctx, url, fetchdef, inner);
    }

    // Buy a token and try the request again when the API says the current
    // one is spent.
    //
    // The retry rewrites the authorization header IN PLACE on the fetchdef,
    // because the header was built by the synchronous PrepareAuth before
    // this request left and carries the token that just failed. Rebuilt the
    // way PrepareAuth builds it, from the same options auth.prefix, so the
    // two cannot drift.
    private object? WithRefresh(Context ctx, string url,
        Dictionary<string, object?> fetchdef, FetcherFunc inner)
    {
        // `auth: null` is the documented way to send NO credential, and
        // PrepareAuth honours it by removing the header. A refusal of a
        // deliberately unauthenticated request is not an expired token and
        // cannot be fixed by buying one - retrying would transmit exactly
        // the credential the caller suppressed.
        if (AuthSuppressed())
        {
            return inner(ctx, url, fetchdef);
        }

        var max = _exchange!.Retries;
        var attempt = 0;

        while (true)
        {
            // The credential THIS attempt goes out with, captured before it
            // leaves: it is what tells a stale refusal apart from a fresh
            // one.
            var used = Credential();

            var res = inner(ctx, url, fetchdef);

            if (attempt >= max || !Spent(res))
            {
                return res;
            }

            // Another request may have bought a token while this one was in
            // flight. Concurrent expiries share the in-flight purchase, but
            // STAGGERED ones do not - so spend what is current before
            // buying: a second exchange for a token that is already fresh
            // is wasted, and on a provider that invalidates the previous
            // credential on issuance it breaks the first request's own
            // retry.
            var current = Credential();
            string token;

            if ("" != current && current != used)
            {
                token = current;
            }
            else
            {
                try
                {
                    token = Buy();
                }
                catch (Exception)
                {
                    // The purchase failed: answer with the API's own
                    // refusal rather than this one. The caller asked for
                    // data, and the refusal is the more useful of the two -
                    // the exchange error is a symptom.
                    return res;
                }
            }

            Reauth(fetchdef, token);

            attempt++;
        }
    }

    private bool Spent(object? res)
    {
        var (status, has) = FresStatus(res);
        if (!has)
        {
            return false;
        }
        foreach (var s in _exchange!.Statuses)
        {
            if (s == status)
            {
                return true;
            }
        }
        return false;
    }

    // `auth` ABSENT and `auth` PRESENT-AND-NULL both mean suppression.
    //
    // go gets away with one nil check because a Go map returns nil for
    // both; a C# Dictionary does not, and MakeOptions.cs deliberately
    // RESTORES a supplied `auth: null` after validate (that IS csharp's
    // auth-suppression fix). Testing only for absence would re-transmit
    // exactly the credential the caller suppressed. Same two-branch shape
    // PrepareAuth uses.
    private bool AuthSuppressed()
    {
        var opts = _liveopts;
        if (null == opts)
        {
            return true;
        }
        return !opts.TryGetValue("auth", out var auth) || null == auth;
    }

    private void Reauth(Dictionary<string, object?>? fetchdef, string token)
    {
        if (null == fetchdef ||
            !fetchdef.TryGetValue("headers", out var hraw) ||
            hraw is not Dictionary<string, object?> headers)
        {
            return;
        }

        // Suppressed auth means NO header, the same answer PrepareAuth
        // gives. Reached defensively - WithRefresh does not retry at all
        // when auth is suppressed - but this is the function that writes
        // the credential, so it is where the rule has to hold.
        if (AuthSuppressed())
        {
            headers.Remove("authorization");
            return;
        }

        var prefix = StructUtils.GetPath(_liveopts, StructUtils.Jt("auth", "prefix"))
            as string ?? "";

        headers["authorization"] = "" == prefix ? token : prefix + " " + token;
    }

    // ---------------------------------------------------------------
    // The access-token exchange.

    // Buy an access token with the refresh token. Concurrent callers share
    // the ONE in-flight purchase; the slot is cleared once settled, so the
    // next expiry buys a fresh token rather than replaying this result.
    private string Buy()
    {
        // TEST MODE BUYS NOTHING. The test feature replaces the transport
        // so no request leaves the process; an exchange here would be the
        // one HTTP call it could not stop, and it would need a live token
        // endpoint for a suite whose whole point is not needing one. A
        // deterministic, obviously-fake token instead - the same answer
        // MakeOptions gives a required server variable, for the same
        // reason.
        if ("live" != _client!.Mode)
        {
            var faketoken = "test-" + _exchange!.Response;
            lock (_mu)
            {
                _cred = faketoken;
            }
            return faketoken;
        }

        SecretsBuy buying;
        var owner = false;

        lock (_mu)
        {
            if (null != _buying)
            {
                buying = _buying;
            }
            else
            {
                buying = new SecretsBuy();
                _buying = buying;
                owner = true;
            }
        }

        if (!owner)
        {
            buying.Done.Wait();
            if (null != buying.Err)
            {
                throw buying.Err;
            }
            return buying.Token;
        }

        var token = "";
        Exception? err = null;
        try
        {
            token = BuyOnce();
        }
        catch (Exception ex)
        {
            err = ex;
        }

        lock (_mu)
        {
            buying.Token = token;
            buying.Err = err;
            _buying = null;
            if (null == err)
            {
                // Publish HERE, before the waiters wake: one writer, under
                // the lock - waiters consume the returned value.
                _cred = token;
            }
        }
        buying.Done.Set();

        if (null != err)
        {
            throw err;
        }
        return token;
    }

    private string BuyOnce()
    {
        var x = _exchange!;

        string refresh;
        lock (_mu)
        {
            refresh = _refresh;
        }

        if ("" == refresh)
        {
            throw new SekretoError(
                "secrets: no refresh token: the provider chain has no '" +
                _secretname + "', and feature.secrets.exchange.refresh is unset");
        }

        var options = _client!.OptionsMap();

        // The token endpoint is RELATIVE to the base, which already carries
        // whatever account or tenant segment the server URL declares.
        var basev = (StructUtils.GetProp(options, "base") as string ?? "").TrimEnd('/');
        var url = basev + "/" + x.Path.TrimStart('/');

        // The body is SERIALISED, never concatenated: a refresh token (or a
        // configured request-field name) carrying a quote, backslash or
        // newline must arrive as that literal value, not as malformed JSON.
        var body = JsonSerializer.Serialize(
            new Dictionary<string, string> { [x.Request] = refresh });

        var fetchdef = new Dictionary<string, object?>
        {
            ["method"] = x.Method,
            ["headers"] = new Dictionary<string, object?>
            {
                ["content-type"] = "application/json",
            },
            ["body"] = body,
        };

        // Deliberately NOT the SDK transport. The transport is what this
        // feature wraps, and sending the token request back through it
        // would recurse on the first expiry - and would route the exchange
        // through the test mock, which knows nothing about it.
        //
        // system.fetch when the caller supplied one, else SdkUtility's own
        // raw HttpClient fetch. The fallback matters: MakeOptions leaves
        // system.fetch unset in the ORDINARY case, and requiring a custom
        // transport there would reject every live token purchase before a
        // request was made. DefaultHttpFetch is `internal` in this
        // assembly, is not the SDK transport (no feature wrapping, no
        // mode/test block) and returns the same { status, json } shape the
        // system.fetch seam promises.
        var sysfetch = StructUtils.GetPath(options, StructUtils.Jt("system", "fetch"));

        object? res;
        if (sysfetch is Func<string, Dictionary<string, object?>, Dictionary<string, object?>> ff)
        {
            res = ff(url, fetchdef);
        }
        else if (sysfetch is Func<string, Dictionary<string, object?>, object?> ffa)
        {
            res = ffa(url, fetchdef);
        }
        else
        {
            res = SdkUtility.DefaultHttpFetch(url, fetchdef);
        }

        var status = Helpers.ToInt(StructUtils.GetProp(res, "status"));

        if (200 > status || 300 <= status)
        {
            throw new SekretoError(
                "secrets: token exchange failed: " + status + " from " + url);
        }

        object? payload;
        if (StructUtils.GetProp(res, "json") is Func<object?> jf)
        {
            payload = jf();
        }
        else
        {
            payload = StructUtils.GetProp(res, "body");
        }

        // Read BOTH closed generics. The SDK's own fetchers hand back the
        // loose model, but a caller-supplied system.fetch is free to build
        // its body with Dictionary<string, object> - and StructUtils.GetProp
        // matches only Dictionary<string, object?>, so it would answer
        // "no token" for a perfectly good response.
        object? raw = null;
        if (payload is Dictionary<string, object?> loosebody)
        {
            loosebody.TryGetValue(x.Response, out raw);
        }
        else if (payload is Dictionary<string, object> tightbody)
        {
            tightbody.TryGetValue(x.Response, out raw);
        }

        var token = raw as string ?? "";

        if ("" == token)
        {
            throw new SekretoError(
                "secrets: token exchange returned no '" + x.Response +
                "' field from " + url);
        }

        return token;
    }

    // ---------------------------------------------------------------
    // The type-model seam.

    // A provider spec arrives in the SDK's loose object model
    // (Dictionary<string, object?>), and sekreto reads its specs as
    // Dictionary<string, object> - `spec.GetValueOrDefault("values") as
    // Dictionary<string, object>` in Providers.Builtins, and the same cast
    // for every plugin's own nested config. A map of the wrong closed
    // generic type casts to NULL rather than failing loudly, so a chain
    // built from unconverted options would silently lose every nested
    // block: a `memory` store with no values, a `hashicorp` store with no
    // auth. Converted here, recursively, and a null VALUE inside a spec
    // survives (the annotation is compile-time; the Dictionary holds it).
    private static object? SpecValue(object? val)
    {
        if (val is Dictionary<string, object?> loose)
        {
            var map = new Dictionary<string, object>();
            foreach (var kv in loose)
            {
                // The `!` is the whole point of the comment above: the
                // VALUE may be null and must stay null. Nullable
                // annotations are compile-time only, and a
                // Dictionary<string, object> holds a null value at runtime
                // exactly as the loose map did - so a spec key given as
                // null reaches the provider as null rather than as a
                // missing key, which is a different thing.
                map[kv.Key] = SpecValue(kv.Value)!;
            }
            return map;
        }

        if (val is List<object?> list)
        {
            var items = new List<object>();
            foreach (var item in list)
            {
                items.Add(SpecValue(item)!);
            }
            return items;
        }

        // Scalars (and anything already closed over the non-nullable
        // generic) pass through untouched.
        return val;
    }
}

// Normalised exchange configuration; null on the feature when the exchange
// is off, so every later decision is a null check.
internal sealed class SecretsExchange
{
    public string Path = "auth/token";
    public string Method = "POST";
    public string Request = "refresh_token";
    public string Response = "access_token";
    public List<int> Statuses = new() { 401 };
    public int Retries = 1;
}

// One shared in-flight resolution: late arrivals wait on Done and read Err.
internal sealed class SecretsCall
{
    public readonly ManualResetEventSlim Done = new(false);
    public Exception? Err;
}

// One shared in-flight token purchase.
internal sealed class SecretsBuy
{
    public readonly ManualResetEventSlim Done = new(false);
    public string Token = "";
    public Exception? Err;
}
