package voxgig.univecsdk.sdktest;

// Drives the primary utility functions against the shared test.json spec
// (../.sdk/test/test.json, section "primary"). Mirrors
// tm/go/test/primary_utility_test.go.

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import static voxgig.univecsdk.sdktest.FeatureHarness.fhMap;
import static voxgig.univecsdk.sdktest.RunnerSupport.getSpec;
import static voxgig.univecsdk.sdktest.RunnerSupport.loadTestSpec;
import static voxgig.univecsdk.sdktest.RunnerSupport.makeCtxFromMap;
import static voxgig.univecsdk.sdktest.RunnerSupport.runset;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;

import org.junit.jupiter.api.Test;

import voxgig.univecsdk.core.Context;
import voxgig.univecsdk.core.Helpers;
import voxgig.univecsdk.core.Operation;
import voxgig.univecsdk.core.UnivecSDK;
import voxgig.univecsdk.core.Result;
import voxgig.univecsdk.core.Spec;
import voxgig.univecsdk.core.Utility;
import voxgig.univecsdk.feature.BaseFeature;

@SuppressWarnings({"unchecked"})
public class PrimaryUtilityTest {

  static Map<String, Object> primary() {
    Map<String, Object> spec = loadTestSpec();
    Map<String, Object> primary = getSpec(spec, "primary");
    assertNotNull(primary, "primary section not found in test.json");
    return primary;
  }

  static UnivecSDK client() {
    return UnivecSDK.testSDK();
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
    UnivecSDK client = client();
    Utility utility = client.getUtility();

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
    Utility utility = client.getUtility();
    Context ctx = makeTestCtx(client, utility, null);
    Object cleaned = utility.clean.apply(ctx, fhMap("key", "secret123", "name", "test"));
    assertNotNull(cleaned, "cleaned should not be null");
  }

  @Test
  public void doneBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "done", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      RunnerSupport.fixctx(ctx, client);
      return utility.done.apply(ctx);
    });
  }

  @Test
  public void makeErrorBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "makeError", "basic"), (entry) -> {
      List<Object> args = entry.get("args") instanceof List
          ? (List<Object>) entry.get("args") : new ArrayList<>();
      if (args.isEmpty()) {
        args.add(new LinkedHashMap<String, Object>());
      }

      Map<String, Object> ctxmap = Helpers.toMapAny(args.get(0));
      if (ctxmap == null) {
        ctxmap = new LinkedHashMap<>();
      }
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      RunnerSupport.fixctx(ctx, client);

      RuntimeException err = null;
      if (args.size() > 1) {
        err = RunnerSupport.errFromMap(Helpers.toMapAny(args.get(1)));
      }

      return utility.makeError.apply(ctx, err);
    });
  }

  @Test
  public void makeErrorNoThrow() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
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
    Utility utility = client.getUtility();
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
    UnivecSDK hookClient = client();
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
    UnivecSDK initClient = client();
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
    UnivecSDK initClient = client();
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
    UnivecSDK liveClient = new UnivecSDK(fhMap(
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
    UnivecSDK blockedClient = new UnivecSDK(fhMap(
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
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "makeContext", "basic"), (entry) -> {
      Map<String, Object> in = Helpers.toMapAny(entry.get("in"));
      if (in != null) {
        Context ctx = utility.makeContext.apply(in, null);
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
    Utility utility = client.getUtility();
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
    Utility utility = client.getUtility();
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
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "makeOptions", "basic"), (entry) -> {
      Map<String, Object> in = Helpers.toMapAny(entry.get("in"));
      Map<String, Object> ctxmap = new LinkedHashMap<>();
      if (in != null) {
        ctxmap.put("options", in.get("options"));
        ctxmap.put("config", in.get("config"));
      }
      Context ctx = utility.makeContext.apply(ctxmap, null);
      ctx.client = client;
      ctx.utility = utility;
      return utility.makeOptions.apply(ctx);
    });
  }

  @Test
  public void makeRequestBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "makeRequest", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      ctx.options = client.optionsMap();

      utility.makeRequest.apply(ctx);

      // Update entry ctx for match checking.
      Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
      if (entryCtx != null) {
        if (ctx.response != null) {
          entryCtx.put("response", "exists");
        }
        if (ctx.result != null) {
          entryCtx.put("result", "exists");
        }
      }

      return null;
    });
  }

  @Test
  public void makeResponseBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "makeResponse", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      RunnerSupport.fixctx(ctx, client);

      utility.makeResponse.apply(ctx);

      // Update entry ctx for match checking with result data.
      Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
      if (entryCtx != null && ctx.result != null) {
        entryCtx.put("result", fhMap(
            "ok", ctx.result.ok,
            "status", ctx.result.status,
            "statusText", ctx.result.statusText,
            "headers", ctx.result.headers,
            "body", ctx.result.body));
      }

      return null;
    });
  }

  @Test
  public void makeResultBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
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
    Utility utility = client.getUtility();
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
    Utility utility = client.getUtility();
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
    Map<String, Object> setupOpts = getSpec(primary(), "makeSpec", "DEF", "setup", "a");
    UnivecSDK specClient = UnivecSDK.testSDK(null, setupOpts);
    Utility specUtility = specClient.getUtility();

    runset(getSpec(primary(), "makeSpec", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, specClient, specUtility);
      ctx.options = specClient.optionsMap();

      specUtility.makeSpec.apply(ctx);

      // Update entry ctx for match.
      Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
      if (entryCtx != null && ctx.spec != null) {
        entryCtx.put("spec", fhMap(
            "base", ctx.spec.base,
            "prefix", ctx.spec.prefix,
            "suffix", ctx.spec.suffix,
            "method", ctx.spec.method,
            "params", ctx.spec.params,
            "query", ctx.spec.query,
            "headers", ctx.spec.headers,
            "step", ctx.spec.step));
      }

      return null;
    });
  }

  @Test
  public void makePointBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    Context ctx = makeTestCtx(client, utility, null);
    List<Object> parts = new ArrayList<>();
    parts.add("items");
    parts.add("{id}");
    Map<String, Object> point = fhMap(
        "parts", parts,
        "args", fhMap("params", new ArrayList<>()),
        "params", new ArrayList<>(),
        "alias", new LinkedHashMap<>(),
        "select", new LinkedHashMap<>(),
        "active", true,
        "transform", new LinkedHashMap<>());
    ctx.op.points = new ArrayList<>(List.of(point));

    utility.makePoint.apply(ctx);
    assertNotNull(ctx.point, "expected point to be set");
  }

  @Test
  public void makeUrlBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "makeUrl", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      if (ctx.result == null) {
        ctx.result = new Result(new LinkedHashMap<>());
      }
      return utility.makeUrl.apply(ctx);
    });
  }

  @Test
  public void operatorBasic() {
    runset(getSpec(primary(), "operator", "basic"), (entry) -> {
      Map<String, Object> in = Helpers.toMapAny(entry.get("in"));
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
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "param", "basic"), (entry) -> {
      List<Object> args = entry.get("args") instanceof List
          ? (List<Object>) entry.get("args") : new ArrayList<>();
      if (args.size() < 2) {
        return null;
      }

      Map<String, Object> ctxmap = Helpers.toMapAny(args.get(0));
      if (ctxmap == null) {
        ctxmap = new LinkedHashMap<>();
      }
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      Object paramdef = args.get(1);

      Object result = utility.param.apply(ctx, paramdef);

      // Copy spec alias back to entry ctx for matching.
      Map<String, Object> matchSpec = Helpers.toMapAny(entry.get("match"));
      if (matchSpec != null) {
        Map<String, Object> ctxMatch = Helpers.toMapAny(matchSpec.get("ctx"));
        if (ctxMatch != null) {
          Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
          if (entryCtx == null) {
            entryCtx = new LinkedHashMap<>();
            entry.put("ctx", entryCtx);
          }
          Map<String, Object> specMatch = Helpers.toMapAny(ctxMatch.get("spec"));
          if (specMatch != null && ctx.spec != null
              && specMatch.get("alias") instanceof Map) {
            entryCtx.put("spec", fhMap("alias", ctx.spec.alias));
          }
        }
      }

      return result;
    });
  }

  @Test
  public void prepareAuthBasic() {
    Map<String, Object> setupOpts = getSpec(primary(), "prepareAuth", "DEF", "setup", "a");
    UnivecSDK authClient = UnivecSDK.testSDK(null, setupOpts);
    Utility authUtility = authClient.getUtility();

    runset(getSpec(primary(), "prepareAuth", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, authClient, authUtility);
      RunnerSupport.fixctx(ctx, authClient);

      authUtility.prepareAuth.apply(ctx);

      // Update entry ctx for match.
      Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
      if (entryCtx != null && ctx.spec != null) {
        entryCtx.put("spec", fhMap("headers", ctx.spec.headers));
      }

      return null;
    });
  }

  @Test
  public void prepareBodyBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "prepareBody", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      RunnerSupport.fixctx(ctx, client);
      return utility.prepareBody.apply(ctx);
    });
  }

  @Test
  public void prepareHeadersBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "prepareHeaders", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      return utility.prepareHeaders.apply(ctx);
    });
  }

  @Test
  public void prepareMethodBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "prepareMethod", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      return utility.prepareMethod.apply(ctx);
    });
  }

  @Test
  public void prepareParamsBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "prepareParams", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      return utility.prepareParams.apply(ctx);
    });
  }

  @Test
  public void preparePathBasic() {
    // Was two hand-written cases that had drifted out of the shared corpus
    // (the preparePath fixture shipped as an empty `set: []`).
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "preparePath", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      return utility.preparePath.apply(ctx);
    });
  }

  @Test
  public void prepareQueryBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "prepareQuery", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      return utility.prepareQuery.apply(ctx);
    });
  }

  @Test
  public void resultBasicBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "resultBasic", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);
      RunnerSupport.fixctx(ctx, client);

      Result result = utility.resultBasic.apply(ctx);

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
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "resultBody", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);

      utility.resultBody.apply(ctx);

      Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
      if (entryCtx != null && ctx.result != null) {
        entryCtx.put("result", fhMap("body", ctx.result.body));
      }

      return null;
    });
  }

  @Test
  public void resultHeadersBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "resultHeaders", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);

      utility.resultHeaders.apply(ctx);

      Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
      if (entryCtx != null && ctx.result != null) {
        entryCtx.put("result", fhMap("headers", ctx.result.headers));
      }

      return null;
    });
  }

  @Test
  public void transformRequestBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "transformRequest", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);

      Object result = utility.transformRequest.apply(ctx);

      // Update entry ctx for match (step changed).
      Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
      if (entryCtx != null && ctx.spec != null) {
        Map<String, Object> specMap = Helpers.toMapAny(entryCtx.get("spec"));
        if (specMap != null) {
          specMap.put("step", ctx.spec.step);
        }
      }

      return result;
    });
  }

  @Test
  public void transformResponseBasic() {
    UnivecSDK client = client();
    Utility utility = client.getUtility();
    runset(getSpec(primary(), "transformResponse", "basic"), (entry) -> {
      Map<String, Object> ctxmap = Helpers.toMapAny(entry.get("ctx"));
      Context ctx = makeCtxFromMap(ctxmap, client, utility);

      Object result = utility.transformResponse.apply(ctx);

      // Update entry ctx for match (step changed).
      Map<String, Object> entryCtx = Helpers.toMapAny(entry.get("ctx"));
      if (entryCtx != null && ctx.spec != null) {
        Map<String, Object> specMap = Helpers.toMapAny(entryCtx.get("spec"));
        if (specMap != null) {
          specMap.put("step", ctx.spec.step);
        }
      }

      return result;
    });
  }
}
