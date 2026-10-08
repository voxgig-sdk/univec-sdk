package JAVAPACKAGE.sdktest;

// Direct unit tests for the operation-pipeline utilities. The generated
// entity tests exercise the happy path; these drive the error and edge
// branches (missing spec/response/result, 4xx handling, transport
// failures, feature add semantics, auth header shaping) that a normal
// success-path op never reaches. All utilities are reached through the
// client utility, so this suite is API-agnostic. Mirrors
// tm/go/test/pipeline_test.go.

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import static JAVAPACKAGE.sdktest.FeatureHarness.fhErrCode;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhMap;
import static JAVAPACKAGE.sdktest.FeatureHarness.fhResponse;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

import org.junit.jupiter.api.Test;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Entity;
import JAVAPACKAGE.core.UnivecSDK;
import JAVAPACKAGE.core.Response;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.SdkError;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.feature.BaseFeature;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
public class PipelineTest {

  // plClient builds a client + isolated utility for pipeline utility tests.
  static UnivecSDK plClient(Map<String, Object> sdkopts) {
    return UnivecSDK.testSDK(null, sdkopts);
  }

  static Context plCtx(UnivecSDK client, Utility utility, Map<String, Object> ctrl) {
    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("opname", "load");
    ctxmap.put("client", client);
    ctxmap.put("utility", utility);
    if (ctrl != null) {
      ctxmap.put("ctrl", ctrl);
    }
    return utility.makeContext.apply(ctxmap, client.getRootCtx());
  }

  // --- feature order (PR #2) ----------------------------------------------

  // resolveOpts runs makeOptions over an options.feature value (map or list)
  // and returns the derived options so __derived__.featureorder can be
  // asserted.
  static Map<String, Object> resolveOpts(Object feature) {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();
    Map<String, Object> options = new LinkedHashMap<>();
    options.put("feature", feature);
    Map<String, Object> cfg = new LinkedHashMap<>();
    cfg.put("options", new LinkedHashMap<>());
    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("client", client);
    ctxmap.put("utility", utility);
    ctxmap.put("options", options);
    ctxmap.put("config", cfg);
    Context ctx = utility.makeContext.apply(ctxmap, client.getRootCtx());
    return utility.makeOptions.apply(ctx);
  }

  static String featureOrder(Map<String, Object> opts) {
    Object raw = Struct.getpath(opts, List.of("__derived__", "featureorder"));
    List<String> names = new ArrayList<>();
    if (raw instanceof List) {
      for (Object o : (List<Object>) raw) {
        names.add(o instanceof String ? (String) o : "");
      }
    }
    return String.join(",", names);
  }

  @Test
  void featureOrderMapIsTestFirst() {
    Map<String, Object> metrics = new LinkedHashMap<>();
    metrics.put("active", true);
    Map<String, Object> test = new LinkedHashMap<>();
    test.put("active", true);
    Map<String, Object> feature = new LinkedHashMap<>();
    feature.put("metrics", metrics);
    feature.put("test", test);
    assertEquals("test,metrics", featureOrder(resolveOpts(feature)));
  }

  @Test
  void featureOrderArrayPreservesExplicitOrder() {
    Map<String, Object> m1 = new LinkedHashMap<>();
    m1.put("name", "metrics");
    m1.put("active", true);
    Map<String, Object> m2 = new LinkedHashMap<>();
    m2.put("name", "test");
    m2.put("active", true);
    List<Object> feature = new ArrayList<>();
    feature.add(m1);
    feature.add(m2);
    Map<String, Object> o = resolveOpts(feature);
    assertEquals("metrics,test", featureOrder(o));
    // The list is normalized to a map for merge/init; opts are preserved.
    assertEquals(Boolean.TRUE,
        Struct.getpath(o, List.of("feature", "metrics", "active")));
    assertEquals(Boolean.TRUE,
        Struct.getpath(o, List.of("feature", "test", "active")));
  }

  @Test
  void featureOrderMapNoTestIsSorted() {
    Map<String, Object> retry = new LinkedHashMap<>();
    retry.put("active", true);
    Map<String, Object> cache = new LinkedHashMap<>();
    cache.put("active", true);
    Map<String, Object> feature = new LinkedHashMap<>();
    feature.put("retry", retry);
    feature.put("cache", cache);
    assertEquals("cache,retry", featureOrder(resolveOpts(feature)));
  }

  // plEntity is a minimal fake entity for the list-wrap test.
  static final class PlEntity implements Entity {
    final String name;
    final List<Object> made;

    PlEntity(String name, List<Object> made) {
      this.name = name;
      this.made = made;
    }

    @Override
    public String getName() {
      return name;
    }

    @Override
    public Entity make() {
      return new PlEntity(name, made);
    }

    @Override
    public Object data(Object... args) {
      if (args.length > 0 && args[0] != null) {
        made.add(args[0]);
      }
      return null;
    }

    @Override
    public Object match(Object... args) {
      return null;
    }
  }

  static String errCodeOf(Runnable r) {
    try {
      r.run();
      return null;
    }
    catch (SdkError e) {
      return e.code;
    }
  }

  static Map<String, Object> stepSpecMap() {
    Map<String, Object> m = new LinkedHashMap<>();
    m.put("step", "s");
    return m;
  }

  // --- makeResponse ---------------------------------------------------------

  @Test
  public void makeResponse_guardsMissingSpecResponseResult() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, null);
    ctx.spec = null;
    ctx.response = new Response(new LinkedHashMap<>());
    ctx.result = new Result(new LinkedHashMap<>());
    final Context c1 = ctx;
    assertEquals("response_no_spec", errCodeOf(() -> utility.makeResponse.apply(c1)));

    ctx = plCtx(client, utility, null);
    ctx.spec = new Spec(stepSpecMap());
    ctx.response = null;
    ctx.result = new Result(new LinkedHashMap<>());
    final Context c2 = ctx;
    assertEquals("response_no_response", errCodeOf(() -> utility.makeResponse.apply(c2)));

    ctx = plCtx(client, utility, null);
    ctx.spec = new Spec(stepSpecMap());
    ctx.response = new Response(new LinkedHashMap<>());
    ctx.result = null;
    final Context c3 = ctx;
    assertEquals("response_no_result", errCodeOf(() -> utility.makeResponse.apply(c3)));
  }

  @Test
  public void makeResponse_4xxSetsResultErrAndCopiesHeaders() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, null);
    ctx.spec = new Spec(stepSpecMap());
    ctx.response = new Response(fhResponse(404, null, fhMap("x-a", "1")));
    ctx.result = new Result(new LinkedHashMap<>());
    utility.makeResponse.apply(ctx);
    assertNotNull(ctx.result.err, "expected result.err set on 4xx");
    assertEquals(404, ctx.result.status);
    assertEquals("1", ctx.result.headers.get("x-a"));
  }

  @Test
  public void makeResponse_2xxParsesBodyAndMarksOk() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, null);
    ctx.spec = new Spec(stepSpecMap());
    ctx.response = new Response(fhResponse(200, fhMap("v", 1), null));
    ctx.result = new Result(new LinkedHashMap<>());
    utility.makeResponse.apply(ctx);
    assertTrue(ctx.result.ok, "expected ok result");
    Map<String, Object> body = (Map<String, Object>) ctx.result.body;
    assertNotNull(body, "expected parsed body");
    assertEquals(1, body.get("v"));
  }

  @Test
  public void makeResponse_recordsToCtrlExplain() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, fhMap("explain", new LinkedHashMap<>()));
    ctx.spec = new Spec(stepSpecMap());
    ctx.response = new Response(fhResponse(200, fhMap("v", 2), null));
    ctx.result = new Result(new LinkedHashMap<>());
    utility.makeResponse.apply(ctx);
    assertNotNull(ctx.ctrl.explain.get("result"), "expected explain.result recorded");
  }

  // --- makeResult -----------------------------------------------------------

  @Test
  public void makeResult_guardsMissingSpecResult() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, null);
    ctx.spec = null;
    ctx.result = new Result(new LinkedHashMap<>());
    final Context c1 = ctx;
    assertEquals("result_no_spec", errCodeOf(() -> utility.makeResult.apply(c1)));

    ctx = plCtx(client, utility, null);
    ctx.spec = new Spec(stepSpecMap());
    ctx.result = null;
    final Context c2 = ctx;
    assertEquals("result_no_result", errCodeOf(() -> utility.makeResult.apply(c2)));
  }

  @Test
  public void makeResult_listOpWrapsResdataIntoEntities() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    List<Object> made = new ArrayList<>();
    Context ctx = plCtx(client, utility, null);
    Map<String, Object> opdef = new LinkedHashMap<>();
    opdef.put("entity", "x");
    opdef.put("name", "list");
    ctx.op = new JAVAPACKAGE.core.Operation(opdef);
    ctx.entity = new PlEntity("x", made);
    ctx.spec = new Spec(stepSpecMap());
    Map<String, Object> resmap = new LinkedHashMap<>();
    List<Object> resdata = new ArrayList<>();
    resdata.add(fhMap("a", 1));
    resdata.add(fhMap("a", 2));
    resmap.put("resdata", resdata);
    ctx.result = new Result(resmap);

    Result result = utility.makeResult.apply(ctx);
    List<Object> wrapped = (List<Object>) result.resdata;
    assertEquals(2, wrapped.size(), "expected 2 wrapped entities");
    assertEquals(2, made.size(), "expected 2 data() calls");
  }

  @Test
  public void makeResult_emptyListYieldsEmptyResdata() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    List<Object> made = new ArrayList<>();
    Context ctx = plCtx(client, utility, null);
    Map<String, Object> opdef = new LinkedHashMap<>();
    opdef.put("entity", "x");
    opdef.put("name", "list");
    ctx.op = new JAVAPACKAGE.core.Operation(opdef);
    ctx.entity = new PlEntity("x", made);
    ctx.spec = new Spec(stepSpecMap());
    Map<String, Object> resmap = new LinkedHashMap<>();
    resmap.put("resdata", new ArrayList<>());
    ctx.result = new Result(resmap);

    Result result = utility.makeResult.apply(ctx);
    assertTrue(result.resdata instanceof List, "expected list resdata");
    assertEquals(0, ((List<Object>) result.resdata).size());
  }

  // --- makeRequest ----------------------------------------------------------

  static Spec reqSpec() {
    Map<String, Object> m = new LinkedHashMap<>();
    m.put("base", "http://h");
    m.put("path", "a");
    m.put("method", "GET");
    m.put("headers", new LinkedHashMap<>());
    m.put("step", "s");
    return new Spec(m);
  }

  @Test
  public void makeRequest_guardsMissingSpec() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();
    utility.fetcher = (ctx, url, fetchdef) -> fhResponse(200, null, null);

    Context ctx = plCtx(client, utility, null);
    ctx.spec = null;
    assertEquals("request_no_spec", errCodeOf(() -> utility.makeRequest.apply(ctx)));
  }

  @Test
  public void makeRequest_transportErrorCarriedOnResponse() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();
    utility.fetcher = (ctx, url, fetchdef) -> {
      throw ctx.makeError("boom", "boom");
    };

    Context ctx = plCtx(client, utility, null);
    ctx.spec = reqSpec();
    Response resp = utility.makeRequest.apply(ctx);
    assertNotNull(resp.err, "expected transport error carried");
    assertEquals("boom", fhErrCode(resp.err));
  }

  @Test
  public void makeRequest_nilTransportResultBecomesResponseError() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();
    utility.fetcher = (ctx, url, fetchdef) -> null;

    Context ctx = plCtx(client, utility, null);
    ctx.spec = reqSpec();
    Response resp = utility.makeRequest.apply(ctx);
    assertNotNull(resp.err, "expected response error for nil transport result");
  }

  @Test
  public void makeRequest_normalTransportResponseWrapped() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();
    utility.fetcher = (ctx, url, fetchdef) -> fhResponse(200, fhMap("a", 1), null);

    Context ctx = plCtx(client, utility, null);
    ctx.spec = reqSpec();
    Response resp = utility.makeRequest.apply(ctx);
    assertEquals(200, resp.status);
  }

  @Test
  public void makeRequest_recordsFetchdefToCtrlExplain() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();
    utility.fetcher = (ctx, url, fetchdef) -> fhResponse(200, null, null);

    Context ctx = plCtx(client, utility, fhMap("explain", new LinkedHashMap<>()));
    ctx.spec = reqSpec();
    utility.makeRequest.apply(ctx);
    assertNotNull(ctx.ctrl.explain.get("fetchdef"), "expected explain.fetchdef recorded");
  }

  // --- done / makeError -------------------------------------------------------

  @Test
  public void done_returnsResdataOnSuccess() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, null);
    Map<String, Object> resmap = new LinkedHashMap<>();
    resmap.put("ok", true);
    resmap.put("resdata", fhMap("id", "i1"));
    ctx.result = new Result(resmap);
    Object out = utility.done.apply(ctx);
    Map<String, Object> om = (Map<String, Object>) out;
    assertNotNull(om, "expected resdata");
    assertEquals("i1", om.get("id"));
  }

  @Test
  public void done_errorsWhenNotOk() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, null);
    Map<String, Object> resmap = new LinkedHashMap<>();
    resmap.put("ok", false);
    ctx.result = new Result(resmap);
    try {
      utility.done.apply(ctx);
      fail("expected an error when result not ok");
    }
    catch (RuntimeException e) {
      // expected
    }
  }

  @Test
  public void makeError_returnsResdataWhenThrowFalse() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, null);
    ctx.ctrl.throwing = false;
    Map<String, Object> resmap = new LinkedHashMap<>();
    resmap.put("ok", false);
    resmap.put("resdata", "fallback");
    ctx.result = new Result(resmap);
    Object out = utility.makeError.apply(ctx, ctx.makeError("test_code", "test message"));
    assertEquals("fallback", out);
  }

  @Test
  public void makeError_recordsToCtrlExplain() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();

    Context ctx = plCtx(client, utility, fhMap("explain", new LinkedHashMap<>()));
    ctx.ctrl.throwing = false;
    Map<String, Object> resmap = new LinkedHashMap<>();
    resmap.put("ok", false);
    ctx.result = new Result(resmap);
    utility.makeError.apply(ctx, ctx.makeError("x", "x"));
    assertNotNull(ctx.ctrl.explain.get("err"), "expected explain.err recorded");
  }

  // --- featureAdd -------------------------------------------------------------

  @Test
  public void featureAdd_appendsByDefault() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();
    Context ctx = plCtx(client, utility, null);
    int start = client.features.size();
    BaseFeature f = new BaseFeature();
    utility.featureAdd.apply(ctx, f);
    assertEquals(start + 1, client.features.size());
    assertEquals(f, client.features.get(client.features.size() - 1),
        "expected the feature appended last");
  }

  @Test
  public void featureAdd_orderingBeforeAfterReplace() {
    UnivecSDK client = plClient(null);
    Utility utility = client.getUtility();
    Context ctx = plCtx(client, utility, null);
    client.features = new ArrayList<>();

    utility.featureAdd.apply(ctx, named("a"));
    utility.featureAdd.apply(ctx, named("b"));
    assertEquals("a,b", names(client), "setup");

    BaseFeature before = named("z1");
    before.addOpts = fhMap("__before__", "b");
    utility.featureAdd.apply(ctx, before);
    assertEquals("a,z1,b", names(client), "__before__");

    BaseFeature after = named("z2");
    after.addOpts = fhMap("__after__", "a");
    utility.featureAdd.apply(ctx, after);
    assertEquals("a,z2,z1,b", names(client), "__after__");

    BaseFeature repl = named("z3");
    repl.addOpts = fhMap("__replace__", "z1");
    utility.featureAdd.apply(ctx, repl);
    assertEquals("a,z2,z3,b", names(client), "__replace__");

    // An ordering option naming no existing feature falls back to append.
    BaseFeature miss = named("z4");
    miss.addOpts = fhMap("__before__", "missing");
    utility.featureAdd.apply(ctx, miss);
    assertEquals("a,z2,z3,b,z4", names(client), "fallback append");
  }

  static BaseFeature named(String name) {
    BaseFeature f = new BaseFeature();
    f.name = name;
    return f;
  }

  static String names(UnivecSDK client) {
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < client.features.size(); i++) {
      if (i > 0) {
        out.append(",");
      }
      out.append(client.features.get(i).getName());
    }
    return out.toString();
  }

  // --- prepareAuth --------------------------------------------------------------

  // A cookie credential as prepareAuth writes it: `<scheme>=K` for the probe
  // key, with no scheme prefix and nothing else in the bag.
  static final Pattern COOKIE_PAIR = Pattern.compile("^[^=;]+=K$");

  static Spec authSpec() {
    Map<String, Object> m = new LinkedHashMap<>();
    m.put("headers", new LinkedHashMap<String, Object>());
    m.put("query", new LinkedHashMap<String, Object>());
    m.put("step", "s");
    return new Spec(m);
  }

  // Where this SDK's prepareAuth actually puts the credential. The name is
  // the API's OWN scheme name, not always "authorization", so it is
  // discovered rather than asserted. `pair` is the `<scheme>=` lead-in of a
  // COOKIE credential, which rides the header bag under the key "cookie"
  // instead of taking a header of its own.
  record AuthCred(String where, String name, Object value, String pair) {
  }

  // A cookie credential rides the header bag, because a cookie IS a header.
  static Map<String, Object> authBag(Spec spec, String where) {
    return "query".equals(where) ? spec.query : spec.headers;
  }

  // `basic: false` is explicit: an HTTP Basic API's generated config carries
  // `auth.basic: true`, testSDK merges it in, and the branch it selects needs
  // a secret as well. With none supplied that branch deliberately writes
  // nothing, which the probe below would read as a public API.
  static Map<String, Object> authBlock(String prefix) {
    return fhMap("prefix", prefix, "basic", Boolean.FALSE);
  }

  // Run prepareAuth with both containers present and see which one the
  // generated utility writes to, and under what name. Null means this SDK
  // places no credential at all - a public API - which is a legitimate
  // shape, and the tests below assert exactly that instead.
  static AuthCred authProbe(Map<String, Object> sdkopts) {
    UnivecSDK client = plClient(sdkopts);
    Utility utility = client.getUtility();
    Context ctx = plCtx(client, utility, null);
    ctx.spec = authSpec();
    utility.prepareAuth.apply(ctx);
    for (String where : new String[] { "headers", "query" }) {
      for (Map.Entry<String, Object> entry : authBag(ctx.spec, where).entrySet()) {
        Object value = entry.getValue();
        String pair = "";
        if ("headers".equals(where) && "cookie".equals(entry.getKey())
            && value instanceof String
            && COOKIE_PAIR.matcher((String) value).matches()) {
          String text = (String) value;
          pair = text.substring(0, text.length() - 1);
        }
        return new AuthCred(where, entry.getKey(), value, pair);
      }
    }
    return null;
  }

  static AuthCred authCredential() {
    return authProbe(fhMap("apikey", "K", "auth", authBlock("Bearer")));
  }

  // Every credential this SDK could possibly place: both credentials and
  // Basic switched on, so whichever branch the API has, something lands
  // unless the API is public.
  static AuthCred authAnyCredential() {
    return authProbe(fhMap(
        "apikey", "K",
        "secret", "S",
        "auth", fhMap("prefix", "Bearer", "basic", Boolean.TRUE)));
  }

  // Runs prepareAuth over a fresh spec, seeding the credential slot first
  // when seed is non-null, and reports what is left there.
  static Object[] authPlaced(Map<String, Object> sdkopts, Object seed) {
    AuthCred cred = authCredential();
    UnivecSDK client = plClient(sdkopts);
    Utility utility = client.getUtility();
    Context ctx = plCtx(client, utility, null);
    ctx.spec = authSpec();
    if (cred != null && seed != null) {
      // Seed what prepareAuth would have written: cred.pair() is the
      // `<scheme>=` lead-in for a cookie and "" for a header or query, so an
      // opaque seed is never mistaken for a stranger's cookie.
      authBag(ctx.spec, cred.where()).put(cred.name(), cred.pair() + seed);
    }
    utility.prepareAuth.apply(ctx);
    if (cred == null) {
      return new Object[] { null, Boolean.FALSE };
    }
    Map<String, Object> bag = authBag(ctx.spec, cred.where());
    return new Object[] { bag.get(cred.name()), bag.containsKey(cred.name()) };
  }

  @Test
  public void prepareAuth_guardsMissingSpec() {
    UnivecSDK client = plClient(fhMap("apikey", "K"));
    Utility utility = client.getUtility();
    Context ctx = plCtx(client, utility, null);
    ctx.spec = null;
    assertEquals("auth_no_spec", errCodeOf(() -> utility.prepareAuth.apply(ctx)));
  }

  // Without this the cases below cannot fail for an SDK whose credential the
  // probe misses: every one of them takes the public-API path instead.
  @Test
  public void prepareAuth_probeFindsTheCredentialThisSdkPlaces() {
    assertEquals(null == authCredential(), null == authAnyCredential(),
        "the probe missed a credential this SDK places, so every case "
        + "takes the public-API path");
  }

  @Test
  public void prepareAuth_placedWhereThisApiPutsIt() {
    AuthCred cred = authCredential();
    if (cred == null) {
      // A public API places nothing, and that is the whole assertion.
      Object[] got = authPlaced(fhMap(
          "apikey", "K",
          "auth", authBlock("Bearer")), null);
      assertFalse((Boolean) got[1], "expected no credential placed at all");
      return;
    }
    assertTrue("headers".equals(cred.where()) || "query".equals(cred.where()),
        "unexpected credential container " + cred.where());
    if (!"".equals(cred.pair())) {
      // A cookie credential is a `<scheme>=<key>` pair, and the scheme name
      // leaves no room for the option's prefix.
      assertTrue(COOKIE_PAIR.matcher(String.valueOf(cred.value())).matches(),
          "expected a cookie pair, got " + cred.value());
      return;
    }
    // A header credential is prefix-joined; a query credential is the raw
    // key, because a query parameter has nowhere to put a scheme name.
    assertEquals("query".equals(cred.where()) ? "K" : "Bearer K", cred.value());
  }

  @Test
  public void prepareAuth_rawApikeyEmptyPrefixAsIs() {
    Object[] got = authPlaced(fhMap(
        "apikey", "K",
        "auth", authBlock("")), null);
    AuthCred cred = authCredential();
    if (cred == null) {
      assertFalse((Boolean) got[1], "expected no credential placed at all");
      return;
    }
    assertEquals(cred.pair() + "K", got[0]);
  }

  @Test
  public void prepareAuth_emptyApikeyDropsCredential() {
    Object[] got = authPlaced(fhMap(
        "apikey", "",
        "auth", authBlock("Bearer")), "stale");
    assertFalse((Boolean) got[1], "expected the credential dropped");
  }

  @Test
  public void prepareAuth_missingApikeyDropsCredential() {
    Map<String, Object> sdkopts = fhMap("auth", authBlock("Bearer"));
    Object apikey = plClient(sdkopts).optionsMap().get("apikey");
    if (apikey instanceof String && !"".equals(apikey)) {
      // SDK options carry a configured apikey; case not reproducible here.
      return;
    }
    Object[] got = authPlaced(sdkopts, "stale");
    assertFalse((Boolean) got[1], "expected the credential dropped");
  }

  @Test
  public void prepareAuth_publicApiNoAuthBlockDropsCredential() {
    Map<String, Object> sdkopts = fhMap("apikey", "K");
    if (plClient(sdkopts).optionsMap().get("auth") != null) {
      // Option validation supplies an auth shape for this SDK, so a truly
      // auth-less client cannot be constructed here.
      return;
    }
    Object[] got = authPlaced(sdkopts, "stale");
    assertFalse((Boolean) got[1], "expected the credential dropped");
  }
}
