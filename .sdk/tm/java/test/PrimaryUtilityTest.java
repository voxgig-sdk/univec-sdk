package JAVAPACKAGE.sdktest;

// Drives the primary utility functions against the shared test.json spec
// (../.sdk/test/test.json, section "primary") through the VENDORED omni
// runner (OmniResolver over test/vendor/omni). Mirrors
// tm/go/test/primary_utility_test.go.
//
// Subjects receive omni's native argument list: a ctx entry arrives as
// args[0], a MAP - OmniResolver.omniCtx builds the typed Context a
// generated utility takes, and OmniResolver.omniSyncCtx writes the
// observable ctx state back for `match: {ctx: ...}` assertions.

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import static JAVAPACKAGE.sdktest.FeatureHarness.fhMap;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.BiFunction;

import org.junit.jupiter.api.Test;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Entity;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.Operation;
import JAVAPACKAGE.core.UnivecSDK;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.SdkError;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.feature.BaseFeature;

@SuppressWarnings({"unchecked"})
public class PrimaryUtilityTest {

  static final String TEST_JSON_FILE = "../.sdk/test/test.json";

  // PENDING sections are the ones deliberately left empty in the shared
  // corpus (.sdk/test/primary/<name>.aon). Everything else MUST contribute
  // cases.
  static final Set<String> PENDING = Set.of(
      "fetcher", "makeFetchDef", "makeResult",
      "featureAdd", "featureHook", "featureInit");

  // One client + one corpus runner for the whole suite (the go shape).
  private static UnivecSDK CLIENT;
  private static Utility UTILITY;
  private static OmniResolver.Run RUN;

  static synchronized OmniResolver.Run run() {
    if (RUN == null) {
      CLIENT = UnivecSDK.testSDK();
      UTILITY = CLIENT.getUtility();
      RUN = OmniResolver.makeRunner(TEST_JSON_FILE, CLIENT).runner("primary", null);
      assertNotNull(RUN.spec, "primary section not found in test.json");
    }
    return RUN;
  }

  static UnivecSDK client() {
    run();
    return CLIENT;
  }

  static Utility utility() {
    run();
    return UTILITY;
  }

  // Run one corpus section, failing loudly when it would run ZERO cases.
  // A renamed section, a fixture that failed to compile, or an empty set
  // used to report PASS while running zero assertions - the whole point of
  // a shared oracle lost without a single red test. (The guard lives here
  // rather than in the runner, which is vendored verbatim; the shared
  // corpus is a v0 spec, and v0 tolerates an empty set.)
  static void runsection(String name, OmniResolver.Subject subject) {
    OmniResolver.Run run = run();
    Map<String, Object> section = Helpers.toMapAny(run.spec.get(name));
    assertNotNull(section, "test corpus section \"" + name
        + "\" missing - check the name against .sdk/test/primary/");
    Map<String, Object> basic = Helpers.toMapAny(section.get("basic"));
    Object set = basic == null ? null : basic.get("set");
    if (!(set instanceof List)) {
      fail("test corpus section \"" + name
          + "\" has no basic.set list - zero cases would run");
    }
    if (((List<Object>) set).isEmpty() && !PENDING.contains(name)) {
      fail("test corpus section \"" + name + "\" is EMPTY - zero cases "
          + "would run; add cases, or mark the fixture PENDING in .sdk/test/primary/");
    }
    run.runset(basic, subject);
  }

  // Helper: create basic test context.
  static Context makeTestCtx(UnivecSDK client, Utility utility,
      Map<String, Object> overrides) {
    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("opname", "load");
    ctxmap.put("client", client);
    ctxmap.put("utility", utility);
    if (overrides != null) {
      ctxmap.putAll(overrides);
    }
    return utility.makeContext.apply(ctxmap, client.getRootCtx());
  }

  // Helper: create full test context with point and match.
  static Context makeTestFullCtx(UnivecSDK client, Utility utility) {
    Context ctx = makeTestCtx(client, utility, null);
    List<Object> params = new ArrayList<>();
    params.add(fhMap("name", "id", "reqd", true));
    List<Object> paramNames = new ArrayList<>();
    paramNames.add("id");
    List<Object> parts = new ArrayList<>();
    parts.add("items");
    parts.add("{id}");
    ctx.point = fhMap(
        "parts", parts,
        "args", fhMap("params", params),
        "params", paramNames,
        "alias", new LinkedHashMap<>(),
        "select", new LinkedHashMap<>(),
        "active", true,
        "transform", new LinkedHashMap<>());
    ctx.match = fhMap("id", "item01");
    ctx.reqmatch = fhMap("id", "item01");
    return ctx;
  }

  @Test
  public void exists() {
    Utility utility = utility();

    assertNotNull(utility.clean, "clean");
    assertNotNull(utility.done, "done");
    assertNotNull(utility.makeError, "makeError");
    assertNotNull(utility.featureAdd, "featureAdd");
    assertNotNull(utility.featureHook, "featureHook");
    assertNotNull(utility.featureInit, "featureInit");
    assertNotNull(utility.fetcher, "fetcher");
    assertNotNull(utility.makeFetchDef, "makeFetchDef");
    assertNotNull(utility.makeContext, "makeContext");
    assertNotNull(utility.makeOptions, "makeOptions");
    assertNotNull(utility.makeRequest, "makeRequest");
    assertNotNull(utility.makeResponse, "makeResponse");
    assertNotNull(utility.makeResult, "makeResult");
    assertNotNull(utility.makePoint, "makePoint");
    assertNotNull(utility.makeSpec, "makeSpec");
    assertNotNull(utility.makeUrl, "makeUrl");
    assertNotNull(utility.param, "param");
    assertNotNull(utility.prepareAuth, "prepareAuth");
    assertNotNull(utility.prepareBody, "prepareBody");
    assertNotNull(utility.prepareHeaders, "prepareHeaders");
    assertNotNull(utility.prepareMethod, "prepareMethod");
    assertNotNull(utility.prepareParams, "prepareParams");
    assertNotNull(utility.preparePath, "preparePath");
    assertNotNull(utility.prepareQuery, "prepareQuery");
    assertNotNull(utility.resultBasic, "resultBasic");
    assertNotNull(utility.resultBody, "resultBody");
    assertNotNull(utility.resultHeaders, "resultHeaders");
    assertNotNull(utility.transformRequest, "transformRequest");
    assertNotNull(utility.transformResponse, "transformResponse");
  }

  @Test
  public void cleanBasic() {
    UnivecSDK client = client();
    Utility utility = utility();
    Context ctx = makeTestCtx(client, utility, null);
    Object cleaned = utility.clean.apply(ctx, fhMap("key", "secret123", "name", "test"));
    assertNotNull(cleaned, "cleaned should not be null");
  }

  @Test
  public void cleanCorpus() {
    runsection("clean", (args) -> {
      if (2 != args.length) {
        throw new RuntimeException("clean: expected 2 args, got " + args.length);
      }
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      return utility().clean.apply(ctx, args[1]);
    });
  }

  @Test
  public void doneBasic() {
    runsection("done", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      return utility().done.apply(ctx);
    });
  }

  @Test
  public void makeErrorBasic() {
    runsection("makeError", (args) -> {
      if (0 == args.length) {
        args = new Object[] { new LinkedHashMap<String, Object>() };
      }

      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());

      RuntimeException err = null;
      if (args.length > 1) {
        err = RunnerSupport.errFromMap(Helpers.toMapAny(args[1]));
      }

      return utility().makeError.apply(ctx, err);
    });
  }

  @Test
  public void makeErrorNoThrow() {
    UnivecSDK client = client();
    Utility utility = utility();
    Context ctx = makeTestFullCtx(client, utility);
    ctx.ctrl.throwing = false;
    Map<String, Object> resmap = new LinkedHashMap<>();
    resmap.put("ok", false);
    resmap.put("resdata", fhMap("id", "safe01"));
    ctx.result = new Result(resmap);

    Object out = utility.makeError.apply(ctx,
        ctx.makeError("test_code", "test message"));
    Map<String, Object> outMap = Helpers.toMapAny(out);
    assertNotNull(outMap, "expected map result");
    assertEquals("safe01", outMap.get("id"));
  }

  @Test
  public void featureAddBasic() {
    UnivecSDK client = client();
    Utility utility = utility();
    Context ctx = makeTestCtx(client, utility, null);
    int startLen = client.features.size();

    utility.featureAdd.apply(ctx, new BaseFeature());

    assertEquals(startLen + 1, client.features.size());
  }

  public static class TestHookFeature extends BaseFeature {
    public Runnable hookFn;

    public void testHook(Context ctx) {
      if (hookFn != null) {
        hookFn.run();
      }
    }
  }

  @Test
  public void featureHookBasic() {
    UnivecSDK hookClient = UnivecSDK.testSDK();
    Utility hookUtility = hookClient.getUtility();
    Context ctx = makeTestCtx(hookClient, hookUtility, null);

    final boolean[] called = { false };
    TestHookFeature hookFeature = new TestHookFeature();
    hookFeature.hookFn = () -> called[0] = true;
    hookClient.features = new ArrayList<>(List.of(hookFeature));

    hookUtility.featureHook.apply(ctx, "TestHook");
    assertTrue(called[0], "expected TestHook to be called");
  }

  public static class TestInitFeature extends BaseFeature {
    public Runnable initFn;

    @Override
    public void init(Context ctx, Map<String, Object> options) {
      if (initFn != null) {
        initFn.run();
      }
    }
  }

  @Test
  public void featureInitBasic() {
    UnivecSDK initClient = UnivecSDK.testSDK();
    Utility initUtility = initClient.getUtility();
    Context ctx = makeTestCtx(initClient, initUtility, null);
    ctx.options.put("feature", fhMap("initfeat", fhMap("active", true)));

    final boolean[] initCalled = { false };
    TestInitFeature feature = new TestInitFeature();
    feature.name = "initfeat";
    feature.active = true;
    feature.initFn = () -> initCalled[0] = true;

    initUtility.featureInit.apply(ctx, feature);
    assertTrue(initCalled[0], "expected init to be called");
  }

  @Test
  public void featureInitInactive() {
    UnivecSDK initClient = UnivecSDK.testSDK();
    Utility initUtility = initClient.getUtility();
    Context ctx = makeTestCtx(initClient, initUtility, null);
    ctx.options.put("feature", fhMap("nofeat", fhMap("active", false)));

    final boolean[] initCalled = { false };
    TestInitFeature feature = new TestInitFeature();
    feature.name = "nofeat";
    feature.active = false;
    feature.initFn = () -> initCalled[0] = true;

    initUtility.featureInit.apply(ctx, feature);
    assertFalse(initCalled[0], "expected init NOT to be called for inactive feature");
  }

  @Test
  public void fetcherLive() {
    final List<Map<String, Object>> calls = new ArrayList<>();
    // Concrete base: a live construction must satisfy any server variables a
    // templated base URL declares; a literal base sidesteps the requirement.
    UnivecSDK liveClient = new UnivecSDK(fhMap(
        "base", "http://localhost:8080",
        "system", fhMap(
            "fetch", (BiFunction<String, Map<String, Object>, Map<String, Object>>)
                (url, fetchdef) -> {
                  calls.add(fhMap("url", url, "init", fetchdef));
                  return fhMap("status", 200, "statusText", "OK");
                })));
    Utility liveUtility = liveClient.getUtility();
    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("opname", "load");
    ctxmap.put("client", liveClient);
    ctxmap.put("utility", liveUtility);
    Context ctx = liveUtility.makeContext.apply(ctxmap, null);

    Map<String, Object> fetchdef = fhMap("method", "GET",
        "headers", new LinkedHashMap<>());
    liveUtility.fetcher.fetch(ctx, "http://example.com/test", fetchdef);
    assertEquals(1, calls.size(), "expected 1 call");
    assertEquals("http://example.com/test", calls.get(0).get("url"));
  }

  @Test
  public void fetcherBlockedTestMode() {
    // Create a live SDK then set mode to test (not using testSDK, which
    // installs the test feature).
    // Concrete base: a live construction must satisfy any server variables a
    // templated base URL declares; a literal base sidesteps the requirement.
    UnivecSDK blockedClient = new UnivecSDK(fhMap(
        "base", "http://localhost:8080",
        "system", fhMap(
            "fetch", (BiFunction<String, Map<String, Object>, Map<String, Object>>)
                (url, fetchdef) -> new LinkedHashMap<>())));
    blockedClient.mode = "test";

    Utility blockedUtility = blockedClient.getUtility();
    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("opname", "load");
    ctxmap.put("client", blockedClient);
    ctxmap.put("utility", blockedUtility);
    Context ctx = blockedUtility.makeContext.apply(ctxmap, null);

    Map<String, Object> fetchdef = fhMap("method", "GET",
        "headers", new LinkedHashMap<>());
    try {
      blockedUtility.fetcher.fetch(ctx, "http://example.com/test", fetchdef);
      fail("expected error for test mode fetch");
    }
    catch (RuntimeException e) {
      assertTrue(String.valueOf(e.getMessage()).contains("blocked"),
          "expected error containing 'blocked', got: " + e.getMessage());
    }
  }

  @Test
  public void makeContextBasic() {
    runsection("makeContext", (args) -> {
      Map<String, Object> in = Helpers.toMapAny(args[0]);
      if (in != null) {
        Context ctx = utility().makeContext.apply(in, null);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", ctx.id);
        if (ctx.op != null) {
          out.put("op", fhMap("name", ctx.op.name, "input", ctx.op.input));
        }
        return out;
      }
      return null;
    });
  }

  @Test
  public void makeFetchDefBasic() {
    UnivecSDK client = client();
    Utility utility = utility();
    Context ctx = makeTestFullCtx(client, utility);
    ctx.spec = new Spec(fhMap(
        "base", "http://localhost:8080",
        "prefix", "/api",
        "path", "items/{id}",
        "suffix", "",
        "params", fhMap("id", "item01"),
        "query", new LinkedHashMap<>(),
        "headers", fhMap("content-type", "application/json"),
        "method", "GET",
        "step", "start"));
    ctx.result = new Result(new LinkedHashMap<>());

    Map<String, Object> fetchdef = utility.makeFetchDef.apply(ctx);
    assertEquals("GET", fetchdef.get("method"));
    String url = fetchdef.get("url") instanceof String ? (String) fetchdef.get("url") : "";
    assertTrue(url.contains("/api/items/item01"),
        "expected url to contain /api/items/item01, got " + url);
    assertEquals("application/json",
        ((Map<String, Object>) fetchdef.get("headers")).get("content-type"));
    assertNull(fetchdef.get("body"), "expected null body");
  }

  @Test
  public void makeFetchDefWithBody() {
    UnivecSDK client = client();
    Utility utility = utility();
    Context ctx = makeTestFullCtx(client, utility);
    ctx.spec = new Spec(fhMap(
        "base", "http://localhost:8080",
        "prefix", "",
        "path", "items",
        "suffix", "",
        "params", new LinkedHashMap<>(),
        "query", new LinkedHashMap<>(),
        "headers", new LinkedHashMap<>(),
        "method", "POST",
        "step", "start",
        "body", fhMap("name", "test")));
    ctx.result = new Result(new LinkedHashMap<>());

    Map<String, Object> fetchdef = utility.makeFetchDef.apply(ctx);
    assertEquals("POST", fetchdef.get("method"));
    assertTrue(fetchdef.get("body") instanceof String,
        "expected body string, got " + fetchdef.get("body"));
    assertTrue(((String) fetchdef.get("body")).contains("\"name\""),
        "expected body to contain name");
  }

  @Test
  public void makeOptionsBasic() {
    runsection("makeOptions", (args) -> {
      Map<String, Object> in = Helpers.toMapAny(args[0]);
      Map<String, Object> ctxmap = new LinkedHashMap<>();
      if (in != null) {
        ctxmap.put("options", in.get("options"));
        ctxmap.put("config", in.get("config"));
      }
      Context ctx = utility().makeContext.apply(ctxmap, null);
      ctx.client = client();
      ctx.utility = utility();
      return utility().makeOptions.apply(ctx);
    });
  }

  @Test
  public void makeRequestBasic() {
    runsection("makeRequest", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      ctx.options = client().optionsMap();

      utility().makeRequest.apply(ctx);

      // Expose response/result existence for the match assertions.
      OmniResolver.omniSyncCtx(args[0], ctx);

      return null;
    });
  }

  @Test
  public void makeResponseBasic() {
    runsection("makeResponse", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());

      utility().makeResponse.apply(ctx);

      OmniResolver.omniSyncCtx(args[0], ctx);

      return null;
    });
  }

  @Test
  public void makeResultBasic() {
    UnivecSDK client = client();
    Utility utility = utility();
    Context ctx = makeTestFullCtx(client, utility);
    ctx.spec = new Spec(fhMap(
        "base", "http://localhost:8080",
        "prefix", "/api",
        "path", "items/{id}",
        "suffix", "",
        "params", fhMap("id", "item01"),
        "query", new LinkedHashMap<>(),
        "headers", new LinkedHashMap<>(),
        "method", "GET",
        "step", "start"));
    ctx.result = new Result(fhMap(
        "ok", true,
        "status", 200,
        "statusText", "OK",
        "headers", new LinkedHashMap<>(),
        "resdata", fhMap("id", "item01", "name", "Test")));

    Result result = utility.makeResult.apply(ctx);
    assertEquals(200, result.status);
  }

  @Test
  public void makeResultNoSpec() {
    UnivecSDK client = client();
    Utility utility = utility();
    Context ctx = makeTestFullCtx(client, utility);
    ctx.spec = null;
    ctx.result = new Result(fhMap(
        "ok", true, "status", 200, "statusText", "OK",
        "headers", new LinkedHashMap<>()));

    try {
      utility.makeResult.apply(ctx);
      fail("expected error for null spec");
    }
    catch (RuntimeException e) {
      // expected
    }
  }

  @Test
  public void makeResultNoResult() {
    UnivecSDK client = client();
    Utility utility = utility();
    Context ctx = makeTestFullCtx(client, utility);
    ctx.spec = new Spec(fhMap("step", "start"));
    ctx.result = null;

    try {
      utility.makeResult.apply(ctx);
      fail("expected error for null result");
    }
    catch (RuntimeException e) {
      // expected
    }
  }

  @Test
  public void makeSpecBasic() {
    Map<String, Object> setupOpts =
        RunnerSupport.getSpec(run().spec, "makeSpec", "DEF", "setup", "a");
    UnivecSDK specClient = UnivecSDK.testSDK(null, setupOpts);
    Utility specUtility = specClient.getUtility();

    runsection("makeSpec", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], specClient, specUtility);
      ctx.options = specClient.optionsMap();

      specUtility.makeSpec.apply(ctx);

      OmniResolver.omniSyncCtx(args[0], ctx);

      return null;
    });
  }

  // A minimal Entity: Context resolves the op through the Entity
  // interface, and a literal {name: ...} map from the fixture is not one -
  // entname would be "" and every lookup would miss, reporting
  // point_no_points for all seven cases. TS reads the same field with
  // getprop and accepts the plain map. (The go peer is plEntity.)
  static final class PlEntity implements Entity {
    private final String name;

    PlEntity(String name) {
      this.name = name;
    }

    @Override
    public String getName() {
      return name;
    }

    @Override
    public Entity make() {
      return new PlEntity(name);
    }

    @Override
    public Object data(Object... args) {
      return null;
    }

    @Override
    public Object match(Object... args) {
      return null;
    }
  }

  // Corpus-driven, like go: TS returns the error AS the value; java throws
  // SdkError. The corpus says `match: out: code` for both, so the error is
  // normalised to a map carrying its code here rather than forking the
  // fixture per language.
  @Test
  public void makePointBasic() {
    runsection("makePoint", (args) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(args[0]);
      if (ctxmap == null) {
        ctxmap = new LinkedHashMap<>();
      }

      Map<String, Object> em = Helpers.toMapAny(ctxmap.get("entity"));
      if (em != null) {
        String name = em.get("name") instanceof String ? (String) em.get("name") : "";
        Map<String, Object> swapped = new LinkedHashMap<>(ctxmap);
        swapped.put("entity", new PlEntity(name));
        ctxmap = swapped;
      }

      Context ctx = OmniResolver.omniCtx(ctxmap, client(), utility());
      try {
        return utility().makePoint.apply(ctx);
      }
      catch (SdkError e) {
        return fhMap("code", e.code);
      }
    });
  }

  @Test
  public void makeUrlBasic() {
    runsection("makeUrl", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      if (ctx.result == null) {
        ctx.result = new Result(new LinkedHashMap<>());
      }
      return utility().makeUrl.apply(ctx);
    });
  }

  @Test
  public void operatorBasic() {
    runsection("operator", (args) -> {
      Map<String, Object> in = Helpers.toMapAny(args[0]);
      Operation op = new Operation(in == null ? new LinkedHashMap<>() : in);
      return fhMap(
          "entity", op.entity,
          "name", op.name,
          "input", op.input,
          "points", op.points);
    });
  }

  @Test
  public void paramBasic() {
    runsection("param", (args) -> {
      if (args.length < 2) {
        return null;
      }

      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      Object paramdef = args[1];

      Object result = utility().param.apply(ctx, paramdef);

      // The spec alias mutation is what mark 80 asserts on.
      OmniResolver.omniSyncCtx(args[0], ctx);

      return result;
    });
  }

  @Test
  public void prepareAuthBasic() {
    Map<String, Object> setupOpts =
        RunnerSupport.getSpec(run().spec, "prepareAuth", "DEF", "setup", "a");
    UnivecSDK authClient = UnivecSDK.testSDK(null, setupOpts);
    Utility authUtility = authClient.getUtility();

    runsection("prepareAuth", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], authClient, authUtility);

      authUtility.prepareAuth.apply(ctx);

      OmniResolver.omniSyncCtx(args[0], ctx);

      return null;
    });
  }

  @Test
  public void prepareBodyBasic() {
    runsection("prepareBody", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      return utility().prepareBody.apply(ctx);
    });
  }

  @Test
  public void prepareHeadersBasic() {
    runsection("prepareHeaders", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      return utility().prepareHeaders.apply(ctx);
    });
  }

  @Test
  public void prepareMethodBasic() {
    runsection("prepareMethod", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      // An op the API does not define resolves NO method; ts answers
      // undefined there and java answers null - both are "no value" to
      // the corpus.
      String method = utility().prepareMethod.apply(ctx);
      if (method == null || method.isEmpty()) {
        return null;
      }
      return method;
    });
  }

  @Test
  public void prepareParamsBasic() {
    runsection("prepareParams", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      return utility().prepareParams.apply(ctx);
    });
  }

  // Was two hand-written cases that had drifted out of the shared corpus
  // (the preparePath fixture shipped as an empty `set: []`). Now driven by
  // the corpus like every other section, so all ports assert the same
  // separator/blank-segment behaviour.
  @Test
  public void preparePathBasic() {
    runsection("preparePath", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      return utility().preparePath.apply(ctx);
    });
  }

  @Test
  public void prepareQueryBasic() {
    runsection("prepareQuery", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());
      return utility().prepareQuery.apply(ctx);
    });
  }

  @Test
  public void resultBasicBasic() {
    runsection("resultBasic", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());

      Result result = utility().resultBasic.apply(ctx);

      Map<String, Object> out = fhMap(
          "status", result.status,
          "statusText", result.statusText);
      if (result.err != null) {
        out.put("err", fhMap("message", result.err.getMessage()));
      }

      return out;
    });
  }

  @Test
  public void resultBodyBasic() {
    runsection("resultBody", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());

      utility().resultBody.apply(ctx);

      OmniResolver.omniSyncCtx(args[0], ctx);

      return null;
    });
  }

  @Test
  public void resultHeadersBasic() {
    runsection("resultHeaders", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());

      utility().resultHeaders.apply(ctx);

      OmniResolver.omniSyncCtx(args[0], ctx);

      return null;
    });
  }

  @Test
  public void transformRequestBasic() {
    runsection("transformRequest", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());

      Object result = utility().transformRequest.apply(ctx);

      // The step advance is what the match assertion reads.
      OmniResolver.omniSyncCtx(args[0], ctx);

      return result;
    });
  }

  @Test
  public void transformResponseBasic() {
    runsection("transformResponse", (args) -> {
      Context ctx = OmniResolver.omniCtx(args[0], client(), utility());

      Object result = utility().transformResponse.apply(ctx);

      OmniResolver.omniSyncCtx(args[0], ctx);

      return result;
    });
  }
}
