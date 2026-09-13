package KOTLINPACKAGE.sdktest

// Drives the shared struct corpus (../.sdk/test/test.json, root key
// "struct") against the vendored Kotlin struct utility THROUGH the vendored
// omni runner (OmniResolver over test/vendor/omni) - the engine half of the
// retired StructRunner. Mirrors tm/java/test/StructCorpusTest.java and the
// go target's struct_utility_test.go coverage. A missing category or
// section FAILS (the old runner skipped it silently - a renamed fixture
// reported PASS while running zero assertions); a failing entry throws
// OmniError with the entry named.

import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory

import java.util.function.Function

import voxgig.omni.Flags

import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.UnivecSDK
import KOTLINPACKAGE.utility.struct.Struct

@Suppress("UNCHECKED_CAST")
class StructCorpusTest {

  companion object {
    const val TEST_JSON_FILE = "../.sdk/test/test.json"

    private var RUN: OmniResolver.Run? = null

    @Synchronized
    fun structRun(): OmniResolver.Run {
      var r = RUN
      if (null == r) {
        r = OmniResolver
          .makeRunner(TEST_JSON_FILE, UnivecSDK.testSDK())
          .runner("struct", linkedMapOf<String, Any?>())
        assertNotNull(r.spec, "struct section not found in test.json")
        RUN = r
      }
      return r
    }
  }

  /** A subject in the struct-corpus shape: one argument in, one value out. */
  fun interface StructSubject {
    fun apply(input: Any?): Any?
  }

  private fun getp(input: Any?, key: String): Any? =
    if (input is Map<*, *>) (input as Map<String, Any?>)[key] else null

  private fun getpDef(input: Any?, key: String, def: Any?): Any? =
    if (input is Map<*, *> && (input as Map<String, Any?>).containsKey(key)) input[key] else def

  private fun hasKey(input: Any?, key: String): Boolean =
    input is Map<*, *> && (input as Map<String, Any?>).containsKey(key)

  @TestFactory
  fun corpus(): Iterable<DynamicTest> {
    val tests = mutableListOf<DynamicTest>()

    // ===== minor =====
    add(tests, "minor", "isnode", true) { Struct.isnode(it) }
    add(tests, "minor", "ismap", true) { Struct.ismap(it) }
    add(tests, "minor", "islist", true) { Struct.islist(it) }
    add(tests, "minor", "iskey", false) { Struct.iskey(it) }
    add(tests, "minor", "strkey", false) { Struct.strkey(it) }
    add(tests, "minor", "isempty", false) { Struct.isempty(it) }
    add(tests, "minor", "isfunc", true) { Struct.isfunc(it) }
    add(tests, "minor", "getprop", false) {
      val v = getp(it, "val")
      val k = getp(it, "key")
      val a = getpDef(it, "alt", Struct.UNDEF)
      if (a === Struct.UNDEF) Struct.getprop(v, k) else Struct.getprop(v, k, a)
    }
    add(tests, "minor", "getelem", false) {
      val v = getp(it, "val")
      val k = getp(it, "key")
      val a = getpDef(it, "alt", Struct.UNDEF)
      if (a === Struct.UNDEF) Struct.getelem(v, k) else Struct.getelem(v, k, a)
    }
    add(tests, "minor", "clone", false) { Struct.clone(it) }
    add(tests, "minor", "items", true) { Struct.items(it) }
    add(tests, "minor", "keysof", true) { Struct.keysof(it) }
    add(tests, "minor", "haskey", false) { Struct.haskey(getp(it, "src"), getp(it, "key")) }
    add(tests, "minor", "setprop", true) {
      val parent = getpDef(it, "parent", Struct.UNDEF)
      Struct.setprop(if (parent === Struct.UNDEF) null else parent, getp(it, "key"), getp(it, "val"))
    }
    add(tests, "minor", "delprop", true) {
      val parent = getpDef(it, "parent", Struct.UNDEF)
      Struct.delprop(if (parent === Struct.UNDEF) null else parent, getp(it, "key"))
    }
    add(tests, "minor", "stringify", false) {
      val v = if (hasKey(it, "val")) getp(it, "val") else Struct.UNDEF
      val maxlen = (getp(it, "max") as? Number)?.toInt()
      if (maxlen == null) Struct.stringify(v) else Struct.stringify(v, maxlen)
    }
    add(tests, "minor", "jsonify", false) {
      val v = if (hasKey(it, "val")) getp(it, "val") else Struct.UNDEF
      Struct.jsonify(v, getp(it, "flags"))
    }
    add(tests, "minor", "pathify", false) {
      val path = if (hasKey(it, "path")) getp(it, "path") else Struct.UNDEF
      Struct.pathify(path, getp(it, "from"), getp(it, "to"))
    }
    add(tests, "minor", "escre", true) { Struct.escre(it) }
    add(tests, "minor", "escurl", true) { Struct.escurl(it) }
    add(tests, "minor", "join", false) { Struct.join(getp(it, "val"), getp(it, "sep"), getp(it, "url")) }
    add(tests, "minor", "flatten", true) {
      Struct.flatten(getp(it, "val"), (getp(it, "depth") as? Number)?.toInt() ?: 1)
    }
    add(tests, "minor", "filter", true) {
      val v = getp(it, "val")
      if ("gt3" == getp(it, "check")) {
        Struct.filter(v) { item -> (item[1] as? Number)?.toDouble()?.let { d -> d > 3 } == true }
      } else {
        Struct.filter(v) { item -> (item[1] as? Number)?.toDouble()?.let { d -> d < 3 } == true }
      }
    }
    add(tests, "minor", "typename", true) { Struct.typename(it) }
    add(tests, "minor", "typify", false) { Struct.typify(it) }
    add(tests, "minor", "size", false) { Struct.size(it) }
    add(tests, "minor", "slice", false) { Struct.slice(getp(it, "val"), getp(it, "start"), getp(it, "end")) }
    add(tests, "minor", "pad", false) { Struct.pad(getp(it, "val"), getp(it, "pad"), getp(it, "char")) }
    add(tests, "minor", "setpath", false) { Struct.setpath(getp(it, "store"), getp(it, "path"), getp(it, "val")) }

    // ===== walk =====
    add(tests, "walk", "basic", true) {
      Struct.walk(it, Struct.WalkApply { _, v, _, p -> if (v is String) v + "~" + p.joinToString(".") else v })
    }
    add(tests, "walk", "depth", false) {
      val src = getp(it, "src")
      val maxdepth = (getp(it, "maxdepth") as? Number)?.toInt()
      val top = arrayOfNulls<Any>(1)
      val cur = arrayOfNulls<Any>(1)
      val copy = Struct.WalkApply { key, value, _, _ ->
        if (Struct.isnode(value)) {
          val child: Any? = if (Struct.islist(value)) mutableListOf<Any?>() else linkedMapOf<String, Any?>()
          if (key == null) {
            top[0] = child
            cur[0] = child
          } else {
            cur[0] = Struct.setprop(cur[0], key, child)
            cur[0] = child
          }
        } else if (key != null) {
          cur[0] = Struct.setprop(cur[0], key, value)
        }
        value
      }
      if (maxdepth == null) Struct.walk(src, copy) else Struct.walk(src, copy, null, maxdepth)
      top[0]
    }
    add(tests, "walk", "copy", true) {
      val cur = arrayOfNulls<Any>(64)
      val walkcopy = Struct.WalkApply { key, value, _, path ->
        if (key == null) {
          cur[0] = when {
            Struct.ismap(value) -> linkedMapOf<String, Any?>()
            Struct.islist(value) -> mutableListOf<Any?>()
            else -> value
          }
          value
        } else {
          var v: Any? = value
          val i = path.size
          if (Struct.isnode(v)) {
            v = if (Struct.ismap(v)) linkedMapOf<String, Any?>() else mutableListOf<Any?>()
            cur[i] = v
          }
          Struct.setprop(cur[i - 1], key, v)
          value
        }
      }
      Struct.walk(it, walkcopy)
      cur[0]
    }

    // ===== merge =====
    add(tests, "merge", "cases", true) { Struct.merge(it) }
    add(tests, "merge", "array", true) { Struct.merge(it) }
    add(tests, "merge", "integrity", true) { Struct.merge(it) }
    add(tests, "merge", "depth", true) {
      val v = getp(it, "val")
      val d = (getp(it, "depth") as? Number)?.toInt() ?: 32
      Struct.merge(v, d)
    }

    // ===== getpath =====
    add(tests, "getpath", "basic", true) { Struct.getpath(getp(it, "store"), getp(it, "path")) }
    add(tests, "getpath", "relative", true) {
      val inj: Struct.Injection? = (it as? Map<String, Any?>)?.let { m ->
        if (!m.containsKey("dparent") && !m.containsKey("dpath") && !m.containsKey("base")) {
          null
        } else {
          Struct.Injection(null, null).apply {
            if (m.containsKey("dparent")) dparent = m["dparent"]
            if (m.containsKey("dpath")) {
              when (val dp = m["dpath"]) {
                is List<*> -> dpath = dp.map { e -> e?.toString() ?: "" }.toMutableList()
                is String -> if (dp.isNotEmpty()) dpath = dp.split(".").toMutableList()
              }
            }
            if (m.containsKey("base") && m["base"] is String) base = m["base"] as String
          }
        }
      }
      Struct.getpath(getp(it, "store"), getp(it, "path"), inj)
    }
    add(tests, "getpath", "special", true) {
      val injMap = getp(it, "inj") as? Map<String, Any?>
      val inj = injMap?.let { im ->
        Struct.Injection(null, null).apply {
          if (im.containsKey("key")) key = im["key"]?.toString() ?: ""
          if (im.containsKey("dparent")) dparent = im["dparent"]
          if (im.containsKey("dpath")) {
            val dp = im["dpath"]
            if (dp is List<*>) dpath = dp.map { e -> e?.toString() ?: "" }.toMutableList()
          }
          if (im.containsKey("meta")) {
            val mm = im["meta"]
            if (mm is Map<*, *>) {
              meta = linkedMapOf<String, Any?>().also { for ((k, v) in mm) it[k.toString()] = v }
            }
          }
        }
      }
      Struct.getpath(getp(it, "store"), getp(it, "path"), inj)
    }

    // ===== inject =====
    // inject.string passes the null modifier so a resolved JSON null
    // (encoded by the runner as "__NULL__") renders as a real null / the
    // literal text "null" (was StructRunner.NULL_MODIFIER).
    add(tests, "inject", "string", true) {
      val inj = Struct.Injection(null, null)
      inj.modify = NULL_MODIFIER
      Struct.inject(getp(it, "val"), getp(it, "store"), inj)
    }
    add(tests, "inject", "deep", true) { Struct.inject(getp(it, "val"), getp(it, "store")) }

    // ===== transform =====
    add(tests, "transform", "paths", true) { Struct.transform(getp(it, "data"), getp(it, "spec")) }
    add(tests, "transform", "cmds", true) { Struct.transform(getp(it, "data"), getp(it, "spec")) }
    add(tests, "transform", "each", true) { Struct.transform(getp(it, "data"), getp(it, "spec")) }
    add(tests, "transform", "pack", true) { Struct.transform(getp(it, "data"), getp(it, "spec")) }
    add(tests, "transform", "modify", true) {
      val opts = linkedMapOf<String, Any?>(
        "modify" to Struct.Modify { v, k, parent, _, _ ->
          if (k != null && parent is MutableMap<*, *> && v is String) {
            (parent as MutableMap<String, Any?>)[k.toString()] = "@$v"
          }
        },
      )
      Struct.transform(getp(it, "data"), getp(it, "spec"), opts)
    }
    add(tests, "transform", "ref", true) { Struct.transform(getp(it, "data"), getp(it, "spec")) }
    add(tests, "transform", "format", false) { Struct.transform(getp(it, "data"), getp(it, "spec")) }
    add(tests, "transform", "apply", true) {
      val opts = linkedMapOf<String, Any?>(
        "extra" to linkedMapOf<String, Any?>(
          "apply" to Function<Any?, Any?> { v -> if (v is String) v.uppercase() else v },
        ),
      )
      Struct.transform(getp(it, "data"), getp(it, "spec"), opts)
    }

    // ===== validate =====
    add(tests, "validate", "basic", false) { Struct.validate(getp(it, "data"), getp(it, "spec")) }
    add(tests, "validate", "child", true) { Struct.validate(getp(it, "data"), getp(it, "spec")) }
    add(tests, "validate", "one", true) { Struct.validate(getp(it, "data"), getp(it, "spec")) }
    add(tests, "validate", "exact", true) { Struct.validate(getp(it, "data"), getp(it, "spec")) }
    add(tests, "validate", "invalid", false) { Struct.validate(getp(it, "data"), getp(it, "spec")) }
    add(tests, "validate", "special", true) {
      val inj = getp(it, "inj") as? Map<String, Any?>
      Struct.validate(getp(it, "data"), getp(it, "spec"), inj)
    }

    // ===== select =====
    add(tests, "select", "basic", true) { Struct.select(getp(it, "obj"), getp(it, "query")) }
    add(tests, "select", "operators", true) { Struct.select(getp(it, "obj"), getp(it, "query")) }
    add(tests, "select", "edge", true) { Struct.select(getp(it, "obj"), getp(it, "query")) }
    add(tests, "select", "alts", true) { Struct.select(getp(it, "obj"), getp(it, "query")) }

    return tests
  }

  // The struct.nullsem section: does a PRESENT key holding a JSON null read
  // as "no value"? Opt-in per target (create-sdkgen ships it; an older
  // project corpus may predate it - the abort below says so OUT LOUD, as a
  // skipped test, rather than passing vacuously). The vendored kotlin
  // struct answers the canonical way on every question, list form included
  // (measured; see docs/design/vendor-tag-rollout.md). All lanes run
  // {null: false}: without the flag the runner rewrites every null to
  // '__NULL__' and the section asserts nothing about null at all.
  @Test
  fun nullsem() {
    val run = structRun()
    val nullsem = Helpers.toMapAny(run.spec["nullsem"])
    if (nullsem == null) {
      Assumptions.abort<Any>(
        "corpus predates struct.nullsem - refresh .sdk/test/struct from create-sdkgen",
      )
      return
    }
    val flags = Flags(nulls = false)

    run.runsetflags(nullsem["getprop"], flags) { args ->
      val input = args.getOrNull(0)
      val alt = getpDef(input, "alt", Struct.UNDEF)
      if (alt === Struct.UNDEF) {
        Struct.getprop(getp(input, "val"), getp(input, "key"))
      } else {
        Struct.getprop(getp(input, "val"), getp(input, "key"), alt)
      }
    }

    run.runsetflags(nullsem["getelem"], flags) { args ->
      val input = args.getOrNull(0)
      val alt = getpDef(input, "alt", Struct.UNDEF)
      if (alt === Struct.UNDEF) {
        Struct.getelem(getp(input, "val"), getp(input, "key"))
      } else {
        Struct.getelem(getp(input, "val"), getp(input, "key"), alt)
      }
    }

    run.runsetflags(nullsem["getpath"], flags) { args ->
      Struct.getpath(getp(args.getOrNull(0), "store"), getp(args.getOrNull(0), "path"))
    }

    run.runsetflags(nullsem["haskey"], flags) { args ->
      Struct.haskey(getp(args.getOrNull(0), "src"), getp(args.getOrNull(0), "key"))
    }

    run.runsetflags(nullsem["keysof"], flags) { args ->
      Struct.keysof(args.getOrNull(0))
    }
  }

  private fun add(
    tests: MutableList<DynamicTest>,
    category: String,
    name: String,
    nullFlag: Boolean,
    subject: StructSubject,
  ) {
    tests.add(
      DynamicTest.dynamicTest("$category-$name") {
        val run = structRun()
        val cat = Helpers.toMapAny(run.spec[category])
        assertNotNull(cat, "struct corpus category missing: $category - check .sdk/test/struct/")
        val spec = Helpers.toMapAny(cat!![name])
        assertNotNull(spec, "struct corpus section missing: $category.$name - check .sdk/test/struct/")
        val set = spec!!["set"]
        assertTrue(
          set is List<*> && set.isNotEmpty(),
          "struct corpus section is EMPTY: $category.$name - zero cases would run",
        )
        run.runsetflags(spec, Flags(nulls = nullFlag, name = "$category.$name")) { args ->
          subject.apply(if (args.isNotEmpty()) args[0] else Struct.UNDEF)
        }
      },
    )
  }

  private val NULL_MODIFIER = Struct.Modify { value, key, parent, _, _ ->
    if (value is String) {
      val repl: Any? = when {
        value == OmniResolver.NULLMARK -> null
        value.contains(OmniResolver.NULLMARK) -> value.replace(OmniResolver.NULLMARK, "null")
        else -> return@Modify
      }
      when {
        parent is MutableMap<*, *> && key != null -> (parent as MutableMap<String, Any?>)[key.toString()] = repl
        parent is MutableList<*> && key is Number -> (parent as MutableList<Any?>)[key.toInt()] = repl
      }
    }
  }
}
