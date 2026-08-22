package KOTLINPACKAGE.sdktest

// Vendored from the voxgig struct kotlin port's CorpusRunner, adapted for
// this SDK: the corpus comes from ../.sdk/test/test.json (root key "struct"),
// and JSON handling uses the SDK's zero-dep Json/Struct utilities.

import java.nio.file.Files
import java.nio.file.Paths
import java.util.TreeMap

import KOTLINPACKAGE.utility.Json
import KOTLINPACKAGE.utility.struct.Struct

@Suppress("UNCHECKED_CAST")
object StructRunner {

  const val NULLMARK = "__NULL__"

  @Volatile
  private var corpus: Map<String, Any?>? = null

  @Synchronized
  fun loadCorpus(): Map<String, Any?> {
    var c = corpus
    if (c != null) {
      return c
    }
    val json = Files.readString(Paths.get("..", ".sdk", "test", "test.json"))
    c = Json.parse(json) as Map<String, Any?>
    corpus = c
    return c
  }

  fun getSpec(category: String, name: String): Map<String, Any?>? {
    val all = loadCorpus()
    val struct = all["struct"] as? Map<String, Any?> ?: return null
    val cat = struct[category] as? Map<String, Any?> ?: return null
    return cat[name] as? Map<String, Any?>
  }

  fun interface Subject {
    fun apply(input: Any?): Any?
  }

  fun fixJSON(v: Any?): Any? {
    if (v == null || v === Struct.UNDEF) {
      return NULLMARK
    }
    return when (v) {
      is Map<*, *> -> v.entries.associateTo(LinkedHashMap<String, Any?>()) {
        (it.key?.toString() ?: "") to fixJSON(it.value)
      }
      is List<*> -> v.mapTo(mutableListOf<Any?>()) { fixJSON(it) }
      else -> v
    }
  }

  /** Modify callback: swap NULLMARK back to real null / literal "null" text. */
  val NULL_MODIFIER = Struct.Modify { value, key, parent, _, _ ->
    if (value is String) {
      val repl: Any? = when {
        value == NULLMARK -> null
        value.contains(NULLMARK) -> value.replace(NULLMARK, "null")
        else -> return@Modify
      }
      when {
        parent is MutableMap<*, *> && key != null -> (parent as MutableMap<String, Any?>)[key.toString()] = repl
        parent is MutableList<*> && key is Number -> (parent as MutableList<Any?>)[key.toInt()] = repl
      }
    }
  }

  class Result(val name: String) {
    var passed: Int = 0
    var total: Int = 0
    val failures: MutableList<String> = mutableListOf()

    override fun toString(): String = "$name: $passed/$total"
  }

  fun runsetflags(
    fullName: String,
    testspec: Map<String, Any?>?,
    nullFlag: Boolean,
    subject: Subject,
  ): Result {
    val res = Result(fullName)
    val set = testspec?.get("set") as? List<Any?> ?: return res
    for ((i, eo) in set.withIndex()) {
      if (eo !is Map<*, *>) {
        continue
      }
      val entry = eo as Map<String, Any?>
      var input = if (entry.containsKey("in")) Struct.clone(entry["in"]) else Struct.UNDEF
      var expected: Any? = if (entry.containsKey("out")) {
        entry["out"]
      } else if (nullFlag) {
        null
      } else {
        Struct.UNDEF
      }
      if (nullFlag) {
        if (entry.containsKey("in")) {
          input = fixJSON(input)
        }
        expected = fixJSON(expected)
      }
      res.total++
      try {
        var got = subject.apply(input)
        if (nullFlag) {
          got = fixJSON(got)
        }
        if (entry.containsKey("err")) {
          res.failures.add("[$i] expected err='${brief(entry["err"])}' but call returned ${brief(got)}")
          continue
        }
        if (deepEqual(got, expected)) {
          res.passed++
        } else {
          res.failures.add("[$i] in=${brief(entry["in"])} expected=${brief(expected)} got=${brief(got)}")
        }
      } catch (ex: Exception) {
        if (entry.containsKey("err")) {
          val expErr = entry["err"]
          val msg = ex.message ?: ""
          val ok = expErr == true ||
            (expErr is String && (expErr.isEmpty() || msg.contains(expErr) || msg.lowercase().contains(expErr.lowercase())))
          if (ok) {
            res.passed++
          } else {
            res.failures.add("[$i] err mismatch: expected '${brief(expErr)}' got '$msg'")
          }
        } else {
          res.failures.add("[$i] in=${brief(entry["in"])} threw=${ex.message}")
        }
      }
    }
    return res
  }

  fun deepEqual(a: Any?, b: Any?): Boolean = normalize(a) == normalize(b)

  fun normalize(v: Any?): Any? {
    if (v === Struct.UNDEF || v == null) {
      return null
    }
    return when (v) {
      is Number -> {
        val d = v.toDouble()
        if (d.isFinite() && Math.floor(d) == d) d.toLong() else d
      }
      is Boolean, is String -> v
      is Map<*, *> -> {
        val out = TreeMap<String, Any?>()
        for ((k, vv) in v) {
          out[k?.toString() ?: ""] = normalize(vv)
        }
        out
      }
      is List<*> -> v.map { normalize(it) }
      else -> v.toString()
    }
  }

  private fun brief(v: Any?): String {
    if (v === Struct.UNDEF) {
      return "__UNDEF__"
    }
    return try {
      val s = Struct.jsonify(v)
      if (s.length > 200) s.substring(0, 197) + "..." else s
    } catch (e: Exception) {
      v.toString()
    }
  }
}
