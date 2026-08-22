package KOTLINPACKAGE.core

import KOTLINPACKAGE.utility.Register

// The transport fetch function: replaceable per-instance so features (retry,
// cache, netsim, proxy, test) can wrap it.
typealias FetcherFn = (Context, String, MutableMap<String, Any?>) -> Any?

/**
 * The utility object: every pipeline step as a replaceable function field,
 * mirroring the ts/go utility objects. Features and tests may replace
 * individual fields (e.g. wrap [fetcher]) on a per-instance basis.
 */
class Utility private constructor(register: Boolean) {

  lateinit var clean: (Context, Any?) -> Any?
  lateinit var done: (Context) -> Any?
  lateinit var makeError: (Context, RuntimeException?) -> Any?
  lateinit var featureAdd: (Context, Feature) -> Unit
  lateinit var featureHook: (Context, String) -> Unit
  lateinit var featureInit: (Context, Feature) -> Unit
  lateinit var fetcher: FetcherFn
  lateinit var makeFetchDef: (Context) -> MutableMap<String, Any?>
  lateinit var makeContext: (MutableMap<String, Any?>?, Context?) -> Context
  lateinit var makeOptions: (Context) -> MutableMap<String, Any?>
  lateinit var makeRequest: (Context) -> Response
  lateinit var makeResponse: (Context) -> Response
  lateinit var makeResult: (Context) -> Result
  lateinit var makePoint: (Context) -> Map<String, Any?>
  lateinit var makeSpec: (Context) -> Spec
  lateinit var makeUrl: (Context) -> String
  lateinit var param: (Context, Any?) -> Any?
  lateinit var prepareAuth: (Context) -> Spec
  lateinit var prepareBody: (Context) -> Any?
  lateinit var prepareHeaders: (Context) -> MutableMap<String, Any?>
  lateinit var prepareMethod: (Context) -> String
  lateinit var prepareParams: (Context) -> MutableMap<String, Any?>
  lateinit var preparePath: (Context) -> String
  lateinit var prepareQuery: (Context) -> MutableMap<String, Any?>
  lateinit var graphqlBody: (Context) -> Any?
  lateinit var graphqlErrors: (Context) -> Boolean
  lateinit var resultBasic: (Context) -> Result
  lateinit var resultBody: (Context) -> Result
  lateinit var resultHeaders: (Context) -> Result
  lateinit var transformRequest: (Context) -> Any?
  lateinit var transformResponse: (Context) -> Any?
  var custom: MutableMap<String, Any?> = linkedMapOf()

  constructor() : this(true)

  init {
    if (register) {
      Register.registerAll(this)
    }
  }

  /** A field-level copy sharing nothing mutable but the function refs. */
  fun copy(): Utility {
    val u = Utility(false)

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

    u.custom = LinkedHashMap(this.custom)

    return u
  }
}
