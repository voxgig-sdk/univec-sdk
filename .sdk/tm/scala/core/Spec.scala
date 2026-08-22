package SCALAPACKAGE.core

import java.util.{LinkedHashMap, List => JList, Map => JMap}

// The resolved HTTP request specification for one operation.
class Spec(specmap: JMap[String, Object]) {

  var parts: JList[Object] = null
  var headers: JMap[String, Object] = new LinkedHashMap[String, Object]()
  var alias: JMap[String, Object] = new LinkedHashMap[String, Object]()
  var base: String = ""
  var prefix: String = ""
  var suffix: String = ""
  var params: JMap[String, Object] = new LinkedHashMap[String, Object]()
  var query: JMap[String, Object] = new LinkedHashMap[String, Object]()
  var step: String = ""
  var method: String = "GET"
  var body: Object = null
  var url: String = ""
  var path: String = ""

  def this() = this(null)

  if (specmap != null) {
    specmap.get("parts") match { case v: JList[_] => parts = v.asInstanceOf[JList[Object]]; case _ => }
    specmap.get("headers") match { case v: JMap[_, _] => headers = v.asInstanceOf[JMap[String, Object]]; case _ => }
    specmap.get("alias") match { case v: JMap[_, _] => alias = v.asInstanceOf[JMap[String, Object]]; case _ => }
    specmap.get("base") match { case v: String => base = v; case _ => }
    specmap.get("prefix") match { case v: String => prefix = v; case _ => }
    specmap.get("suffix") match { case v: String => suffix = v; case _ => }
    specmap.get("params") match { case v: JMap[_, _] => params = v.asInstanceOf[JMap[String, Object]]; case _ => }
    specmap.get("query") match { case v: JMap[_, _] => query = v.asInstanceOf[JMap[String, Object]]; case _ => }
    specmap.get("step") match { case v: String => step = v; case _ => }
    specmap.get("method") match { case v: String => method = v; case _ => }
    if (specmap.containsKey("body")) body = specmap.get("body")
    specmap.get("url") match { case v: String => url = v; case _ => }
    specmap.get("path") match { case v: String => path = v; case _ => }
  }
}
