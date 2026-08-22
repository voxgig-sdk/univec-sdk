// Univec SDK utility: makeRequest - build the fetch definition and
// call the transport. Transport failures are carried on the returned
// Response (Err) rather than thrown, mirroring the go pipeline.

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static Response MakeRequestUtil(Context ctx)
    {
        if (ctx.Out.TryGetValue("request", out var outReq) && outReq is Response cached)
        {
            return cached;
        }

        var spec = ctx.Spec;
        var utility = ctx.Utility!;

        var response = new Response(new Dictionary<string, object?>());
        var result = new Result(new Dictionary<string, object?>());
        ctx.Result = result;

        if (spec == null)
        {
            throw ctx.MakeError("request_no_spec",
                "Expected context spec property to be defined.");
        }

        Dictionary<string, object?> fetchdef;
        try
        {
            fetchdef = utility.MakeFetchDef(ctx);
        }
        catch (Exception err)
        {
            response.Err = err;
            ctx.Response = response;
            spec.Step = "postrequest";
            return response;
        }

        if (ctx.Ctrl.Explain != null)
        {
            ctx.Ctrl.Explain["fetchdef"] = fetchdef;
        }

        spec.Step = "prerequest";

        var url = fetchdef.TryGetValue("url", out var u) ? u as string ?? "" : "";

        object? fetched = null;
        Exception? fetchErr = null;
        try
        {
            fetched = utility.Fetcher(ctx, url, fetchdef);
        }
        catch (Exception ex)
        {
            fetchErr = ex;
        }

        if (fetchErr != null)
        {
            response.Err = fetchErr;
        }
        else if (fetched == null)
        {
            response = new Response(new Dictionary<string, object?>
            {
                ["err"] = ctx.MakeError("request_no_response", "response: undefined"),
            });
        }
        else if (fetched is Dictionary<string, object?> fm)
        {
            response = new Response(fm);
        }
        else
        {
            response.Err = ctx.MakeError("request_invalid_response", "response: invalid type");
        }

        spec.Step = "postrequest";
        ctx.Response = response;

        return response;
    }
}
