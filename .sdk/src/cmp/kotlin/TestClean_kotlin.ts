
import {
  Content,
  File,
  cmp,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'


import type { Model } from '@voxgig/apidef'


// The canary sweep: every credential slot holds a distinctive value, every
// diagnostic feature this SDK ships is switched on with a capturing sink, a
// real operation runs through every outcome, and every string that leaves
// the SDK is searched for the canaries and their encoded forms. It also
// proves its own sensitivity: with clean switched off the canary MUST show.
const TestClean = cmp(function TestClean(props: any) {
  const model: Model = props.ctx$.model
  const target = props.target
  const kotlinpackage: string = props.kotlinpackage

  const SDK = model.const.Name + 'SDK'

  const auth = {
    suppressed: isAuthSuppressed(model),
    where: resolveAuthIn(model),
    name: 'header' === resolveAuthIn(model)
      ? resolveAuthName(model).toLowerCase() : resolveAuthName(model),
    basic: isHttpBasicAuth(model),
  }

  File({ name: 'CleanTest.' + target.ext }, () => Content(render(kotlinpackage, SDK, auth)))
})


type AuthSpec = { suppressed: boolean, where: string, name: string, basic: boolean }


function render(kotlinpackage: string, SDK: string, auth: AuthSpec): string {
  return `package ${kotlinpackage}.sdktest

// The canary sweep: every credential slot holds a distinctive value, every
// diagnostic feature this SDK ships is switched on with a capturing sink, a
// real operation runs through every outcome, and every string that leaves
// the SDK is searched for the canaries and their encoded forms. It also
// proves its own sensitivity: with clean switched off the canary MUST show.

import java.io.PrintWriter
import java.io.StringWriter
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.function.Consumer
import java.util.function.Supplier
import java.util.logging.Handler
import java.util.logging.Level
import java.util.logging.LogRecord
import java.util.logging.Logger

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test

import ${kotlinpackage}.core.Config
import ${kotlinpackage}.core.Context
import ${kotlinpackage}.core.Helpers
import ${kotlinpackage}.core.${SDK}
import ${kotlinpackage}.core.Result
import ${kotlinpackage}.core.SdkEntity
import ${kotlinpackage}.core.SdkError
import ${kotlinpackage}.core.Spec
import ${kotlinpackage}.core.Utility
import ${kotlinpackage}.feature.BaseFeature
import ${kotlinpackage}.sdktest.FeatureHarness.fhHasFeature
import ${kotlinpackage}.utility.struct.Struct

@Suppress("UNCHECKED_CAST")
class CleanTest {

  // Generated: the credential's wire placement is fixed when the SDK is built.
  private val authSuppressed = ${auth.suppressed}
  private val authWhere = "${ktstr(auth.where)}"
  private val authName = "${ktstr(auth.name)}"

  private val canaryApikey = "CANARY-APIKEY-k9x2m7q4p1"
  private val canarySecret = "CANARY-SECRET-w3e8r5t2y6"
  private val canaryHeader = "CANARY-HEADER-z1x4c7v0b3"
  private val canaryValue = "CANARY-VALUE-n5m8b2v9c4"

  private val mask = "[redacted]"

  private val noOp = "no operation of this SDK completes against a plain 200; nothing to sweep"

  private fun b64(s: String): String =
    Base64.getEncoder().encodeToString(s.toByteArray(StandardCharsets.UTF_8))

  // Every form a canary can travel in.
  private val forms: List<String> = run {
    val out = mutableListOf<String>()
    for (v in listOf(canaryApikey, canarySecret, canaryHeader, canaryValue)) {
      out.add(v)
      out.add(b64(v))
      out.add(URLEncoder.encode(v, StandardCharsets.UTF_8))
    }
    out.add(b64(canaryApikey + ":" + canarySecret))
    out
  }

  class Sink(val name: String, val text: String)

  // Header maps keep the caller's spelling; the assertion should not care.
  private fun header(map: Any?, name: String): Any? {
    val m = Helpers.toMapAny(map) ?: return null
    for ((k, v) in m) {
      if (k.lowercase() == name.lowercase()) {
        return v
      }
    }
    return null
  }

  private fun leaks(text: String): List<String> = forms.filter { text.contains(it) }

  // The SDK's own objects print their data, not a class name, so a raw spec
  // handed back with clean off shows what it holds.
  private fun plain(v: Any?): Any? = when (v) {
    is Spec -> linkedMapOf<String, Any?>(
      "method" to v.method, "url" to v.url, "path" to v.path,
      "headers" to v.headers, "query" to v.query, "body" to v.body)
    is Result -> linkedMapOf<String, Any?>(
      "status" to v.status, "headers" to v.headers, "body" to v.body, "resdata" to v.resdata)
    is SdkEntity -> v.data()
    else -> v
  }

  private fun stack(err: Throwable): String {
    val sw = StringWriter()
    err.printStackTrace(PrintWriter(sw))
    return sw.toString()
  }

  private fun surfaces(name: String, v: Any?): List<Sink> {
    val out = mutableListOf<Sink>()
    val push = { kind: String, fn: () -> String ->
      try {
        out.add(Sink(name + ":" + kind, fn()))
      } catch (e: Throwable) {
      }
    }
    push("json") { Struct.jsonify(plain(v)) }
    push("string") { v.toString() }
    if (v is Throwable) {
      push("message") { v.message ?: "" }
      push("stack") { stack(v) }
    }
    if (v is SdkError) {
      push("map") { Struct.jsonify(v.toMap()) }
      push("spec") { Struct.jsonify(plain(v.spec)) }
      push("result") { Struct.jsonify(plain(v.result)) }
    }
    if (v is Context) {
      push("record") { Struct.jsonify(v.toMap()) }
    }
    return out
  }

  // Captures the serialised context from inside the pipeline: what a hook
  // author would hand to a logger.
  inner class CaptureFeature(private val sinks: MutableList<Sink>) :
    BaseFeature("capture", "0.0.1", true) {
    override fun preRequest(ctx: Context) { sinks.addAll(surfaces("ctx@PreRequest", ctx)) }
    override fun preResponse(ctx: Context) { sinks.addAll(surfaces("ctx@PreResponse", ctx)) }
    override fun preUnexpected(ctx: Context) { sinks.addAll(surfaces("ctx@PreUnexpected", ctx)) }
  }

  // A feature that fails from inside the pipeline, quoting the request it
  // saw in the code and the message. makeError cleans a failed stage, but
  // PreUnexpected fires inside makeError: what a hook throws there does not
  // pass through it.
  inner class ThrowFeature(private val unexpected: Boolean) :
    BaseFeature("throwhook", "0.0.1", true) {
    private fun saw(ctx: Context): RuntimeException {
      val saw = "hook saw " + Struct.jsonify(plain(ctx.spec))
      return ctx.makeError(saw, saw)
    }
    override fun preResponse(ctx: Context) { throw saw(ctx) }
    override fun preUnexpected(ctx: Context) {
      if (unexpected) {
        throw saw(ctx)
      }
    }
  }

  // A stream that fails while the caller iterates it, quoting a credential.
  inner class StreamThrowFeature : BaseFeature("streamthrow", "0.0.1", true) {
    override fun preDone(ctx: Context) {
      ctx.result?.stream = Supplier<Iterator<Any?>> {
        object : Iterator<Any?> {
          override fun hasNext(): Boolean = throw RuntimeException("stream saw " + canaryApikey)
          override fun next(): Any? = throw NoSuchElementException()
        }
      }
    }
  }

  // A stream that succeeds, yielding the result's items.
  inner class StreamOkFeature : BaseFeature("streamok", "0.0.1", true) {
    override fun preDone(ctx: Context) {
      val resdata = ctx.result?.resdata
      val items: List<Any?> = when (resdata) {
        is List<*> -> resdata.toList()
        null -> emptyList()
        else -> listOf(resdata)
      }
      ctx.result?.stream = Supplier<Iterator<Any?>> { items.iterator() }
    }
  }

  class Scenario(val name: String, val respond: (String, MutableMap<String, Any?>) -> Any?)

  private fun response(status: Int, data: Any?, headers: Map<String, String>?): MutableMap<String, Any?> {
    val h = linkedMapOf<String, Any?>("content-type" to "application/json")
    headers?.forEach { (k, v) -> h[k] = v }
    val out = linkedMapOf<String, Any?>()
    out["status"] = status
    out["statusText"] = if (status < 400) "OK" else "ERR"
    out["headers"] = h
    out["json"] = Supplier<Any?> { data }
    out["body"] = Struct.jsonify(data)
    return out
  }

  private val scenarios: List<Scenario> = listOf(
    Scenario("ok") { _, _ ->
      response(200, linkedMapOf<String, Any?>("id" to "i1", "name" to "n1"),
        mapOf("x-session-token" to "RESP-TOKEN-a1b2c3d4e5"))
    },
    Scenario("notfound") { _, _ ->
      response(404, linkedMapOf<String, Any?>("error" to "no such record"), null)
    },
    Scenario("server") { _, _ ->
      response(500, linkedMapOf<String, Any?>("error" to "boom"), null)
    },
    Scenario("transport") { url, _ ->
      throw RuntimeException("socket hang up (URL was: \\"" + url + "\\")")
    },
    Scenario("notjson") { _, _ ->
      val out = linkedMapOf<String, Any?>()
      out["status"] = 200
      out["statusText"] = "OK"
      out["headers"] = linkedMapOf<String, Any?>()
      out["json"] = Supplier<Any?> { null }
      out["body"] = "<html>"
      out
    },
  )

  // Offline, as every generated suite is: the test OPTION resolves a required
  // server variable to test-<name>, and installs no transport.
  private fun offline(opts: Map<String, Any?>): MutableMap<String, Any?> {
    val out = LinkedHashMap<String, Any?>(opts)
    out["test"] = linkedMapOf<String, Any?>("active" to true)
    return out
  }

  // A client the sweep cannot build leaves nothing swept: a harness error, not
  // a leak.
  private fun construct(opts: Map<String, Any?>): ${SDK} =
    try {
      ${SDK}(offline(opts))
    } catch (e: RuntimeException) {
      throw IllegalStateException(
        "clean harness: the client could not be constructed, so nothing was swept: " + e.message, e)
    }

  private fun makeSdk(scenario: Scenario, sinks: MutableList<Sink>, cleanopts: Map<String, Any?>?,
    vararg extra: BaseFeature, auth: MutableMap<String, Any?>? = null): ${SDK} {
    val capture = { name: String -> Consumer<Any?> { rec -> sinks.addAll(surfaces(name, rec)) } }

    val feature = linkedMapOf<String, Any?>()
    if (fhHasFeature("log")) {
      val logger = Logger.getLogger("clean-sweep-" + System.nanoTime())
      logger.useParentHandlers = false
      logger.level = Level.ALL
      logger.addHandler(object : Handler() {
        override fun publish(record: LogRecord) { sinks.addAll(surfaces("log", record.message)) }
        override fun flush() {}
        override fun close() {}
      })
      feature["log"] = linkedMapOf<String, Any?>("active" to true, "logger" to logger)
    }
    if (fhHasFeature("debug")) {
      feature["debug"] = linkedMapOf<String, Any?>("active" to true, "onEntry" to capture("debug"))
    }
    if (fhHasFeature("audit")) {
      feature["audit"] = linkedMapOf<String, Any?>("active" to true, "sink" to capture("audit"))
    }
    if (fhHasFeature("telemetry")) {
      feature["telemetry"] = linkedMapOf<String, Any?>("active" to true, "exporter" to capture("telemetry"))
    }
    if (fhHasFeature("cost")) {
      feature["cost"] = linkedMapOf<String, Any?>("active" to true, "sink" to capture("cost"))
    }
    if (fhHasFeature("metrics")) {
      feature["metrics"] = linkedMapOf<String, Any?>("active" to true)
    }
    if (fhHasFeature("clienttrack")) {
      feature["clienttrack"] = linkedMapOf<String, Any?>("active" to true)
    }

    val clean = linkedMapOf<String, Any?>("values" to canaryValue)
    cleanopts?.forEach { (k, v) -> clean[k] = v }

    val fetcher: (Context, String, MutableMap<String, Any?>) -> Any? =
      { _, url, fetchdef -> scenario.respond(url, fetchdef) }

    val opts = linkedMapOf<String, Any?>()
    opts["apikey"] = canaryApikey
    opts["secret"] = canarySecret
    opts["headers"] = linkedMapOf<String, Any?>("X-Custom-Token" to canaryHeader)
    opts["clean"] = clean
    opts["feature"] = feature
    opts["extend"] = mutableListOf<Any?>(CaptureFeature(sinks), *extra)
    opts["utility"] = linkedMapOf<String, Any?>("fetcher" to fetcher)
    if (auth != null) {
      opts["auth"] = auth
    }
    return construct(opts)
  }

  class Target(val accessor: Method, val op: String, val match: Map<String, Any?>)

  private fun accessors(): List<Method> =
    ${SDK}::class.java.methods
      .filter {
        SdkEntity::class.java.isAssignableFrom(it.returnType) &&
          it.parameterCount == 1 && Modifier.isPublic(it.modifiers)
      }
      .sortedBy { it.name }

  private fun entityOf(sdk: ${SDK}, m: Method): SdkEntity? =
    try {
      m.invoke(sdk, *arrayOf<Any?>(null)) as? SdkEntity
    } catch (e: Throwable) {
      null
    }

  private fun call(ent: SdkEntity, op: String, match: Map<String, Any?>,
    ctrl: MutableMap<String, Any?>?): Any? {
    val arg = LinkedHashMap<String, Any?>(match)
    return when (op) {
      "list" -> ent.list(arg, ctrl)
      "load" -> ent.load(arg, ctrl)
      "create" -> ent.create(arg, ctrl)
      "update" -> ent.update(arg, ctrl)
      "patch" -> ent.patch(arg, ctrl)
      "remove" -> ent.remove(arg, ctrl)
      else -> throw IllegalArgumentException("no such op: " + op)
    }
  }

  // Every path parameter an operation's points declare, filled in.
  private fun filled(entname: String, opname: String): Map<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    val points = Struct.getpath(Config.sharedConfig(), listOf("entity", entname, "op", opname, "points"))
    if (points !is List<*>) {
      return out
    }
    for (point in points) {
      val params = Struct.getpath(point, listOf("args", "params"))
      if (params is List<*>) {
        for (param in params) {
          val name = Struct.getprop(param, "name")
          if (name is String) {
            out[name] = "p1"
          }
        }
      }
    }
    return out
  }

  // The first operation that completes against a plain 200: with no
  // arguments, else with every path parameter its points declare filled in.
  private fun usableOp(): Target? {
    val plainFetch: (Context, String, MutableMap<String, Any?>) -> Any? =
      { _, _, _ -> response(200, linkedMapOf<String, Any?>("id" to "i1"), null) }
    val plain = construct(linkedMapOf<String, Any?>(
      "apikey" to canaryApikey,
      "utility" to linkedMapOf<String, Any?>("fetcher" to plainFetch)))
    val entities = Helpers.toMapAny(Config.sharedConfig()["entity"]) ?: linkedMapOf()
    val rank = mapOf("list" to 0, "load" to 1)
    for (m in accessors()) {
      val inst = entityOf(plain, m) ?: continue
      val ecfg = Helpers.toMapAny(entities[inst.name]) ?: continue
      val ops = (Helpers.toMapAny(ecfg["op"]) ?: linkedMapOf()).keys.sortedBy { rank[it] ?: 2 }
      for (op in ops) {
        for (match in listOf(linkedMapOf<String, Any?>(), filled(inst.name, op))) {
          try {
            call(entityOf(plain, m)!!, op, match, null)
            return Target(m, op, match)
          } catch (e: Throwable) {
            continue
          }
        }
      }
    }
    return null
  }

  // Nothing usable is a visible skip; the lane then misses the swept line.
  private fun usableOrSkip(): Target {
    val target = usableOp()
    if (target == null) {
      println("clean: skipped: " + noOp)
    }
    assumeTrue(target != null, noOp)
    return target!!
  }

  private fun drive(sdk: ${SDK}, target: Target, ctrl: MutableMap<String, Any?>?, sinks: MutableList<Sink>): Throwable? {
    // A caller may keep the record it passed rather than read ctrl's entry.
    val held = ctrl?.get("explain")
    val entity = entityOf(sdk, target.accessor)!!
    var out: Any? = null
    var err: Throwable? = null
    try {
      out = call(entity, target.op, target.match, ctrl)
    } catch (e: Throwable) {
      err = e
    }
    if (err != null) {
      sinks.addAll(surfaces("error", err))
    }
    if (out != null) {
      sinks.addAll(surfaces("result", out))
    }
    // Raw, as a caller copying the match into another query reads it.
    sinks.addAll(surfaces("match", entity.match()))
    val explain = ctrl?.get("explain")
    if (explain != null) {
      sinks.addAll(surfaces("explain", explain))
    }
    if (held != null && held !== explain) {
      sinks.addAll(surfaces("explain:held", held))
    }
    return err
  }

  @Test
  fun noCredentialLeavesTheSdkInAnyForm() {
    val target = usableOrSkip()

    val sinks = mutableListOf<Sink>()
    val errors = linkedMapOf<String, Throwable>()
    val explains = linkedMapOf<String, MutableMap<String, Any?>>()

    for (scenario in scenarios) {
      for (variant in listOf("throw", "explain", "nothrow")) {
        val sdk = makeSdk(scenario, sinks, null)
        val ctrl: MutableMap<String, Any?>? = when (variant) {
          "throw" -> null
          "explain" -> linkedMapOf<String, Any?>("explain" to linkedMapOf<String, Any?>())
          else -> linkedMapOf<String, Any?>("throw" to false, "explain" to linkedMapOf<String, Any?>())
        }
        val err = drive(sdk, target, ctrl, sinks)
        val key = scenario.name + "/" + variant
        if (err != null) {
          errors[key] = err
        }
        val explain = Helpers.toMapAny(ctrl?.get("explain"))
        if (explain != null) {
          explains[key] = explain
        }
        sinks.addAll(surfaces("sdk", sdk))
      }
    }

    // A name given at run time replaces the declared one: the match leaves
    // out whichever name prepareAuth placed.
    drive(makeSdk(scenarios[0], sinks, null, auth = linkedMapOf<String, Any?>("name" to "zzcred")),
      target, null, sinks)

    // No clean option at all: the schema defaults still apply.
    val bareFetch: (Context, String, MutableMap<String, Any?>) -> Any? =
      { _, url, fetchdef -> scenarios[1].respond(url, fetchdef) }
    val bare = construct(linkedMapOf<String, Any?>(
      "apikey" to canaryApikey,
      "secret" to canarySecret,
      "headers" to linkedMapOf<String, Any?>("X-Custom-Token" to canaryHeader),
      "utility" to linkedMapOf<String, Any?>("fetcher" to bareFetch)))
    assertNotNull(drive(bare, target, null, sinks), "the 404 should fail")

    // A credential mistyped as a map. The kotlin validator collects its
    // errors and substitutes the default rather than rejecting, so there is
    // no rejection to sweep: sweep the client, and what clean makes of the
    // value should anything quote it.
    try {
      val mistyped = ${SDK}(offline(linkedMapOf<String, Any?>(
        "apikey" to linkedMapOf<String, Any?>("value" to canaryApikey),
        "clean" to linkedMapOf<String, Any?>("values" to canaryValue))))
      sinks.addAll(surfaces("mistyped", mistyped))
      sinks.addAll(surfaces("mistyped:quoted",
        mistyped.getUtility().clean(mistyped.getRootCtx(), "found map: " + canaryApikey)))
    } catch (e: RuntimeException) {
      sinks.addAll(surfaces("mistyped:rejected", e))
    }

    // A number is registered as the text a message quotes it in.
    val numeric = construct(linkedMapOf<String, Any?>("apikey" to 918273645))
    val numbered = numeric.getUtility().clean(numeric.getRootCtx(), "found 918273645")

    for (unexpected in listOf(false, true)) {
      val hooked = makeSdk(scenarios[0], sinks, null, ThrowFeature(unexpected))
      assertNotNull(drive(hooked, target, linkedMapOf<String, Any?>("explain" to linkedMapOf<String, Any?>()), sinks),
        "the throwing hook should fail the operation")
    }

    // Iterating a stream runs inside the same catch path as the operation,
    // and the explain record the caller passed is cleaned however it ends.
    for ((name, extra) in listOf<Pair<String, Array<BaseFeature>>>(
      Pair("stream", arrayOf(StreamThrowFeature())),
      Pair("stream-ok", arrayOf(StreamOkFeature())),
      Pair("stream-plain", arrayOf()))) {
      val streaming = entityOf(makeSdk(scenarios[0], sinks, null, *extra), target.accessor)!!
      val explain = linkedMapOf<String, Any?>()
      var streamerr: Throwable? = null
      try {
        streaming.stream(target.op, linkedMapOf<String, Any?>("reqmatch" to LinkedHashMap(target.match)),
          linkedMapOf<String, Any?>("ctrl" to linkedMapOf<String, Any?>("explain" to explain)))
          .forEach { }
      } catch (e: Throwable) {
        streamerr = e
      }
      assertEquals("stream" == name, streamerr != null, name + ": only the failing stream throws")
      if (streamerr != null) {
        sinks.addAll(surfaces(name, streamerr))
      }
      assertTrue(explain.isNotEmpty(), name + ": the explain record was not filled")
      sinks.addAll(surfaces(name + ":explain", explain))
    }

    // The raw path returns its failure rather than throwing it.
    val raw = makeSdk(scenarios[3], sinks, null).direct(linkedMapOf<String, Any?>("path" to "raw"))
    assertTrue(false == raw["ok"] && raw["err"] is Throwable,
      "a transport failure should fail direct() with an error")
    sinks.addAll(surfaces("direct", raw["err"]))

    // A registered value used as a property name is masked; names that mask
    // alike are kept apart.
    val probe = makeSdk(scenarios[0], sinks, null)
    val named = probe.getUtility().clean(probe.getRootCtx(),
      linkedMapOf<String, Any?>(canaryValue to 1, canaryHeader to 2, "plain" to 3))
    sinks.addAll(surfaces("named", named))

    val leaked = sinks
      .map { Pair(it.name, leaks(it.text)) }
      .filter { it.second.isNotEmpty() }

    println("clean: swept " + sinks.size + " surface(s), " + leaked.size + " leak(s)")

    assertEquals(0, leaked.size, "credential leaked through: " +
      leaked.joinToString("; ") { it.first + " [" + it.second.joinToString(", ") + "]" })

    assertEquals("found " + mask, numbered)
    assertEquals(linkedMapOf<String, Any?>(mask to 1, mask + "#1" to 2, "plain" to 3), named)

    // The positive half: the slot the credential travelled in is masked,
    // and an unregistered token in a response header is masked by name.
    val notfound = errors["notfound/throw"]
    assertNotNull(notfound, "the 404 scenario must throw")
    assertTrue(notfound is SdkError, "the 404 scenario should throw an SdkError, got " + notfound)
    val nf = notfound as SdkError
    assertEquals(404, nf.status)
    val spec = Helpers.toMapAny(nf.spec) ?: linkedMapOf()
    if (!authSuppressed) {
      if ("query" == authWhere) {
        assertEquals(mask, header(spec["query"], authName))
      } else if ("cookie" == authWhere) {
        assertTrue(header(spec["headers"], "cookie").toString().contains(mask),
          "cookie: " + header(spec["headers"], "cookie"))
      } else {
        assertTrue(header(spec["headers"], authName).toString().endsWith(mask),
          authName + ": " + header(spec["headers"], authName))
      }
    }
    assertEquals(mask, header(spec["headers"], "x-custom-token"))

    val explained = explains["ok/explain"] ?: linkedMapOf()
    val result = Helpers.toMapAny(explained["result"])
    assertNotNull(result, "the explain record should carry the result")
    assertEquals(mask, header(result!!["headers"], "x-session-token"))
  }

  @Test
  fun theSweepCanSeeALeakCleanSwitchedOffShowsTheCredential() {
    val target = usableOrSkip()

    val sinks = mutableListOf<Sink>()
    val sdk = makeSdk(scenarios[1], sinks, mapOf("active" to false))
    val err = drive(sdk, target, null, sinks)
    assertNotNull(err)

    // Explaining a failure must not cost it its error.
    val explained = drive(makeSdk(scenarios[1], mutableListOf(), mapOf("active" to false)), target,
      linkedMapOf<String, Any?>("explain" to linkedMapOf<String, Any?>()), mutableListOf())
    assertEquals(err?.message, explained?.message, "with clean off, explain lost the error")

    val leaked = sinks.filter { leaks(it.text).isNotEmpty() }
    assertTrue(leaked.isNotEmpty(), "with clean off, nothing showed the canary: the sweep is blind")

    if (!authSuppressed) {
      val text = Struct.jsonify(plain((err as? SdkError)?.spec))
      assertTrue(text.contains(canaryApikey) || text.contains(b64(canaryApikey + ":" + canarySecret)),
        "the raw spec should carry the credential when clean is off")
    }
  }

  // An entity block, of per-entity settings or seeded records keyed by
  // entity name and id, is not read at all, and nor are rbac's rules, keyed by
  // entity and operation names.
  @Test
  fun aFeatureNameDoesNotMakeItsSettingsSecret() {
    val sdk = construct(linkedMapOf<String, Any?>(
      "apikey" to canaryApikey,
      "feature" to linkedMapOf<String, Any?>(
        "secrets" to linkedMapOf<String, Any?>(
          "active" to false, "kind" to "SETTING-KIND-4829", "token" to canarySecret),
        "rbac" to linkedMapOf<String, Any?>(
          "active" to false, "rules" to linkedMapOf<String, Any?>("zztoken.load" to "PLAINRULE-k7j5h3g1")),
        "test" to linkedMapOf<String, Any?>("active" to false, "entity" to linkedMapOf<String, Any?>(
          "zztoken" to linkedMapOf<String, Any?>(
            "ZZTOKEN01" to linkedMapOf<String, Any?>("note" to "PLAINRECORD-t5r3e1w9"))))),
      "entity" to linkedMapOf<String, Any?>("zztoken" to linkedMapOf<String, Any?>(
        "alias" to linkedMapOf<String, Any?>("zzkey" to "PLAINALIAS-m2n4b6v8")))))
    val root = sdk.getRootCtx()
    assertEquals("SETTING-KIND-4829 " + mask,
      sdk.getUtility().clean(root, "SETTING-KIND-4829 " + canarySecret))
    assertEquals("record PLAINRECORD-t5r3e1w9",
      sdk.getUtility().clean(root, "record PLAINRECORD-t5r3e1w9"))
    assertEquals("alias PLAINALIAS-m2n4b6v8",
      sdk.getUtility().clean(root, "alias PLAINALIAS-m2n4b6v8"))
    assertEquals("rule PLAINRULE-k7j5h3g1",
      sdk.getUtility().clean(root, "rule PLAINRULE-k7j5h3g1"))
  }

  @Test
  fun theGeneratedConfigsOwnCleanBlockIsHonoured() {
    val cfgclean = linkedMapOf<String, Any?>("keys" to "zzsens", "values" to "CONFIG-SEEDED-1")
    val utility = Utility()
    val ctx = utility.makeContext(linkedMapOf<String, Any?>(
      "utility" to utility,
      "config" to linkedMapOf<String, Any?>("options" to linkedMapOf<String, Any?>("clean" to cfgclean)),
      "options" to linkedMapOf<String, Any?>(
        "clean" to linkedMapOf<String, Any?>("values" to "CALLER-SEEDED-2"))), null)
    ctx.options = utility.makeOptions(ctx)

    assertEquals("a " + mask + " b " + mask,
      utility.clean(ctx, "a CONFIG-SEEDED-1 b CALLER-SEEDED-2"))
    assertEquals(linkedMapOf<String, Any?>("my_zzsens" to mask, "other" to "y"),
      utility.clean(ctx, linkedMapOf<String, Any?>("my_zzsens" to "x", "other" to "y")))
    assertEquals("CONFIG-SEEDED-1", cfgclean["values"])
  }
}
`
}


// A Kotlin double-quoted string literal body: the auth name comes from the
// API's own securityScheme.
function ktstr(s: string): string {
  return String(s)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\$/g, '\\$')
}


export {
  TestClean
}
