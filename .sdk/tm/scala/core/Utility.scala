package SCALAPACKAGE.core

import java.util.{LinkedHashMap, Map => JMap}

// The utility object: every pipeline step as a replaceable function field,
// mirroring the ts/go utility objects. Features and tests may replace
// individual fields (e.g. wrap `fetcher`) on a per-instance basis.
class Utility private (noregister: Boolean) {

  var clean: CleanFn = null
  var done: CtxFn[Object] = null
  var makeError: MakeErrorFn = null
  var featureAdd: FeatureFn = null
  var featureHook: HookFn = null
  var featureInit: FeatureFn = null
  var fetcher: FetcherFn = null
  var makeFetchDef: CtxFn[JMap[String, Object]] = null
  var makeContext: MakeContextFn = null
  var makeOptions: CtxFn[JMap[String, Object]] = null
  var makeRequest: CtxFn[Response] = null
  var makeResponse: CtxFn[Response] = null
  var makeResult: CtxFn[Result] = null
  var makePoint: CtxFn[JMap[String, Object]] = null
  var makeSpec: CtxFn[Spec] = null
  var makeUrl: CtxFn[String] = null
  var param: ParamFn = null
  var prepareAuth: CtxFn[Spec] = null
  var prepareBody: CtxFn[Object] = null
  var prepareHeaders: CtxFn[JMap[String, Object]] = null
  var prepareMethod: CtxFn[String] = null
  var prepareParams: CtxFn[JMap[String, Object]] = null
  var preparePath: CtxFn[String] = null
  var prepareQuery: CtxFn[JMap[String, Object]] = null
  var graphqlBody: CtxFn[Object] = null
  var graphqlErrors: CtxFn[java.lang.Boolean] = null
  var resultBasic: CtxFn[Result] = null
  var resultBody: CtxFn[Result] = null
  var resultHeaders: CtxFn[Result] = null
  var transformRequest: CtxFn[Object] = null
  var transformResponse: CtxFn[Object] = null
  var custom: JMap[String, Object] = new LinkedHashMap[String, Object]()

  // The struct utility surface, exposed as a member so features/tests can
  // reach the struct functions through the utility object.
  val struct: SCALAPACKAGE.utility.StructUtility.type = SCALAPACKAGE.utility.StructUtility

  def this() = {
    this(false)
    SCALAPACKAGE.utility.Register.registerAll(this)
  }

  // A field-level copy sharing nothing mutable but the function refs.
  def copy(): Utility = {
    val u = new Utility(true)
    u.clean = this.clean
    u.done = this.done
    u.makeError = this.makeError
    u.featureAdd = this.featureAdd
    u.featureHook = this.featureHook
    u.featureInit = this.featureInit
    u.fetcher = this.fetcher
    u.makeFetchDef = this.makeFetchDef
    u.makeContext = this.makeContext
    u.makeOptions = this.makeOptions
    u.makeRequest = this.makeRequest
    u.makeResponse = this.makeResponse
    u.makeResult = this.makeResult
    u.makePoint = this.makePoint
    u.makeSpec = this.makeSpec
    u.makeUrl = this.makeUrl
    u.param = this.param
    u.prepareAuth = this.prepareAuth
    u.prepareBody = this.prepareBody
    u.prepareHeaders = this.prepareHeaders
    u.prepareMethod = this.prepareMethod
    u.prepareParams = this.prepareParams
    u.preparePath = this.preparePath
    u.prepareQuery = this.prepareQuery
    u.graphqlBody = this.graphqlBody
    u.graphqlErrors = this.graphqlErrors
    u.resultBasic = this.resultBasic
    u.resultBody = this.resultBody
    u.resultHeaders = this.resultHeaders
    u.transformRequest = this.transformRequest
    u.transformResponse = this.transformResponse
    u.custom = new LinkedHashMap[String, Object](this.custom)
    u
  }
}
