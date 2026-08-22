package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Utility

/** Wires the utility implementations onto a Utility instance. */
object Register {

  fun registerAll(u: Utility) {
    u.clean = ::clean
    u.done = ::done
    u.makeError = ::makeError
    u.featureAdd = ::featureAdd
    u.featureHook = ::featureHook
    u.featureInit = ::featureInit
    u.fetcher = ::fetcher
    u.makeFetchDef = ::makeFetchDef
    u.makeContext = ::makeContext
    u.makeOptions = ::makeOptions
    u.makeRequest = ::makeRequest
    u.makeResponse = ::makeResponse
    u.makeResult = ::makeResult
    u.makePoint = ::makePoint
    u.makeSpec = ::makeSpec
    u.makeUrl = ::makeUrl
    u.param = ::param
    u.prepareAuth = ::prepareAuth
    u.prepareBody = ::prepareBody
    u.prepareHeaders = ::prepareHeaders
    u.prepareMethod = ::prepareMethod
    u.prepareParams = ::prepareParams
    u.preparePath = ::preparePath
    u.prepareQuery = ::prepareQuery
    u.graphqlBody = ::graphqlBody
    u.graphqlErrors = ::graphqlErrors
    u.resultBasic = ::resultBasic
    u.resultBody = ::resultBody
    u.resultHeaders = ::resultHeaders
    u.transformRequest = ::transformRequest
    u.transformResponse = ::transformResponse
  }
}
