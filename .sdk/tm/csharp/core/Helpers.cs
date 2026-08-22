// Univec SDK - shared value helpers for the loose object model
// (Dictionary<string, object?> maps, List<object?> lists, string/long/double
// /bool scalars - the same representation the vendored Voxgig.Struct port
// uses).

namespace UnivecSdk;

public static class Helpers
{
    // UnsupportedOp is thrown by entity base methods for operations the
    // underlying API spec doesn't define. The UnivecEntityBase class
    // declares every CRUD method on every entity, so absent ops must still
    // be callable - they error at runtime instead of failing to compile.
    public static Exception UnsupportedOp(string opname, string entityname)
    {
        return new InvalidOperationException(
            $"operation '{opname}' not supported by entity '{entityname}'");
    }

    public static Dictionary<string, object?>? ToMapAny(object? v)
    {
        return v as Dictionary<string, object?>;
    }

    public static int ToInt(object? v)
    {
        return v switch
        {
            int n => n,
            long n => (int)n,
            double n => (int)n,
            float n => (int)n,
            short n => n,
            byte n => n,
            _ => -1,
        };
    }

    public static long ToLong(object? v)
    {
        return v switch
        {
            int n => n,
            long n => n,
            double n => (long)n,
            float n => (long)n,
            short n => n,
            byte n => n,
            _ => -1,
        };
    }

    public static object? GetCtxProp(Dictionary<string, object?>? m, string key)
    {
        if (m == null)
        {
            return null;
        }
        return m.TryGetValue(key, out var v) ? v : null;
    }
}
