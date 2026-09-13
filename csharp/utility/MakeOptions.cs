// Univec SDK utility: makeOptions - merge, validate and derive the
// client options.

using System.Text.RegularExpressions;

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    // {name} placeholders in a templated server URL (OpenAPI server
    // variables). Compiled once: MakeOptions runs per client construction.
    private static readonly Regex ServerVarRe =
        new(@"\{([A-Za-z0-9_]+)\}", RegexOptions.Compiled);


    /// <summary>
    /// Replaces one utility member from <c>options.utility</c>, matching the
    /// ts reference: a key naming a real member REPLACES it, and any other
    /// key is attached as a custom extra. Returns false when the key names no
    /// member or the value is not that member's delegate type, so the caller
    /// keeps it in Custom.
    /// </summary>
    /// <remarks>
    /// REFLECTION, NOT A KEYED SWITCH. The go and java ports list every member
    /// by hand and carry a "keep this in step with registerAll" warning,
    /// because a utility added to one list and not the other is overridable
    /// there and not here. C# can read the field set off the type itself, so
    /// the list cannot drift, and FieldType.IsInstanceOfType is a real check
    /// rather than an unchecked cast - a wrongly-shaped value falls through to
    /// Custom instead of throwing later in the pipeline.
    ///
    /// Only a PUBLIC name may replace a member. Option keys are camelCase, as
    /// ts spells them, and fields here are PascalCase; public names carry no
    /// underscore, so an underscore means the caller named something of their
    /// own rather than a member.
    /// </remarks>
    internal static bool OverrideUtil(Utility utility, string key, object? val)
    {
        if (string.IsNullOrEmpty(key) || key.Contains('_'))
        {
            return false;
        }

        var name = char.ToUpperInvariant(key[0]) + key.Substring(1);
        if ("Custom" == name)
        {
            return false;
        }

        var field = typeof(Utility).GetField(name);
        if (null == field || null == val)
        {
            return false;
        }

        if (field.FieldType.IsInstanceOfType(val))
        {
            field.SetValue(utility, val);
            return true;
        }

        // SAME SHAPE, DIFFERENT NAMED TYPE. Every member is a NAMED delegate
        // (FetcherFunc) or a constructed Func/Action, and C# delegate types are
        // nominal: a naturally-typed lambda gets Func`4, and
        // `Func<Context, string, Dictionary<string, object?>, object?>` written
        // out longhand is a third type again. None is an instance of
        // FetcherFunc despite an identical signature, so IsInstanceOfType alone
        // honoured only a caller who knew to declare the named type - which is
        // to say, almost nobody.
        //
        // CreateDelegate rebinds the same target and method onto the field's
        // type, and with throwOnBindFailure: false it returns null rather than
        // throwing when the signature genuinely does not match - so a wrongly
        // shaped delegate still falls through to `custom`.
        if (val is Delegate d && typeof(Delegate).IsAssignableFrom(field.FieldType))
        {
            var converted = Delegate.CreateDelegate(field.FieldType, d.Target, d.Method, false);
            if (null != converted)
            {
                field.SetValue(utility, converted);
                return true;
            }
        }

        return false;
    }

    internal static Dictionary<string, object?> MakeOptionsUtil(Context ctx)
    {
        var options = ctx.Options ?? new Dictionary<string, object?>();

        // Merge utility overrides from options onto the utility object.
        // Read from original options before clone for safety.
        //
        // A key naming a real utility member REPLACES it; anything else is
        // attached as a custom extra. Shelving everything in Custom - a map
        // nothing reads - made `utility: { fetcher = ... }`, the documented
        // transport seam, a silent no-op here while ts honoured it.
        if (Helpers.ToMapAny(options.TryGetValue("utility", out var cu) ? cu : null)
            is Dictionary<string, object?> customUtils)
        {
            var utility = ctx.Utility;
            if (utility != null)
            {
                foreach (var kv in customUtils)
                {
                    if (!OverrideUtil(utility, kv.Key, kv.Value))
                    {
                        utility.Custom[kv.Key] = kv.Value;
                    }
                }
            }
        }

        // `auth: null` is the documented way to disable auth outright, and
        // PrepareAuth honours it before it ever reads the apikey. It cannot
        // survive validate: depending on the struct port a stored null is
        // either REPLACED by the optspec default - transmitting the credential
        // the caller withheld - or REJECTED outright. Withhold the key for
        // validate, then put the null back. Same fix as ts/js/go makeOptions.
        //
        // Suppliedness cannot be recovered after validate, hence here, and it
        // must tell an ABSENT auth from a present null: TryGetValue rather
        // than an indexer null check, which cannot distinguish them.
        var authSuppressed = options.TryGetValue("auth", out var authval) && null == authval;

        var opts = StructUtils.Clone(options) as Dictionary<string, object?>
            ?? new Dictionary<string, object?>();

        if (authSuppressed)
        {
            opts.Remove("auth");
        }

        // Feature add-order. options.feature may be given as an ordered LIST of
        // { name, active, ...opts } entries (the list position IS the order in
        // which features are added), or as a { name: {opts} } map. Normalize a
        // list to a map (so merge/validate/init are unchanged) and remember the
        // explicit order; a map defaults to test-first so the `test` mock
        // transport is installed as the base of the transport wrapper chain.
        var featureorder = new List<object?>();
        if (opts.TryGetValue("feature", out var frawInit) &&
            frawInit is List<object?> flist)
        {
            var fmap = new Dictionary<string, object?>();
            foreach (var entry in flist)
            {
                if (entry is Dictionary<string, object?> em &&
                    StructUtils.GetProp(em, "name") is string fname && fname != "")
                {
                    var fopts = new Dictionary<string, object?>(em);
                    fopts.Remove("name");
                    fmap[fname] = fopts;
                    featureorder.Add(fname);
                }
            }
            opts["feature"] = fmap;
        }

        var config = ctx.Config ?? new Dictionary<string, object?>();
        var cfgopts = config.TryGetValue("options", out var co) &&
            co is Dictionary<string, object?> cm
            ? cm : new Dictionary<string, object?>();

        var optspec = new Dictionary<string, object?>
        {
            ["apikey"] = "",
            ["secret"] = "",
            ["base"] = "http://localhost:8000",
            ["prefix"] = "",
            ["suffix"] = "",
            // `basic` and `secret`: HTTP Basic Auth needs a second credential
            // and a flag to say the pair is Basic rather than a single bearer
            // token.
            ["auth"] = new Dictionary<string, object?>
            {
                ["prefix"] = "",
                ["basic"] = false,
            },
            ["headers"] = new Dictionary<string, object?>
            {
                ["`$CHILD`"] = "`$STRING`",
            },
            // OpenAPI server-variable defaults, carried by the generated
            // config whenever the spec's server URL is templated. Accepted
            // here so validation does not reject the SDK's own config; the
            // {name} substitution into base is a separate concern.
            ["server"] = new Dictionary<string, object?>
            {
                ["`$CHILD`"] = "",
            },
            ["allow"] = new Dictionary<string, object?>
            {
                ["method"] = "GET,PUT,POST,PATCH,DELETE,OPTIONS",
                ["op"] = "create,update,load,list,remove,command,direct,graphql",
            },
            ["entity"] = new Dictionary<string, object?>
            {
                ["`$CHILD`"] = new Dictionary<string, object?>
                {
                    ["`$OPEN`"] = true,
                    ["active"] = false,
                    ["alias"] = new Dictionary<string, object?>(),
                },
            },
            ["feature"] = new Dictionary<string, object?>
            {
                ["`$CHILD`"] = new Dictionary<string, object?>
                {
                    ["`$OPEN`"] = true,
                    ["active"] = false,
                },
            },
            ["utility"] = new Dictionary<string, object?>(),
            // Feature INSTANCES supplied at construction (the `extend` seam
            // the client constructor reads after the config-driven features):
            // class instances, not data, so `$ANY` accepts them verbatim.
            // Without this entry the seam is DEAD - validate REJECTS the
            // unknown key ("Unexpected keys at field <root>: extend"), so a
            // caller cannot hand in a feature the model did not activate,
            // although the README documents the option. Ported from
            // MakeOptionsUtility.ts / make_options.go / MakeOptions.java,
            // which all carry it.
            ["extend"] = "`$ANY`",
            ["system"] = new Dictionary<string, object?>(),
            ["test"] = new Dictionary<string, object?>
            {
                ["active"] = false,
                ["entity"] = new Dictionary<string, object?>
                {
                    ["`$OPEN`"] = true,
                },
            },
            ["clean"] = new Dictionary<string, object?>
            {
                ["keys"] = "key,token,id",
            },
        };

        // Preserve system.fetch across merge/validate (delegates survive
        // Clone, but validation may reshape the system block).
        var sysFetch = StructUtils.GetPath(opts, StructUtils.Jt("system", "fetch"));

        var merged = StructUtils.Merge(new List<object?>
        {
            new Dictionary<string, object?>(),
            // CLONE the config side. `config` is a process-wide singleton
            // (SdkConfig.SharedConfig), and Merge uses its nested maps as
            // merge TARGETS - without this, one client's options (headers,
            // server, ...) are written into the shared config and inherited by
            // every client constructed afterwards.
            StructUtils.Clone(cfgopts),
            opts,
        });
        var validated = StructUtils.Validate(merged, optspec);
        opts = validated as Dictionary<string, object?> ?? new Dictionary<string, object?>();

        // Restore the suppression the optspec default would otherwise erase.
        if (authSuppressed)
        {
            opts["auth"] = null;
        }

        // Resolve a templated base URL (e.g. https://{tenant_id}.hanko.io).
        // Every placeholder must resolve to a non-empty value: from
        // options.server (user), else the Config default. A placeholder that
        // resolves to "" is a construction ERROR in live mode - the URL cannot
        // work - but in test mode substitutes the deterministic value
        // "test-<name>" so offline tests need no configuration. The SDK
        // constructor has no error return, so a missing required variable
        // THROWS: this is construction-time misconfiguration.
        if (opts.TryGetValue("base", out var baseRaw) && baseRaw is string baseUrl &&
            baseUrl.Contains('{'))
        {
            var testmode =
                StructUtils.GetPath(opts, StructUtils.Jt("test", "active")) is bool ta && ta ||
                StructUtils.GetPath(opts, StructUtils.Jt("feature", "test", "active"))
                    is bool fa && fa;

            var server = opts.TryGetValue("server", out var sv) &&
                sv is Dictionary<string, object?> svm
                ? svm : new Dictionary<string, object?>();

            var sdkname = StructUtils.GetPath(config, StructUtils.Jt("main", "name"))
                is string mn && mn != "" ? mn : "SDK";

            opts["base"] = ServerVarRe.Replace(baseUrl, m =>
            {
                var name = m.Groups[1].Value;
                var val = server.TryGetValue(name, out var v) && v is string s ? s : "";
                if (val == "")
                {
                    if (testmode)
                    {
                        return "test-" + name;
                    }
                    throw new UnivecError("server_var_required",
                        sdkname + ": the server variable '" + name + "' is required: " +
                        "the API base URL is '" + baseUrl + "' - pass " +
                        "new Dictionary<string, object?> { [\"server\"] = new " +
                        "Dictionary<string, object?> { [\"" + name + "\"] = \"...\" } } " +
                        "in the SDK options",
                        ctx);
                }
                return val;
            });
        }

        // Restore system.fetch.
        if (sysFetch != null)
        {
            if (opts.TryGetValue("system", out var sys) &&
                sys is Dictionary<string, object?> sm)
            {
                sm["fetch"] = sysFetch;
            }
            else
            {
                opts["system"] = new Dictionary<string, object?>
                {
                    ["fetch"] = sysFetch,
                };
            }
        }

        // Derived clean config.
        var cleanKeys = "key,token,id";
        if (StructUtils.GetPath(opts, StructUtils.Jt("clean", "keys")) is string cks)
        {
            cleanKeys = cks;
        }

        var filtered = cleanKeys.Split(',')
            .Select(p => p.Trim())
            .Where(p => p != "")
            .Select(StructUtils.EscRe)
            .ToList();
        var keyre = string.Join("|", filtered);

        // Resolve the feature add-order: an explicit list order (above) wins;
        // otherwise order the map test-first, then the remaining names sorted,
        // so the outcome is deterministic and `test` is always the base
        // transport.
        if (featureorder.Count == 0)
        {
            var fmap = Helpers.ToMapAny(StructUtils.GetProp(opts, "feature"))
                ?? new Dictionary<string, object?>();
            var names = fmap.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
            if (names.Contains("test"))
            {
                featureorder.Add("test");
                foreach (var n in names)
                {
                    if (n != "test")
                    {
                        featureorder.Add(n);
                    }
                }
            }
            else
            {
                foreach (var n in names)
                {
                    featureorder.Add(n);
                }
            }

            // Station special case, mirroring test's: its transport wrap must
            // sit immediately outside the base transport (inside retry/cache/
            // netsim), so map-form activation hoists it to just after test -
            // or first, when no test entry exists. Without this the sorted
            // default would init station last and wrap OUTSIDE the recording
            // features, turning its wire-truth events into fiction.
            var si = featureorder.IndexOf("station");
            if (si >= 0)
            {
                featureorder.RemoveAt(si);
                featureorder.Insert(featureorder.IndexOf("test") + 1, "station");
            }
        }

        var derived = new Dictionary<string, object?>
        {
            ["clean"] = new Dictionary<string, object?>(),
        };
        if (keyre != "")
        {
            derived["clean"] = new Dictionary<string, object?>
            {
                ["keyre"] = keyre,
            };
        }
        derived["featureorder"] = featureorder;
        opts["__derived__"] = derived;

        return opts;
    }
}
