package KOTLINPACKAGE.core

import KOTLINPACKAGE.utility.struct.Struct

/** A resolved entity operation (name, input kind, endpoint definitions). */
@Suppress("UNCHECKED_CAST")
class Operation(opmap: Map<String, Any?>?) {

  var entity: String = "_"
  var name: String = "_"
  var input: String = "_"
  var points: MutableList<MutableMap<String, Any?>> = mutableListOf()
  var alias: MutableMap<String, Any?>? = null

  init {
    var v = Struct.getprop(opmap, "entity")
    if (v is String && v != "") {
      this.entity = v
    }
    v = Struct.getprop(opmap, "name")
    if (v is String && v != "") {
      this.name = v
    }
    v = Struct.getprop(opmap, "input")
    if (v is String && v != "") {
      this.input = v
    }

    val rawPoints = Struct.getprop(opmap, "points")
    if (rawPoints is List<*>) {
      for (t in rawPoints) {
        if (t is MutableMap<*, *>) {
          this.points.add(t as MutableMap<String, Any?>)
        }
      }
    }

    val rawAlias = Struct.getprop(opmap, "alias")
    if (rawAlias is MutableMap<*, *>) {
      this.alias = rawAlias as MutableMap<String, Any?>
    }
  }
}
