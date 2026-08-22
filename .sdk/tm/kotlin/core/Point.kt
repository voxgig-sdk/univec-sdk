package KOTLINPACKAGE.core

import KOTLINPACKAGE.utility.struct.Struct

/** A single endpoint definition (typed view over a point map). */
@Suppress("UNCHECKED_CAST")
class Point(pointmap: Map<String, Any?>?) {

  var args: MutableMap<String, Any?>
  var rename: MutableMap<String, Any?>
  var method: String = ""
  var orig: String = ""
  var parts: MutableList<Any?> = mutableListOf()
  var params: MutableList<Any?>? = null
  var select: MutableMap<String, Any?>? = null
  // Absent in config means ACTIVE: emission drops `active: true` as a
  // default (sdkgen L0), so only an explicit `active: false` turns a point off.
  var active: Boolean = true
  var relations: MutableList<Any?>? = null
  var alias: MutableMap<String, Any?> = linkedMapOf()
  var transform: MutableMap<String, Any?> = linkedMapOf()

  init {
    var v = Struct.getprop(pointmap, "args")
    if (v is MutableMap<*, *>) {
      this.args = v as MutableMap<String, Any?>
    } else {
      this.args = linkedMapOf()
      this.args["params"] = mutableListOf<Any?>()
    }

    v = Struct.getprop(pointmap, "rename")
    if (v is MutableMap<*, *>) {
      this.rename = v as MutableMap<String, Any?>
    } else {
      this.rename = linkedMapOf()
      this.rename["params"] = linkedMapOf<String, Any?>()
    }

    v = Struct.getprop(pointmap, "method")
    if (v is String) {
      this.method = v
    }

    v = Struct.getprop(pointmap, "orig")
    if (v is String) {
      this.orig = v
    }

    v = Struct.getprop(pointmap, "parts")
    if (v is MutableList<*>) {
      this.parts = v as MutableList<Any?>
    }

    v = Struct.getprop(pointmap, "params")
    if (v is MutableList<*>) {
      this.params = v as MutableList<Any?>
    }

    v = Struct.getprop(pointmap, "select")
    if (v is MutableMap<*, *>) {
      this.select = v as MutableMap<String, Any?>
    }

    v = Struct.getprop(pointmap, "active")
    if (v is Boolean) {
      this.active = v
    }

    v = Struct.getprop(pointmap, "relations")
    if (v is MutableList<*>) {
      this.relations = v as MutableList<Any?>
    }

    v = Struct.getprop(pointmap, "alias")
    if (v is MutableMap<*, *>) {
      this.alias = v as MutableMap<String, Any?>
    }

    v = Struct.getprop(pointmap, "transform")
    if (v is MutableMap<*, *>) {
      this.transform = v as MutableMap<String, Any?>
    }
  }
}
