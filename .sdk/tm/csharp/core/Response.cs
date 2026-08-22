// Univec SDK - transport response wrapper.

using Voxgig.Struct;

namespace UnivecSdk;

public class Response
{
    public int Status = -1;
    public string StatusText = "";
    public object? Headers;
    public Func<object?>? JsonFunc;
    public object? Body;
    public Exception? Err;

    public Response(Dictionary<string, object?>? resmap)
    {
        resmap ??= new Dictionary<string, object?>();

        var s = StructUtils.GetProp(resmap, "status");
        if (s != null)
        {
            Status = Helpers.ToInt(s);
        }

        if (StructUtils.GetProp(resmap, "statusText") is string st)
        {
            StatusText = st;
        }

        Headers = StructUtils.GetProp(resmap, "headers");

        if (StructUtils.GetProp(resmap, "json") is Func<object?> jf)
        {
            JsonFunc = jf;
        }

        Body = StructUtils.GetProp(resmap, "body");

        if (StructUtils.GetProp(resmap, "err") is Exception er)
        {
            Err = er;
        }
    }
}
