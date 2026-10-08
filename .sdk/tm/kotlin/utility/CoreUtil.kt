package KOTLINPACKAGE.utility

import java.io.PrintWriter
import java.io.StringWriter
import java.nio.charset.StandardCharsets
import java.util.Base64

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Entity
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.Operation
import KOTLINPACKAGE.core.Response
import KOTLINPACKAGE.core.Result
import KOTLINPACKAGE.core.Schema
import KOTLINPACKAGE.core.SdkError
import KOTLINPACKAGE.core.Spec
import KOTLINPACKAGE.utility.struct.Struct

fun makeContext(ctxmap: MutableMap<String, Any?>?, basectx: Context?): Context {
  return Context(ctxmap, basectx)
}

// Everything that leaves the pipeline passes through clean; inside it data
// stays raw, so a hook can still read the header it must add to. See
// docs/explanation/secret-redaction.md.

private const val MAXDEPTH = 32
private const val CIRCULAR = "[circular]"

// The derived clean block: built by makeOptions from the raw input, grown by
// cleanAdd for as long as the client lives (features register later).
class CleanConfig(
  val active: Boolean,
  val keys: List<String>,
  val values: MutableList<String>,
  val mask: String,
  val hint: Int,
  val min: Int,
) {
  // The options map this sits in can itself be printed; the registry never is.
  override fun toString(): String = "CleanConfig(active=$active)"
}

private fun normkey(key: Any?): String {
  return key.toString().lowercase().replace("-", "").replace("_", "")
}

private val SPLIT_RE = Regex("\\s*,\\s*")

private fun splitkeys(keys: Any?): List<String> {
  return (keys?.toString() ?: "").split(SPLIT_RE).map { normkey(it) }.filter { "" != it }
}

fun splitvalues(values: Any?): List<String> {
  if (values is List<*>) {
    return values.filterIsInstance<String>()
  }
  return (values?.toString() ?: "").split(SPLIT_RE).filter { "" != it }
}

private fun count(v: Any?, dflt: Int): Int {
  val n: Double = when (v) {
    is Number -> v.toDouble()
    is String -> v.trim().toDoubleOrNull() ?: return dflt
    else -> return dflt
  }
  if (n.isNaN() || n.isInfinite() || n < 0) {
    return dflt
  }
  return Math.floor(n).toInt()
}

fun makeCleanConfig(cleanopts: Any?): CleanConfig {
  val opts = Helpers.toMapAny(cleanopts) ?: linkedMapOf()
  return CleanConfig(
    active = false != opts["active"],
    keys = splitkeys(opts["keys"]),
    values = mutableListOf(),
    mask = (opts["mask"] as? String) ?: "[redacted]",
    hint = count(opts["hint"], 0),
    min = Math.max(1, count(opts["min"], 4)),
  )
}

// A context without options (makeError accepts a bare one) still masks by
// the schema defaults.
private fun cleanConfig(ctx: Context?): CleanConfig {
  val derived = Helpers.toMapAny(ctx?.options?.get("__derived__"))?.get("clean")
  if (derived is CleanConfig) {
    return derived
  }
  return makeCleanConfig(Schema.optspec["clean"])
}

// encodeURIComponent, byte for byte: URLEncoder differs on space and `~!'()*`.
private fun percentEncode(value: String): String {
  val out = StringBuilder()
  for (b in value.toByteArray(StandardCharsets.UTF_8)) {
    val c = b.toInt() and 0xff
    val ch = c.toChar()
    if ((ch in 'A'..'Z') || (ch in 'a'..'z') || (ch in '0'..'9') || "-_.!~*'()".indexOf(ch) >= 0) {
      out.append(ch)
    } else {
      out.append('%').append(String.format("%02X", c))
    }
  }
  return out.toString()
}

// The encoded forms a value travels in.
private fun forms(value: String): List<String> {
  val out = mutableListOf(value)
  fun add(s: String) {
    if ("" != s && !out.contains(s)) {
      out.add(s)
    }
  }
  try {
    add(Base64.getEncoder().encodeToString(value.toByteArray(StandardCharsets.UTF_8)))
  } catch (e: RuntimeException) {
  }
  try {
    add(percentEncode(value))
  } catch (e: RuntimeException) {
  }
  try {
    val json = Struct.jsonify(value)
    if (json.length >= 2) {
      add(json.substring(1, json.length - 1))
    }
  } catch (e: RuntimeException) {
  }
  return out
}

internal fun registerValue(cfg: CleanConfig, value: Any?) {
  if (value !is String || value.length < cfg.min) {
    return
  }
  synchronized(cfg) {
    var changed = false
    for (form in forms(value)) {
      if (form.length >= cfg.min && !cfg.values.contains(form)) {
        cfg.values.add(form)
        changed = true
      }
    }
    if (changed) {
      cfg.values.sortByDescending { it.length }
    }
  }
}

fun cleanAdd(ctx: Context, value: Any?) {
  registerValue(cleanConfig(ctx), value)
}

// Every scalar under a sensitive name in the options, at any depth and of any
// shape: a credential mistyped as a map or a number is still one, and a
// message can quote it. A key under `feature` names a feature, not a field,
// so a feature called secrets does not make its settings secret.
// Entity blocks (entity settings, seeded records) hold no credential, and nor
// do rbac's rules, keyed by entity and operation names.
internal fun registerSensitive(cfg: CleanConfig, opts: Map<String, Any?>) {
  val seen = mutableListOf<Any>()
  for ((k, v) in opts) {
    if ("entity" == k) {
      continue
    }
    val under = sensitiveKey(cfg, k)
    when {
      "feature" == k && v is Map<*, *> -> for ((name, fopts) in v) {
        addSensitive(cfg, plainSettings(fopts, name?.toString()), under, 2, seen)
      }
      "feature" == k && v is List<*> -> for (fopts in v) {
        addSensitive(cfg, plainSettings(fopts, (fopts as? Map<*, *>)?.get("name") as? String), under, 2, seen)
      }
      else -> addSensitive(cfg, if ("test" == k) plainSettings(v, null) else v, under, 1, seen)
    }
  }
}

private fun plainSettings(block: Any?, name: String?): Any? =
  if (block is Map<*, *>) block.filterKeys { it != "entity" && !("rbac" == name && it == "rules") }
  else block

private fun addSensitive(cfg: CleanConfig, v: Any?, under: Boolean, depth: Int, seen: MutableList<Any>) {
  if (v == null || MAXDEPTH <= depth) {
    return
  }
  if (v is String || v is Number) {
    if (under) {
      registerValue(cfg, v.toString())
      registerValue(cfg, Struct.stringify(v))
    }
    return
  }
  if (seen.any { it === v }) {
    return
  }
  seen.add(v)
  when (v) {
    is Map<*, *> -> for ((k, item) in v) {
      addSensitive(cfg, item, under || sensitiveKey(cfg, k), depth + 1, seen)
    }
    is Collection<*> -> for (item in v) {
      addSensitive(cfg, item, under, depth + 1, seen)
    }
    is Array<*> -> for (item in v) {
      addSensitive(cfg, item, under, depth + 1, seen)
    }
  }
}

private fun maskValue(cfg: CleanConfig, value: String): String {
  if (0 < cfg.hint && value.length > 2 * cfg.hint) {
    return cfg.mask + value.substring(value.length - cfg.hint)
  }
  return cfg.mask
}

private fun cleanString(cfg: CleanConfig, text: String): String {
  val values = synchronized(cfg) { cfg.values.toList() }
  var out = text
  for (value in values) {
    if (out.contains(value)) {
      out = out.replace(value, maskValue(cfg, value))
    }
  }
  return out
}

private fun sensitiveKey(cfg: CleanConfig, key: Any?): Boolean {
  if (key == null || key is Number) {
    return false
  }
  val nk = normkey(key)
  for (k in cfg.keys) {
    if (nk.contains(k)) {
      return true
    }
  }
  return false
}

private val DROP = Any()

private fun isfunc(v: Any): Boolean {
  if (v is Function<*>) {
    return true
  }
  val cls = v.javaClass
  return cls.isSynthetic || cls.interfaces.any { it.name.startsWith("java.util.function.") }
}

private fun stackOf(err: Throwable): String {
  val sw = StringWriter()
  err.printStackTrace(PrintWriter(sw))
  return sw.toString()
}

// The SDK's own objects have no serialisation hook, so this is the record
// each one leaves as. The context stays raw on the error and is not here.
private fun record(v: Any): MutableMap<String, Any?> {
  val out = linkedMapOf<String, Any?>()
  when (v) {
    is Throwable -> {
      out["message"] = v.message ?: ""
      out["stack"] = stackOf(v)
      if (v is SdkError) {
        out["sdk"] = v.sdk
        out["code"] = v.code
        out["status"] = v.status
        out["result"] = v.result
        out["spec"] = v.spec
      }
    }
    is Spec -> {
      out["method"] = v.method
      out["base"] = v.base
      out["prefix"] = v.prefix
      out["suffix"] = v.suffix
      out["path"] = v.path
      out["url"] = v.url
      out["params"] = v.params
      out["query"] = v.query
      out["headers"] = v.headers
      out["body"] = v.body
      out["step"] = v.step
    }
    is Result -> {
      out["ok"] = v.ok
      out["status"] = v.status
      out["statusText"] = v.statusText
      out["headers"] = v.headers
      out["body"] = v.body
      out["resdata"] = v.resdata
      out["resmatch"] = v.resmatch
      out["err"] = v.err
      out["paging"] = v.paging
    }
    is Response -> {
      out["status"] = v.status
      out["statusText"] = v.statusText
      out["headers"] = v.headers
      out["body"] = v.body
      out["err"] = v.err
    }
    is Operation -> {
      out["entity"] = v.entity
      out["name"] = v.name
      out["input"] = v.input
    }
    is Context -> {
      out["id"] = v.id
      out["op"] = v.op
      out["spec"] = v.spec
      out["entity"] = v.entity
      out["result"] = v.result
      out["response"] = v.response
      out["meta"] = v.meta
    }
    is Entity -> {
      out["name"] = v.name
      out["data"] = try { v.data() } catch (e: RuntimeException) { null }
    }
  }
  return out
}

// A masked plain-data copy: functions dropped, cycles cut, and nothing
// shared with the live value, whose spec must stay raw.
@Suppress("UNCHECKED_CAST")
private fun snapshot(cfg: CleanConfig, v: Any?, key: Any?, depth: Int, seen: MutableList<Any>): Any? {
  if (v == null || v === Struct.UNDEF) {
    return v
  }

  if (v is String) {
    return if (sensitiveKey(cfg, key)) maskValue(cfg, v) else cleanString(cfg, v)
  }

  if (isfunc(v)) {
    return DROP
  }

  if (v is Number || v is Boolean || v is Char) {
    return if (sensitiveKey(cfg, key)) cfg.mask else v
  }

  if (MAXDEPTH <= depth || seen.any { it === v }) {
    return CIRCULAR
  }

  if (sensitiveKey(cfg, key)) {
    return cfg.mask
  }

  seen.add(v)
  try {
    return when (v) {
      is List<*> -> {
        val out = mutableListOf<Any?>()
        v.forEachIndexed { i, item ->
          val s = snapshot(cfg, item, i, depth + 1, seen)
          if (s !== DROP) {
            out.add(s)
          }
        }
        out
      }
      is Map<*, *> -> plain(cfg, v, depth, seen)
      is Throwable, is Spec, is Result, is Response, is Operation, is Context, is Entity ->
        plain(cfg, record(v), depth, seen)
      else -> cleanString(cfg, v.toString())
    }
  } finally {
    seen.removeAt(seen.size - 1)
  }
}

private fun plain(cfg: CleanConfig, v: Map<*, *>, depth: Int, seen: MutableList<Any>): MutableMap<String, Any?> {
  val out = linkedMapOf<String, Any?>()
  for ((k, item) in v) {
    val s = snapshot(cfg, item, k, depth + 1, seen)
    if (s !== DROP) {
      out[cleanName(cfg, out, k.toString())] = s
    }
  }
  return out
}

// A registered value used as a property name is masked like any other
// string; names that mask alike take a counter, so none is lost.
private fun cleanName(cfg: CleanConfig, out: Map<String, Any?>, key: String): String {
  val name = cleanString(cfg, key)
  if (name == key || !out.containsKey(name)) {
    return name
  }
  var i = 1
  while (out.containsKey(name + "#" + i)) {
    i++
  }
  return name + "#" + i
}

internal fun cleanWith(cfg: CleanConfig, value: Any?): Any? {
  if (!cfg.active) {
    return value
  }

  if (value is String) {
    return cleanString(cfg, value)
  }

  // An SdkError is cleaned in place, since it is about to be thrown.
  if (value is SdkError) {
    value.msg = cleanString(cfg, value.msg)
    value.code = cleanString(cfg, value.code)
    value.result = snapshot(cfg, value.result, "result", 1, mutableListOf())
    value.spec = snapshot(cfg, value.spec, "spec", 1, mutableListOf())
    return value
  }

  // A foreign exception's message cannot be rewritten, so it is replaced by
  // an SdkError with the cleaned message and the original frames; the
  // original is not attached, as a printed stack trace would show it.
  if (value is Throwable) {
    val out = SdkError("", cleanString(cfg, value.message ?: value.toString()), null)
    out.stackTrace = value.stackTrace
    return out
  }

  val out = snapshot(cfg, value, null, 0, mutableListOf())
  return if (out === DROP) null else out
}

fun clean(ctx: Context, value: Any?): Any? {
  return cleanWith(cleanConfig(ctx), value)
}

fun cleanKey(ctx: Context, key: Any?): Boolean {
  return sensitiveKey(cleanConfig(ctx), key)
}

// The caller holds the explain map, so the cleaned copy is written back into
// it rather than swapped for it.
private fun cleanExplain(ctx: Context) {
  val explain = ctx.ctrl.explain ?: return
  val cleaned = Helpers.toMapAny(clean(ctx, explain))
  if (cleaned != null && cleaned !== explain) {
    explain.clear()
    explain.putAll(cleaned)
  }
}

fun done(ctx: Context): Any? {
  if (ctx.ctrl.explain != null) {
    cleanExplain(ctx)
    val rm = Helpers.toMapAny(ctx.ctrl.explain!!["result"])
    rm?.remove("err")
  }

  val result = ctx.result
  if (result != null && result.ok) {
    return result.resdata
  }

  return makeError(ctx, null)
}

// makeError finalises a failed operation: wraps the causing error in an
// SdkError carrying the cleaned result and spec, records it on ctx.ctrl,
// and either throws it (default) or — when ctrl.throw is false — returns
// the result's fallback resdata instead.
fun makeError(ctx: Context, errIn: RuntimeException?): Any? {
  var opname = ctx.op.name
  if ("" == opname || "_" == opname) {
    opname = "unknown operation"
  }

  var result = ctx.result
  if (result == null) {
    result = Result(linkedMapOf())
  }
  result.ok = false

  var err = errIn
  if (err == null) {
    err = result.err
  }
  if (err == null) {
    err = ctx.makeError("unknown", "unknown error")
  }

  val errmsg = err.message ?: err.toString()
  var msg = "UnivecSDK: $opname: $errmsg"
  msg = clean(ctx, msg) as String

  result.err = null

  val spec = ctx.spec

  if (ctx.ctrl.explain != null) {
    cleanExplain(ctx)
    val errRecord = linkedMapOf<String, Any?>()
    errRecord["message"] = msg
    ctx.ctrl.explain!!["err"] = errRecord
  }

  var code = ""
  if (err is SdkError) {
    code = clean(ctx, err.code) as String
  }

  val sdkErr = SdkError(code, msg, ctx)
  sdkErr.result = clean(ctx, result)
  sdkErr.spec = clean(ctx, spec)
  sdkErr.status = result.status

  ctx.ctrl.err = sdkErr

  // Fire PreUnexpected so observability features (metrics, telemetry, audit,
  // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  // rbac short-circuit). Fires after ctx.ctrl.err is set so hooks can read the
  // error; features guard against double-recording when PreDone already fired.
  ctx.utility?.let { it.featureHook(ctx, "PreUnexpected") }

  if (ctx.ctrl.throwing == false) {
    return result.resdata
  }

  throw sdkErr
}
