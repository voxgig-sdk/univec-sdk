// Univec SDK - utility object: the pluggable set of pipeline functions.
// Every pipeline step is a closure field so features (and custom utilities)
// can wrap or replace behaviour per client instance.

import Foundation

public final class Utility {
  public var clean: ((Context, Value) -> Value)!
  public var done: ((Context) throws -> Value)!
  public var makeError: ((Context, Error?) throws -> Value)!
  public var featureAdd: ((Context, BaseFeature) -> Void)!
  public var featureHook: ((Context, String) -> Void)!
  public var featureInit: ((Context, BaseFeature) -> Void)!
  public var fetcher: FetcherFunc!
  public var makeFetchDef: ((Context) throws -> VMap)!
  public var makeContext: (([String: Any?]?, Context?) -> Context)!
  public var makeOptions: ((Context) -> VMap)!
  public var makeRequest: ((Context) throws -> Response)!
  public var makeResponse: ((Context) throws -> Response)!
  public var makeResult: ((Context) throws -> Result)!
  public var makePoint: ((Context) throws -> VMap?)!
  public var makeSpec: ((Context) throws -> Spec)!
  public var makeUrl: ((Context) throws -> String)!
  public var param: ((Context, Value) -> Value)!
  public var prepareAuth: ((Context) throws -> Spec)!
  public var prepareBody: ((Context) -> Value)!
  public var prepareHeaders: ((Context) -> VMap)!
  public var prepareMethod: ((Context) -> String)!
  public var prepareParams: ((Context) -> VMap)!
  public var preparePath: ((Context) -> String)!
  public var prepareQuery: ((Context) -> VMap)!
  public var graphqlBody: ((Context) -> Value)!
  public var graphqlErrors: ((Context) -> Bool)!
  public var resultBasic: ((Context) -> Result)!
  public var resultBody: ((Context) -> Result)!
  public var resultHeaders: ((Context) -> Result)!
  public var transformRequest: ((Context) -> Value)!
  public var transformResponse: ((Context) -> Value)!
  public var custom: [String: Any?] = [:]

  public init() {
    registerAll(self)
  }

  private init(noregister: Bool) {}

  // A shallow copy sharing the same closures but with an independent Custom
  // map, so per-entity utility views can diverge safely.
  public static func copy(_ src: Utility) -> Utility {
    let u = Utility(noregister: true)
    u.clean = src.clean
    u.done = src.done
    u.makeError = src.makeError
    u.featureAdd = src.featureAdd
    u.featureHook = src.featureHook
    u.featureInit = src.featureInit
    u.fetcher = src.fetcher
    u.makeFetchDef = src.makeFetchDef
    u.makeContext = src.makeContext
    u.makeOptions = src.makeOptions
    u.makeRequest = src.makeRequest
    u.makeResponse = src.makeResponse
    u.makeResult = src.makeResult
    u.makePoint = src.makePoint
    u.makeSpec = src.makeSpec
    u.makeUrl = src.makeUrl
    u.param = src.param
    u.prepareAuth = src.prepareAuth
    u.prepareBody = src.prepareBody
    u.prepareHeaders = src.prepareHeaders
    u.prepareMethod = src.prepareMethod
    u.prepareParams = src.prepareParams
    u.preparePath = src.preparePath
    u.prepareQuery = src.prepareQuery
    u.graphqlBody = src.graphqlBody
    u.graphqlErrors = src.graphqlErrors
    u.resultBasic = src.resultBasic
    u.resultBody = src.resultBody
    u.resultHeaders = src.resultHeaders
    u.transformRequest = src.transformRequest
    u.transformResponse = src.transformResponse
    u.custom = src.custom
    return u
  }
}
