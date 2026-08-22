// Univec SDK utility: registration - wires every utility
// implementation onto a Utility instance (called by the Utility
// constructor).

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    public static void RegisterAll(Utility u)
    {
        u.Clean = CleanUtil;
        u.Done = DoneUtil;
        u.MakeError = MakeErrorUtil;
        u.FeatureAdd = FeatureAddUtil;
        u.FeatureHook = FeatureHookUtil;
        u.FeatureInit = FeatureInitUtil;
        u.Fetcher = FetcherUtil;
        u.MakeFetchDef = MakeFetchDefUtil;
        u.MakeContext = MakeContextUtil;
        u.MakeOptions = MakeOptionsUtil;
        u.MakeRequest = MakeRequestUtil;
        u.MakeResponse = MakeResponseUtil;
        u.MakeResult = MakeResultUtil;
        u.MakePoint = MakePointUtil;
        u.MakeSpec = MakeSpecUtil;
        u.MakeUrl = MakeUrlUtil;
        u.Param = ParamUtil;
        u.PrepareAuth = PrepareAuthUtil;
        u.PrepareBody = PrepareBodyUtil;
        u.PrepareHeaders = PrepareHeadersUtil;
        u.PrepareMethod = PrepareMethodUtil;
        u.PrepareParams = PrepareParamsUtil;
        u.PreparePath = PreparePathUtil;
        u.PrepareQuery = PrepareQueryUtil;
        u.GraphqlBody = GraphqlBodyUtil;
        u.GraphqlErrors = GraphqlErrorsUtil;
        u.ResultBasic = ResultBasicUtil;
        u.ResultBody = ResultBodyUtil;
        u.ResultHeaders = ResultHeadersUtil;
        u.TransformRequest = TransformRequestUtil;
        u.TransformResponse = TransformResponseUtil;
    }
}
