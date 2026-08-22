package KOTLINPACKAGE.feature

import java.util.function.IntConsumer
import java.util.function.LongSupplier

// Shared option readers for the feature implementations. Feature options
// arrive as Map<String,Any?> (from SDK options or test harnesses), so numeric
// values may be Int, Long or Double and callbacks arrive as functional
// instances. These helpers normalise access and supply defaults, mirroring
// the `null == opts.x ? def : opts.x` pattern of the ts features.
@Suppress("UNCHECKED_CAST")
object FeatureOptions {

  fun foptBool(options: Map<String, Any?>?, key: String, def: Boolean): Boolean {
    if (options == null) {
      return def
    }
    val v = options[key]
    if (v is Boolean) {
      return v
    }
    return def
  }

  fun foptInt(options: Map<String, Any?>?, key: String, def: Int): Int {
    if (options == null) {
      return def
    }
    val v = options[key]
    if (v is Number) {
      return v.toInt()
    }
    return def
  }

  fun foptNum(options: Map<String, Any?>?, key: String, def: Double): Double {
    if (options == null) {
      return def
    }
    val v = options[key]
    if (v is Number) {
      return v.toDouble()
    }
    return def
  }

  fun foptStr(options: Map<String, Any?>?, key: String, def: String): String {
    if (options == null) {
      return def
    }
    val v = options[key]
    if (v is String && "" != v) {
      return v
    }
    return def
  }

  fun foptMap(options: Map<String, Any?>?, key: String): MutableMap<String, Any?>? {
    if (options == null) {
      return null
    }
    val v = options[key]
    if (v is MutableMap<*, *>) {
      return v as MutableMap<String, Any?>
    }
    return null
  }

  fun foptList(options: Map<String, Any?>?, key: String): MutableList<Any?>? {
    if (options == null) {
      return null
    }
    val v = options[key]
    if (v is MutableList<*>) {
      return v as MutableList<Any?>
    }
    return null
  }

  // foptStrList reads a list option as strings.
  fun foptStrList(options: Map<String, Any?>?, key: String): MutableList<String>? {
    val raw = foptList(options, key) ?: return null
    val out = mutableListOf<String>()
    for (v in raw) {
      if (v is String) {
        out.add(v)
      }
    }
    return out
  }

  // foptSleep returns the injectable sleep (option "sleep": IntConsumer of
  // ms), defaulting to a real Thread.sleep.
  fun foptSleep(options: Map<String, Any?>?): IntConsumer {
    val s = options?.get("sleep")
    if (s is IntConsumer) {
      return s
    }
    return IntConsumer { ms ->
      if (ms > 0) {
        try {
          Thread.sleep(ms.toLong())
        } catch (e: InterruptedException) {
          Thread.currentThread().interrupt()
        }
      }
    }
  }

  // foptNow returns the injectable clock (option "now": LongSupplier of ms),
  // defaulting to the wall clock.
  fun foptNow(options: Map<String, Any?>?): LongSupplier {
    val n = options?.get("now")
    if (n is LongSupplier) {
      return n
    }
    return LongSupplier { System.currentTimeMillis() }
  }

  // fheaderGet reads a header value case-insensitively; null when absent.
  fun fheaderGet(headers: Map<String, Any?>?, name: String): Any? {
    if (headers == null) {
      return null
    }
    for (e in headers.entries) {
      if (e.key.equals(name, ignoreCase = true)) {
        return e.value
      }
    }
    return null
  }

  fun fheaderHas(headers: Map<String, Any?>?, name: String): Boolean {
    if (headers == null) {
      return false
    }
    for (k in headers.keys) {
      if (k.equals(name, ignoreCase = true)) {
        return true
      }
    }
    return false
  }

  // fheaderSetDefault sets a header only when no case-insensitive variant of
  // it exists already (never clobber a caller-provided value).
  fun fheaderSetDefault(headers: MutableMap<String, Any?>?, name: String, value: String) {
    if (headers == null) {
      return
    }
    if (fheaderHas(headers, name)) {
      return
    }
    headers[name] = value
  }

  // fresStatus extracts the numeric status from a transport-shaped response.
  fun fresStatus(res: Any?): Int {
    if (res !is Map<*, *>) {
      return -1
    }
    val s = (res as Map<String, Any?>)["status"]
    if (s is Number) {
      return s.toInt()
    }
    return -1
  }

  // fresHeader reads a header from a transport-shaped response,
  // case-insensitively, as a string ("" when absent).
  fun fresHeader(res: Any?, name: String): String {
    if (res !is Map<*, *>) {
      return ""
    }
    val headers = (res as Map<String, Any?>)["headers"]
    if (headers !is Map<*, *>) {
      return ""
    }
    val v = fheaderGet(headers as Map<String, Any?>, name)
    return if (v is String) v else ""
  }

  // fparseInt parses a decimal string; def when unparseable.
  fun fparseInt(s: String, def: Int): Int {
    return try {
      s.trim().toInt()
    } catch (e: RuntimeException) {
      def
    }
  }
}
