package KOTLINPACKAGE.core

/** The resolved HTTP request specification for one operation. */
@Suppress("UNCHECKED_CAST")
class Spec(specmap: Map<String, Any?>? = null) {

  var parts: MutableList<Any?>? = null
  var headers: MutableMap<String, Any?> = linkedMapOf()
  var alias: MutableMap<String, Any?> = linkedMapOf()
  var base: String = ""
  var prefix: String = ""
  var suffix: String = ""
  var params: MutableMap<String, Any?> = linkedMapOf()
  var query: MutableMap<String, Any?> = linkedMapOf()
  var step: String = ""
  var method: String = "GET"
  var body: Any? = null
  var url: String = ""
  var path: String = ""

  init {
    if (specmap != null) {
      var v = specmap["parts"]
      if (v is MutableList<*>) {
        this.parts = v as MutableList<Any?>
      }
      v = specmap["headers"]
      if (v is MutableMap<*, *>) {
        this.headers = v as MutableMap<String, Any?>
      }
      v = specmap["alias"]
      if (v is MutableMap<*, *>) {
        this.alias = v as MutableMap<String, Any?>
      }
      v = specmap["base"]
      if (v is String) {
        this.base = v
      }
      v = specmap["prefix"]
      if (v is String) {
        this.prefix = v
      }
      v = specmap["suffix"]
      if (v is String) {
        this.suffix = v
      }
      v = specmap["params"]
      if (v is MutableMap<*, *>) {
        this.params = v as MutableMap<String, Any?>
      }
      v = specmap["query"]
      if (v is MutableMap<*, *>) {
        this.query = v as MutableMap<String, Any?>
      }
      v = specmap["step"]
      if (v is String) {
        this.step = v
      }
      v = specmap["method"]
      if (v is String) {
        this.method = v
      }
      if (specmap.containsKey("body")) {
        this.body = specmap["body"]
      }
      v = specmap["url"]
      if (v is String) {
        this.url = v
      }
      v = specmap["path"]
      if (v is String) {
        this.path = v
      }
    }
  }
}
