// Univec SDK utility: clean - the one choke point every egress passes
// through. Everything that leaves the pipeline is cleaned; inside it data
// stays raw, so a hook can still read the header it must add to. See
// docs/explanation/secret-redaction.md.

using System.Collections;
using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;

using Voxgig.Struct;

namespace UnivecSdk.Util;

// The derived clean block, MUTABLE after MakeOptions since features register
// values later. Fields rather than properties: System.Text.Json serialises
// properties, so a JSON of the options shows this block as {} and never the
// registry it holds.
public sealed class CleanConfig
{
    public bool Active = true;
    public List<string> Keys = new();
    // Requests on other threads clean while one registers, so a registration
    // publishes a new list and never changes a published one.
    public List<string> Values = new();
    public string Mask = "[redacted]";
    public int Hint;
    public int Min = 4;
    internal readonly object Registering = new();
}

public static partial class SdkUtility
{
    private const int CleanMaxDepth = 32;
    private const string CleanCircular = "[circular]";

    // A dropped slot (a delegate): omitted from a map, null in a list.
    private static readonly object CleanDrop = new();

    private static readonly JsonSerializerOptions CleanJsonOpts = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static string CleanNormKey(string key)
    {
        return key.ToLowerInvariant().Replace("-", "").Replace("_", "");
    }

    private static List<string> CleanSplitKeys(object? keys)
    {
        return (Convert.ToString(keys) ?? "")
            .Split(',')
            .Select(k => CleanNormKey(k.Trim()))
            .Where(k => k != "")
            .ToList();
    }

    internal static List<string> CleanSplitValues(object? values)
    {
        if (values is IList list && values is not string)
        {
            return list.OfType<string>().ToList();
        }
        return (Convert.ToString(values) ?? "")
            .Split(',')
            .Select(v => v.Trim())
            .Where(v => v != "")
            .ToList();
    }

    private static int CleanCount(object? val, int dflt)
    {
        double n;
        if (val is string s)
        {
            if (!double.TryParse(s.Trim(), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out n))
            {
                return dflt;
            }
        }
        else if (val is int or long or double or float or short or byte or decimal)
        {
            n = Convert.ToDouble(val);
        }
        else
        {
            return dflt;
        }
        n = Math.Floor(n);
        return double.IsFinite(n) && 0 <= n ? (int)n : dflt;
    }

    internal static CleanConfig MakeCleanConfig(object? cleanopts)
    {
        var opts = cleanopts as Dictionary<string, object?> ?? new Dictionary<string, object?>();
        return new CleanConfig
        {
            Active = !(opts.TryGetValue("active", out var a) && a is bool ab && !ab),
            Keys = CleanSplitKeys(opts.TryGetValue("keys", out var k) ? k : null),
            Values = new List<string>(),
            Mask = opts.TryGetValue("mask", out var m) && m is string ms ? ms : "[redacted]",
            Hint = CleanCount(opts.TryGetValue("hint", out var h) ? h : null, 0),
            Min = Math.Max(1, CleanCount(opts.TryGetValue("min", out var mn) ? mn : null, 4)),
        };
    }

    // A context without options (MakeError accepts a bare one) still masks by
    // the schema defaults.
    internal static CleanConfig CleanConfigOf(Context? ctx)
    {
        if (ctx?.Options != null &&
            ctx.Options.TryGetValue("__derived__", out var draw) &&
            draw is Dictionary<string, object?> derived &&
            derived.TryGetValue("clean", out var craw) &&
            craw is CleanConfig cfg)
        {
            return cfg;
        }
        return MakeCleanConfig(StructUtils.GetProp(SdkSchema.Optspec, "clean"));
    }

    // The encoded forms a value travels in.
    private static List<string> CleanForms(string value)
    {
        var out_ = new List<string> { value };
        void Add(string s)
        {
            if (s != "" && !out_.Contains(s))
            {
                out_.Add(s);
            }
        }
        try { Add(Convert.ToBase64String(Encoding.UTF8.GetBytes(value))); } catch (Exception) { }
        try { Add(Uri.EscapeDataString(value)); } catch (Exception) { }
        try
        {
            var quoted = JsonSerializer.Serialize(value, CleanJsonOpts);
            Add(quoted.Substring(1, quoted.Length - 2));
        }
        catch (Exception) { }
        return out_;
    }

    internal static void CleanAddUtil(Context ctx, object? value)
    {
        CleanRegister(CleanConfigOf(ctx), value);
    }

    private static void CleanRegister(CleanConfig cfg, object? value)
    {
        if (value is not string s || s.Length < cfg.Min)
        {
            return;
        }
        lock (cfg.Registering)
        {
            var added = CleanForms(s).Where(f => f.Length >= cfg.Min && !cfg.Values.Contains(f)).ToList();
            if (0 == added.Count)
            {
                return;
            }
            var values = new List<string>(cfg.Values);
            values.AddRange(added);
            values.Sort((a, b) => b.Length.CompareTo(a.Length));
            Volatile.Write(ref cfg.Values, values);
        }
    }

    private static string CleanMaskValue(CleanConfig cfg, string value)
    {
        if (0 < cfg.Hint && value.Length > 2 * cfg.Hint)
        {
            return cfg.Mask + value.Substring(value.Length - cfg.Hint);
        }
        return cfg.Mask;
    }

    private static string CleanString(CleanConfig cfg, string text)
    {
        var out_ = text;
        foreach (var value in Volatile.Read(ref cfg.Values))
        {
            if (out_.Contains(value))
            {
                out_ = out_.Replace(value, CleanMaskValue(cfg, value));
            }
        }
        return out_;
    }

    private static bool CleanSensitiveKey(CleanConfig cfg, object? key)
    {
        if (key is not string ks)
        {
            return false;
        }
        var nk = CleanNormKey(ks);
        foreach (var k in cfg.Keys)
        {
            if (nk.Contains(k))
            {
                return true;
            }
        }
        return false;
    }

    private static string CleanCamel(string name)
    {
        return name == "" ? name : char.ToLowerInvariant(name[0]) + name.Substring(1);
    }

    private static bool CleanIsNumber(object val)
    {
        return val is int or long or double or float or short or byte or decimal or
            sbyte or ushort or uint or ulong;
    }

    // A registered value used as a map key is masked like any other string;
    // keys that mask alike take a counter, so none is lost.
    private static string CleanName(CleanConfig cfg, Dictionary<string, object?> out_, string key)
    {
        var name = CleanString(cfg, key);
        if (name == key || !out_.ContainsKey(name))
        {
            return name;
        }
        var i = 1;
        while (out_.ContainsKey(name + "#" + i))
        {
            i++;
        }
        return name + "#" + i;
    }

    // A masked plain-data copy: functions dropped, cycles cut, and nothing
    // shared with the live value, whose spec must stay raw. A typed pipeline
    // product (Spec, Result, a feature record) reads through its public
    // fields, the way a structured logger would; the context reads through
    // its own record so its client, options and config never enter.
    private static object? CleanSnapshot(CleanConfig cfg, object? val, object? key,
        int depth, List<object> seen)
    {
        if (val == null || ReferenceEquals(val, StructUtils.NONE))
        {
            return val;
        }

        if (val is string s)
        {
            return CleanSensitiveKey(cfg, key) ? CleanMaskValue(cfg, s) : CleanString(cfg, s);
        }

        if (val is Delegate)
        {
            return CleanDrop;
        }

        if (val is bool || val is int || val is long || val is double || val is float ||
            val is short || val is byte || val is decimal || val is char || val.GetType().IsEnum)
        {
            return CleanSensitiveKey(cfg, key) ? cfg.Mask : val;
        }

        if (CleanMaxDepth <= depth || seen.Any(o => ReferenceEquals(o, val)))
        {
            return CleanCircular;
        }

        if (CleanSensitiveKey(cfg, key))
        {
            return cfg.Mask;
        }

        seen.Add(val);
        try
        {
            if (val is IDictionary dict)
            {
                var out_ = new Dictionary<string, object?>();
                foreach (DictionaryEntry kv in dict)
                {
                    var k = Convert.ToString(kv.Key) ?? "";
                    var v = CleanSnapshot(cfg, kv.Value, k, depth + 1, seen);
                    if (!ReferenceEquals(v, CleanDrop))
                    {
                        out_[CleanName(cfg, out_, k)] = v;
                    }
                }
                return out_;
            }

            if (val is IList list)
            {
                var out_ = new List<object?>();
                foreach (var item in list)
                {
                    var v = CleanSnapshot(cfg, item, null, depth + 1, seen);
                    out_.Add(ReferenceEquals(v, CleanDrop) ? null : v);
                }
                return out_;
            }

            if (val is Exception err)
            {
                var out_ = new Dictionary<string, object?>
                {
                    ["message"] = CleanString(cfg, err.Message),
                    ["stack"] = CleanString(cfg, err.StackTrace ?? ""),
                };
                if (err is UnivecError se)
                {
                    out_["sdk"] = se.Sdk;
                    out_["code"] = CleanString(cfg, se.Code);
                    out_["status"] = se.Status;
                    out_["result"] = CleanSnapshot(cfg, se.ResultVal, "result", depth + 1, seen);
                    out_["spec"] = CleanSnapshot(cfg, se.SpecVal, "spec", depth + 1, seen);
                }
                return out_;
            }

            if (val is Context ctx)
            {
                return CleanSnapshot(cfg, ctx.RawRecord(), key, depth, seen);
            }

            if (val is IEntity ent)
            {
                return ent.GetName();
            }

            var fields = val.GetType().GetFields(BindingFlags.Public | BindingFlags.Instance);
            if (0 == fields.Length)
            {
                return CleanString(cfg, Convert.ToString(val) ?? "");
            }
            var rec = new Dictionary<string, object?>();
            foreach (var f in fields)
            {
                var k = CleanCamel(f.Name);
                var v = CleanSnapshot(cfg, f.GetValue(val), k, depth + 1, seen);
                if (!ReferenceEquals(v, CleanDrop))
                {
                    rec[k] = v;
                }
            }
            return rec;
        }
        finally
        {
            seen.RemoveAt(seen.Count - 1);
        }
    }

    // The SDK's own error is cleaned in place, since it is about to be thrown.
    internal static object? CleanUtil(Context ctx, object? val)
    {
        var cfg = CleanConfigOf(ctx);

        if (!cfg.Active)
        {
            return val;
        }

        if (val is string s)
        {
            return CleanString(cfg, s);
        }

        if (val is UnivecError err)
        {
            err.SetMessage(CleanString(cfg, err.Message));
            err.Code = CleanString(cfg, err.Code);
            if (err.ResultVal != null && err.ResultVal is not string)
            {
                err.ResultVal = CleanSnapshot(cfg, err.ResultVal, "result", 1, new List<object>());
            }
            if (err.SpecVal != null && err.SpecVal is not string)
            {
                err.SpecVal = CleanSnapshot(cfg, err.SpecVal, "spec", 1, new List<object>());
            }
            return err;
        }

        // Exception's message is read-only, so a foreign exception leaves as a
        // cleaned copy of the SDK's own error, without the raw one as its cause.
        if (val is Exception ex)
        {
            return new UnivecError("", CleanString(cfg, ex.Message), null);
        }

        var out_ = CleanSnapshot(cfg, val, null, 0, new List<object>());
        return ReferenceEquals(out_, CleanDrop) ? null : out_;
    }

    internal static bool CleanKeyUtil(Context ctx, object? key)
    {
        return CleanSensitiveKey(CleanConfigOf(ctx), key);
    }

    // Every scalar under a sensitive name, at any depth and of any shape: a
    // credential mistyped as a map or a number is still a credential, and the
    // validation error that rejects it quotes it.
    internal static void CleanAddSensitive(Context ctx, object? val)
    {
        CleanAddSensitiveIn(CleanConfigOf(ctx), val, false, 0, new List<object>());
    }

    private static void CleanAddSensitiveIn(CleanConfig cfg, object? val, bool under,
        int depth, List<object> seen)
    {
        if (val == null || CleanMaxDepth <= depth)
        {
            return;
        }
        if (val is string s)
        {
            if (under) CleanRegister(cfg, s);
            return;
        }
        if (CleanIsNumber(val))
        {
            if (under) CleanRegister(cfg, Convert.ToString(val, CultureInfo.InvariantCulture));
            return;
        }
        if (seen.Any(o => ReferenceEquals(o, val)))
        {
            return;
        }
        if (val is IDictionary dict)
        {
            seen.Add(val);
            foreach (DictionaryEntry kv in dict)
            {
                CleanAddSensitiveIn(cfg, kv.Value,
                    under || CleanSensitiveKey(cfg, Convert.ToString(kv.Key)), depth + 1, seen);
            }
        }
        else if (val is IList list)
        {
            seen.Add(val);
            foreach (var item in list)
            {
                CleanAddSensitiveIn(cfg, item, under, depth + 1, seen);
            }
        }
    }
}
