// Univec SDK - resolved operation definition.

using Voxgig.Struct;

namespace UnivecSdk;

public class Operation
{
    public string Entity = "_";
    public string Name = "_";
    public string Input = "_";
    public List<Dictionary<string, object?>> Points = new();
    public Dictionary<string, object?>? Alias;

    public Operation(Dictionary<string, object?> opmap)
    {
        if (StructUtils.GetProp(opmap, "entity") is string entity && entity != "")
        {
            Entity = entity;
        }
        if (StructUtils.GetProp(opmap, "name") is string name && name != "")
        {
            Name = name;
        }
        if (StructUtils.GetProp(opmap, "input") is string input && input != "")
        {
            Input = input;
        }

        var rawPoints = StructUtils.GetProp(opmap, "points");
        if (rawPoints is List<object?> tlist)
        {
            foreach (var t in tlist)
            {
                if (t is Dictionary<string, object?> tm)
                {
                    Points.Add(tm);
                }
            }
        }
        else if (rawPoints is List<Dictionary<string, object?>> mlist)
        {
            Points = mlist;
        }

        if (StructUtils.GetProp(opmap, "alias") is Dictionary<string, object?> am)
        {
            Alias = am;
        }
    }
}
