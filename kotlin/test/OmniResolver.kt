package voxgig.univecsdk.sdktest

// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (voxgig.omni.makeRunner(spec, provider)), presented to the corpus
// tests in the struct-runner shape they already use (run.spec, run.runset,
// run.runsetflags, run.client). No compat shim is vendored: the adapter
// below IS the whole bridge, per language, per the vendor-tag rollout
// (docs/design/vendor-tag-rollout.md, Decision 4). It supersedes the
// engine half of RunnerSupport (runset/matchDeep) and the whole
// StructRunner class (support lives on in RunnerSupport).
//
// Kotlin-specific decisions, each load-bearing:
//
// 1. TWO VALUE MODELS. The vendored kotlin omni port has a sealed `Json`
//    (Absent/Null/Bool/Num/Str/JList/JMap); the SDK runtime has plain
//    `Any?` - LinkedHashMap, MutableList, String, Long/Double, Boolean,
//    null, and Struct.UNDEF for "no value". `toStruct`/`toOmni` convert at
//    the subject boundary. Integral numbers cross as Long, matching what
//    the SDK's own Json parser feeds the utilities. Ported from the
//    struct kotlin port's own omni bridge (voxgig/struct
//    kotlin/src/test/kotlin/voxgig/struct/Omni.kt).
//
// 2. ZERO-ARGUMENT ENTRIES. The corpus carries entries with no `in`,
//    `args` or `ctx`, meaning "call the subject with NO argument". The
//    kotlin port already distinguishes that case natively - such an entry
//    arrives as one `Json.Absent` argument - so no novalargs spec rewrite
//    (go) and no compat shim (lua/php) is needed: `toStruct(Json.Absent)`
//    IS `Struct.UNDEF`, the port's own no-value sentinel, and
//    `toOmni(Struct.UNDEF)` is `Json.Absent` on the way out.
//
// 3. MUTATED ARGUMENTS CANNOT CROSS BY IDENTITY. `toStruct` builds new
//    containers, so an in-place rewrite by the subject would be invisible
//    to the runner - and `match: {args: ...}` asserts exactly that
//    (minor/setpath, merge/integrity), as does every `match: {ctx: ...}`
//    read of state a subject wrote back with `omniSyncCtx`. So the
//    wrapped subject REFILLS omni's own (mutable) containers in place
//    after the call (`writeback`), which the runner then matches against.
//    Safe because the runner clones `entry.in` before handing it over.
//
// 4. CONTEXTS STAY MAPS ACROSS THE RUNNER. omni sets `entry.ctx` to
//    args[0] and `match: {ctx: ...}` assertions read THROUGH it with
//    omni's own getpath, which walks Json maps only. So the subjects
//    receive the MAP, build the typed Context with
//    OmniResolver.omniCtx(args[0], ...) at the call site, run the
//    utility, and write the observable ctx state back into the same map
//    with omniSyncCtx - which is what makes the live SDK reachable
//    through ctx.client for the generated utilities (omni#56; the same
//    idiom as the go and java resolvers). NOTE: this port's runner marks
//    `ctx.client` with `Json.Bool(true)` - presence, not identity - so a
//    DEF-built client can never be resolved back from the ctx map;
//    sections that need a specially-optioned client construct it at the
//    call site (makeSpec/prepareAuth), same as the retired engine did.
//
// 5. THE VENDORED KOTLIN PORT LACKS THE omni#54 RUNNER FIXES the
//    TypeScript port has at this tag (voxgig/omni#64 landed them for
//    js/go/py only): Util.jsonstr has no cycle guard, and the match base
//    is rebuilt per check rather than guarded. Both only bite on CYCLIC
//    values - and a `Json` value built by this resolver's `toOmni` from
//    acyclic corpus data cannot be cyclic, because typed SDK state (a
//    Context, a client) never enters the Json world (decision 4). The
//    errify half (non-Error throwables) cannot arise: kotlin subjects
//    fail by THROWING, and the errify hook below keeps the SDK error's
//    code for `match: {err: {code: ...}}` assertions.

import java.nio.file.Paths
import java.util.LinkedHashMap
import kotlin.math.abs
import kotlin.math.floor

import voxgig.omni.Flags
import voxgig.omni.Json
import voxgig.omni.Provider
import voxgig.omni.RunPack
import voxgig.omni.Subject as OmniSubject
import voxgig.omni.errify as omniErrify
import voxgig.omni.loadspec
import voxgig.omni.makeRunner as makeOmniRunner

import voxgig.univecsdk.core.Context
import voxgig.univecsdk.core.Helpers
import voxgig.univecsdk.core.UnivecSDK
import voxgig.univecsdk.core.SdkError
import voxgig.univecsdk.core.Utility
import voxgig.univecsdk.utility.struct.Struct

@Suppress("UNCHECKED_CAST")
object OmniResolver {

  // The sentinels, under the names the corpus tests already use.
  const val NULLMARK = voxgig.omni.NULLMARK
  const val UNDEFMARK = voxgig.omni.UNDEFMARK
  const val EXISTSMARK = voxgig.omni.EXISTSMARK

  /** The function under test, in this port's plain-value shape. */
  fun interface Subject {
    fun call(args: MutableList<Any?>): Any?
  }

  /** Resolves one named section of the spec. */
  fun interface NamedRunner {
    fun runner(name: String, store: Any?): Run
  }

  /**
   * What the runner returns for one named spec section - the struct-runner
   * shape the corpus call sites consume. A failing entry throws
   * voxgig.omni.OmniError, which fails the JUnit test with the entry named.
   */
  class Run internal constructor(
    private val pack: RunPack,
    val client: UnivecSDK?,
  ) {
    /** The resolved spec section, in this port's plain-value shape. */
    val spec: MutableMap<String, Any?> =
      toStruct(pack.spec) as? MutableMap<String, Any?> ?: linkedMapOf()

    /** A named group of the resolved spec. */
    fun set(name: String): Any? = spec[name]

    /** Run one set of test entries with omni's default flags. */
    fun runset(testspec: Any?, subject: Subject?) {
      runsetflags(testspec, Flags(), subject)
    }

    /** Run one set of test entries with explicit flags. */
    fun runsetflags(testspec: Any?, flags: Flags, subject: Subject?) {
      val wrapped: OmniSubject? = if (null == subject) {
        null
      } else {
        { jargs ->
          val pargs = jargs.mapTo(mutableListOf<Any?>()) { toStruct(it) }
          val got = subject.call(pargs)
          // Refill omni's own containers so `match.args` / `match.ctx`
          // see in-place mutation (decision 3 above).
          for (index in jargs.indices) {
            writeback(jargs[index], pargs[index])
          }
          toOmni(got)
        }
      }
      pack.runsetflags(toOmni(testspec), flags, wrapped)
    }
  }

  /**
   * The struct runner's makeRunner(testfile, client) signature, backed by
   * vendored omni. `testfile` is a spec path (absolutized against the
   * working directory - omni's docs say a port must resolve the path
   * itself) or an already-parsed spec value (omni's own capability), which
   * keeps smoke tests free of fixture files.
   */
  fun makeRunner(testfile: Any?, client: UnivecSDK?): NamedRunner {
    val spec: Json = when (testfile) {
      is Json -> testfile
      is String -> loadspec(Paths.get(testfile).toAbsolutePath().normalize().toString())
      else -> toOmni(testfile)
    }

    val runner = makeOmniRunner(spec, sdkProvider(client))

    return NamedRunner { name, store ->
      Run(runner.runner(name, if (null == store) Json.Absent else toOmni(store)), client)
    }
  }

  /** omni's value model -> this port's (see decision 1 above). */
  fun toStruct(value: Json): Any? = when (value) {
    is Json.Absent -> Struct.UNDEF
    is Json.Null -> null
    is Json.Bool -> value.value
    is Json.Num -> {
      val d = value.value
      // Integral JSON numbers become Long, exactly as the SDK's own
      // zero-dep Json parser produces them - the utilities' arithmetic
      // and string rendering are written against that contract.
      if (d.isFinite() && floor(d) == d && abs(d) < 9007199254740992.0) d.toLong() else d
    }
    is Json.Str -> value.value
    is Json.JList -> value.value.mapTo(mutableListOf()) { toStruct(it) }
    is Json.JMap ->
      LinkedHashMap<String, Any?>().also { out ->
        value.value.forEach { (key, entry) -> out[key] = toStruct(entry) }
      }
  }

  /**
   * This port's value model -> omni's. A function or a sentinel has no
   * JSON form and omni only ever stringifies one, so it becomes its own
   * rendering rather than silently collapsing to null.
   */
  fun toOmni(value: Any?): Json = when {
    value is Json -> value
    value === Struct.UNDEF -> Json.Absent
    null == value -> Json.Null
    value is Boolean -> Json.Bool(value)
    value is Number -> Json.Num(value.toDouble())
    value is String -> Json.Str(value)
    value is List<*> -> Json.JList(value.mapTo(mutableListOf()) { toOmni(it) })
    value is Map<*, *> ->
      Json.JMap(
        LinkedHashMap<String, Json>().also { out ->
          value.forEach { (key, entry) -> out["$key"] = toOmni(entry) }
        },
      )
    else -> Json.Str(Struct.stringify(value))
  }

  /** Refill omni's own container from the (possibly rewritten) argument. */
  private fun writeback(target: Json, source: Any?) {
    if (target is Json.JMap && source is Map<*, *>) {
      target.value.clear()
      source.forEach { (key, entry) -> target.value["$key"] = toOmni(entry) }
    } else if (target is Json.JList && source is List<*>) {
      target.value.clear()
      source.forEach { entry -> target.value.add(toOmni(entry)) }
    }
  }

  /** Wrap a live client as an omni provider (see decision 4 above). */
  private fun sdkProvider(client: UnivecSDK?): Provider = Provider(
    // NO subject-by-name hook: the SDK's Utility fields are TYPED function
    // properties (a Context in, a typed value out), so a generic name
    // lookup cannot produce omni's (List<Json>) -> Json subject without a
    // per-name adapter; every corpus call site passes its subject
    // explicitly, so the hook would be dead weight (the java resolver's
    // decision, unchanged here).
    subject = null,

    // A DEF.client entry becomes another live test SDK, wrapped the same
    // way. (This port's runner cannot hand the provider back through the
    // ctx map - see decision 4 - so a section needing that client also
    // constructs it at the call site.)
    client = { options ->
      val opts = toStruct(options) as? MutableMap<String, Any?>
      sdkProvider(UnivecSDK.testSDK(null, opts ?: linkedMapOf()))
    },

    contextify = null,

    // Client options may reference the runner store.
    inject = { options, store ->
      val popts = toStruct(options)
      Struct.inject(popts, toStruct(store))
      toOmni(popts)
    },

    // Keep the SDK error's code beside its message, so a corpus
    // `match: {err: {code: ...}}` can assert on it - the kotlin analogue
    // of the omni#54 errify fix (see decision 5 above).
    errify = { err ->
      if (err is SdkError) {
        val out = LinkedHashMap<String, Json>()
        out["name"] = Json.str("SdkError")
        out["message"] = Json.str(err.message)
        if (err.code.isNotEmpty()) {
          out["code"] = Json.str(err.code)
        }
        Json.JMap(out)
      } else {
        omniErrify(err)
      }
    },
  )

  /**
   * Build the typed Context a generated utility takes from the ctx MAP
   * omni handed the subject (args[0]). (The engine half of the retired
   * RunnerSupport.runset call sites did this as makeCtxFromMap + fixctx,
   * per section, by hand.)
   */
  fun omniCtx(arg: Any?, client: UnivecSDK?, utility: Utility?): Context {
    val ctxmap = Helpers.toMapAny(arg) ?: linkedMapOf()
    val ctx = RunnerSupport.makeCtxFromMap(ctxmap, client, utility)
    RunnerSupport.fixctx(ctx, client)
    return ctx
  }

  /**
   * Write the OBSERVABLE state of a typed context back into the ctx map
   * the entry holds, which is where a `match: {ctx: ...}` assertion reads
   * (through the wrapped subject's writeback - decision 3). The subject
   * mutated the typed context; the map is what the runner can walk. (The
   * retired engine call sites did this per section, by hand, as "update
   * entry ctx for match".)
   */
  fun omniSyncCtx(arg: Any?, ctx: Context?) {
    val ctxmap = Helpers.toMapAny(arg)
    if (null == ctxmap || null == ctx) {
      return
    }

    val spec = ctx.spec
    if (null != spec) {
      val out = linkedMapOf<String, Any?>(
        "base" to spec.base,
        "prefix" to spec.prefix,
        "suffix" to spec.suffix,
        "path" to spec.path,
        "method" to spec.method,
        "params" to spec.params,
        "query" to spec.query,
        "headers" to spec.headers,
        "step" to spec.step,
        "alias" to spec.alias,
      )
      if (null != spec.body) {
        out["body"] = spec.body
      }
      if (spec.url.isNotEmpty()) {
        out["url"] = spec.url
      }
      ctxmap["spec"] = out
    }

    val result = ctx.result
    if (null != result) {
      val out = linkedMapOf<String, Any?>(
        "ok" to result.ok,
        "status" to result.status,
        "statusText" to result.statusText,
        "headers" to result.headers,
      )
      if (null != result.body) {
        out["body"] = result.body
      }
      val err = result.err
      if (null != err) {
        out["err"] = linkedMapOf<String, Any?>("message" to err.message)
      }
      if (null != result.resdata) {
        out["resdata"] = result.resdata
      }
      if (null != result.resmatch) {
        out["resmatch"] = result.resmatch
      }
      ctxmap["result"] = out
    }

    if (null != ctx.response) {
      ctxmap["response"] = "exists"
    }
  }
}
