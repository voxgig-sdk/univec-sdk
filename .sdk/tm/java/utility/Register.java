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

  /**
   * Replaces one utility member from {@code options.utility}, matching the ts
   * reference: a key naming a real utility member REPLACES it, and any other
   * key is attached as a custom extra.
   *
   * <p>Without this the override was a no-op here. {@code makeOptions} put
   * every entry in {@code u.custom}, which nothing reads, so a caller passing
   * {@code utility: {"fetcher": myTransport}} - the documented way to script
   * the transport, and the seam the shared feature corpus runs on - was
   * silently ignored while ts and js honoured it. The custom-utility test did
   * not catch it because it asserted the side map rather than the behaviour.
   *
   * <p>Returns false when the key names no member, or when the value is not
   * that member's interface; the caller then keeps it in {@code custom}. A
   * wrong shape is deliberately NOT an error: ts attaches whatever it is
   * given, so a typed port that rejected it outright would diverge in the
   * other direction.
   *
   * <p>Erasure limits how much of a shape java can check: the {@code CtxFn}
   * members all erase to the same interface, so the key decides which field a
   * {@code CtxFn} lands on and the cast is unchecked. That is the same
   * guarantee the dynamic donors give.
   *
   * <p>Keep this list in step with registerAll above - a utility added to one
   * and not the other is overridable in ts and not here, which is the
   * divergence this exists to remove.
   */
  @SuppressWarnings({"unchecked"})
  public static boolean overrideUtil(Utility u, String key, Object val) {
    switch (key) {
      case "clean":
        if (val instanceof Utility.CleanFn) { u.clean = (Utility.CleanFn) val; return true; }
        return false;
      case "makeError":
        if (val instanceof Utility.MakeErrorFn) { u.makeError = (Utility.MakeErrorFn) val; return true; }
        return false;
      case "featureAdd":
        if (val instanceof Utility.FeatureFn) { u.featureAdd = (Utility.FeatureFn) val; return true; }
        return false;
      case "featureHook":
        if (val instanceof Utility.HookFn) { u.featureHook = (Utility.HookFn) val; return true; }
        return false;
      case "featureInit":
        if (val instanceof Utility.FeatureFn) { u.featureInit = (Utility.FeatureFn) val; return true; }
        return false;
      case "fetcher":
        if (val instanceof Utility.FetcherFn) { u.fetcher = (Utility.FetcherFn) val; return true; }
        return false;
      case "makeContext":
        if (val instanceof Utility.MakeContextFn) { u.makeContext = (Utility.MakeContextFn) val; return true; }
        return false;
      case "param":
        if (val instanceof Utility.ParamFn) { u.param = (Utility.ParamFn) val; return true; }
        return false;
      default:
        break;
    }

    if (!(val instanceof Utility.CtxFn)) {
      return false;
    }
    Utility.CtxFn<Object> fn = (Utility.CtxFn<Object>) val;

    switch (key) {
      case "done": u.done = fn; return true;
      case "makeFetchDef": u.makeFetchDef = (Utility.CtxFn) fn; return true;
      case "makeOptions": u.makeOptions = (Utility.CtxFn) fn; return true;
      case "makeRequest": u.makeRequest = (Utility.CtxFn) fn; return true;
      case "makeResponse": u.makeResponse = (Utility.CtxFn) fn; return true;
      case "makeResult": u.makeResult = (Utility.CtxFn) fn; return true;
      case "makePoint": u.makePoint = (Utility.CtxFn) fn; return true;
      case "makeSpec": u.makeSpec = (Utility.CtxFn) fn; return true;
      case "makeUrl": u.makeUrl = (Utility.CtxFn) fn; return true;
      case "prepareAuth": u.prepareAuth = (Utility.CtxFn) fn; return true;
      case "prepareBody": u.prepareBody = fn; return true;
      case "prepareHeaders": u.prepareHeaders = (Utility.CtxFn) fn; return true;
      case "prepareMethod": u.prepareMethod = (Utility.CtxFn) fn; return true;
      case "prepareParams": u.prepareParams = (Utility.CtxFn) fn; return true;
      case "preparePath": u.preparePath = (Utility.CtxFn) fn; return true;
      case "prepareQuery": u.prepareQuery = (Utility.CtxFn) fn; return true;
      case "graphqlBody": u.graphqlBody = fn; return true;
      case "graphqlErrors": u.graphqlErrors = (Utility.CtxFn) fn; return true;
      case "resultBasic": u.resultBasic = (Utility.CtxFn) fn; return true;
      case "resultBody": u.resultBody = (Utility.CtxFn) fn; return true;
      case "resultHeaders": u.resultHeaders = (Utility.CtxFn) fn; return true;
      case "transformRequest": u.transformRequest = fn; return true;
      case "transformResponse": u.transformResponse = fn; return true;
      default: return false;
    }
  }
}
