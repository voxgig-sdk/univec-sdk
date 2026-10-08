// Univec SDK - shared option readers for the feature implementations.
// Options arrive as Dictionary<string, object?>, so a numeric value may be any
// numeric type; `decimal` is what System.Text.Json yields through JsonElement.

namespace UnivecSdk.Feature;

internal static class FeatureOptions
{
    internal static object? Opt(Dictionary<string, object?>? options, string key)
    {
        if (options == null)
        {
            return null;
        }
        return options.TryGetValue(key, out var v) ? v : null;
    }

    internal static bool FoptBool(Dictionary<string, object?>? options, string key, bool def)
    {
        return Opt(options, key) is bool b ? b : def;
    }

    internal static int FoptInt(Dictionary<string, object?>? options, string key, int def)
    {
        return Opt(options, key) switch
        {
            int n => n,
            long n => (int)n,
            short n => n,
            sbyte n => n,
            uint n => (int)n,
            ulong n => (int)n,
            ushort n => n,
            byte n => n,
            double n => (int)n,
            float n => (int)n,
            // Via double: decimal->int is the one conversion C# range-checks
            // even unchecked, and no other target throws on an oversized option.
            decimal n => (int)(double)n,
            _ => def,
        };
    }

    internal static double FoptNum(Dictionary<string, object?>? options, string key, double def)
    {
        return Opt(options, key) switch
        {
            int n => n,
            long n => n,
            short n => n,
            sbyte n => n,
            uint n => n,
            ulong n => n,
            ushort n => n,
            byte n => n,
            double n => n,
            float n => n,
            decimal n => (double)n,
            _ => def,
        };
    }

    internal static string FoptStr(Dictionary<string, object?>? options, string key, string def)
    {
        return Opt(options, key) is string s && s != "" ? s : def;
    }

    internal static Dictionary<string, object?>? FoptMap(Dictionary<string, object?>? options, string key)
    {
        return Opt(options, key) as Dictionary<string, object?>;
    }

    internal static List<object?>? FoptList(Dictionary<string, object?>? options, string key)
    {
        return Opt(options, key) as List<object?>;
    }

    // FoptStrList reads a list option as strings (List<object?> or List<string>).
    internal static List<string>? FoptStrList(Dictionary<string, object?>? options, string key)
    {
        var raw = Opt(options, key);
        if (raw is List<string> sl)
        {
            return sl;
        }
        if (raw is List<object?> ol)
        {
            var outlist = new List<string>();
            foreach (var v in ol)
            {
                if (v is string s)
                {
                    outlist.Add(s);
                }
            }
            return outlist;
        }
        return null;
    }

    // FoptSleep returns the injectable sleep (option "sleep": Action<int> ms),
    // defaulting to a real Thread.Sleep. Injected clocks keep tests
    // deterministic.
    internal static Action<int> FoptSleep(Dictionary<string, object?>? options)
    {
        if (Opt(options, "sleep") is Action<int> fn)
        {
            return fn;
        }
        return ms =>
        {
            if (ms > 0)
            {
                Thread.Sleep(ms);
            }
        };
    }

    // FoptNow returns the injectable clock (option "now": Func<long>, ms),
    // defaulting to the wall clock.
    internal static Func<long> FoptNow(Dictionary<string, object?>? options)
    {
        if (Opt(options, "now") is Func<long> fn)
        {
            return fn;
        }
        return () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }

    // FheaderGet reads a header value case-insensitively.
    internal static (object? val, bool has) FheaderGet(Dictionary<string, object?>? headers, string name)
    {
        if (headers == null)
        {
            return (null, false);
        }
        foreach (var kv in headers)
        {
            if (string.Equals(kv.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                return (kv.Value, true);
            }
        }
        return (null, false);
    }

    // FheaderSetDefault sets a header only when no case-insensitive variant
    // of it exists already (never clobber a caller-provided value).
    internal static void FheaderSetDefault(Dictionary<string, object?>? headers, string name, string value)
    {
        if (headers == null)
        {
            return;
        }
        var (_, has) = FheaderGet(headers, name);
        if (has)
        {
            return;
        }
        headers[name] = value;
    }

    // FresStatus extracts the numeric status from a transport-shaped response
    // (map with a "status" entry). Returns has=false when absent/non-numeric.
    internal static (int status, bool has) FresStatus(object? res)
    {
        if (res is not Dictionary<string, object?> rm)
        {
            return (0, false);
        }
        if (!rm.TryGetValue("status", out var raw))
        {
            return (0, false);
        }
        return raw switch
        {
            int n => (n, true),
            long n => ((int)n, true),
            double n => ((int)n, true),
            _ => (0, false),
        };
    }

    // FresHeader reads a header from a transport-shaped response,
    // case-insensitively, as a string.
    internal static (string val, bool has) FresHeader(object? res, string name)
    {
        if (res is not Dictionary<string, object?> rm)
        {
            return ("", false);
        }
        if (!rm.TryGetValue("headers", out var rawHeaders) ||
            rawHeaders is not Dictionary<string, object?> headers)
        {
            return ("", false);
        }
        var (v, has) = FheaderGet(headers, name);
        if (!has || v is not string s)
        {
            return ("", false);
        }
        return (s, true);
    }

    // FparseInt parses a decimal string; def when unparseable.
    internal static int FparseInt(string s, int def)
    {
        return int.TryParse(s.Trim(), out var n) ? n : def;
    }

    // Fclean passes a record a feature is about to emit through the SDK's
    // clean utility: every sink, buffer and logger receives the masked copy.
    internal static Dictionary<string, object?> Fclean(Context ctx, Dictionary<string, object?> record)
    {
        var clean = ctx.Utility?.Clean;
        return clean == null
            ? record
            : clean(ctx, record) as Dictionary<string, object?> ?? record;
    }

    internal static string FcleanStr(Context ctx, string text)
    {
        var clean = ctx.Utility?.Clean;
        return clean == null ? text : clean(ctx, text) as string ?? text;
    }
}
