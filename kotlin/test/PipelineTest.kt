package voxgig.univecsdk.sdktest

// Direct unit tests for the operation-pipeline utilities. These drive the
// error and edge branches (missing spec/response/result, 4xx handling,
// transport failures, feature add semantics, auth header shaping).

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

import voxgig.univecsdk.core.Context
import voxgig.univecsdk.core.Entity
import voxgig.univecsdk.core.Operation
import voxgig.univecsdk.core.UnivecSDK
import voxgig.univecsdk.core.Response
import voxgig.univecsdk.core.Result
import voxgig.univecsdk.core.SdkError
import voxgig.univecsdk.core.Spec
import voxgig.univecsdk.core.Utility
import voxgig.univecsdk.feature.BaseFeature
import voxgig.univecsdk.utility.struct.Struct
import voxgig.univecsdk.sdktest.FeatureHarness.fhErrCode
import voxgig.univecsdk.sdktest.FeatureHarness.fhMap
import voxgig.univecsdk.sdktest.FeatureHarness.fhResponse

@Suppress("UNCHECKED_CAST")
class PipelineTest {

  private fun plClient(sdkopts: MutableMap<String, Any?>?): UnivecSDK {
    return UnivecSDK.testSDK(null, sdkopts)
  }

  private fun plCtx(client: UnivecSDK, utility: Utility, ctrl: MutableMap<String, Any?>?): Context {
    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = "load"
    ctxmap["client"] = client
    ctxmap["utility"] = utility
    if (ctrl != null) {
      ctxmap["ctrl"] = ctrl
    }
    return utility.makeContext(ctxmap, client.getRootCtx())
  }

  // --- feature order (PR #2) ----------------------------------------------

  // resolveOpts runs makeOptions over an options.feature value (map or list)
  // and returns the derived options so __derived__.featureorder can be
  // asserted.
  private fun resolveOpts(feature: Any?): MutableMap<String, Any?> {
    val client = plClient(null)
    val utility = client.getUtility()
    val options = linkedMapOf<String, Any?>("feature" to feature)
    val cfg = linkedMapOf<String, Any?>("options" to linkedMapOf<String, Any?>())
    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["client"] = client
    ctxmap["utility"] = utility
    ctxmap["options"] = options
    ctxmap["config"] = cfg
    val ctx = utility.makeContext(ctxmap, client.getRootCtx())
    return utility.makeOptions(ctx)
  }

  private fun featureOrder(opts: MutableMap<String, Any?>): String {
    val raw = Struct.getpath(opts, listOf("__derived__", "featureorder"))
    val names = mutableListOf<String>()
    if (raw is List<*>) {
      for (o in raw) {
        names.add(o as? String ?: "")
      }
    }
    return names.joinToString(",")
  }

  @Test
  fun featureOrderMapIsTestFirst() {
    val feature = linkedMapOf<String, Any?>(
      "metrics" to linkedMapOf<String, Any?>("active" to true),
      "test" to linkedMapOf<String, Any?>("active" to true),
    )
    assertEquals("test,metrics", featureOrder(resolveOpts(feature)))
  }

  @Test
  fun featureOrderArrayPreservesExplicitOrder() {
    val feature = mutableListOf<Any?>(
      linkedMapOf<String, Any?>("name" to "metrics", "active" to true),
      linkedMapOf<String, Any?>("name" to "test", "active" to true),
    )
    val o = resolveOpts(feature)
    assertEquals("metrics,test", featureOrder(o))
    // The list is normalized to a map for merge/init; opts are preserved.
    assertEquals(true, Struct.getpath(o, listOf("feature", "metrics", "active")))
    assertEquals(true, Struct.getpath(o, listOf("feature", "test", "active")))
  }

  @Test
  fun featureOrderMapNoTestIsSorted() {
    val feature = linkedMapOf<String, Any?>(
      "retry" to linkedMapOf<String, Any?>("active" to true),
      "cache" to linkedMapOf<String, Any?>("active" to true),
    )
    assertEquals("cache,retry", featureOrder(resolveOpts(feature)))
  }

  // plEntity is a minimal fake entity for the list-wrap test.
  private class PlEntity(override val name: String, val made: MutableList<Any?>) : Entity {
    override fun make(): Entity = PlEntity(name, made)

    override fun data(vararg args: Any?): Any? {
      if (args.isNotEmpty() && args[0] != null) {
        made.add(args[0])
      }
      return null
    }

    override fun match(vararg args: Any?): Any? = null
  }

  private fun errCodeOf(r: () -> Unit): String? {
    return try {
      r()
      null
    } catch (e: SdkError) {
      e.code
    }
  }

  private fun stepSpecMap(): MutableMap<String, Any?> {
    val m = linkedMapOf<String, Any?>()
    m["step"] = "s"
    return m
  }

  // --- makeResponse ---------------------------------------------------------

  @Test
  fun makeResponse_guardsMissingSpecResponseResult() {
    val client = plClient(null)
    val utility = client.getUtility()

    var ctx = plCtx(client, utility, null)
    ctx.spec = null
    ctx.response = Response(linkedMapOf())
    ctx.result = Result(linkedMapOf())
    val c1 = ctx
    assertEquals("response_no_spec", errCodeOf { utility.makeResponse(c1) })

    ctx = plCtx(client, utility, null)
    ctx.spec = Spec(stepSpecMap())
    ctx.response = null
    ctx.result = Result(linkedMapOf())
    val c2 = ctx
    assertEquals("response_no_response", errCodeOf { utility.makeResponse(c2) })

    ctx = plCtx(client, utility, null)
    ctx.spec = Spec(stepSpecMap())
    ctx.response = Response(linkedMapOf())
    ctx.result = null
    val c3 = ctx
    assertEquals("response_no_result", errCodeOf { utility.makeResponse(c3) })
  }

  @Test
  fun makeResponse_4xxSetsResultErrAndCopiesHeaders() {
    val client = plClient(null)
    val utility = client.getUtility()

    val ctx = plCtx(client, utility, null)
    ctx.spec = Spec(stepSpecMap())
    ctx.response = Response(fhResponse(404, null, fhMap("x-a", "1")))
    ctx.result = Result(linkedMapOf())
    utility.makeResponse(ctx)
    assertNotNull(ctx.result!!.err, "expected result.err set on 4xx")
    assertEquals(404, ctx.result!!.status)
    assertEquals("1", ctx.result!!.headers["x-a"])
  }

  @Test
  fun makeResponse_2xxParsesBodyAndMarksOk() {
    val client = plClient(null)
    val utility = client.getUtility()

    val ctx = plCtx(client, utility, null)
    ctx.spec = Spec(stepSpecMap())
    ctx.response = Response(fhResponse(200, fhMap("v", 1), null))
    ctx.result = Result(linkedMapOf())
    utility.makeResponse(ctx)
    assertTrue(ctx.result!!.ok, "expected ok result")
    val body = ctx.result!!.body as MutableMap<String, Any?>
    assertNotNull(body, "expected parsed body")
    assertEquals(1, body["v"])
  }

  @Test
  fun makeResponse_recordsToCtrlExplain() {
    val client = plClient(null)
    val utility = client.getUtility()

    val ctx = plCtx(client, utility, fhMap("explain", linkedMapOf<String, Any?>()))
    ctx.spec = Spec(stepSpecMap())
    ctx.response = Response(fhResponse(200, fhMap("v", 2), null))
    ctx.result = Result(linkedMapOf())
    utility.makeResponse(ctx)
    assertNotNull(ctx.ctrl.explain!!["result"], "expected explain.result recorded")
  }

  // --- makeResult -----------------------------------------------------------

  @Test
  fun makeResult_guardsMissingSpecResult() {
    val client = plClient(null)
    val utility = client.getUtility()

    var ctx = plCtx(client, utility, null)
    ctx.spec = null
    ctx.result = Result(linkedMapOf())
    val c1 = ctx
    assertEquals("result_no_spec", errCodeOf { utility.makeResult(c1) })

    ctx = plCtx(client, utility, null)
    ctx.spec = Spec(stepSpecMap())
    ctx.result = null
    val c2 = ctx
    assertEquals("result_no_result", errCodeOf { utility.makeResult(c2) })
  }

  @Test
  fun makeResult_listOpWrapsResdataIntoEntities() {
    val client = plClient(null)
    val utility = client.getUtility()

    val made = mutableListOf<Any?>()
    val ctx = plCtx(client, utility, null)
    val opdef = linkedMapOf<String, Any?>()
    opdef["entity"] = "x"
    opdef["name"] = "list"
    ctx.op = Operation(opdef)
    ctx.entity = PlEntity("x", made)
    ctx.spec = Spec(stepSpecMap())
    val resmap = linkedMapOf<String, Any?>()
    val resdata = mutableListOf<Any?>()
    resdata.add(fhMap("a", 1))
    resdata.add(fhMap("a", 2))
    resmap["resdata"] = resdata
    ctx.result = Result(resmap)

    val result = utility.makeResult(ctx)
    val wrapped = result.resdata as List<Any?>
    assertEquals(2, wrapped.size, "expected 2 wrapped entities")
    assertEquals(2, made.size, "expected 2 data() calls")
  }

  @Test
  fun makeResult_emptyListYieldsEmptyResdata() {
    val client = plClient(null)
    val utility = client.getUtility()

    val made = mutableListOf<Any?>()
    val ctx = plCtx(client, utility, null)
    val opdef = linkedMapOf<String, Any?>()
    opdef["entity"] = "x"
    opdef["name"] = "list"
    ctx.op = Operation(opdef)
    ctx.entity = PlEntity("x", made)
    ctx.spec = Spec(stepSpecMap())
    val resmap = linkedMapOf<String, Any?>()
    resmap["resdata"] = mutableListOf<Any?>()
    ctx.result = Result(resmap)

    val result = utility.makeResult(ctx)
    assertTrue(result.resdata is List<*>, "expected list resdata")
    assertEquals(0, (result.resdata as List<Any?>).size)
  }

  // --- makeRequest ----------------------------------------------------------

  private fun reqSpec(): Spec {
    val m = linkedMapOf<String, Any?>()
    m["base"] = "http://h"
    m["path"] = "a"
    m["method"] = "GET"
    m["headers"] = linkedMapOf<String, Any?>()
    m["step"] = "s"
    return Spec(m)
  }

  @Test
  fun makeRequest_guardsMissingSpec() {
    val client = plClient(null)
    val utility = client.getUtility()
    utility.fetcher = { _, _, _ -> fhResponse(200, null, null) }

    val ctx = plCtx(client, utility, null)
    ctx.spec = null
    assertEquals("request_no_spec", errCodeOf { utility.makeRequest(ctx) })
  }

  @Test
  fun makeRequest_transportErrorCarriedOnResponse() {
    val client = plClient(null)
    val utility = client.getUtility()
    utility.fetcher = { ctx, _, _ -> throw ctx.makeError("boom", "boom") }

    val ctx = plCtx(client, utility, null)
    ctx.spec = reqSpec()
    val resp = utility.makeRequest(ctx)
    assertNotNull(resp.err, "expected transport error carried")
    assertEquals("boom", fhErrCode(resp.err))
  }

  @Test
  fun makeRequest_nilTransportResultBecomesResponseError() {
    val client = plClient(null)
    val utility = client.getUtility()
    utility.fetcher = { _, _, _ -> null }

    val ctx = plCtx(client, utility, null)
    ctx.spec = reqSpec()
    val resp = utility.makeRequest(ctx)
    assertNotNull(resp.err, "expected response error for nil transport result")
  }

  @Test
  fun makeRequest_normalTransportResponseWrapped() {
    val client = plClient(null)
    val utility = client.getUtility()
    utility.fetcher = { _, _, _ -> fhResponse(200, fhMap("a", 1), null) }

    val ctx = plCtx(client, utility, null)
    ctx.spec = reqSpec()
    val resp = utility.makeRequest(ctx)
    assertEquals(200, resp.status)
  }

  @Test
  fun makeRequest_recordsFetchdefToCtrlExplain() {
    val client = plClient(null)
    val utility = client.getUtility()
    utility.fetcher = { _, _, _ -> fhResponse(200, null, null) }

    val ctx = plCtx(client, utility, fhMap("explain", linkedMapOf<String, Any?>()))
    ctx.spec = reqSpec()
    utility.makeRequest(ctx)
    assertNotNull(ctx.ctrl.explain!!["fetchdef"], "expected explain.fetchdef recorded")
  }

  // --- done / makeError -------------------------------------------------------

  @Test
  fun done_returnsResdataOnSuccess() {
    val client = plClient(null)
    val utility = client.getUtility()

    val ctx = plCtx(client, utility, null)
    val resmap = linkedMapOf<String, Any?>()
    resmap["ok"] = true
    resmap["resdata"] = fhMap("id", "i1")
    ctx.result = Result(resmap)
    val out = utility.done(ctx)
    val om = out as MutableMap<String, Any?>
    assertNotNull(om, "expected resdata")
    assertEquals("i1", om["id"])
  }

  @Test
  fun done_errorsWhenNotOk() {
    val client = plClient(null)
    val utility = client.getUtility()

    val ctx = plCtx(client, utility, null)
    val resmap = linkedMapOf<String, Any?>()
    resmap["ok"] = false
    ctx.result = Result(resmap)
    try {
      utility.done(ctx)
      throw AssertionError("expected an error when result not ok")
    } catch (e: RuntimeException) {
      // expected
    }
  }

  @Test
  fun makeError_returnsResdataWhenThrowFalse() {
    val client = plClient(null)
    val utility = client.getUtility()

    val ctx = plCtx(client, utility, null)
    ctx.ctrl.throwing = false
    val resmap = linkedMapOf<String, Any?>()
    resmap["ok"] = false
    resmap["resdata"] = "fallback"
    ctx.result = Result(resmap)
    val out = utility.makeError(ctx, ctx.makeError("test_code", "test message"))
    assertEquals("fallback", out)
  }

  @Test
  fun makeError_recordsToCtrlExplain() {
    val client = plClient(null)
    val utility = client.getUtility()

    val ctx = plCtx(client, utility, fhMap("explain", linkedMapOf<String, Any?>()))
    ctx.ctrl.throwing = false
    val resmap = linkedMapOf<String, Any?>()
    resmap["ok"] = false
    ctx.result = Result(resmap)
    utility.makeError(ctx, ctx.makeError("x", "x"))
    assertNotNull(ctx.ctrl.explain!!["err"], "expected explain.err recorded")
  }

  // --- featureAdd -------------------------------------------------------------

  @Test
  fun featureAdd_appendsByDefault() {
    val client = plClient(null)
    val utility = client.getUtility()
    val ctx = plCtx(client, utility, null)
    val start = client.features.size
    val f = BaseFeature()
    utility.featureAdd(ctx, f)
    assertEquals(start + 1, client.features.size)
    assertEquals(f, client.features[client.features.size - 1], "expected the feature appended last")
  }

  @Test
  fun featureAdd_orderingBeforeAfterReplace() {
    val client = plClient(null)
    val utility = client.getUtility()
    val ctx = plCtx(client, utility, null)
    client.features = mutableListOf()

    utility.featureAdd(ctx, named("a"))
    utility.featureAdd(ctx, named("b"))
    assertEquals("a,b", names(client), "setup")

    val before = named("z1")
    before.addOpts = fhMap("__before__", "b")
    utility.featureAdd(ctx, before)
    assertEquals("a,z1,b", names(client), "__before__")

    val after = named("z2")
    after.addOpts = fhMap("__after__", "a")
    utility.featureAdd(ctx, after)
    assertEquals("a,z2,z1,b", names(client), "__after__")

    val repl = named("z3")
    repl.addOpts = fhMap("__replace__", "z1")
    utility.featureAdd(ctx, repl)
    assertEquals("a,z2,z3,b", names(client), "__replace__")

    // An ordering option naming no existing feature falls back to append.
    val miss = named("z4")
    miss.addOpts = fhMap("__before__", "missing")
    utility.featureAdd(ctx, miss)
    assertEquals("a,z2,z3,b,z4", names(client), "fallback append")
  }

  private fun named(name: String): BaseFeature {
    val f = BaseFeature()
    f.name = name
    return f
  }

  private fun names(client: UnivecSDK): String {
    val out = StringBuilder()
    for (i in client.features.indices) {
      if (i > 0) {
        out.append(",")
      }
      out.append(client.features[i].name)
    }
    return out.toString()
  }

  // --- prepareAuth --------------------------------------------------------------

  private fun authSpec(headers: MutableMap<String, Any?>?): Spec {
    val m = linkedMapOf<String, Any?>()
    m["headers"] = headers ?: linkedMapOf<String, Any?>()
    m["step"] = "s"
    return Spec(m)
  }

  @Test
  fun prepareAuth_guardsMissingSpec() {
    val client = plClient(fhMap("apikey", "K"))
    val utility = client.getUtility()
    val ctx = plCtx(client, utility, null)
    ctx.spec = null
    assertEquals("auth_no_spec", errCodeOf { utility.prepareAuth(ctx) })
  }

  @Test
  fun prepareAuth_apikeyWithPrefixSpaceJoined() {
    val client = plClient(fhMap("apikey", "K", "auth", fhMap("prefix", "Bearer")))
    val utility = client.getUtility()
    val ctx = plCtx(client, utility, null)
    ctx.spec = authSpec(null)
    utility.prepareAuth(ctx)
    assertEquals("Bearer K", ctx.spec!!.headers["authorization"])
  }

  @Test
  fun prepareAuth_rawApikeyEmptyPrefixAsIs() {
    val client = plClient(fhMap("apikey", "K", "auth", fhMap("prefix", "")))
    val utility = client.getUtility()
    val ctx = plCtx(client, utility, null)
    ctx.spec = authSpec(null)
    utility.prepareAuth(ctx)
    assertEquals("K", ctx.spec!!.headers["authorization"])
  }

  @Test
  fun prepareAuth_emptyApikeyDropsHeader() {
    val client = plClient(fhMap("apikey", "", "auth", fhMap("prefix", "Bearer")))
    val utility = client.getUtility()
    val ctx = plCtx(client, utility, null)
    ctx.spec = authSpec(fhMap("authorization", "stale"))
    utility.prepareAuth(ctx)
    assertFalse(ctx.spec!!.headers.containsKey("authorization"), "expected authorization dropped")
  }

  @Test
  fun prepareAuth_missingApikeyDropsHeader() {
    val client = plClient(fhMap("auth", fhMap("prefix", "Bearer")))
    val options = client.optionsMap()
    val apikey = options["apikey"]
    if (apikey is String && "" != apikey) {
      // SDK options carry a configured apikey; case not reproducible here.
      return
    }
    val utility = client.getUtility()
    val ctx = plCtx(client, utility, null)
    ctx.spec = authSpec(fhMap("authorization", "stale"))
    utility.prepareAuth(ctx)
    assertFalse(ctx.spec!!.headers.containsKey("authorization"), "expected authorization dropped")
  }

  @Test
  fun prepareAuth_publicApiNoAuthBlockDropsHeader() {
    val client = plClient(fhMap("apikey", "K"))
    val options = client.optionsMap()
    if (options["auth"] != null) {
      // Option validation supplies an auth shape for this SDK.
      return
    }
    val utility = client.getUtility()
    val ctx = plCtx(client, utility, null)
    ctx.spec = authSpec(fhMap("authorization", "stale"))
    utility.prepareAuth(ctx)
    assertNull(ctx.spec!!.headers["authorization"], "expected authorization dropped")
  }
}
