// Drives the shared struct corpus (../../.sdk/test/test.json, root key
// "struct") against the vendored struct utility THROUGH the vendored omni
// runner (OmniResolver over test/vendor/omni) - the engine half of the
// retired StructRunner. Mirrors tm/go/test/struct_utility_test.go.
// A missing category or section FAILS (the old runner skipped it silently
// - a renamed fixture reported PASS while running zero assertions); a
// failing entry throws OmniError with the entry named.
//
// RUN: cd test && dotnet test
// RUN-SOME: dotnet test --filter "DisplayName~MinorIsNode"

using Voxgig.Struct;
using Xunit;

namespace UnivecSdk.Test;


public class StructUtilityTest
{
    private static OmniResolver.Run? RUN;
    private static readonly object RunLock = new();

    private static OmniResolver.Run StructRun()
    {
        lock (RunLock)
        {
            if (RUN == null)
            {
                RUN = OmniResolver.MakeRunner(StructRunner.TestJsonPath(),
                    UnivecSDK.TestSDK(null, null))("struct");
                Assert.True(0 < RUN.Spec.Count,
                    "struct section not found in test.json");
            }
            return RUN;
        }
    }

    /// <summary>A subject in the struct-corpus shape: one argument in, one value out.</summary>
    private delegate object? StructSubject(object? input);

    private static object? Getp(object? input, string key)
    {
        return input is Dictionary<string, object?> m && m.TryGetValue(key, out var v)
            ? v : null;
    }

    private static object? GetpDef(object? input, string key, object? def)
    {
        return input is Dictionary<string, object?> m && m.ContainsKey(key)
            ? m[key] : def;
    }

    private static int? IntArg(object? val)
        => val == null ? null : (int?)Convert.ToInt32(val);

    // Run one corpus section, failing loudly when a category or section is
    // missing or EMPTY - a renamed fixture must not report PASS while
    // running zero assertions.
    private static void RunStruct(string category, string name, bool nullFlag,
        StructSubject subject)
    {
        var run = StructRun();
        var cat = run.Spec.TryGetValue(category, out var c)
            ? c as Dictionary<string, object?> : null;
        Assert.True(null != cat, "struct corpus category missing: " + category +
            " - check .sdk/test/struct/");
        var spec = cat!.TryGetValue(name, out var s)
            ? s as Dictionary<string, object?> : null;
        Assert.True(null != spec, "struct corpus section missing: " + category +
            "." + name + " - check .sdk/test/struct/");
        var set = spec!.TryGetValue("set", out var sv) ? sv as List<object?> : null;
        Assert.True(set != null && 0 < set.Count,
            "struct corpus section is EMPTY: " + category + "." + name +
            " - zero cases would run");
        run.RunSetFlags(spec, new Dictionary<string, bool> { ["null"] = nullFlag },
            args => subject(0 < args.Length ? args[0] : StructUtils.NONE));
    }

    private static Dictionary<string, object?> Section(string category, string name)
    {
        var run = StructRun();
        var cat = run.Spec.TryGetValue(category, out var c)
            ? c as Dictionary<string, object?> : null;
        Assert.True(null != cat, "struct corpus category missing: " + category);
        var spec = cat!.TryGetValue(name, out var s)
            ? s as Dictionary<string, object?> : null;
        Assert.True(null != spec,
            "struct corpus section missing: " + category + "." + name);
        return spec!;
    }

    // The struct-corpus nullModifier (was the old runner's ad-hoc handling):
    // a bare "__NULL__" becomes a real null, and an embedded "__NULL__"
    // inside a larger string is rewritten to the literal text "null".
    // Mirrors omni's NullModifier for struct's own Modify callback shape.
    private static readonly Modify NullModifier = (val, key, parent, inj, store) =>
    {
        if (val is not string text)
        {
            return val;
        }
        object? repl;
        if (OmniResolver.NULLMARK == text)
        {
            repl = null;
        }
        else if (text.Contains(OmniResolver.NULLMARK))
        {
            repl = text.Replace(OmniResolver.NULLMARK, "null");
        }
        else
        {
            return val;
        }
        StructUtils.SetProp(parent, key, repl);
        return repl;
    };


    // ========================================================================
    // minor-exists: verify all expected functions exist
    // ========================================================================

    [Fact]
    public void MinorExists()
    {
        // Verify all expected functions resolve as delegates (callable).
        var checks = new (string name, Delegate fn)[]
        {
            ("isnode",    (Func<object?, bool>)   StructUtils.IsNode),
            ("ismap",     (Func<object?, bool>)   StructUtils.IsMap),
            ("islist",    (Func<object?, bool>)   StructUtils.IsList),
            ("iskey",     (Func<object?, bool>)   StructUtils.IsKey),
            ("isempty",   (Func<object?, bool>)   StructUtils.IsEmpty),
            ("isfunc",    (Func<object?, bool>)   StructUtils.IsFunc),
            ("size",      (Func<object?, int>)    StructUtils.Size),
            ("typify",    (Func<object?, int>)    StructUtils.Typify),
            ("typename",  (Func<int, string>)     StructUtils.TypeName),
            ("strkey",    (Func<object?, string?>) StructUtils.StrKey),
            ("keysof",    (Func<object?, List<string>>) StructUtils.KeysOf),
            ("haskey",    (Func<object?, object?, bool>) StructUtils.HasKey),
            ("getelem",   (Func<object?, object?, object?, object?>) StructUtils.GetElem),
            ("getprop",   (Func<object?, object?, object?, object?>) StructUtils.GetProp),
            ("setprop",   (Func<object?, object?, object?, object?>) StructUtils.SetProp),
            ("delprop",   (Func<object?, object?, object?>)          StructUtils.DelProp),
            ("clone",     (Func<object?, object?>)  StructUtils.Clone),
            ("escre",     (Func<string?, string>)   StructUtils.EscRe),
            ("escurl",    (Func<string?, string>)   StructUtils.EscUrl),
            ("stringify", (Func<object?, int?, string>) StructUtils.Stringify),
        };

        foreach (var (name, fn) in checks)
            Assert.True(fn != null, $"{name} should exist");
    }


    // ========================================================================
    // Minor utility tests (driven from test.json through the resolver)
    // ========================================================================

    [Fact]
    public void MinorIsNode()
    {
        RunStruct("minor", "isnode", true, input => StructUtils.IsNode(input));
    }

    [Fact]
    public void MinorIsMap()
    {
        RunStruct("minor", "ismap", true, input => StructUtils.IsMap(input));
    }

    [Fact]
    public void MinorIsList()
    {
        RunStruct("minor", "islist", true, input => StructUtils.IsList(input));
    }

    [Fact]
    public void MinorIsKey()
    {
        RunStruct("minor", "iskey", false, input => StructUtils.IsKey(input));
    }

    [Fact]
    public void MinorStrKey()
    {
        RunStruct("minor", "strkey", false, input => StructUtils.StrKey(input));
    }

    [Fact]
    public void MinorIsEmpty()
    {
        RunStruct("minor", "isempty", false, input => StructUtils.IsEmpty(input));
    }

    [Fact]
    public void MinorIsFunc()
    {
        RunStruct("minor", "isfunc", true, input => StructUtils.IsFunc(input));

        // Edge: actual delegates should be recognised.
        Func<object?> f0 = () => null;
        Assert.True(StructUtils.IsFunc(f0));
        Assert.True(StructUtils.IsFunc((Action)(() => { })));
    }

    [Fact]
    public void MinorClone()
    {
        RunStruct("minor", "clone", false, input => StructUtils.Clone(input));

        // Edge: functions should be shallow-copied, not cloned.
        Func<object?> f0 = () => null;
        var src = new Dictionary<string, object?> { ["a"] = f0 };
        var cloned = StructUtils.Clone(src) as Dictionary<string, object?>;
        Assert.NotNull(cloned);
        Assert.Same(f0, cloned["a"]);
    }

    [Fact]
    public void MinorEscRe()
    {
        RunStruct("minor", "escre", true, input => StructUtils.EscRe(input as string));
    }

    [Fact]
    public void MinorEscUrl()
    {
        RunStruct("minor", "escurl", true, input => StructUtils.EscUrl(input as string));
    }

    [Fact]
    public void MinorStringify()
    {
        RunStruct("minor", "stringify", false, input =>
        {
            // null:false keeps a JSON-null val as a real null (rendered
            // "null"); an absent val is NONE (rendered ""). Mirrors the
            // canonical harness.
            var val = GetpDef(input, "val", StructUtils.NONE);
            var max = Getp(input, "max");
            return StructUtils.Stringify(val, IntArg(max));
        });
    }

    [Fact]
    public void MinorJsonify()
    {
        RunStruct("minor", "jsonify", false, input =>
        {
            var val = Getp(input, "val");
            if (Getp(input, "flags") is Dictionary<string, object?> flags)
            {
                var indent = flags.TryGetValue("indent", out var iv) && iv != null
                    ? Convert.ToInt32(iv) : 2;
                var offset = flags.TryGetValue("offset", out var ov) && ov != null
                    ? Convert.ToInt32(ov) : 0;
                return StructUtils.Jsonify(val, indent, offset);
            }
            return StructUtils.Jsonify(val);
        });
    }

    [Fact]
    public void MinorPathify()
    {
        RunStruct("minor", "pathify", false, input =>
        {
            // null:false keeps a JSON-null path as a real null
            // ("<unknown-path:null>") and an absent path as NONE
            // ("<unknown-path>"); null parts are dropped.
            var path = GetpDef(input, "path", StructUtils.NONE);
            var from = IntArg(Getp(input, "from"));
            var to = IntArg(Getp(input, "to"));
            return null == to
                ? (null == from
                    ? StructUtils.Pathify(path)
                    : StructUtils.Pathify(path, from.Value))
                : StructUtils.Pathify(path, from ?? 0, to.Value);
        });
    }

    [Fact]
    public void MinorItems()
    {
        RunStruct("minor", "items", true, input => StructUtils.Items(input));
    }

    [Fact]
    public void MinorGetProp()
    {
        RunStruct("minor", "getprop", false, input =>
        {
            var val = Getp(input, "val");
            var key = Getp(input, "key");
            // Canonical's default alt is `undefined`, so the no-alt call has
            // to ask for NONE explicitly: `GetProp(val, key)` defaults `alt`
            // to null, which answers "null" where canonical answers
            // "undefined", and under `null: false` the corpus tells them
            // apart. It also omits `alt` only when the KEY is missing
            // (`undefined === vin.alt`), so an explicit `alt: null` is
            // passed through - unlike getelem below, which omits a null alt
            // too (`null == vin.alt`). (The struct repo's own C# suite binds
            // it the same way.)
            if (input is Dictionary<string, object?> m && m.ContainsKey("alt"))
                return StructUtils.GetProp(val, key, m["alt"]);
            return StructUtils.GetProp(val, key, StructUtils.NONE);
        });
    }

    [Fact]
    public void MinorEdgeGetProp()
    {
        // String arrays.
        var strarr = new List<object?> { "a", "b", "c", "d", "e" };
        Assert.Equal("c", StructUtils.GetProp(strarr, 2));
        Assert.Equal("c", StructUtils.GetProp(strarr, "2"));
    }

    [Fact]
    public void MinorGetElem()
    {
        RunStruct("minor", "getelem", false, input =>
        {
            var val = Getp(input, "val");
            var key = Getp(input, "key");
            // Canonical's default alt is `undefined`; see MinorGetProp.
            var alt = Getp(input, "alt");
            return null != alt
                ? StructUtils.GetElem(val, key, alt)
                : StructUtils.GetElem(val, key, StructUtils.NONE);
        });
    }

    [Fact]
    public void MinorSetProp()
    {
        RunStruct("minor", "setprop", true, input =>
        {
            var parent = Getp(input, "parent");
            var key = Getp(input, "key");
            var val = Getp(input, "val");
            return StructUtils.SetProp(parent, key, val);
        });
    }

    [Fact]
    public void MinorEdgeSetProp()
    {
        var strarr0 = new List<object?> { "a", "b", "c", "d", "e" };
        var strarr1 = new List<object?> { "a", "b", "c", "d", "e" };
        Assert.True(StructRunner.DeepEqual(
            new List<object?> { "a", "b", "C", "d", "e" },
            StructUtils.SetProp(strarr0, 2, "C")));
        Assert.True(StructRunner.DeepEqual(
            new List<object?> { "a", "b", "CC", "d", "e" },
            StructUtils.SetProp(strarr1, "2", "CC")));
    }

    [Fact]
    public void MinorDelProp()
    {
        RunStruct("minor", "delprop", true, input =>
        {
            var parent = Getp(input, "parent");
            var key = Getp(input, "key");
            return StructUtils.DelProp(parent, key);
        });
    }

    [Fact]
    public void MinorKeysOf()
    {
        RunStruct("minor", "keysof", true, input => StructUtils.KeysOf(input));
    }

    [Fact]
    public void MinorHasKey()
    {
        RunStruct("minor", "haskey", false, input =>
            StructUtils.HasKey(Getp(input, "src"), Getp(input, "key")));
    }

    [Fact]
    public void MinorStringifyEdge()
    {
        // Basic edge cases beyond what the JSON spec covers.
        Assert.Equal("1",      StructUtils.Stringify(1));
        Assert.Equal("true",   StructUtils.Stringify(true));
        Assert.Equal("hello",  StructUtils.Stringify("hello"));
        // Match TS: NONE (undefined) -> ""; JSON null -> "null".
        Assert.Equal("",       StructUtils.Stringify(StructUtils.NONE));
        Assert.Equal("null",   StructUtils.Stringify(null));
    }

    [Fact]
    public void MinorTypify()
    {
        RunStruct("minor", "typify", false, input => StructUtils.Typify(input));
    }

    [Fact]
    public void MinorTypeName()
    {
        RunStruct("minor", "typename", true, input =>
            StructUtils.TypeName(Convert.ToInt32(input)));
    }

    [Fact]
    public void MinorSize()
    {
        RunStruct("minor", "size", false, input => StructUtils.Size(input));
    }

    [Fact]
    public void MinorSlice()
    {
        RunStruct("minor", "slice", false, input =>
        {
            var val = Getp(input, "val");
            var start = IntArg(Getp(input, "start"));
            var end = IntArg(Getp(input, "end"));
            return StructUtils.Slice(val, start, end);
        });
    }

    [Fact]
    public void MinorFlatten()
    {
        RunStruct("minor", "flatten", true, input =>
        {
            var val = Getp(input, "val") as List<object?>;
            var depth = IntArg(Getp(input, "depth"));
            return StructUtils.Flatten(val ?? [], depth ?? 1);
        });
    }

    // Named filter predicates used in test.json.
    private static readonly Dictionary<string, Func<List<object?>, bool>> FilterChecks = new()
    {
        ["gt3"] = n => StructRunner.IsNumericValue(n[1]) && StructRunner.ToDoubleVal(n[1]) > 3,
        ["lt3"] = n => StructRunner.IsNumericValue(n[1]) && StructRunner.ToDoubleVal(n[1]) < 3,
    };

    [Fact]
    public void MinorFilter()
    {
        RunStruct("minor", "filter", true, input =>
        {
            var val = Getp(input, "val");
            var chk = Getp(input, "check") as string;
            if (chk != null && FilterChecks.TryGetValue(chk, out var check))
                return StructUtils.Filter(val, check);
            return StructUtils.Filter(val, n => n[1] is string s && s.Length > 0);
        });
    }

    [Fact]
    public void MinorPad()
    {
        RunStruct("minor", "pad", false, input =>
        {
            var str = Getp(input, "val");
            var padding = Getp(input, "pad");
            // spec uses "char" as key for the pad character
            var padchar = Getp(input, "char") ?? Getp(input, "padchar");

            var pad = padding != null ? Convert.ToInt32(padding) : 44;
            return StructUtils.Pad(str, pad, padchar as string);
        });
    }

    [Fact]
    public void MinorJoin()
    {
        RunStruct("minor", "join", false, input =>
        {
            if (input is not Dictionary<string, object?>)
                return StructUtils.Join([input]);
            var arr = Getp(input, "val");
            var sep = Getp(input, "sep");
            var url = Getp(input, "url") is bool b && b;
            return StructUtils.Join(arr as List<object?> ?? [], sep as string, url);
        });
    }

    [Fact]
    public void MinorSetPath()
    {
        RunStruct("minor", "setpath", false, input =>
        {
            var store = Getp(input, "store");
            var path = Getp(input, "path");
            var val = Getp(input, "val");
            return StructUtils.SetPath(store, path, val);
        });
    }


    // ========================================================================
    // The struct.nullsem section: does a PRESENT key holding a JSON null
    // read as "no value"? Opt-in per target (create-sdkgen ships it; an
    // older project corpus may predate it - the skip below says so OUT
    // LOUD rather than passing vacuously). All lanes run {null: false}:
    // without the flag the runner rewrites every null to '__NULL__' and
    // the section asserts nothing about null at all.
    // ========================================================================

    [Fact]
    public void Nullsem()
    {
        var run = StructRun();
        var nullsem = run.Spec.TryGetValue("nullsem", out var ns)
            ? ns as Dictionary<string, object?> : null;
        if (nullsem == null)
        {
            // xUnit has no runtime skip without extra packages; say it loudly.
            Console.Error.WriteLine("SKIP: corpus predates struct.nullsem - " +
                "refresh .sdk/test/struct from create-sdkgen");
            return;
        }
        var flags = new Dictionary<string, bool> { ["null"] = false };

        run.RunSetFlags(nullsem["getprop"], flags, args =>
        {
            var input = args[0];
            // Canonical's default alt is `undefined` -> NONE; see MinorGetProp.
            if (input is Dictionary<string, object?> m && m.ContainsKey("alt"))
                return StructUtils.GetProp(Getp(input, "val"), Getp(input, "key"), m["alt"]);
            return StructUtils.GetProp(Getp(input, "val"), Getp(input, "key"),
                StructUtils.NONE);
        });

        run.RunSetFlags(nullsem["getelem"], flags, args =>
        {
            var input = args[0];
            var alt = Getp(input, "alt");
            return null != alt
                ? StructUtils.GetElem(Getp(input, "val"), Getp(input, "key"), alt)
                : StructUtils.GetElem(Getp(input, "val"), Getp(input, "key"),
                    StructUtils.NONE);
        });

        run.RunSetFlags(nullsem["getpath"], flags, args =>
        {
            // The port's GetPath spells "no value" as null - for a plain
            // MISS and for a stored null alike (its alt parameter is not
            // consulted on the path walk), where canonical answers
            // undefined for both. Map that spelling to omni absence at the
            // boundary; the distinction the lane guards (null-as-VALUE vs
            // no-value) stays observable, because a port that read a
            // stored null as a value would fail the getprop/haskey lanes.
            var res = StructUtils.GetPath(Getp(args[0], "store"), Getp(args[0], "path"));
            return res ?? StructUtils.NONE;
        });

        run.RunSetFlags(nullsem["haskey"], flags, args =>
            StructUtils.HasKey(Getp(args[0], "src"), Getp(args[0], "key")));

        run.RunSetFlags(nullsem["keysof"], flags, args =>
            StructUtils.KeysOf(args[0]));
    }


    // ========================================================================
    // Walk tests
    // ========================================================================

    [Fact]
    public void WalkBasic()
    {
        // subject: Walk(val, walkpath) where walkpath appends "~path.join('.')"
        WalkApply walkpath = (key, val, parent, path) =>
        {
            if (val is string s)
                return s + "~" + string.Join(".", path.Select(p => p?.ToString()));
            return val;
        };

        RunStruct("walk", "basic", true, input => StructUtils.Walk(input, walkpath));
    }

    [Fact]
    public void WalkLog()
    {
        var logSpec = Section("walk", "log");
        var testIn = StructUtils.Clone(logSpec["in"]);
        var outSpec = logSpec["out"] as Dictionary<string, object?>;

        WalkApply makeWalkLog(List<object?> log)
        {
            // TS Stringify(undefined)="" but Stringify(null)="null". The C#
            // walk passes null at root for both key and parent - render those
            // as empty string to match the corpus log format ("p=", "k=").
            string Render(object? v) =>
                v == null ? "" : StructUtils.Stringify(v);

            return (key, val, parent, path) =>
            {
                string ks = key is string sk ? sk : "";
                string entry =
                    "k=" + StructUtils.Stringify(ks) +
                    ", v=" + Render(val) +
                    ", p=" + Render(parent) +
                    ", t=" + StructUtils.Pathify(path);
                log.Add(entry);
                return val;
            };
        }

        // Test after (post-order).
        var logAfter = new List<object?>();
        StructUtils.Walk(testIn, null, makeWalkLog(logAfter));
        Assert.True(StructRunner.DeepEqual(outSpec?["after"], logAfter),
            $"walk-log after:\n  got:  {StructUtils.Stringify(logAfter)}\n  want: {StructUtils.Stringify(outSpec?["after"])}");

        // Test before (pre-order).
        var logBefore = new List<object?>();
        StructUtils.Walk(testIn, makeWalkLog(logBefore));
        Assert.True(StructRunner.DeepEqual(outSpec?["before"], logBefore),
            $"walk-log before:\n  got:  {StructUtils.Stringify(logBefore)}\n  want: {StructUtils.Stringify(outSpec?["before"])}");

        // Test both.
        var logBoth = new List<object?>();
        var bothCb = makeWalkLog(logBoth);
        StructUtils.Walk(testIn, bothCb, bothCb);
        Assert.True(StructRunner.DeepEqual(outSpec?["both"], logBoth),
            $"walk-log both:\n  got:  {StructUtils.Stringify(logBoth)}\n  want: {StructUtils.Stringify(outSpec?["both"])}");
    }

    [Fact]
    public void WalkDepth()
    {
        RunStruct("walk", "depth", false, input =>
        {
            var src = Getp(input, "src");
            var md = IntArg(Getp(input, "maxdepth"));

            // Build a copy using a single current-node pointer (matches the
            // go walk-depth test).
            object? top = null;
            object? cur = null;

            WalkApply copy = (key, val, parent, path) =>
            {
                if (StructUtils.IsNode(val))
                {
                    object? child = StructUtils.IsList(val)
                        ? (object?)new List<object?>()
                        : new Dictionary<string, object?>();
                    if (key == null) { top = child; cur = child; }
                    else { StructUtils.SetProp(cur, key, child); cur = child; }
                }
                else if (key != null)
                    StructUtils.SetProp(cur, key, val);
                return val;
            };

            StructUtils.Walk(src, copy, null, md);
            return top;
        });
    }

    [Fact]
    public void WalkCopy()
    {
        RunStruct("walk", "copy", true, input =>
        {
            var cur = new object?[StructUtils.MAXDEPTH + 1];

            WalkApply walkcopy = (key, val, parent, path) =>
            {
                if (key == null) // root
                {
                    cur[0] = StructUtils.IsMap(val)
                        ? (object?)new Dictionary<string, object?>()
                        : StructUtils.IsList(val)
                            ? new List<object?>()
                            : val;
                    return val;
                }

                int i = path.Count;
                object? v = val;

                if (StructUtils.IsNode(val))
                {
                    cur[i] = StructUtils.IsMap(val)
                        ? (object?)new Dictionary<string, object?>()
                        : new List<object?>();
                    v = cur[i];
                }

                cur[i - 1] = StructUtils.SetProp(cur[i - 1], key, v) ?? cur[i - 1];
                return val;
            };

            StructUtils.Walk(input, walkcopy);
            return cur[0];
        });
    }


    // ========================================================================
    // Merge tests
    // ========================================================================

    [Fact]
    public void MergeBasic()
    {
        var basic = Section("merge", "basic");
        object? result = StructUtils.Merge(basic["in"]);
        Assert.True(StructRunner.DeepEqual(basic["out"], result),
            $"merge-basic: expected {StructUtils.Stringify(basic["out"])} but got {StructUtils.Stringify(result)}");
    }

    [Fact]
    public void MergeCases()
    {
        RunStruct("merge", "cases", true, input => StructUtils.Merge(input));
    }

    [Fact]
    public void MergeArray()
    {
        RunStruct("merge", "array", true, input => StructUtils.Merge(input));
    }

    [Fact]
    public void MergeIntegrity()
    {
        RunStruct("merge", "integrity", true, input => StructUtils.Merge(input));
    }

    [Fact]
    public void MergeDepth()
    {
        RunStruct("merge", "depth", true, input =>
        {
            var val = Getp(input, "val");
            var depth = IntArg(Getp(input, "depth"));
            return StructUtils.Merge(val, depth);
        });
    }

    [Fact]
    public void MergeSpecial()
    {
        // Functions should survive merge as shallow copies.
        Func<int> f0 = () => 11;

        var r0 = StructUtils.Merge(new List<object?> { f0 }) as Func<int>;
        Assert.NotNull(r0);
        Assert.Equal(f0(), r0!());

        var r1 = StructUtils.Merge(new List<object?> { null, f0 }) as Func<int>;
        Assert.NotNull(r1);
        Assert.Equal(f0(), r1!());

        var r2 = StructUtils.Merge(new List<object?> {
            new Dictionary<string, object?> { ["a"] = f0 }
        }) as Dictionary<string, object?>;
        Assert.NotNull(r2);
        var fr2 = r2!["a"] as Func<int>;
        Assert.NotNull(fr2);
        Assert.Equal(f0(), fr2!());
    }


    // ========================================================================
    // GetPath tests
    // ========================================================================

    [Fact]
    public void GetpathExists()
    {
        Delegate fn = (Func<object?, object?, object?, InjectState?, object?>)StructUtils.GetPath;
        Assert.NotNull(fn);
    }

    [Fact]
    public void GetpathBasic()
    {
        RunStruct("getpath", "basic", true, input =>
            StructUtils.GetPath(Getp(input, "store"), Getp(input, "path")));
    }

    [Fact]
    public void GetpathRelative()
    {
        RunStruct("getpath", "relative", true, input =>
        {
            var state = new InjectState { DParent = Getp(input, "dparent") };

            if (Getp(input, "dpath") is string dpathStr && dpathStr.Length > 0)
                state.DPath = dpathStr.Split('.').Cast<object?>().ToList();

            return StructUtils.GetPath(Getp(input, "store"), Getp(input, "path"),
                null, state);
        });
    }

    [Fact]
    public void GetpathSpecial()
    {
        RunStruct("getpath", "special", true, input =>
        {
            InjectState? state = null;
            if (Getp(input, "inj") is Dictionary<string, object?> injMap)
            {
                state = new InjectState();
                if (injMap.TryGetValue("key", out var kv) && kv != null)
                    state.Key = StructUtils.Stringify(kv);
                if (injMap.TryGetValue("meta", out var mv) &&
                    mv is Dictionary<string, object?> metaMap)
                    state.Meta = metaMap;
            }

            return StructUtils.GetPath(Getp(input, "store"), Getp(input, "path"),
                null, state);
        });
    }

    [Fact]
    public void GetpathHandler()
    {
        // Handler that turns any ref lookup into "<ref>" (e.g. "$FOO" → "foo").
        var refMap = new Dictionary<string, object?> { ["$FOO"] = "foo" };

        RunStruct("getpath", "handler", true, input =>
        {
            var state = new InjectState
            {
                Handler = (inj, val, refStr, st) =>
                    refStr != null && refMap.TryGetValue(refStr, out var mapped)
                        ? mapped : val,
            };
            return StructUtils.GetPath(Getp(input, "store"), Getp(input, "path"),
                null, state);
        });
    }


    // ========================================================================
    // Inject tests
    // ========================================================================

    [Fact]
    public void InjectExists()
    {
        Delegate fn = (Func<object?, object?, InjectState?, object?>)StructUtils.Inject;
        Assert.NotNull(fn);
    }

    [Fact]
    public void InjectBasic()
    {
        var basic = Section("inject", "basic");
        var inVal = basic["in"] as Dictionary<string, object?>;
        Assert.NotNull(inVal);
        object? val = inVal!.TryGetValue("val", out var v) ? v : null;
        object? store = inVal.TryGetValue("store", out var s) ? s : null;
        object? expected = basic.TryGetValue("out", out var o) ? o : null;

        object? result = StructUtils.Inject(val, store);
        Assert.True(StructRunner.DeepEqual(expected, result),
            $"inject-basic: expected {StructUtils.Stringify(expected)} but got {StructUtils.Stringify(result)}");
    }

    [Fact]
    public void InjectString()
    {
        // The nullModifier renders a resolved JSON null (encoded by the
        // runner as "__NULL__") as the literal text "null".
        RunStruct("inject", "string", true, input =>
        {
            var state = new InjectState { ModifyFn = NullModifier };
            return StructUtils.Inject(Getp(input, "val"), Getp(input, "store"), state);
        });
    }

    [Fact]
    public void InjectDeep()
    {
        RunStruct("inject", "deep", true, input =>
            StructUtils.Inject(Getp(input, "val"), Getp(input, "store")));
    }


    // ========================================================================
    // Transform tests
    // ========================================================================

    [Fact]
    public void TransformExists()
    {
        Delegate fn = (Func<object?, object?, InjectState?, object?>)StructUtils.Transform;
        Assert.NotNull(fn);
    }

    [Fact]
    public void TransformBasic()
    {
        var basic = Section("transform", "basic");
        var inVal = basic["in"] as Dictionary<string, object?>;
        Assert.NotNull(inVal);
        object? data = inVal!.TryGetValue("data", out var d) ? d : null;
        object? spec = inVal.TryGetValue("spec", out var s) ? s : null;
        object? expected = basic.TryGetValue("out", out var o) ? o : null;

        object? result = StructUtils.Transform(data, spec);
        Assert.True(StructRunner.DeepEqual(expected, result),
            $"transform-basic: expected {StructUtils.Stringify(expected)} " +
            $"but got {StructUtils.Stringify(result)}");
    }

    [Fact]
    public void TransformPaths()
    {
        RunStruct("transform", "paths", true, input =>
            StructUtils.Transform(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void TransformCmds()
    {
        RunStruct("transform", "cmds", true, input =>
            StructUtils.Transform(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void TransformEach()
    {
        RunStruct("transform", "each", true, input =>
            StructUtils.Transform(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void TransformPack()
    {
        RunStruct("transform", "pack", true, input =>
            StructUtils.Transform(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void TransformRef()
    {
        RunStruct("transform", "ref", true, input =>
            StructUtils.Transform(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void TransformFormat()
    {
        RunStruct("transform", "format", false, input =>
            StructUtils.Transform(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void TransformModify()
    {
        RunStruct("transform", "modify", true, input =>
        {
            // Match the JS test guard: only mutate string leaves.
            Modify myModify = (val, key, parent, inj, store) =>
            {
                if (key != null && val is string s && s.Length > 0)
                    StructUtils.SetProp(parent, key, "@" + s);
                return val;
            };
            var state = new InjectState { ModifyFn = myModify };
            return StructUtils.Transform(Getp(input, "data"), Getp(input, "spec"), state);
        });
    }

    [Fact]
    public void TransformApply()
    {
        RunStruct("transform", "apply", true, input =>
            StructUtils.Transform(Getp(input, "data"), Getp(input, "spec")));
    }


    // ========================================================================
    // Validate tests
    // ========================================================================

    [Fact]
    public void ValidateExists()
    {
        Assert.NotNull((object)(StructUtils.Validate));
    }

    [Fact]
    public void ValidateBasic()
    {
        RunStruct("validate", "basic", false, input =>
            StructUtils.Validate(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void ValidateChild()
    {
        RunStruct("validate", "child", true, input =>
            StructUtils.Validate(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void ValidateOne()
    {
        RunStruct("validate", "one", true, input =>
            StructUtils.Validate(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void ValidateExact()
    {
        RunStruct("validate", "exact", true, input =>
            StructUtils.Validate(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void ValidateInvalid()
    {
        RunStruct("validate", "invalid", false, input =>
            StructUtils.Validate(Getp(input, "data"), Getp(input, "spec")));
    }

    [Fact]
    public void ValidateSpecial()
    {
        RunStruct("validate", "special", true, input =>
        {
            var injdef = new InjectState();
            if (Getp(input, "inj") is Dictionary<string, object?> injEntry &&
                injEntry.TryGetValue("meta", out var mv) &&
                mv is Dictionary<string, object?> meta)
            {
                injdef.Meta = meta;
            }
            return StructUtils.Validate(Getp(input, "data"), Getp(input, "spec"), injdef);
        });
    }


    // ========================================================================
    // Select tests
    // ========================================================================

    [Fact]
    public void SelectExists()
    {
        Assert.NotNull((object)(StructUtils.Select));
    }

    [Fact]
    public void SelectBasic()
    {
        RunStruct("select", "basic", true, input =>
            StructUtils.Select(Getp(input, "obj"), Getp(input, "query")));
    }

    [Fact]
    public void SelectOperators()
    {
        RunStruct("select", "operators", true, input =>
            StructUtils.Select(Getp(input, "obj"), Getp(input, "query")));
    }

    [Fact]
    public void SelectEdge()
    {
        RunStruct("select", "edge", true, input =>
            StructUtils.Select(Getp(input, "obj"), Getp(input, "query")));
    }

    [Fact]
    public void SelectAlts()
    {
        RunStruct("select", "alts", true, input =>
            StructUtils.Select(Getp(input, "obj"), Getp(input, "query")));
    }
}
