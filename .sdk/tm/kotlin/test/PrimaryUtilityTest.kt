package KOTLINPACKAGE.sdktest

// Drives the primary utility functions against the shared test.json spec
// (../.sdk/test/test.json, section "primary") through the VENDORED omni
// runner (OmniResolver over test/vendor/omni). Mirrors
// tm/java/test/PrimaryUtilityTest.java and tm/go/test/primary_utility_test.go.
//
// Subjects receive omni's native argument list as plain values: a ctx entry
// arrives as args[0], a MAP - OmniResolver.omniCtx builds the typed Context
// a generated utility takes, and OmniResolver.omniSyncCtx writes the
// observable ctx state back for `match: {ctx: ...}` assertions.

import java.util.function.BiFunction

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assertions.fail
import org.junit.jupiter.api.Test

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Entity
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.Operation
import KOTLINPACKAGE.core.UnivecSDK
import KOTLINPACKAGE.core.Result
import KOTLINPACKAGE.core.SdkError
import KOTLINPACKAGE.core.Spec
import KOTLINPACKAGE.core.Utility
import KOTLINPACKAGE.feature.BaseFeature
import KOTLINPACKAGE.sdktest.FeatureHarness.fhMap

@Suppress("UNCHECKED_CAST")
class PrimaryUtilityTest {

  companion object {
    const val TEST_JSON_FILE = "../.sdk/test/test.json"

    // PENDING sections are the ones deliberately left empty in the shared
    // corpus (.sdk/test/primary/<name>.aon). Everything else MUST
    // contribute cases.
    val PENDING = setOf(
      "fetcher", "makeFetchDef", "makeResult",
      "featureAdd", "featureHook", "featureInit",
    )

    // One client + one corpus runner for the whole suite (the go shape).
    private var CLIENT: UnivecSDK? = null
    private var UTILITY: Utility? = null
    private var RUN: OmniResolver.Run? = null

    @Synchronized
    fun run(): OmniResolver.Run {
      var r = RUN
      if (null == r) {
        val client = UnivecSDK.testSDK()
        CLIENT = client
        UTILITY = client.getUtility()
        r = OmniResolver.makeRunner(TEST_JSON_FILE, client).runner("primary", null)
        assertNotNull(r.spec, "primary section not found in test.json")
        RUN = r
      }
      return r
    }

    fun client(): UnivecSDK {
      run()
      return CLIENT!!
    }

    fun utility(): Utility {
      run()
      return UTILITY!!
    }
  }

  // Run one corpus section, failing loudly when it would run ZERO cases.
  // A renamed section, a fixture that failed to compile, or an empty set
  // used to report PASS while running zero assertions - the whole point of
  // a shared oracle lost without a single red test. (The guard lives here
  // rather than in the runner, which is vendored verbatim; the shared
  // corpus is a v0 spec, and v0 tolerates an empty set.)
  private fun runsection(name: String, subject: OmniResolver.Subject) {
    val run = run()
    val section = Helpers.toMapAny(run.spec[name])
    assertNotNull(
      section,
      "test corpus section \"$name\" missing - check the name against .sdk/test/primary/",
    )
    val basic = Helpers.toMapAny(section!!["basic"])
    val set = basic?.get("set")
    if (set !is List<*>) {
      fail<Any>("test corpus section \"$name\" has no basic.set list - zero cases would run")
      return
    }
    if (set.isEmpty() && !PENDING.contains(name)) {
      fail<Any>(
        "test corpus section \"$name\" is EMPTY - zero cases would run; " +
          "add cases, or mark the fixture PENDING in .sdk/test/primary/",
      )
      return
    }
    run.runset(basic, subject)
  }

  // Helper: create basic test context.
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

  // Helper: create full test context with point and match.
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
    val utility = utility()

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
    val utility = utility()
    val ctx = makeTestCtx(client, utility, null)
    val cleaned = utility.clean(ctx, fhMap("key", "secret123", "name", "test"))
    assertNotNull(cleaned, "cleaned should not be null")
  }

  @Test
  fun cleanCorpus() {
    runsection("clean") { args ->
      if (2 != args.size) {
        throw RuntimeException("clean: expected 2 args, got ${args.size}")
      }
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      utility().clean(ctx, args[1])
    }
  }

  @Test
  fun doneBasic() {
    runsection("done") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      utility().done(ctx)
    }
  }

  @Test
  fun makeErrorBasic() {
    runsection("makeError") { args ->
      val ctxarg = if (args.isEmpty()) linkedMapOf<String, Any?>() else args[0]

      val ctx = OmniResolver.omniCtx(ctxarg, client(), utility())

      var err: RuntimeException? = null
      if (args.size > 1) {
        err = RunnerSupport.errFromMap(Helpers.toMapAny(args[1]))
      }

      utility().makeError(ctx, err)
    }
  }

  @Test
  fun makeErrorNoThrow() {
    val client = client()
    val utility = utility()
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
    val utility = utility()
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
    val hookClient = UnivecSDK.testSDK()
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
    val initClient = UnivecSDK.testSDK()
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
    val initClient = UnivecSDK.testSDK()
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
    // Concrete base: a live construction must satisfy any server variables a
    // templated base URL declares; a literal base sidesteps the requirement.
    val liveClient = UnivecSDK(
      fhMap(
        "base", "http://localhost:8080",
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
    // Create a live SDK then set mode to test (not using testSDK, which
    // installs the test feature).
    // Concrete base: a live construction must satisfy any server variables a
    // templated base URL declares; a literal base sidesteps the requirement.
    val blockedClient = UnivecSDK(
      fhMap(
        "base", "http://localhost:8080",
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
    runsection("makeContext") { args ->
      val inm = Helpers.toMapAny(args.getOrNull(0))
      if (inm != null) {
        val ctx = utility().makeContext(inm, null)
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
    val utility = utility()
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
    val utility = utility()
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
    runsection("makeOptions") { args ->
      val inm = Helpers.toMapAny(args.getOrNull(0))
      val ctxmap = linkedMapOf<String, Any?>()
      if (inm != null) {
        ctxmap["options"] = inm["options"]
        ctxmap["config"] = inm["config"]
      }
      val ctx = utility().makeContext(ctxmap, null)
      ctx.client = client()
      ctx.utility = utility()
      utility().makeOptions(ctx)
    }
  }

  @Test
  fun makeRequestBasic() {
    runsection("makeRequest") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      ctx.options = client().optionsMap()

      utility().makeRequest(ctx)

      // Expose response/result existence for the match assertions.
      OmniResolver.omniSyncCtx(args[0], ctx)

      null
    }
  }

  @Test
  fun makeResponseBasic() {
    runsection("makeResponse") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())

      utility().makeResponse(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)

      null
    }
  }

  @Test
  fun makeResultBasic() {
    val client = client()
    val utility = utility()
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
    val utility = utility()
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
    val utility = utility()
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
    val setupOpts = RunnerSupport.getSpec(run().spec, "makeSpec", "DEF", "setup", "a")
    val specClient = UnivecSDK.testSDK(null, setupOpts)
    val specUtility = specClient.getUtility()

    runsection("makeSpec") { args ->
      val ctx = OmniResolver.omniCtx(args[0], specClient, specUtility)
      ctx.options = specClient.optionsMap()

      specUtility.makeSpec(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)

      null
    }
  }

  // A minimal Entity: Context resolves the op through the Entity interface,
  // and a literal {name: ...} map from the fixture is not one - entname
  // would be "" and every lookup would miss, reporting point_no_points for
  // all seven cases. TS reads the same field with getprop and accepts the
  // plain map. (The java peer is PlEntity; the go peer is plEntity.)
  private class PuEntity(override val name: String) : Entity {
    override fun make(): Entity = PuEntity(name)

    override fun data(vararg args: Any?): Any? = null

    override fun match(vararg args: Any?): Any? = null
  }

  // Corpus-driven, like go/java: TS returns the error AS the value; kotlin
  // throws SdkError. The corpus says `match: out: code` for both, so the
  // error is normalised to a map carrying its code here rather than forking
  // the fixture per language.
  @Test
  fun makePointBasic() {
    runsection("makePoint") { args ->
      var ctxmap = Helpers.toMapAny(args.getOrNull(0))
      if (ctxmap == null) {
        ctxmap = linkedMapOf()
      }

      val em = Helpers.toMapAny(ctxmap["entity"])
      if (em != null) {
        val name = if (em["name"] is String) em["name"] as String else ""
        val swapped = LinkedHashMap<String, Any?>(ctxmap)
        swapped["entity"] = PuEntity(name)
        ctxmap = swapped
      }

      val ctx = OmniResolver.omniCtx(ctxmap, client(), utility())
      try {
        utility().makePoint(ctx)
      } catch (e: SdkError) {
        fhMap("code", e.code)
      }
    }
  }

  @Test
  fun makeUrlBasic() {
    runsection("makeUrl") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      if (ctx.result == null) {
        ctx.result = Result(linkedMapOf())
      }
      utility().makeUrl(ctx)
    }
  }

  @Test
  fun operatorBasic() {
    runsection("operator") { args ->
      val inm = Helpers.toMapAny(args.getOrNull(0))
      val op = Operation(inm ?: linkedMapOf())
      fhMap("entity", op.entity, "name", op.name, "input", op.input, "points", op.points)
    }
  }

  @Test
  fun paramBasic() {
    runsection("param") { args ->
      if (args.size < 2) {
        return@runsection null
      }

      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      val paramdef = args[1]

      val result = utility().param(ctx, paramdef)

      // The spec alias mutation is what the match assertion reads.
      OmniResolver.omniSyncCtx(args[0], ctx)

      result
    }
  }

  @Test
  fun prepareAuthBasic() {
    val setupOpts = RunnerSupport.getSpec(run().spec, "prepareAuth", "DEF", "setup", "a")
    val authClient = UnivecSDK.testSDK(null, setupOpts)
    val authUtility = authClient.getUtility()

    runsection("prepareAuth") { args ->
      val ctx = OmniResolver.omniCtx(args[0], authClient, authUtility)

      authUtility.prepareAuth(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)

      null
    }
  }

  @Test
  fun prepareBodyBasic() {
    runsection("prepareBody") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      utility().prepareBody(ctx)
    }
  }

  @Test
  fun prepareHeadersBasic() {
    runsection("prepareHeaders") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      utility().prepareHeaders(ctx)
    }
  }

  @Test
  fun prepareMethodBasic() {
    runsection("prepareMethod") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      // An op the API does not define resolves NO method; ts answers
      // undefined there and kotlin answers null - both are "no value" to
      // the corpus.
      val method = utility().prepareMethod(ctx)
      if (method.isNullOrEmpty()) null else method
    }
  }

  @Test
  fun prepareParamsBasic() {
    runsection("prepareParams") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      utility().prepareParams(ctx)
    }
  }

  // Was two hand-written cases that had drifted out of the shared corpus
  // (the preparePath fixture shipped as an empty `set: []`). Now driven by
  // the corpus like every other section, so all ports assert the same
  // separator/blank-segment behaviour.
  @Test
  fun preparePathBasic() {
    runsection("preparePath") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      utility().preparePath(ctx)
    }
  }

  @Test
  fun prepareQueryBasic() {
    runsection("prepareQuery") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())
      utility().prepareQuery(ctx)
    }
  }

  @Test
  fun resultBasicBasic() {
    runsection("resultBasic") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())

      val result = utility().resultBasic(ctx)

      val out = fhMap("status", result.status, "statusText", result.statusText)
      if (result.err != null) {
        out["err"] = fhMap("message", result.err!!.message)
      }

      out
    }
  }

  @Test
  fun resultBodyBasic() {
    runsection("resultBody") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())

      utility().resultBody(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)

      null
    }
  }

  @Test
  fun resultHeadersBasic() {
    runsection("resultHeaders") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())

      utility().resultHeaders(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)

      null
    }
  }

  @Test
  fun transformRequestBasic() {
    runsection("transformRequest") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())

      val result = utility().transformRequest(ctx)

      // The step advance is what the match assertion reads.
      OmniResolver.omniSyncCtx(args[0], ctx)

      result
    }
  }

  @Test
  fun transformResponseBasic() {
    runsection("transformResponse") { args ->
      val ctx = OmniResolver.omniCtx(args[0], client(), utility())

      val result = utility().transformResponse(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)

      result
    }
  }
}
