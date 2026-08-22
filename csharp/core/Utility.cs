// Univec SDK - utility object: the pluggable set of pipeline functions.
// Every pipeline step is a delegate field so features (and custom utilities)
// can wrap or replace behaviour per client instance.

namespace UnivecSdk;

public class Utility
{
    public Func<Context, object?, object?> Clean = null!;
    public Func<Context, object?> Done = null!;
    public Func<Context, Exception?, object?> MakeError = null!;
    public Action<Context, Feature.BaseFeature> FeatureAdd = null!;
    public Action<Context, string> FeatureHook = null!;
    public Action<Context, Feature.BaseFeature> FeatureInit = null!;
    public FetcherFunc Fetcher = null!;
    public Func<Context, Dictionary<string, object?>> MakeFetchDef = null!;
    public Func<Dictionary<string, object?>?, Context?, Context> MakeContext = null!;
    public Func<Context, Dictionary<string, object?>> MakeOptions = null!;
    public Func<Context, Response> MakeRequest = null!;
    public Func<Context, Response> MakeResponse = null!;
    public Func<Context, Result> MakeResult = null!;
    public Func<Context, Dictionary<string, object?>?> MakePoint = null!;
    public Func<Context, Spec> MakeSpec = null!;
    public Func<Context, string> MakeUrl = null!;
    public Func<Context, object?, object?> Param = null!;
    public Func<Context, Spec> PrepareAuth = null!;
    public Func<Context, object?> PrepareBody = null!;
    public Func<Context, Dictionary<string, object?>> PrepareHeaders = null!;
    public Func<Context, string> PrepareMethod = null!;
    public Func<Context, Dictionary<string, object?>> PrepareParams = null!;
    public Func<Context, string> PreparePath = null!;
    public Func<Context, Dictionary<string, object?>> PrepareQuery = null!;
    public Func<Context, object?> GraphqlBody = null!;
    public Func<Context, bool> GraphqlErrors = null!;
    public Func<Context, Result> ResultBasic = null!;
    public Func<Context, Result> ResultBody = null!;
    public Func<Context, Result> ResultHeaders = null!;
    public Func<Context, object?> TransformRequest = null!;
    public Func<Context, object?> TransformResponse = null!;
    public Dictionary<string, object?> Custom = new();

    public Utility()
    {
        Util.SdkUtility.RegisterAll(this);
    }

    private Utility(bool _noregister)
    {
    }

    // A shallow copy sharing the same delegates but with an independent
    // Custom map, so per-entity utility views can diverge safely.
    public static Utility Copy(Utility src)
    {
        var u = new Utility(true)
        {
            Clean = src.Clean,
            Done = src.Done,
            MakeError = src.MakeError,
            FeatureAdd = src.FeatureAdd,
            FeatureHook = src.FeatureHook,
            FeatureInit = src.FeatureInit,
            Fetcher = src.Fetcher,
            MakeFetchDef = src.MakeFetchDef,
            MakeContext = src.MakeContext,
            MakeOptions = src.MakeOptions,
            MakeRequest = src.MakeRequest,
            MakeResponse = src.MakeResponse,
            MakeResult = src.MakeResult,
            MakePoint = src.MakePoint,
            MakeSpec = src.MakeSpec,
            MakeUrl = src.MakeUrl,
            Param = src.Param,
            PrepareAuth = src.PrepareAuth,
            PrepareBody = src.PrepareBody,
            PrepareHeaders = src.PrepareHeaders,
            PrepareMethod = src.PrepareMethod,
            PrepareParams = src.PrepareParams,
            PreparePath = src.PreparePath,
            PrepareQuery = src.PrepareQuery,
            GraphqlBody = src.GraphqlBody,
            GraphqlErrors = src.GraphqlErrors,
            ResultBasic = src.ResultBasic,
            ResultBody = src.ResultBody,
            ResultHeaders = src.ResultHeaders,
            TransformRequest = src.TransformRequest,
            TransformResponse = src.TransformResponse,
            Custom = new Dictionary<string, object?>(src.Custom),
        };
        return u;
    }
}
