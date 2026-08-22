// Univec SDK - HTTP request specification.

namespace UnivecSdk;

public class Spec
{
    public List<object?>? Parts;
    public Dictionary<string, object?> Headers = new();
    public Dictionary<string, object?> Alias = new();
    public string Base = "";
    public string Prefix = "";
    public string Suffix = "";
    public Dictionary<string, object?> Params = new();
    public Dictionary<string, object?> Query = new();
    public string Step = "";
    public string Method = "GET";
    public object? Body;
    public string Url = "";
    public string Path = "";

    public Spec(Dictionary<string, object?>? specmap)
    {
        if (specmap == null)
        {
            return;
        }

        if (specmap.TryGetValue("parts", out var v) && v is List<object?> parts)
        {
            Parts = parts;
        }
        if (specmap.TryGetValue("headers", out v) && v is Dictionary<string, object?> h)
        {
            Headers = h;
        }
        if (specmap.TryGetValue("alias", out v) && v is Dictionary<string, object?> a)
        {
            Alias = a;
        }
        if (specmap.TryGetValue("base", out v) && v is string b)
        {
            Base = b;
        }
        if (specmap.TryGetValue("prefix", out v) && v is string p)
        {
            Prefix = p;
        }
        if (specmap.TryGetValue("suffix", out v) && v is string sf)
        {
            Suffix = sf;
        }
        if (specmap.TryGetValue("params", out v) && v is Dictionary<string, object?> pm)
        {
            Params = pm;
        }
        if (specmap.TryGetValue("query", out v) && v is Dictionary<string, object?> q)
        {
            Query = q;
        }
        if (specmap.TryGetValue("step", out v) && v is string st)
        {
            Step = st;
        }
        if (specmap.TryGetValue("method", out v) && v is string m)
        {
            Method = m;
        }
        if (specmap.TryGetValue("body", out v))
        {
            Body = v;
        }
        if (specmap.TryGetValue("url", out v) && v is string u)
        {
            Url = u;
        }
        if (specmap.TryGetValue("path", out v) && v is string pa)
        {
            Path = pa;
        }
    }
}
