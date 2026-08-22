package JAVAPACKAGE.utility;

import JAVAPACKAGE.core.Utility;

/** Wires the utility implementations onto a Utility instance. */
public final class Register {

  private Register() {}

  public static void registerAll(Utility u) {
    u.clean = Clean::clean;
    u.done = Done::done;
    u.makeError = MakeError::makeError;
    u.featureAdd = FeatureAdd::featureAdd;
    u.featureHook = FeatureHookUtil::featureHook;
    u.featureInit = FeatureInit::featureInit;
    u.fetcher = Fetcher::fetcher;
    u.makeFetchDef = MakeFetchDef::makeFetchDef;
    u.makeContext = MakeContext::makeContext;
    u.makeOptions = MakeOptions::makeOptions;
    u.makeRequest = MakeRequest::makeRequest;
    u.makeResponse = MakeResponse::makeResponse;
    u.makeResult = MakeResult::makeResult;
    u.makePoint = MakePoint::makePoint;
    u.makeSpec = MakeSpec::makeSpec;
    u.makeUrl = MakeUrl::makeUrl;
    u.param = Param::param;
    u.prepareAuth = PrepareAuth::prepareAuth;
    u.prepareBody = PrepareBody::prepareBody;
    u.prepareHeaders = PrepareHeaders::prepareHeaders;
    u.prepareMethod = PrepareMethod::prepareMethod;
    u.prepareParams = PrepareParams::prepareParams;
    u.preparePath = PreparePath::preparePath;
    u.prepareQuery = PrepareQuery::prepareQuery;
    u.graphqlBody = Graphql::graphqlBody;
    u.graphqlErrors = Graphql::graphqlErrors;
    u.resultBasic = ResultBasic::resultBasic;
    u.resultBody = ResultBody::resultBody;
    u.resultHeaders = ResultHeaders::resultHeaders;
    u.transformRequest = TransformRequest::transformRequest;
    u.transformResponse = TransformResponse::transformResponse;
  }
}
