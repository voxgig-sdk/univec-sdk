package KOTLINPACKAGE.sdktest

// Drives the primary utility functions against the shared test.json spec
// (../.sdk/test/test.json, section "primary").

import java.util.function.BiFunction

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.Operation
import KOTLINPACKAGE.core.UnivecSDK
import KOTLINPACKAGE.core.Result
import KOTLINPACKAGE.core.Spec
import KOTLINPACKAGE.core.Utility
import KOTLINPACKAGE.feature.BaseFeature
import KOTLINPACKAGE.sdktest.FeatureHarness.fhMap
import KOTLINPACKAGE.sdktest.RunnerSupport.getSpec
import KOTLINPACKAGE.sdktest.RunnerSupport.loadTestSpec
import KOTLINPACKAGE.sdktest.RunnerSupport.makeCtxFromMap
import KOTLINPACKAGE.sdktest.RunnerSupport.runset

@Suppress("UNCHECKED_CAST")
class PrimaryUtilityTest {

  private fun primary(): MutableMap<String, Any?> {
    val spec = loadTestSpec()
    val primary = getSpec(spec, "primary")
    assertNotNull(primary, "primary section not found in test.json")
    return primary!!
  }

  private fun client(): UnivecSDK = UnivecSDK.testSDK()

  private fun makeTestCtx(client: UnivecSDK, utility: Utility, overrides: MutableMap<String, Any?>?): Context {
    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = "load"
    ctxmap["client"] = client
    ctxmap["utility"] = utility
    if (overrides != null) {
      ctxmap.putAll(overrides)
    }
    return utility.makeContext(ctxmap, client.getRootCtx())
  }

  private fun makeTestFullCtx(client: UnivecSDK, utility: Utility): Context {
    val ctx = makeTestCtx(client, utility, null)
    val params = mutableListOf<Any?>()
    params.add(fhMap("name", "id", "reqd", true))
    val paramNames = mutableListOf<Any?>()
    paramNames.add("id")
    val parts = mutableListOf<Any?>()
    parts.add("items")
    parts.add("{id}")
    ctx.point = fhMap(
      "parts", parts,
      "args", fhMap("params", params),
      "params", paramNames,
      "alias", linkedMapOf<String, Any?>(),
      "select", linkedMapOf<String, Any?>(),
      "active", true,
      "transform", linkedMapOf<String, Any?>(),
    )
    ctx.match = fhMap("id", "item01")
    ctx.reqmatch = fhMap("id", "item01")
    return ctx
  }

  @Test
  fun exists() {
    val client = client()
    val utility = client.getUtility()

    assertNotNull(utility.clean, "clean")
    assertNotNull(utility.done, "done")
    assertNotNull(utility.makeError, "makeError")
    assertNotNull(utility.featureAdd, "featureAdd")
    assertNotNull(utility.featureHook, "featureHook")
    assertNotNull(utility.featureInit, "featureInit")
    assertNotNull(utility.fetcher, "fetcher")
    assertNotNull(utility.makeFetchDef, "makeFetchDef")
    assertNotNull(utility.makeContext, "makeContext")
    assertNotNull(utility.makeOptions, "makeOptions")
    assertNotNull(utility.makeRequest, "makeRequest")
    assertNotNull(utility.makeResponse, "makeResponse")
    assertNotNull(utility.makeResult, "makeResult")
    assertNotNull(utility.makePoint, "makePoint")
    assertNotNull(utility.makeSpec, "makeSpec")
    assertNotNull(utility.makeUrl, "makeUrl")
    assertNotNull(utility.param, "param")
    assertNotNull(utility.prepareAuth, "prepareAuth")
    assertNotNull(utility.prepareBody, "prepareBody")
    assertNotNull(utility.prepareHeaders, "prepareHeaders")
    assertNotNull(utility.prepareMethod, "prepareMethod")
    assertNotNull(utility.prepareParams, "prepareParams")
    assertNotNull(utility.preparePath, "preparePath")
    assertNotNull(utility.prepareQuery, "prepareQuery")
    assertNotNull(utility.resultBasic, "resultBasic")
    assertNotNull(utility.resultBody, "resultBody")
    assertNotNull(utility.resultHeaders, "resultHeaders")
    assertNotNull(utility.transformRequest, "transformRequest")
    assertNotNull(utility.transformResponse, "transformResponse")
  }

  @Test
  fun cleanBasic() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestCtx(client, utility, null)
    val cleaned = utility.clean(ctx, fhMap("key", "secret123", "name", "test"))
    assertNotNull(cleaned, "cleaned should not be null")
  }

  @Test
  fun doneBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "done", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      RunnerSupport.fixctx(ctx, client)
      utility.done(ctx)
    }
  }

  @Test
  fun makeErrorBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "makeError", "basic")) { entry ->
      val args = if (entry["args"] is List<*>) (entry["args"] as MutableList<Any?>) else mutableListOf()
      if (args.isEmpty()) {
        args.add(linkedMapOf<String, Any?>())
      }

      var ctxmap = Helpers.toMapAny(args[0])
      if (ctxmap == null) {
        ctxmap = linkedMapOf()
      }
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      RunnerSupport.fixctx(ctx, client)

      var err: RuntimeException? = null
      if (args.size > 1) {
        err = RunnerSupport.errFromMap(Helpers.toMapAny(args[1]))
      }

      utility.makeError(ctx, err)
    }
  }

  @Test
  fun makeErrorNoThrow() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestFullCtx(client, utility)
    ctx.ctrl.throwing = false
    val resmap = linkedMapOf<String, Any?>()
    resmap["ok"] = false
    resmap["resdata"] = fhMap("id", "safe01")
    ctx.result = Result(resmap)

    val out = utility.makeError(ctx, ctx.makeError("test_code", "test message"))
    val outMap = Helpers.toMapAny(out)
    assertNotNull(outMap, "expected map result")
    assertEquals("safe01", outMap!!["id"])
  }

  @Test
  fun featureAddBasic() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestCtx(client, utility, null)
    val startLen = client.features.size

    utility.featureAdd(ctx, BaseFeature())

    assertEquals(startLen + 1, client.features.size)
  }

  class TestHookFeature : BaseFeature() {
    var hookFn: Runnable? = null

    fun testHook(ctx: Context) {
      hookFn?.run()
    }
  }

  @Test
  fun featureHookBasic() {
    val hookClient = client()
    val hookUtility = hookClient.getUtility()
    val ctx = makeTestCtx(hookClient, hookUtility, null)

    val called = booleanArrayOf(false)
    val hookFeature = TestHookFeature()
    hookFeature.hookFn = Runnable { called[0] = true }
    hookClient.features = mutableListOf(hookFeature)

    hookUtility.featureHook(ctx, "TestHook")
    assertTrue(called[0], "expected TestHook to be called")
  }

  class TestInitFeature : BaseFeature() {
    var initFn: Runnable? = null

    override fun init(ctx: Context, options: MutableMap<String, Any?>) {
      initFn?.run()
    }
  }

  @Test
  fun featureInitBasic() {
    val initClient = client()
    val initUtility = initClient.getUtility()
    val ctx = makeTestCtx(initClient, initUtility, null)
    ctx.options!!["feature"] = fhMap("initfeat", fhMap("active", true))

    val initCalled = booleanArrayOf(false)
    val feature = TestInitFeature()
    feature.name = "initfeat"
    feature.active = true
    feature.initFn = Runnable { initCalled[0] = true }

    initUtility.featureInit(ctx, feature)
    assertTrue(initCalled[0], "expected init to be called")
  }

  @Test
  fun featureInitInactive() {
    val initClient = client()
    val initUtility = initClient.getUtility()
    val ctx = makeTestCtx(initClient, initUtility, null)
    ctx.options!!["feature"] = fhMap("nofeat", fhMap("active", false))

    val initCalled = booleanArrayOf(false)
    val feature = TestInitFeature()
    feature.name = "nofeat"
    feature.active = false
    feature.initFn = Runnable { initCalled[0] = true }

    initUtility.featureInit(ctx, feature)
    assertFalse(initCalled[0], "expected init NOT to be called for inactive feature")
  }

  @Test
  fun fetcherLive() {
    val calls = mutableListOf<MutableMap<String, Any?>>()
    val liveClient = UnivecSDK(
      fhMap(
        "system",
        fhMap(
          "fetch",
          BiFunction<String, MutableMap<String, Any?>, MutableMap<String, Any?>> { url, fetchdef ->
            calls.add(fhMap("url", url, "init", fetchdef))
            fhMap("status", 200, "statusText", "OK")
          },
        ),
      ),
    )
    val liveUtility = liveClient.getUtility()
    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = "load"
    ctxmap["client"] = liveClient
    ctxmap["utility"] = liveUtility
    val ctx = liveUtility.makeContext(ctxmap, null)

    val fetchdef = fhMap("method", "GET", "headers", linkedMapOf<String, Any?>())
    liveUtility.fetcher(ctx, "http://example.com/test", fetchdef)
    assertEquals(1, calls.size, "expected 1 call")
    assertEquals("http://example.com/test", calls[0]["url"])
  }

  @Test
  fun fetcherBlockedTestMode() {
    val blockedClient = UnivecSDK(
      fhMap(
        "system",
        fhMap("fetch", BiFunction<String, MutableMap<String, Any?>, MutableMap<String, Any?>> { _, _ -> linkedMapOf() }),
      ),
    )
    blockedClient.mode = "test"

    val blockedUtility = blockedClient.getUtility()
    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = "load"
    ctxmap["client"] = blockedClient
    ctxmap["utility"] = blockedUtility
    val ctx = blockedUtility.makeContext(ctxmap, null)

    val fetchdef = fhMap("method", "GET", "headers", linkedMapOf<String, Any?>())
    try {
      blockedUtility.fetcher(ctx, "http://example.com/test", fetchdef)
      throw AssertionError("expected error for test mode fetch")
    } catch (e: RuntimeException) {
      assertTrue(e.message.toString().contains("blocked"), "expected error containing 'blocked', got: ${e.message}")
    }
  }

  @Test
  fun makeContextBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "makeContext", "basic")) { entry ->
      val inm = Helpers.toMapAny(entry["in"])
      if (inm != null) {
        val ctx = utility.makeContext(inm, null)
        val out = linkedMapOf<String, Any?>()
        out["id"] = ctx.id
        out["op"] = fhMap("name", ctx.op.name, "input", ctx.op.input)
        out
      } else {
        null
      }
    }
  }

  @Test
  fun makeFetchDefBasic() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestFullCtx(client, utility)
    ctx.spec = Spec(
      fhMap(
        "base", "http://localhost:8080",
        "prefix", "/api",
        "path", "items/{id}",
        "suffix", "",
        "params", fhMap("id", "item01"),
        "query", linkedMapOf<String, Any?>(),
        "headers", fhMap("content-type", "application/json"),
        "method", "GET",
        "step", "start",
      ),
    )
    ctx.result = Result(linkedMapOf())

    val fetchdef = utility.makeFetchDef(ctx)
    assertEquals("GET", fetchdef["method"])
    val url = if (fetchdef["url"] is String) fetchdef["url"] as String else ""
    assertTrue(url.contains("/api/items/item01"), "expected url to contain /api/items/item01, got $url")
    assertEquals("application/json", (fetchdef["headers"] as MutableMap<String, Any?>)["content-type"])
    assertNull(fetchdef["body"], "expected null body")
  }

  @Test
  fun makeFetchDefWithBody() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestFullCtx(client, utility)
    ctx.spec = Spec(
      fhMap(
        "base", "http://localhost:8080",
        "prefix", "",
        "path", "items",
        "suffix", "",
        "params", linkedMapOf<String, Any?>(),
        "query", linkedMapOf<String, Any?>(),
        "headers", linkedMapOf<String, Any?>(),
        "method", "POST",
        "step", "start",
        "body", fhMap("name", "test"),
      ),
    )
    ctx.result = Result(linkedMapOf())

    val fetchdef = utility.makeFetchDef(ctx)
    assertEquals("POST", fetchdef["method"])
    assertTrue(fetchdef["body"] is String, "expected body string, got ${fetchdef["body"]}")
    assertTrue((fetchdef["body"] as String).contains("\"name\""), "expected body to contain name")
  }

  @Test
  fun makeOptionsBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "makeOptions", "basic")) { entry ->
      val inm = Helpers.toMapAny(entry["in"])
      val ctxmap = linkedMapOf<String, Any?>()
      if (inm != null) {
        ctxmap["options"] = inm["options"]
        ctxmap["config"] = inm["config"]
      }
      val ctx = utility.makeContext(ctxmap, null)
      ctx.client = client
      ctx.utility = utility
      utility.makeOptions(ctx)
    }
  }

  @Test
  fun makeRequestBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "makeRequest", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      ctx.options = client.optionsMap()

      utility.makeRequest(ctx)

      val entryCtx = Helpers.toMapAny(entry["ctx"])
      if (entryCtx != null) {
        if (ctx.response != null) {
          entryCtx["response"] = "exists"
        }
        if (ctx.result != null) {
          entryCtx["result"] = "exists"
        }
      }

      null
    }
  }

  @Test
  fun makeResponseBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "makeResponse", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      RunnerSupport.fixctx(ctx, client)

      utility.makeResponse(ctx)

      val entryCtx = Helpers.toMapAny(entry["ctx"])
      if (entryCtx != null && ctx.result != null) {
        entryCtx["result"] = fhMap(
          "ok", ctx.result!!.ok,
          "status", ctx.result!!.status,
          "statusText", ctx.result!!.statusText,
          "headers", ctx.result!!.headers,
          "body", ctx.result!!.body,
        )
      }

      null
    }
  }

  @Test
  fun makeResultBasic() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestFullCtx(client, utility)
    ctx.spec = Spec(
      fhMap(
        "base", "http://localhost:8080",
        "prefix", "/api",
        "path", "items/{id}",
        "suffix", "",
        "params", fhMap("id", "item01"),
        "query", linkedMapOf<String, Any?>(),
        "headers", linkedMapOf<String, Any?>(),
        "method", "GET",
        "step", "start",
      ),
    )
    ctx.result = Result(
      fhMap(
        "ok", true,
        "status", 200,
        "statusText", "OK",
        "headers", linkedMapOf<String, Any?>(),
        "resdata", fhMap("id", "item01", "name", "Test"),
      ),
    )

    val result = utility.makeResult(ctx)
    assertEquals(200, result.status)
  }

  @Test
  fun makeResultNoSpec() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestFullCtx(client, utility)
    ctx.spec = null
    ctx.result = Result(fhMap("ok", true, "status", 200, "statusText", "OK", "headers", linkedMapOf<String, Any?>()))

    try {
      utility.makeResult(ctx)
      throw AssertionError("expected error for null spec")
    } catch (e: RuntimeException) {
      // expected
    }
  }

  @Test
  fun makeResultNoResult() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestFullCtx(client, utility)
    ctx.spec = Spec(fhMap("step", "start"))
    ctx.result = null

    try {
      utility.makeResult(ctx)
      throw AssertionError("expected error for null result")
    } catch (e: RuntimeException) {
      // expected
    }
  }

  @Test
  fun makeSpecBasic() {
    val setupOpts = getSpec(primary(), "makeSpec", "DEF", "setup", "a")
    val specClient = UnivecSDK.testSDK(null, setupOpts)
    val specUtility = specClient.getUtility()

    runset(getSpec(primary(), "makeSpec", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, specClient, specUtility)
      ctx.options = specClient.optionsMap()

      specUtility.makeSpec(ctx)

      val entryCtx = Helpers.toMapAny(entry["ctx"])
      if (entryCtx != null && ctx.spec != null) {
        entryCtx["spec"] = fhMap(
          "base", ctx.spec!!.base,
          "prefix", ctx.spec!!.prefix,
          "suffix", ctx.spec!!.suffix,
          "method", ctx.spec!!.method,
          "params", ctx.spec!!.params,
          "query", ctx.spec!!.query,
          "headers", ctx.spec!!.headers,
          "step", ctx.spec!!.step,
        )
      }

      null
    }
  }

  @Test
  fun makePointBasic() {
    val client = client()
    val utility = client.getUtility()
    val ctx = makeTestCtx(client, utility, null)
    val parts = mutableListOf<Any?>()
    parts.add("items")
    parts.add("{id}")
    val point = fhMap(
      "parts", parts,
      "args", fhMap("params", mutableListOf<Any?>()),
      "params", mutableListOf<Any?>(),
      "alias", linkedMapOf<String, Any?>(),
      "select", linkedMapOf<String, Any?>(),
      "active", true,
      "transform", linkedMapOf<String, Any?>(),
    )
    ctx.op.points = mutableListOf(point)

    utility.makePoint(ctx)
    assertNotNull(ctx.point, "expected point to be set")
  }

  @Test
  fun makeUrlBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "makeUrl", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      if (ctx.result == null) {
        ctx.result = Result(linkedMapOf())
      }
      utility.makeUrl(ctx)
    }
  }

  @Test
  fun operatorBasic() {
    runset(getSpec(primary(), "operator", "basic")) { entry ->
      val inm = Helpers.toMapAny(entry["in"])
      val op = Operation(inm ?: linkedMapOf())
      fhMap("entity", op.entity, "name", op.name, "input", op.input, "points", op.points)
    }
  }

  @Test
  fun paramBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "param", "basic")) { entry ->
      val args = if (entry["args"] is List<*>) (entry["args"] as List<Any?>) else mutableListOf<Any?>()
      if (args.size < 2) {
        return@runset null
      }

      var ctxmap = Helpers.toMapAny(args[0])
      if (ctxmap == null) {
        ctxmap = linkedMapOf()
      }
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      val paramdef = args[1]

      val result = utility.param(ctx, paramdef)

      val matchSpec = Helpers.toMapAny(entry["match"])
      if (matchSpec != null) {
        val ctxMatch = Helpers.toMapAny(matchSpec["ctx"])
        if (ctxMatch != null) {
          var entryCtx = Helpers.toMapAny(entry["ctx"])
          if (entryCtx == null) {
            entryCtx = linkedMapOf()
            entry["ctx"] = entryCtx
          }
          val specMatch = Helpers.toMapAny(ctxMatch["spec"])
          if (specMatch != null && ctx.spec != null && specMatch["alias"] is Map<*, *>) {
            entryCtx["spec"] = fhMap("alias", ctx.spec!!.alias)
          }
        }
      }

      result
    }
  }

  @Test
  fun prepareAuthBasic() {
    val setupOpts = getSpec(primary(), "prepareAuth", "DEF", "setup", "a")
    val authClient = UnivecSDK.testSDK(null, setupOpts)
    val authUtility = authClient.getUtility()

    runset(getSpec(primary(), "prepareAuth", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, authClient, authUtility)
      RunnerSupport.fixctx(ctx, authClient)

      authUtility.prepareAuth(ctx)

      val entryCtx = Helpers.toMapAny(entry["ctx"])
      if (entryCtx != null && ctx.spec != null) {
        entryCtx["spec"] = fhMap("headers", ctx.spec!!.headers)
      }

      null
    }
  }

  @Test
  fun prepareBodyBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "prepareBody", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      RunnerSupport.fixctx(ctx, client)
      utility.prepareBody(ctx)
    }
  }

  @Test
  fun prepareHeadersBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "prepareHeaders", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      utility.prepareHeaders(ctx)
    }
  }

  @Test
  fun prepareMethodBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "prepareMethod", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      utility.prepareMethod(ctx)
    }
  }

  @Test
  fun prepareParamsBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "prepareParams", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      utility.prepareParams(ctx)
    }
  }

  @Test
  fun preparePathBasic() {
    // Was two hand-written cases that had drifted out of the shared corpus
    // (the preparePath fixture shipped as an empty `set: []`).
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "preparePath", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      utility.preparePath(ctx)
    }
  }

  @Test
  fun prepareQueryBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "prepareQuery", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      utility.prepareQuery(ctx)
    }
  }

  @Test
  fun resultBasicBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "resultBasic", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)
      RunnerSupport.fixctx(ctx, client)

      val result = utility.resultBasic(ctx)

      val out = fhMap("status", result.status, "statusText", result.statusText)
      if (result.err != null) {
        out["err"] = fhMap("message", result.err!!.message)
      }

      out
    }
  }

  @Test
  fun resultBodyBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "resultBody", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)

      utility.resultBody(ctx)

      val entryCtx = Helpers.toMapAny(entry["ctx"])
      if (entryCtx != null && ctx.result != null) {
        entryCtx["result"] = fhMap("body", ctx.result!!.body)
      }

      null
    }
  }

  @Test
  fun resultHeadersBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "resultHeaders", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)

      utility.resultHeaders(ctx)

      val entryCtx = Helpers.toMapAny(entry["ctx"])
      if (entryCtx != null && ctx.result != null) {
        entryCtx["result"] = fhMap("headers", ctx.result!!.headers)
      }

      null
    }
  }

  @Test
  fun transformRequestBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "transformRequest", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)

      val result = utility.transformRequest(ctx)

      val entryCtx = Helpers.toMapAny(entry["ctx"])
      if (entryCtx != null && ctx.spec != null) {
        val specMap = Helpers.toMapAny(entryCtx["spec"])
        specMap?.put("step", ctx.spec!!.step)
      }

      result
    }
  }

  @Test
  fun transformResponseBasic() {
    val client = client()
    val utility = client.getUtility()
    runset(getSpec(primary(), "transformResponse", "basic")) { entry ->
      val ctxmap = Helpers.toMapAny(entry["ctx"])
      val ctx = makeCtxFromMap(ctxmap, client, utility)

      val result = utility.transformResponse(ctx)

      val entryCtx = Helpers.toMapAny(entry["ctx"])
      if (entryCtx != null && ctx.spec != null) {
        val specMap = Helpers.toMapAny(entryCtx["spec"])
        specMap?.put("step", ctx.spec!!.step)
      }

      result
    }
  }
}
