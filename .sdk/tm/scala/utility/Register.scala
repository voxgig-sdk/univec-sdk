package SCALAPACKAGE.utility

import SCALAPACKAGE.core.Utility

// Wires the utility implementations onto a Utility instance.
object Register {
  def registerAll(u: Utility): Unit = {
    u.clean = (ctx, v) => Clean.clean(ctx, v)
    u.done = (ctx) => Done.done(ctx)
    u.makeError = (ctx, err) => MakeError.makeError(ctx, err)
    u.featureAdd = (ctx, f) => FeatureAdd.featureAdd(ctx, f)
    u.featureHook = (ctx, name) => FeatureHookUtil.featureHook(ctx, name)
    u.featureInit = (ctx, f) => FeatureInit.featureInit(ctx, f)
    u.fetcher = (ctx, url, fetchdef) => Fetcher.fetcher(ctx, url, fetchdef)
    u.makeFetchDef = (ctx) => MakeFetchDef.makeFetchDef(ctx)
    u.makeContext = (ctxmap, base) => MakeContext.makeContext(ctxmap, base)
    u.makeOptions = (ctx) => MakeOptions.makeOptions(ctx)
    u.makeRequest = (ctx) => MakeRequest.makeRequest(ctx)
    u.makeResponse = (ctx) => MakeResponse.makeResponse(ctx)
    u.makeResult = (ctx) => MakeResult.makeResult(ctx)
    u.makePoint = (ctx) => MakePoint.makePoint(ctx)
    u.makeSpec = (ctx) => MakeSpec.makeSpec(ctx)
    u.makeUrl = (ctx) => MakeUrl.makeUrl(ctx)
    u.param = (ctx, pd) => Param.param(ctx, pd)
    u.prepareAuth = (ctx) => PrepareAuth.prepareAuth(ctx)
    u.prepareBody = (ctx) => PrepareBody.prepareBody(ctx)
    u.prepareHeaders = (ctx) => PrepareHeaders.prepareHeaders(ctx)
    u.prepareMethod = (ctx) => PrepareMethod.prepareMethod(ctx)
    u.prepareParams = (ctx) => PrepareParams.prepareParams(ctx)
    u.preparePath = (ctx) => PreparePath.preparePath(ctx)
    u.prepareQuery = (ctx) => PrepareQuery.prepareQuery(ctx)
    u.graphqlBody = (ctx) => Graphql.graphqlBody(ctx)
    u.graphqlErrors = (ctx) => Graphql.graphqlErrors(ctx)
    u.resultBasic = (ctx) => ResultBasic.resultBasic(ctx)
    u.resultBody = (ctx) => ResultBody.resultBody(ctx)
    u.resultHeaders = (ctx) => ResultHeaders.resultHeaders(ctx)
    u.transformRequest = (ctx) => TransformRequest.transformRequest(ctx)
    u.transformResponse = (ctx) => TransformResponse.transformResponse(ctx)
  }
}
