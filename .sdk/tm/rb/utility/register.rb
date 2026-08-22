# Univec SDK utility registration
require_relative '../core/utility_type'
require_relative 'clean'
require_relative 'done'
require_relative 'make_error'
require_relative 'feature_add'
require_relative 'feature_hook'
require_relative 'feature_init'
require_relative 'fetcher'
require_relative 'make_fetch_def'
require_relative 'make_context'
require_relative 'make_options'
require_relative 'make_request'
require_relative 'make_response'
require_relative 'make_result'
require_relative 'make_point'
require_relative 'make_spec'
require_relative 'make_url'
require_relative 'param'
require_relative 'prepare_auth'
require_relative 'prepare_body'
require_relative 'prepare_headers'
require_relative 'prepare_method'
require_relative 'prepare_params'
require_relative 'prepare_path'
require_relative 'prepare_query'
require_relative 'graphql'
require_relative 'result_basic'
require_relative 'result_body'
require_relative 'result_headers'
require_relative 'transform_request'
require_relative 'transform_response'

UnivecUtility.registrar = ->(u) {
  u.clean = UnivecUtilities::Clean
  u.done = UnivecUtilities::Done
  u.make_error = UnivecUtilities::MakeError
  u.feature_add = UnivecUtilities::FeatureAdd
  u.feature_hook = UnivecUtilities::FeatureHook
  u.feature_init = UnivecUtilities::FeatureInit
  u.fetcher = UnivecUtilities::Fetcher
  u.make_fetch_def = UnivecUtilities::MakeFetchDef
  u.make_context = UnivecUtilities::MakeContext
  u.make_options = UnivecUtilities::MakeOptions
  u.make_request = UnivecUtilities::MakeRequest
  u.make_response = UnivecUtilities::MakeResponse
  u.make_result = UnivecUtilities::MakeResult
  u.make_point = UnivecUtilities::MakePoint
  u.make_spec = UnivecUtilities::MakeSpec
  u.make_url = UnivecUtilities::MakeUrl
  u.param = UnivecUtilities::Param
  u.prepare_auth = UnivecUtilities::PrepareAuth
  u.prepare_body = UnivecUtilities::PrepareBody
  u.prepare_headers = UnivecUtilities::PrepareHeaders
  u.prepare_method = UnivecUtilities::PrepareMethod
  u.prepare_params = UnivecUtilities::PrepareParams
  u.prepare_path = UnivecUtilities::PreparePath
  u.prepare_query = UnivecUtilities::PrepareQuery
  u.graphql_body = UnivecUtilities::GraphqlBody
  u.graphql_errors = UnivecUtilities::GraphqlErrors
  u.result_basic = UnivecUtilities::ResultBasic
  u.result_body = UnivecUtilities::ResultBody
  u.result_headers = UnivecUtilities::ResultHeaders
  u.transform_request = UnivecUtilities::TransformRequest
  u.transform_response = UnivecUtilities::TransformResponse
}
