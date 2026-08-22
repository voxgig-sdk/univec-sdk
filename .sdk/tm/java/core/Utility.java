package JAVAPACKAGE.core;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The utility object: every pipeline step as a replaceable function field,
 * mirroring the ts/go utility objects. Features and tests may replace
 * individual fields (e.g. wrap {@code fetcher}) on a per-instance basis.
 */
public class Utility {

  @FunctionalInterface
  public interface CtxFn<T> {
    T apply(Context ctx);
  }

  @FunctionalInterface
  public interface CleanFn {
    Object apply(Context ctx, Object val);
  }

  @FunctionalInterface
  public interface MakeErrorFn {
    Object apply(Context ctx, RuntimeException err);
  }

  @FunctionalInterface
  public interface FeatureFn {
    void apply(Context ctx, Feature f);
  }

  @FunctionalInterface
  public interface HookFn {
    void apply(Context ctx, String name);
  }

  @FunctionalInterface
  public interface FetcherFn {
    Object fetch(Context ctx, String fullurl, Map<String, Object> fetchdef);
  }

  @FunctionalInterface
  public interface MakeContextFn {
    Context apply(Map<String, Object> ctxmap, Context basectx);
  }

  @FunctionalInterface
  public interface ParamFn {
    Object apply(Context ctx, Object paramdef);
  }

  public CleanFn clean;
  public CtxFn<Object> done;
  public MakeErrorFn makeError;
  public FeatureFn featureAdd;
  public HookFn featureHook;
  public FeatureFn featureInit;
  public FetcherFn fetcher;
  public CtxFn<Map<String, Object>> makeFetchDef;
  public MakeContextFn makeContext;
  public CtxFn<Map<String, Object>> makeOptions;
  public CtxFn<Response> makeRequest;
  public CtxFn<Response> makeResponse;
  public CtxFn<Result> makeResult;
  public CtxFn<Map<String, Object>> makePoint;
  public CtxFn<Spec> makeSpec;
  public CtxFn<String> makeUrl;
  public ParamFn param;
  public CtxFn<Spec> prepareAuth;
  public CtxFn<Object> prepareBody;
  public CtxFn<Map<String, Object>> prepareHeaders;
  public CtxFn<String> prepareMethod;
  public CtxFn<Map<String, Object>> prepareParams;
  public CtxFn<String> preparePath;
  public CtxFn<Map<String, Object>> prepareQuery;
  public CtxFn<Object> graphqlBody;
  public CtxFn<Result> graphqlErrors;
  public CtxFn<Result> resultBasic;
  public CtxFn<Result> resultBody;
  public CtxFn<Result> resultHeaders;
  public CtxFn<Object> transformRequest;
  public CtxFn<Object> transformResponse;
  public Map<String, Object> custom = new LinkedHashMap<>();

  public Utility() {
    JAVAPACKAGE.utility.Register.registerAll(this);
  }

  private Utility(boolean noregister) {}

  /** A field-level copy sharing nothing mutable but the function refs. */
  public Utility copy() {
    Utility u = new Utility(true);

    u.clean = this.clean;
    u.done = this.done;
    u.makeError = this.makeError;
    u.featureAdd = this.featureAdd;
    u.featureHook = this.featureHook;
    u.featureInit = this.featureInit;
    u.fetcher = this.fetcher;
    u.makeFetchDef = this.makeFetchDef;
    u.makeContext = this.makeContext;
    u.makeOptions = this.makeOptions;
    u.makeRequest = this.makeRequest;
    u.makeResponse = this.makeResponse;
    u.makeResult = this.makeResult;
    u.makePoint = this.makePoint;
    u.makeSpec = this.makeSpec;
    u.makeUrl = this.makeUrl;
    u.param = this.param;
    u.prepareAuth = this.prepareAuth;
    u.prepareBody = this.prepareBody;
    u.prepareHeaders = this.prepareHeaders;
    u.prepareMethod = this.prepareMethod;
    u.prepareParams = this.prepareParams;
    u.preparePath = this.preparePath;
    u.prepareQuery = this.prepareQuery;
    u.graphqlBody = this.graphqlBody;
    u.graphqlErrors = this.graphqlErrors;
    u.resultBasic = this.resultBasic;
    u.resultBody = this.resultBody;
    u.resultHeaders = this.resultHeaders;
    u.transformRequest = this.transformRequest;
    u.transformResponse = this.transformResponse;

    u.custom = new LinkedHashMap<>(this.custom);

    return u;
  }
}
