

const { clean } = require('./CleanUtility')
const { done } = require('./DoneUtility')
const { makeError } = require('./MakeErrorUtility')
const { featureAdd } = require('./FeatureAddUtility')
const { featureHook } = require('./FeatureHookUtility')
const { featureInit } = require('./FeatureInitUtility')
const { fetcher } = require('./FetcherUtility')
const { makeFetchDef } = require('./MakeFetchDefUtility')
const { makeContext } = require('./MakeContextUtility')
const { makeOptions } = require('./MakeOptionsUtility')
const { makeRequest } = require('./MakeRequestUtility')
const { makeResponse } = require('./MakeResponseUtility')
const { makeResult } = require('./MakeResultUtility')
const { makePoint } = require('./MakePointUtility')
const { makeSpec } = require('./MakeSpecUtility')
const { makeUrl } = require('./MakeUrlUtility')
const { param } = require('./ParamUtility')
const { prepareAuth } = require('./PrepareAuthUtility')
const { prepareBody } = require('./PrepareBodyUtility')
const { prepareHeaders } = require('./PrepareHeadersUtility')
const { prepareMethod } = require('./PrepareMethodUtility')
const { prepareParams } = require('./PrepareParamsUtility')
const { preparePath } = require('./PreparePathUtility')
const { prepareQuery } = require('./PrepareQueryUtility')
const { resultBasic } = require('./ResultBasicUtility')
const { resultBody } = require('./ResultBodyUtility')
const { resultHeaders } = require('./ResultHeadersUtility')
const { transformRequest } = require('./TransformRequestUtility')
const { transformResponse } = require('./TransformResponseUtility')

const { StructUtility } = require('./StructUtility')


class Utility {

  clean = clean
  done = done
  makeError = makeError
  featureAdd = featureAdd
  featureHook = featureHook
  featureInit = featureInit
  fetcher = fetcher
  makeFetchDef = makeFetchDef
  makeContext = makeContext
  makeOptions = makeOptions
  makeRequest = makeRequest
  makeResponse = makeResponse
  makeResult = makeResult
  makePoint = makePoint
  makeSpec = makeSpec
  makeUrl = makeUrl
  param = param
  prepareAuth = prepareAuth
  prepareBody = prepareBody
  prepareHeaders = prepareHeaders
  prepareMethod = prepareMethod
  prepareParams = prepareParams
  preparePath = preparePath
  prepareQuery = prepareQuery
  resultBasic = resultBasic
  resultBody = resultBody
  resultHeaders = resultHeaders
  transformRequest = transformRequest
  transformResponse = transformResponse

  struct = new StructUtility()
}


module.exports = {
  Utility
}
