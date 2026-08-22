// Univec SDK - operation result.

using Voxgig.Struct;

namespace UnivecSdk;

public class Result
{
    public bool Ok;
    public int Status = -1;
    public string StatusText = "";
    public Dictionary<string, object?> Headers = new();
    public object? Body;
    public Exception? Err;
    public object? Resdata;
    public Dictionary<string, object?>? Resmatch;

    // Feature extensions: pagination signals (paging feature) and the
    // incremental item iterator (streaming feature).
    public Dictionary<string, object?>? Paging;
    public bool Streaming;
    public Func<IEnumerable<object?>>? Stream;

    public Result(Dictionary<string, object?>? resmap)
    {
        resmap ??= new Dictionary<string, object?>();

        if (StructUtils.GetProp(resmap, "ok") is bool b)
        {
            Ok = b;
        }

        var s = StructUtils.GetProp(resmap, "status");
        if (s != null)
        {
            Status = Helpers.ToInt(s);
        }

        if (StructUtils.GetProp(resmap, "statusText") is string st)
        {
            StatusText = st;
        }

        if (StructUtils.GetProp(resmap, "headers") is Dictionary<string, object?> hm)
        {
            Headers = hm;
        }

        Body = StructUtils.GetProp(resmap, "body");

        if (StructUtils.GetProp(resmap, "err") is Exception er)
        {
            Err = er;
        }

        Resdata = StructUtils.GetProp(resmap, "resdata");

        if (StructUtils.GetProp(resmap, "resmatch") is Dictionary<string, object?> rmm)
        {
            Resmatch = rmm;
        }
    }
}
