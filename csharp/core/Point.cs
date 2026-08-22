// Univec SDK - typed view over an endpoint (point) definition.

using Voxgig.Struct;

namespace UnivecSdk;

public class Point
{
    public Dictionary<string, object?> Args = new() { ["params"] = new List<object?>() };
    public Dictionary<string, object?> Rename = new() { ["params"] = new Dictionary<string, object?>() };
    public string Method = "";
    public string Orig = "";
    public List<object?> Parts = new();
    public List<object?>? Params;
    public Dictionary<string, object?>? Select;
    // Absent in config means ACTIVE: emission drops `active: true` as a
    // default (sdkgen L0), so only an explicit `active: false` turns a point off.
    public bool Active = true;
    public List<object?>? Relations;
    public Dictionary<string, object?> Alias = new();
    public Dictionary<string, object?> Transform = new();

    public Point(Dictionary<string, object?>? pointmap)
    {
        if (StructUtils.GetProp(pointmap, "args") is Dictionary<string, object?> am)
        {
            Args = am;
        }
        if (StructUtils.GetProp(pointmap, "rename") is Dictionary<string, object?> rm)
        {
            Rename = rm;
        }
        if (StructUtils.GetProp(pointmap, "method") is string m)
        {
            Method = m;
        }
        if (StructUtils.GetProp(pointmap, "orig") is string o)
        {
            Orig = o;
        }
        if (StructUtils.GetProp(pointmap, "parts") is List<object?> pl)
        {
            Parts = pl;
        }
        if (StructUtils.GetProp(pointmap, "params") is List<object?> pr)
        {
            Params = pr;
        }
        if (StructUtils.GetProp(pointmap, "select") is Dictionary<string, object?> sm)
        {
            Select = sm;
        }
        if (StructUtils.GetProp(pointmap, "active") is bool ab)
        {
            Active = ab;
        }
        if (StructUtils.GetProp(pointmap, "relations") is List<object?> rl)
        {
            Relations = rl;
        }
        if (StructUtils.GetProp(pointmap, "alias") is Dictionary<string, object?> al)
        {
            Alias = al;
        }
        if (StructUtils.GetProp(pointmap, "transform") is Dictionary<string, object?> tf)
        {
            Transform = tf;
        }
    }
}
