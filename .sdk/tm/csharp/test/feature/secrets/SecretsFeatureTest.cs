// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
// the csharp port of tm/ts/test/feature/secrets/Secrets.test.ts and
// tm/go/test/feature/secrets/secrets_feature_test.go.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because SecretsFeature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic.
// With the feature inactive nothing changes at all. With it active and the
// option unset, the chain (env, dotenv, a custom provider, a vault)
// supplies the credential instead.
//
// This file lives in the test `feature/` container on purpose: `target add`
// trims it, along with the feature source and the vendored library, for a
// project whose model does not select `secrets`.
//
// WHAT MAKES THESE TESTS ABLE TO FAIL, which is the whole point of the
// file. Every fail-closed case is driven through a LIVE client with a
// recording `system.fetch`, so the thing being counted IS the transport.
// A previous tranche shipped fail-closed tests built on the offline test
// harness, whose mock transport REPLACES the fetcher - so the counter they
// asserted on was never reached, and "no request went out" was true for a
// healthy SDK carrying no secrets feature at all. Here:
//
//   * the assertion is on a recorder hung off `system.fetch`;
//   * the failure is matched on the PROVIDER'S OWN message, so an
//     unrelated failure (a blocked op, a missing route) cannot stand in
//     for fail-closed;
//   * and every fail-closed case carries a CONTROL leg - the same
//     construction with a WORKING provider, which must reach that same
//     transport exactly once, carrying the credential. Only then does a
//     zero mean REFUSED rather than UNWIRED.
//
// The feature is CONSTRUCTED DIRECTLY and handed in through the `extend`
// option when the generated config did not already install it, so these
// tests hold in any generated tree - whether or not the project's model
// activated the feature.

using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;

using Voxgig.Struct;
using Xunit;

using Voxgig.Sekreto;

using UnivecSdk;
using UnivecSdk.Feature;

namespace UnivecSdk.Test.Secrets;

// --- support ---------------------------------------------------------------

// A source of secrets built in code: sekreto's IProvider is two methods,
// and Sekreto's constructor takes a live instance directly.
internal class ProbeProvider : IProvider
{
    public Func<string, string?> Fn = _ => null;
    public List<string> Asked = new();

    public string Lookup(string name)
    {
        lock (Asked)
        {
            Asked.Add(name);
        }
        return Fn(name)!;
    }

    public string Describe() => "probe:test";
}

// One recorded request, as the transport saw it.
internal class WireCall
{
    public string Url = "";
    public string Auth = "";
    public bool HasAuth;
    public string Body = "";
}

// The recording transport: `system.fetch` for a LIVE client. It scripts one
// status per API call (the last repeating) and answers the exchange's token
// endpoint separately, so a case can say "401 then 200" without counting
// calls itself.
internal class Wire
{
    private readonly object _mu = new();

    public List<WireCall> Calls = new();
    public List<int> ApiStatus = new() { 200 };
    public List<string> Tokens = new() { "ACCESS01", "ACCESS02", "ACCESS03" };
    public string TokenPath = "auth/token";
    public string RespField = "access_token";

    private int _issued;
    private int _apicalls;

    public Dictionary<string, object?> Fetch(string url, Dictionary<string, object?> fetchdef)
    {
        lock (_mu)
        {
            var call = new WireCall { Url = url };

            if (fetchdef.TryGetValue("headers", out var hraw) &&
                hraw is Dictionary<string, object?> headers &&
                headers.TryGetValue("authorization", out var auth))
            {
                call.HasAuth = true;
                call.Auth = auth as string ?? "";
            }
            if (fetchdef.TryGetValue("body", out var braw) && braw is string body)
            {
                call.Body = body;
            }

            Calls.Add(call);

            if (url.EndsWith("/" + TokenPath))
            {
                var token = Tokens[Math.Min(_issued, Tokens.Count - 1)];
                _issued++;
                return Response(200, new Dictionary<string, object?> { [RespField] = token });
            }

            var status = ApiStatus[Math.Min(_apicalls, ApiStatus.Count - 1)];
            _apicalls++;
            return Response(status,
                new Dictionary<string, object?> { ["ok"] = status < 400 });
        }
    }

    private static Dictionary<string, object?> Response(int status, object? payload)
    {
        return new Dictionary<string, object?>
        {
            ["status"] = status,
            ["statusText"] = "X",
            ["headers"] = new Dictionary<string, object?>(),
            ["json"] = (Func<object?>)(() => payload),
        };
    }

    // The calls that did NOT go to the token endpoint.
    public List<WireCall> Api()
    {
        lock (_mu)
        {
            return Calls.FindAll(c => !c.Url.EndsWith("/" + TokenPath));
        }
    }

    public List<WireCall> Token()
    {
        lock (_mu)
        {
            return Calls.FindAll(c => c.Url.EndsWith("/" + TokenPath));
        }
    }

    // What went out, for a failure message that names the leak rather than
    // just its count.
    public string Report()
    {
        lock (_mu)
        {
            return string.Join(", ", Calls.ConvertAll(c => c.Url + " auth=" + c.Auth));
        }
    }
}

public class SecretsFeatureTest
{
    private const string EnvPrefix = "PROJECTENV_TEST_SECRETS_";
    private const string SecretsBase = "http://secrets.test/api";

    // The Authorization header carries the SPEC's credential prefix, which a
    // TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
    // `Bearer <token>`, an apiKey scheme the raw token. So assert on the
    // CREDENTIAL and let the prefix be whatever this SDK's API declares -
    // pinning the whole header value passes only for a prefix-less API, and
    // this file ships to every project that selects the feature.
    private static void CredentialIs(string header, string token)
    {
        var got = header ?? "";
        Assert.True(got == token || got.EndsWith(" " + token),
            "expected the authorization header to carry " + token + ", got: " + got);
    }

    // Construct the client and ADOPT the feature via `extend` ONLY when the
    // generated config did not already install it. When this SDK was
    // generated with `secrets` model-active the ordinary factory path builds
    // the instance, and adding a second via extend would DOUBLE the feature:
    // two transport wraps, two resolutions, and a token purchase the
    // assertions cannot account for.
    private static UnivecSDK WithSecrets(Func<bool, UnivecSDK> build)
    {
        var client = build(false);
        if (null == SecretsOf(client))
        {
            client = build(true);
        }
        return client;
    }

    private static SecretsFeature? SecretsOf(UnivecSDK client)
    {
        foreach (var f in client.Features)
        {
            if (f is SecretsFeature sf)
            {
                return sf;
            }
        }
        return null;
    }

    // A LIVE client carrying the secrets feature, wired to the recording
    // transport. `allow.op` is named explicitly: a project that narrows the
    // default set would otherwise turn the raw-path cases into a false RED
    // (the control leg refused before it reached the transport), and the
    // rule under test lives at the transport, downstream of the allow gate
    // either way.
    private static UnivecSDK SecretsClient(Wire w, Dictionary<string, object?> extra)
    {
        return WithSecrets(extend =>
        {
            var opts = new Dictionary<string, object?>
            {
                ["base"] = SecretsBase,
                ["allow"] = new Dictionary<string, object?>
                {
                    ["op"] = "create,update,load,list,remove,command,direct,graphql",
                },
                ["system"] = new Dictionary<string, object?>
                {
                    ["fetch"] = (Func<string, Dictionary<string, object?>,
                        Dictionary<string, object?>>)w.Fetch,
                },
            };
            foreach (var kv in extra)
            {
                opts[kv.Key] = kv.Value;
            }
            if (extend)
            {
                opts["extend"] = new List<object?> { new SecretsFeature() };
            }
            return new UnivecSDK(opts);
        });
    }

    // The env chain, the shape most of these tests use.
    private static Dictionary<string, object?> SecretsOpts(Dictionary<string, object?>? extra)
    {
        var fopts = new Dictionary<string, object?>
        {
            ["active"] = true,
            ["providers"] = new List<object?>
            {
                new Dictionary<string, object?>
                {
                    ["kind"] = "env",
                    ["prefix"] = EnvPrefix,
                },
            },
        };
        foreach (var kv in extra ?? new Dictionary<string, object?>())
        {
            fopts[kv.Key] = kv.Value;
        }
        return new Dictionary<string, object?> { ["secrets"] = fopts };
    }

    private static Dictionary<string, object?> ProviderOpts(object provider,
        Dictionary<string, object?>? extra)
    {
        var fopts = new Dictionary<string, object?>
        {
            ["active"] = true,
            ["providers"] = new List<object?> { provider },
        };
        foreach (var kv in extra ?? new Dictionary<string, object?>())
        {
            fopts[kv.Key] = kv.Value;
        }
        return new Dictionary<string, object?> { ["secrets"] = fopts };
    }

    // Perform real entity operations - which is what runs the PreSpec hook
    // and the ordinary request pipeline - until `stop` reports the
    // observable state a test is waiting for. Each op's own outcome is
    // irrelevant (no seeded data, a scripted response); an op the API does
    // not define fails BEFORE the transport, which is why several may need
    // driving. Entity names come from the SDK's own config, because this
    // file is a TEMPLATE and no project's entity names are known here.
    private static void DriveEntityOpUntil(UnivecSDK client, string what, Func<bool> stop)
    {
        var entities = StructUtils.GetProp(client.OptionsMap(), "entity")
            as Dictionary<string, object?> ?? new Dictionary<string, object?>();

        foreach (var name in entities.Keys)
        {
            if ("" == name)
            {
                continue;
            }

            var accessor = client.GetType().GetMethod(
                char.ToUpperInvariant(name[0]) + name.Substring(1),
                new[] { typeof(Dictionary<string, object?>) });

            if (null == accessor)
            {
                continue;
            }

            object? ent;
            try
            {
                ent = accessor.Invoke(client, new object?[] { null });
            }
            catch (TargetInvocationException)
            {
                continue;
            }

            if (null == ent)
            {
                continue;
            }

            foreach (var opname in new[] { "List", "Load" })
            {
                var op = ent.GetType().GetMethod(opname,
                    new[]
                    {
                        typeof(Dictionary<string, object?>),
                        typeof(Dictionary<string, object?>),
                    });

                if (null == op)
                {
                    continue;
                }

                try
                {
                    op.Invoke(ent, new object?[] { null, null });
                }
                catch (Exception ex)
                {
                    // The operation's own outcome is not what is under test,
                    // but the fail-closed cases assert on the PROVIDER'S OWN
                    // message, so the last failure is kept. Reflection wraps
                    // the SDK's throw in a TargetInvocationException; the
                    // SDK error is the inner one.
                    _lasterr = (ex as TargetInvocationException)?.InnerException ?? ex;
                }

                if (stop())
                {
                    return;
                }
            }
        }

        Assert.Fail("no entity operation " + what + " - nothing to assert on");
    }

    // The last error an entity op raised, for the fail-closed cases that
    // assert on the PROVIDER'S OWN message. Per thread: xunit runs test
    // classes in parallel.
    [ThreadStatic]
    private static Exception? _lasterr;

    // Drive ops until one request reached the recorder.
    private static void DriveEntityOp(UnivecSDK client, Wire w)
    {
        var before = w.Api().Count;
        DriveEntityOpUntil(client, "reached the transport", () => before < w.Api().Count);
    }


    // --- the feature-inactive baseline: bit-identical behaviour ------------

    [Fact]
    public void InactiveApikeyOptionBehavesExactlyAsBefore()
    {
        var client = UnivecSDK.TestSDK(null,
            new Dictionary<string, object?> { ["apikey"] = "OPTKEY01" });

        var fetchdef = client.Prepare(new Dictionary<string, object?> { ["path"] = "/" });
        var headers = fetchdef["headers"] as Dictionary<string, object?>;

        CredentialIs(headers!["authorization"] as string ?? "", "OPTKEY01");

        Assert.True(null == SecretsOf(client),
            "no model activation and no extend: the feature must not be installed");
    }

    [Fact]
    public void InactiveNoApikeyMeansNoAuthorizationHeader()
    {
        var client = UnivecSDK.TestSDK(null, null);

        var fetchdef = client.Prepare(new Dictionary<string, object?> { ["path"] = "/" });
        var headers = fetchdef["headers"] as Dictionary<string, object?>;

        Assert.False(headers!.ContainsKey("authorization"),
            "an SDK with no apikey must send no authorization header");
    }


    // --- active: the provider chain, on the wire ---------------------------

    [Fact]
    public void ApikeyOptionStillWinsOverTheChain()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", "ENVKEY01");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["apikey"] = "OPTKEY01",
                ["feature"] = SecretsOpts(null),
            });

            DriveEntityOp(client, w);
            CredentialIs(w.Api()[0].Auth, "OPTKEY01");

            // The explicit option is a real store, not a special case: a
            // directed read names it like any other.
            var sf = SecretsOf(client);
            Assert.True(null != sf, "the extend seam did not install the feature");
            Assert.Equal("OPTKEY01", sf!.GetSekreto()!.GetFrom("options", "apikey"));
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", null);
        }
    }

    [Fact]
    public void AnOmittedApikeyDefersToTheChainAtTheTransportSeam()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", "ENVKEY02");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = SecretsOpts(null),
            });

            // Before any op, nothing has been resolved.
            Assert.Equal("", SecretsOf(client)!.Credential());

            DriveEntityOp(client, w);

            // Resolution happens AT THE TRANSPORT - the one seam every wire
            // path crosses - so the credential is ON THE WIRE, not merely
            // resolved.
            CredentialIs(w.Api()[0].Auth, "ENVKEY02");
            Assert.Equal("ENVKEY02", SecretsOf(client)!.Credential());

            // csharp holds the credential in FEATURE STATE and injects it at
            // the transport; the shared options map is never written, which
            // is what keeps every concurrent operation's raw read safe.
            Assert.Equal("", StructUtils.GetProp(client.OptionsMap(), "apikey") as string ?? "");
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", null);
        }
    }

    [Fact]
    public void CustomProviderObjectsAreAcceptedVerbatim()
    {
        var probe = new ProbeProvider { Fn = _ => "CUSTOM01" };

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(probe, null),
        });

        DriveEntityOp(client, w);

        CredentialIs(w.Api()[0].Auth, "CUSTOM01");
        Assert.Equal("apikey", probe.Asked[0]);
    }

    [Fact]
    public void AMissEverywhereLeavesTheHeaderOff()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", null);

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = SecretsOpts(null),
        });

        DriveEntityOp(client, w);

        Assert.False(w.Api()[0].HasAuth,
            "a chain MISS must fall through to an unauthenticated request, got header " +
            w.Api()[0].Auth);
    }

    // sekreto's miss-vs-error invariant: a MISS falls through to the next
    // provider, an ERROR does not. A broken vault must never degrade into an
    // unauthenticated request.
    [Fact]
    public void AProviderErrorFailsTheEntityOpAndNothingReachesTheWire()
    {
        var broken = new ProbeProvider
        {
            Fn = _ => throw new SekretoError("vault unreachable"),
        };

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(broken, null),
        });

        DriveEntityOpUntil(client, "consulted the chain", () => 0 < broken.Asked.Count);

        Assert.True(0 == w.Api().Count,
            "a broken vault must never yield a request, but the transport saw: " +
            w.Report());

        // CONTROL, which makes that zero mean REFUSED rather than UNWIRED:
        // the same construction with a WORKING provider must reach the same
        // transport, once, carrying the credential.
        var control = new Wire();
        var ok = SecretsClient(control, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(
                new ProbeProvider { Fn = _ => "CONTROL01" }, null),
        });

        DriveEntityOp(ok, control);

        Assert.True(1 == control.Api().Count,
            "the control request did not reach system.fetch exactly once, so this " +
            "test cannot observe a request going out at all: " + control.Report());
        CredentialIs(control.Api()[0].Auth, "CONTROL01");
    }

    // A settled failure must not latch. Holding one meant a transient vault
    // outage poisoned the client permanently: every later operation kept
    // failing long after the vault recovered.
    [Fact]
    public void AProviderRecoversAfterATransientFailure()
    {
        var calls = 0;
        var flaky = new ProbeProvider
        {
            Fn = _ =>
            {
                calls++;
                if (1 == calls)
                {
                    throw new SekretoError("vault unreachable");
                }
                return "RECOVERED01";
            },
        };

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(flaky, null),
        });

        DriveEntityOpUntil(client, "consulted the chain", () => 0 < calls);
        Assert.True(0 == w.Api().Count, "the first op must not reach the wire");

        DriveEntityOp(client, w);
        CredentialIs(w.Api()[0].Auth, "RECOVERED01");
    }

    // `auth: null` is the documented way to disable auth outright, and
    // PrepareAuth honours it before it ever reads the apikey. csharp needs a
    // TWO-BRANCH check (key absent OR key present-and-null), because
    // MakeOptions deliberately keeps a supplied null PRESENT - unlike go,
    // where one nil test covers both. Getting this wrong re-transmits
    // exactly the credential the caller suppressed.
    [Fact]
    public void AuthNullSuppressesTheCredentialChainOrNoChain()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", "ENVKEY03");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["auth"] = null,
                ["apikey"] = "OPTKEY01",
                ["feature"] = SecretsOpts(null),
            });

            DriveEntityOp(client, w);

            Assert.False(w.Api()[0].HasAuth,
                "auth null must suppress the credential, got header " + w.Api()[0].Auth);

            // The suppression survives option validation rather than being
            // replaced by the optspec's default auth map.
            var opts = client.OptionsMap();
            Assert.True(opts.TryGetValue("auth", out var authval) && null == authval,
                "options.auth must stay a PRESENT null");
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", null);
        }
    }

    // With `cache: false`, a provider that answered once and then reports a
    // MISS (a revoked secret) must RETRACT the credential: the next request
    // must go out with no authorization header.
    [Fact]
    public void UncachedMissRetractsTheCredential()
    {
        var have = true;
        var revocable = new ProbeProvider { Fn = _ => have ? "REVOCABLE01" : null };

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(revocable,
                new Dictionary<string, object?> { ["cache"] = false }),
        });

        DriveEntityOp(client, w);
        CredentialIs(w.Api()[0].Auth, "REVOCABLE01");

        have = false;

        DriveEntityOp(client, w);
        var last = w.Api()[w.Api().Count - 1];
        Assert.True(!last.HasAuth || "" == last.Auth,
            "after the chain reports a miss, the retracted credential must not go " +
            "out; the wire saw " + last.Auth);
    }

    // A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
    // feature used to override from the layer above.
    //
    // DEFAULT caching here, which is the whole point: `cache: true` is
    // about holding a HIT, and keeping the settled resolution after a miss
    // meant the chain was never asked again for the life of the client. A
    // secret provisioned after startup (a mounted file, a vault policy
    // granted a minute late) was invisible forever, and the only workaround
    // was giving up hit caching entirely.
    [Fact]
    public void CachedMissIsReasked()
    {
        var present = false;
        var calls = 0;
        var late = new ProbeProvider
        {
            Fn = _ =>
            {
                calls++;
                return present ? "LATEKEY01" : null;
            },
        };

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(late, null),
        });

        DriveEntityOp(client, w);
        var first = w.Api()[0];
        Assert.True(!first.HasAuth || "" == first.Auth,
            "the chain has nothing yet, so no credential should go out");

        var asked = calls;
        Assert.True(0 < asked);

        // The secret is provisioned while the client is live.
        present = true;

        DriveEntityOp(client, w);
        CredentialIs(w.Api()[w.Api().Count - 1].Auth, "LATEKEY01");

        Assert.True(asked < calls,
            "the MISS was cached: a secret that appears later can never be picked up");
    }

    // The other half of the same rule: a HIT is still cached by default, so
    // the fix above must not turn every request into a chain walk.
    [Fact]
    public void CachedHitIsKept()
    {
        var calls = 0;
        var counting = new ProbeProvider
        {
            Fn = _ =>
            {
                calls++;
                return "STABLEKEY01";
            },
        };

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(counting, null),
        });

        DriveEntityOp(client, w);
        DriveEntityOp(client, w);

        Assert.True(1 == calls,
            "a hit must be cached under the default cache: true, chain asked " +
            calls + " times");
    }

    [Fact]
    public void CacheFalseAsksTheChainOnEveryResolve()
    {
        var calls = 0;
        var counting = new ProbeProvider
        {
            Fn = _ =>
            {
                calls++;
                return "KEY" + calls;
            },
        };

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(counting,
                new Dictionary<string, object?> { ["cache"] = false }),
        });

        DriveEntityOp(client, w);
        DriveEntityOp(client, w);

        Assert.True(1 < calls,
            "the chain was asked once and cached, despite cache: false");
    }

    [Fact]
    public void SecretNameIsConfigurable()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "API_TOKEN", "TOKKEY01");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = SecretsOpts(
                    new Dictionary<string, object?> { ["name"] = "api.token" }),
            });

            DriveEntityOp(client, w);
            CredentialIs(w.Api()[0].Auth, "TOKKEY01");
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "API_TOKEN", null);
        }
    }

    // The Sekreto instance is LIVE, for callers who want arbitrary secrets
    // or redaction. Never a clone: sekreto holds provider state that has to
    // stay live to be worth anything.
    [Fact]
    public void SekretoIsLiveForArbitrarySecretsAndRedaction()
    {
        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = new Dictionary<string, object?>
            {
                ["secrets"] = new Dictionary<string, object?>
                {
                    ["active"] = true,
                    ["providers"] = new List<object?>
                    {
                        new Dictionary<string, object?>
                        {
                            ["kind"] = "memory",
                            ["values"] = new Dictionary<string, object?>
                            {
                                ["DB_PASSWORD"] = "dbpass01",
                            },
                        },
                    },
                },
            },
        });

        var secrets = SecretsOf(client)!.GetSekreto()!;

        // The nested `values` map arrives in the SDK's loose object model
        // and sekreto reads it as Dictionary<string, object>: a converter
        // that dropped the nested block would leave the store EMPTY and this
        // read would miss.
        Assert.Equal("dbpass01", secrets.Get("db.password"));
        Assert.Equal("the password is [redacted], keep it safe",
            secrets.Redact("the password is dbpass01, keep it safe"));
    }

    // THE PROVIDER VOCABULARY IS NON-EMPTY, and it matches what the SDK
    // actually carries.
    //
    // A provider kind the model did NOT select is unknown to this Sekreto -
    // upstream's contract since the registry was retired, and the reason
    // Config emits the plugin definitions at all. The failure this exists to
    // catch is the SILENT one: a Config that emits an EMPTY vocabulary while
    // the SDK still ships every plugin file its model selected. Every
    // builtin-only test above stays green through that, and the SDK then
    // refuses each of those kinds at runtime as "unknown provider kind".
    //
    // So the expected set is read off the ASSEMBLY, not off the config: the
    // vendored plugin classes compile into this SDK exactly when the model
    // selected their group, so what they export is an independent witness of
    // what the model asked for. Conditioning on the config instead would let
    // an empty vocabulary make this test pass by returning early - which is
    // the whole defect.
    [Fact]
    public void ASelectedPluginKindIsInTheSdkVocabulary()
    {
        // Every Definition the generated tree carries, discovered rather
        // than listed: this file ships to projects with any subset of the
        // plugin groups, and upstream is free to add a kind.
        var carried = new List<string>();
        foreach (var t in typeof(SecretsFeature).Assembly.GetTypes())
        {
            if ("Voxgig.Sekreto.Plugins" != t.Namespace)
            {
                continue;
            }
            foreach (var f in t.GetFields(BindingFlags.Public | BindingFlags.Static))
            {
                if (typeof(Voxgig.Plugin.Definition) == f.FieldType)
                {
                    carried.Add(t.Name + "." + f.Name);
                }
            }
        }

        if (0 == carried.Count)
        {
            // No plugin groups in this project's model: nothing to assert.
            return;
        }

        var vocabulary = SdkConfig.FeaturePlugins("secrets");

        var kinds = new List<string>();
        foreach (var d in vocabulary)
        {
            if (d is Voxgig.Plugin.Definition def)
            {
                kinds.Add(def.Name);
            }
        }

        Assert.True(carried.Count == kinds.Count,
            "the SDK carries " + carried.Count + " plugin definitions (" +
            string.Join(", ", carried) + ") but the config's vocabulary holds " +
            kinds.Count + " (" + string.Join(", ", kinds) + ") - every kind the " +
            "model selected must be passed to Sekreto, or the SDK refuses it at " +
            "runtime as an unknown provider kind");

        // Construction is where an unknown kind is refused, so the Sekreto
        // being built at all IS the second half of the check. The memory
        // store comes FIRST so sekreto's first-hit rule answers from it and
        // the vault is never contacted - the kind has to be DECLARABLE, not
        // reachable.

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = new Dictionary<string, object?>
            {
                ["secrets"] = new Dictionary<string, object?>
                {
                    ["active"] = true,
                    ["providers"] = new List<object?>
                    {
                        new Dictionary<string, object?>
                        {
                            ["kind"] = "memory",
                            ["values"] = new Dictionary<string, object?>
                            {
                                ["APIKEY"] = "VOCAB01",
                            },
                        },
                        new Dictionary<string, object?>
                        {
                            ["kind"] = kinds[0],
                            ["addr"] = "https://vault.test",
                            ["token"] = "x",
                            ["command"] = "true",
                            ["project"] = "p",
                            ["region"] = "eu-west-1",
                            ["vault"] = "v",
                            ["account"] = "a",
                        },
                    },
                },
            },
        });

        DriveEntityOp(client, w);
        CredentialIs(w.Api()[0].Auth, "VOCAB01");
    }


    // --- THE RAW PATHS ----------------------------------------------------
    //
    // Direct and Graphql run NO feature hooks at all - the client fragment
    // says so itself ("like Direct, this bypasses the feature pipeline") -
    // so for them the transport seam is the ONLY place resolution can
    // happen. These are the cases that would pass vacuously against a
    // PreSpec-only implementation, and the ones that pin the seam choice.

    [Fact]
    public void DirectCarriesTheChainCredential()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", "DIRECTKEY01");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = SecretsOpts(null),
            });

            var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/probe" });

            Assert.True(Equals(res["ok"], true), "direct refused: " + res.GetValueOrDefault("err"));
            Assert.True(1 == w.Api().Count,
                "expected one direct call on the wire, got " + w.Api().Count);
            CredentialIs(w.Api()[0].Auth, "DIRECTKEY01");
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "APIKEY", null);
        }
    }

    [Fact]
    public void AProviderErrorFailsDirectRatherThanSending()
    {
        var w = new Wire();
        var broken = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(
                new ProbeProvider { Fn = _ => throw new SekretoError("vault unreachable") },
                null),
        });

        var res = broken.Direct(new Dictionary<string, object?> { ["path"] = "/probe" });

        Assert.True(0 == w.Calls.Count,
            "a request must not go out unauthenticated because a provider broke, " +
            "but one reached the transport: " + w.Report());
        Assert.True(Equals(res["ok"], false), "a broken chain must refuse the raw path");

        // The PROVIDER'S OWN message, so an unrelated failure cannot stand
        // in for fail-closed.
        var err = res.GetValueOrDefault("err") as Exception;
        Assert.True(null != err, "expected the provider error in-band, got: " +
            res.GetValueOrDefault("err"));
        Assert.Contains("vault unreachable", err!.Message);

        // CONTROL: the same construction with a WORKING provider must reach
        // the same transport exactly once, carrying the credential.
        var control = new Wire();
        var ok = SecretsClient(control, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(new ProbeProvider { Fn = _ => "RAWKEY01" }, null),
        });

        var good = ok.Direct(new Dictionary<string, object?> { ["path"] = "/probe" });

        Assert.True(Equals(good["ok"], true),
            "the control request failed: " + good.GetValueOrDefault("err"));
        Assert.True(1 == control.Calls.Count,
            "the control request never reached system.fetch, so this test cannot " +
            "observe a request going out at all");
        CredentialIs(control.Calls[0].Auth, "RAWKEY01");
    }

    [Fact]
    public void AProviderErrorFailsGraphqlRatherThanSending()
    {
        var w = new Wire();
        var broken = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(
                new ProbeProvider { Fn = _ => throw new SekretoError("vault unreachable") },
                null),
        });

        var res = broken.Graphql("{ thing }", null);

        Assert.True(0 == w.Calls.Count,
            "a graphql request must not go out unauthenticated, but one reached " +
            "the transport: " + w.Report());
        Assert.True(Equals(res["ok"], false), "a broken chain must refuse graphql");

        var err = res.GetValueOrDefault("err") as Exception;
        Assert.True(null != err, "expected the provider error in-band, got: " +
            res.GetValueOrDefault("err"));
        Assert.Contains("vault unreachable", err!.Message);

        var control = new Wire();
        var ok = SecretsClient(control, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(new ProbeProvider { Fn = _ => "RAWKEY01" }, null),
        });

        var good = ok.Graphql("{ thing }", null);

        Assert.True(Equals(good["ok"], true),
            "the control request failed: " + good.GetValueOrDefault("err"));
        Assert.True(1 == control.Calls.Count,
            "the control graphql request never reached system.fetch, so this test " +
            "cannot observe a request going out at all");
        CredentialIs(control.Calls[0].Auth, "RAWKEY01");
    }


    // --- FAIL CLOSED ON A CONSTRUCTION FAILURE ----------------------------
    //
    // The chain a project configures can be wrong before a single lookup
    // happens: a provider kind that does not exist (or one whose plugin
    // group the model did not select), and sekreto's constructor refuses
    // it; or a secret name Names.EnvKey rejects. Init is void and cannot
    // fail the client construction the way ts's throwing init does, so it
    // HOLDS that error in `_initerr` and the transport gate refuses to send.
    //
    // That gate is worth exactly as much as the seam it lives behind, which
    // is why Init wraps FIRST and builds SECOND: an Init that returns early
    // on the construction failure before installing the wrapper leaves no
    // gate at all, and a misconfigured chain then sends ordinary
    // UNAUTHENTICATED requests - or, with an explicit apikey and a bad
    // secret name, the credential itself - while the held error is read by
    // nothing. Every other case in this file passes with the gate deleted
    // and with the wrap moved last; these four are the ones that go RED.
    // The three wire paths - the entity pipeline, Direct and Graphql - each
    // carry their own CONTROL leg, so a zero means REFUSED and not UNWIRED.

    // A provider kind sekreto has never heard of: its constructor throws
    // before this feature has a Sekreto at all. Matched on sekreto's OWN
    // message, so an unrelated failure cannot stand in for fail-closed.
    private const string UnknownKind = "unknown provider kind: nosuchkind";

    private static Dictionary<string, object?> MisconfiguredChain()
    {
        return ProviderOpts(new Dictionary<string, object?>
        {
            ["kind"] = "nosuchkind",
            ["name"] = "broken",
        }, null);
    }

    private static bool SaysUnknownKind(object? err)
    {
        var msg = err is Exception ex ? ex.Message : (err?.ToString() ?? "");
        return msg.Contains(UnknownKind);
    }

    private static string ErrMessage(Dictionary<string, object?> res)
    {
        var err = res.GetValueOrDefault("err");
        return err is Exception ex ? ex.Message : (err?.ToString() ?? "");
    }

    [Fact]
    public void AConstructionFailureFailsTheEntityOpAndNothingReachesTheWire()
    {
        // THE RULE.
        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = MisconfiguredChain(),
        });

        // The feature must still be INSTALLED: a construction failure that
        // silently uninstalls the feature is the same fail-open by another
        // route, and nothing downstream would be gating anything.
        Assert.True(null != SecretsOf(client),
            "a chain that failed to build must leave the feature installed and gating");

        _lasterr = null;
        // Stop on EITHER outcome - the refusal we want, or a request going
        // out, which is the failure this test exists to catch. Stopping only
        // on the refusal would report "nothing to assert on" for the leak.
        DriveEntityOpUntil(client, "refused the operation or sent one",
            () => 0 < w.Api().Count || SaysUnknownKind(_lasterr));

        Assert.True(0 == w.Api().Count,
            "a chain that failed to BUILD sent an UNAUTHENTICATED request: " + w.Report());

        Assert.True(null != _lasterr, "the entity op must fail when the chain cannot be built");
        Assert.True(SaysUnknownKind(_lasterr),
            "the refusal must carry sekreto's own message (" + UnknownKind + "), got: " +
            _lasterr!.Message);

        // CONTROL, which makes that zero mean REFUSED rather than UNWIRED:
        // the same construction with a WORKING provider must reach the same
        // transport, once, carrying the credential.
        var control = new Wire();
        var ok = SecretsClient(control, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(new ProbeProvider { Fn = _ => "INITKEY01" }, null),
        });

        DriveEntityOp(ok, control);

        Assert.True(1 == control.Api().Count,
            "the control request did not reach system.fetch exactly once, so this " +
            "test cannot observe a request going out at all: " + control.Report());
        CredentialIs(control.Api()[0].Auth, "INITKEY01");
    }

    [Fact]
    public void AConstructionFailureFailsDirectRatherThanSending()
    {
        // THE RULE. Direct runs no feature hook at all, so the ONLY thing
        // that can refuse it is the transport wrapper - the one a
        // build-first Init never installs on a construction failure.
        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = MisconfiguredChain(),
        });

        var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/probe" });

        Assert.True(0 == w.Calls.Count,
            "a chain that failed to BUILD sent an UNAUTHENTICATED direct request: " +
            w.Report());
        Assert.True(Equals(res["ok"], false),
            "a chain that could not be built must refuse the raw path fail-closed");
        Assert.True(SaysUnknownKind(res.GetValueOrDefault("err")),
            "the refusal must carry sekreto's own message (" + UnknownKind + "), got: " +
            ErrMessage(res));

        // CONTROL.
        var control = new Wire();
        var ok = SecretsClient(control, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(new ProbeProvider { Fn = _ => "INITKEY01" }, null),
        });

        var good = ok.Direct(new Dictionary<string, object?> { ["path"] = "/probe" });

        Assert.True(Equals(good["ok"], true),
            "the control request failed: " + good.GetValueOrDefault("err"));
        Assert.True(1 == control.Calls.Count,
            "the control request never reached system.fetch, so this test cannot " +
            "observe a request going out at all");
        CredentialIs(control.Calls[0].Auth, "INITKEY01");
    }

    [Fact]
    public void AConstructionFailureFailsGraphqlRatherThanSending()
    {
        // THE RULE.
        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = MisconfiguredChain(),
        });

        var res = client.Graphql("{ thing }", null);

        Assert.True(0 == w.Calls.Count,
            "a chain that failed to BUILD sent an UNAUTHENTICATED graphql request: " +
            w.Report());
        Assert.True(Equals(res["ok"], false),
            "a chain that could not be built must refuse graphql fail-closed");
        Assert.True(SaysUnknownKind(res.GetValueOrDefault("err")),
            "the refusal must carry sekreto's own message (" + UnknownKind + "), got: " +
            ErrMessage(res));

        // CONTROL.
        var control = new Wire();
        var ok = SecretsClient(control, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(new ProbeProvider { Fn = _ => "INITKEY01" }, null),
        });

        var good = ok.Graphql("{ thing }", null);

        Assert.True(Equals(good["ok"], true),
            "the control request failed: " + good.GetValueOrDefault("err"));
        Assert.True(1 == control.Calls.Count,
            "the control graphql request never reached system.fetch, so this test " +
            "cannot observe a request going out at all");
        CredentialIs(control.Calls[0].Auth, "INITKEY01");
    }

    // The OTHER construction failure, and the one that tells wrap-first
    // from wrap-last: an explicit apikey with a secret name Names.EnvKey
    // refuses. Init holds that error and returns before it ever builds a
    // Sekreto, so an Init that wraps at the END has installed nothing -
    // and the credential goes out on the wire through the ordinary
    // PrepareAuth path, EXPLICIT and unresolved, exactly as if the feature
    // had never been configured. The unknown-kind cases above cannot see
    // this: their failure lands in a catch that falls through to the wrap.
    private const string InvalidName = "sekreto: invalid name: Not Valid!";

    [Fact]
    public void AnInvalidSecretNameFailsDirectRatherThanSending()
    {
        // THE RULE.
        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["apikey"] = "EXPLICIT01",
            ["feature"] = new Dictionary<string, object?>
            {
                ["secrets"] = new Dictionary<string, object?>
                {
                    ["active"] = true,
                    ["name"] = "Not Valid!",
                },
            },
        });

        Assert.True(null != SecretsOf(client),
            "an invalid secret name must leave the feature installed and gating");

        var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/probe" });

        Assert.True(0 == w.Calls.Count,
            "an invalid secret name still let a request out, carrying the explicit " +
            "credential: " + w.Report());
        Assert.True(Equals(res["ok"], false),
            "an invalid secret name must refuse the raw path fail-closed");
        Assert.Contains(InvalidName, ErrMessage(res));

        // CONTROL: the same construction with a VALID name must reach the
        // transport once, carrying that same explicit credential.
        var control = new Wire();
        var ok = SecretsClient(control, new Dictionary<string, object?>
        {
            ["apikey"] = "EXPLICIT01",
            ["feature"] = new Dictionary<string, object?>
            {
                ["secrets"] = new Dictionary<string, object?>
                {
                    ["active"] = true,
                    ["name"] = "apikey",
                },
            },
        });

        var good = ok.Direct(new Dictionary<string, object?> { ["path"] = "/probe" });

        Assert.True(Equals(good["ok"], true),
            "the control request failed: " + good.GetValueOrDefault("err"));
        Assert.True(1 == control.Calls.Count,
            "the control request never reached system.fetch, so this test cannot " +
            "observe a request going out at all");
        CredentialIs(control.Calls[0].Auth, "EXPLICIT01");
    }


    // --- the access-token exchange ----------------------------------------

    private static Dictionary<string, object?> ExchangeOpts(Dictionary<string, object?>? xextra)
    {
        var x = new Dictionary<string, object?> { ["active"] = true };
        foreach (var kv in xextra ?? new Dictionary<string, object?>())
        {
            x[kv.Key] = kv.Value;
        }
        return SecretsOpts(new Dictionary<string, object?>
        {
            ["name"] = "refresh_token",
            ["exchange"] = x,
        });
    }

    [Fact]
    public void TheRefreshTokenBuysAnAccessTokenAndASpentOneIsReboughtOnce()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "REFRESH01");
        try
        {
            // First API call is refused, the retry succeeds.
            var w = new Wire { ApiStatus = new List<int> { 401, 200 } };
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = ExchangeOpts(null),
            });

            var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/thing" });

            Assert.True(2 == w.Token().Count,
                "expected the initial purchase plus one rebuy, got " + w.Token().Count);
            Assert.Contains("REFRESH01", w.Token()[0].Body);

            Assert.True(2 == w.Api().Count,
                "expected the request to be retried exactly once, got " + w.Api().Count);
            CredentialIs(w.Api()[0].Auth, "ACCESS01");
            // The retry must carry the NEW token, not the spent one.
            CredentialIs(w.Api()[1].Auth, "ACCESS02");

            Assert.True(Equals(res["ok"], true), "the caller sees the successful retry");
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    [Fact]
    public void AnExplicitExchangeRefreshWinsOverTheChain()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "FROMCHAIN");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = ExchangeOpts(
                    new Dictionary<string, object?> { ["refresh"] = "EXPLICIT01" }),
            });

            client.Direct(new Dictionary<string, object?> { ["path"] = "/thing" });

            Assert.Contains("EXPLICIT01", w.Token()[0].Body);
            Assert.DoesNotContain("FROMCHAIN", w.Token()[0].Body);
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    [Fact]
    public void OnePurchaseServesManyRequests()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "REFRESH01");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = ExchangeOpts(null),
            });

            client.Direct(new Dictionary<string, object?> { ["path"] = "/one" });
            client.Direct(new Dictionary<string, object?> { ["path"] = "/two" });
            client.Direct(new Dictionary<string, object?> { ["path"] = "/three" });

            Assert.True(1 == w.Token().Count,
                "a token still working must not be re-bought, saw " + w.Token().Count);
            Assert.True(3 == w.Api().Count);
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    [Fact]
    public void ConcurrentFirstRequestsShareOnePurchase()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "REFRESH01");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = ExchangeOpts(null),
            });

            Parallel.For(0, 4, i =>
                client.Direct(new Dictionary<string, object?> { ["path"] = "/p" + i }));

            Assert.True(1 == w.Token().Count,
                "four operations at once must not open four token requests, saw " +
                w.Token().Count);
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    [Fact]
    public void AStatusOutsideExchangeStatusesIsNotAnExpiry()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "REFRESH01");
        try
        {
            var w = new Wire { ApiStatus = new List<int> { 403 } };
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = ExchangeOpts(null),
            });

            client.Direct(new Dictionary<string, object?> { ["path"] = "/thing" });

            Assert.True(1 == w.Api().Count, "403 is not in the default statuses");
            Assert.True(1 == w.Token().Count);
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    [Fact]
    public void ExchangeStatusesAndFieldNamesAreConfigurable()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "REFRESH01");
        try
        {
            var w = new Wire
            {
                ApiStatus = new List<int> { 403, 200 },
                TokenPath = "oauth/grant",
                RespField = "token",
            };
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["feature"] = ExchangeOpts(new Dictionary<string, object?>
                {
                    ["path"] = "oauth/grant",
                    ["request"] = "grant",
                    ["response"] = "token",
                    ["statuses"] = new List<object?> { 403 },
                }),
            });

            client.Direct(new Dictionary<string, object?> { ["path"] = "/thing" });

            Assert.True(2 == w.Api().Count, "403 was declared an expiry");
            Assert.True(w.Token()[0].Url.EndsWith("/oauth/grant"),
                "the token endpoint is relative to base: " + w.Token()[0].Url);
            Assert.Contains("\"grant\"", w.Token()[0].Body);
            CredentialIs(w.Api()[1].Auth, "ACCESS02");
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    [Fact]
    public void AnExplicitApikeyIsSpentBeforeAnythingIsBought()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "REFRESH01");
        try
        {
            var w = new Wire();
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["apikey"] = "HELDTOKEN01",
                ["feature"] = ExchangeOpts(null),
            });

            client.Direct(new Dictionary<string, object?> { ["path"] = "/thing" });

            Assert.True(0 == w.Token().Count, "nothing needed buying");
            CredentialIs(w.Api()[0].Auth, "HELDTOKEN01");
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    [Fact]
    public void NoRefreshTokenAnywhereIsAnErrorNotAnUnauthenticatedCall()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ExchangeOpts(null),
        });

        var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/thing" });

        Assert.True(Equals(res["ok"], false),
            "expected a failure, got: " + res.GetValueOrDefault("ok"));
        Assert.True(0 == w.Api().Count,
            "a request must not go out unauthenticated because the chain was empty: " +
            w.Report());
    }

    [Fact]
    public void ExchangeAuthNullSuppressesTheCredentialRefusalOrNot()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "REFRESH01");
        try
        {
            // `auth: null` is the documented way to send no credential at
            // all. A refusal of a deliberately unauthenticated request is
            // not an expired token: buying one and retrying would transmit
            // exactly the credential the caller suppressed.
            var w = new Wire { ApiStatus = new List<int> { 401 } };
            var client = SecretsClient(w, new Dictionary<string, object?>
            {
                ["auth"] = null,
                ["feature"] = ExchangeOpts(null),
            });

            client.Direct(new Dictionary<string, object?> { ["path"] = "/thing" });

            Assert.True(1 == w.Api().Count, "a suppressed request must not be retried");
            Assert.False(w.Api()[0].HasAuth,
                "no credential may be sent when auth is suppressed, got " +
                w.Api()[0].Auth);

            // AND NO PURCHASE. Resolve() runs before WithRefresh's
            // suppression check, so the refresh token used to go to the
            // token endpoint in a request body even here. Stopping the
            // retry does not unsend it, and only the token endpoint can
            // see this.
            Assert.True(0 == w.Token().Count,
                "auth null suppressed the credential but the refresh token was " +
                "still POSTed to the exchange endpoint");
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    // Test mode buys nothing and needs no token endpoint: the test feature
    // replaces the transport so no request leaves the process, and an
    // exchange would be the one HTTP call it could not stop.
    [Fact]
    public void TestModeBuysNothingAndNeedsNoTokenEndpoint()
    {
        Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", "REFRESH01");
        try
        {
            var w = new Wire();
            var client = WithSecrets(extend =>
            {
                var opts = new Dictionary<string, object?>
                {
                    ["base"] = SecretsBase,
                    ["system"] = new Dictionary<string, object?>
                    {
                        ["fetch"] = (Func<string, Dictionary<string, object?>,
                            Dictionary<string, object?>>)w.Fetch,
                    },
                    ["feature"] = ExchangeOpts(null),
                };
                if (extend)
                {
                    opts["extend"] = new List<object?> { new SecretsFeature() };
                }
                return UnivecSDK.TestSDK(null, opts);
            });

            DriveEntityOpUntil(client, "resolved the fake token",
                () => "" != SecretsOf(client)!.Credential());

            Assert.True(0 == w.Calls.Count,
                "test mode must not do IO, saw " + w.Calls.Count + " calls");
            // A deterministic placeholder, so offline suites need no
            // configuration.
            Assert.Equal("test-access_token", SecretsOf(client)!.Credential());
        }
        finally
        {
            Environment.SetEnvironmentVariable(EnvPrefix + "REFRESH_TOKEN", null);
        }
    }

    // THE EXCHANGE WITH NO system.fetch, end to end over a real socket.
    //
    // The ordinary case: MakeOptions leaves system.fetch unset, so the API
    // call takes the SDK's default HttpClient transport and the token
    // purchase takes SdkUtility.DefaultHttpFetch. The refresh token is full
    // of JSON-hostile characters, which proves the body is SERIALISED and
    // not concatenated - a token carrying a quote, a backslash or a newline
    // must arrive as that literal value.
    [Fact]
    public void ExchangeOverARealSocketWithNoSystemFetch()
    {
        const string tricky = "re\"fresh\\to\nken";

        var listener = new HttpListener();
        var port = FreePort();
        var prefix = "http://127.0.0.1:" + port + "/";
        listener.Prefixes.Add(prefix);
        listener.Start();

        var gotrefresh = "";
        var gotauth = "";
        var served = new ManualResetEventSlim(false);

        // A THREAD, not Task.Run: a test method that blocks on a Task is
        // xUnit1031, and the listener loop is not async work anyway.
        var serving = new Thread(() =>
        {
            try
            {
                while (listener.IsListening)
                {
                    var ctx = listener.GetContext();
                    var body = new StreamReader(ctx.Request.InputStream, Encoding.UTF8)
                        .ReadToEnd();

                    string payload;
                    if (ctx.Request.Url!.AbsolutePath.EndsWith("/auth/token"))
                    {
                        var parsed = JsonSerializer.Deserialize<Dictionary<string, string>>(body);
                        gotrefresh = parsed != null && parsed.TryGetValue("refresh_token", out var r)
                            ? r : "";
                        payload = "{\"access_token\": \"RAWTOK01\"}";
                    }
                    else
                    {
                        gotauth = ctx.Request.Headers["authorization"] ?? "";
                        payload = "{}";
                        served.Set();
                    }

                    var bytes = Encoding.UTF8.GetBytes(payload);
                    ctx.Response.ContentType = "application/json";
                    ctx.Response.ContentLength64 = bytes.Length;
                    ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
                    ctx.Response.OutputStream.Close();
                }
            }
            catch (Exception)
            {
                // Teardown closes the listener out from under GetContext.
            }
        })
        { IsBackground = true };
        serving.Start();

        try
        {
            // No system.fetch ANYWHERE.
            var client = WithSecrets(extend =>
            {
                var opts = new Dictionary<string, object?>
                {
                    ["base"] = "http://127.0.0.1:" + port + "/api",
                    ["allow"] = new Dictionary<string, object?>
                    {
                        ["op"] = "create,update,load,list,remove,command,direct,graphql",
                    },
                    ["feature"] = new Dictionary<string, object?>
                    {
                        ["secrets"] = new Dictionary<string, object?>
                        {
                            ["active"] = true,
                            ["name"] = "refresh_token",
                            ["exchange"] = new Dictionary<string, object?>
                            {
                                ["active"] = true,
                                ["refresh"] = tricky,
                            },
                        },
                    },
                };
                if (extend)
                {
                    opts["extend"] = new List<object?> { new SecretsFeature() };
                }
                return new UnivecSDK(opts);
            });

            var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/thing" });

            Assert.True(Equals(res["ok"], true),
                "the raw exchange call failed: " + res.GetValueOrDefault("err"));
            Assert.True(served.Wait(TimeSpan.FromSeconds(5)),
                "the API request never reached the socket");

            Assert.Equal(tricky, gotrefresh);
            CredentialIs(gotauth, "RAWTOK01");
        }
        finally
        {
            listener.Stop();
            listener.Close();
            serving.Join(TimeSpan.FromSeconds(5));
        }
    }

    private static int FreePort()
    {
        var probe = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return port;
    }


    // --- concurrency -------------------------------------------------------

    // A provider failure closes the transport gate; a later retry that
    // SUCCEEDS reopens it and every waiting operation goes out with the
    // FRESH credential - never the stale pre-failure header, and never
    // nothing. This is also the lane that would expose an unlocked Sekreto
    // cache (a concurrently-mutated List<T> corrupts silently) or a mutated
    // shared options map.
    [Fact]
    public void TheGateRecoversUnderConcurrency()
    {
        var mode = "fail";
        var release = new ManualResetEventSlim(false);

        var flaky = new ProbeProvider
        {
            Fn = _ =>
            {
                var m = Volatile.Read(ref mode);
                if ("fail" == m)
                {
                    throw new SekretoError("vault unreachable");
                }
                if ("slow" == m)
                {
                    release.Wait(TimeSpan.FromSeconds(5));
                }
                return "FRESH01";
            },
        };

        var w = new Wire();
        var client = SecretsClient(w, new Dictionary<string, object?>
        {
            ["feature"] = ProviderOpts(flaky,
                new Dictionary<string, object?> { ["cache"] = false }),
        });

        // 1. The failure closes the gate: nothing reaches the wire.
        var res = client.Direct(new Dictionary<string, object?> { ["path"] = "/gated" });
        Assert.True(Equals(res["ok"], false), "a failed resolution must refuse the request");
        Assert.True(0 == w.Calls.Count,
            "a failed resolution must keep the wire silent, saw " + w.Report());

        // 2. Recovery under concurrency: eight operations race the slow
        // retry; all of them must come out carrying the fresh credential.
        Volatile.Write(ref mode, "slow");

        var opening = new Thread(() =>
        {
            Thread.Sleep(20);
            release.Set();
        })
        { IsBackground = true };
        opening.Start();

        Parallel.For(0, 8, i =>
            client.Direct(new Dictionary<string, object?> { ["path"] = "/c" + i }));

        opening.Join(TimeSpan.FromSeconds(5));

        Assert.True(0 < w.Api().Count, "recovery must let the operations out");
        foreach (var call in w.Api())
        {
            CredentialIs(call.Auth, "FRESH01");
        }
    }
}
