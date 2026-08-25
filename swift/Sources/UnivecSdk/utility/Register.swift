// Univec SDK utility: registration - wires every utility implementation
// onto a Utility instance (called by the Utility constructor).

import Foundation

func registerAll(_ u: Utility) {
  u.clean = cleanUtil
  u.done = doneUtil
  u.makeError = makeErrorUtil
  u.featureAdd = featureAddUtil
  u.featureHook = featureHookUtil
  u.featureInit = featureInitUtil
  u.fetcher = fetcherUtil
  u.makeFetchDef = makeFetchDefUtil
  u.makeContext = makeContextUtil
  u.makeOptions = makeOptionsUtil
  u.makeRequest = makeRequestUtil
  u.makeResponse = makeResponseUtil
  u.makeResult = makeResultUtil
  u.makePoint = makePointUtil
  u.makeSpec = makeSpecUtil
  u.makeUrl = makeUrlUtil
  u.param = paramUtil
  u.prepareAuth = prepareAuthUtil
  u.prepareBody = prepareBodyUtil
  u.prepareHeaders = prepareHeadersUtil
  u.prepareMethod = prepareMethodUtil
  u.prepareParams = prepareParamsUtil
  u.preparePath = preparePathUtil
  u.prepareQuery = prepareQueryUtil
  u.graphqlBody = graphqlBodyUtil
  u.graphqlErrors = graphqlErrorsUtil
  u.resultBasic = resultBasicUtil
  u.resultBody = resultBodyUtil
  u.resultHeaders = resultHeadersUtil
  u.transformRequest = transformRequestUtil
  u.transformResponse = transformResponseUtil
}

func makeContextUtil(_ ctxmap: [String: Any?]?, _ basectx: Context?) -> Context {
  return Context(ctxmap, basectx)
}
