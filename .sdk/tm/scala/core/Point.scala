package SCALAPACKAGE.core

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.utility.struct.Struct

// A single endpoint definition (typed view over a point map).
class Point(pointmap: JMap[String, Object]) {

  var args: JMap[String, Object] = null
  var rename: JMap[String, Object] = null
  var method: String = ""
  var orig: String = ""
  var parts: JList[Object] = new ArrayList[Object]()
  var params: JList[Object] = null
  var select: JMap[String, Object] = null
  // Absent in config means ACTIVE: emission drops `active: true` as a default (sdkgen L0), so only an explicit `active: false` turns a point off.
  var active: Boolean = true
  var relations: JList[Object] = null
  var alias: JMap[String, Object] = new LinkedHashMap[String, Object]()
  var transform: JMap[String, Object] = new LinkedHashMap[String, Object]()

  locally {
    Struct.getprop(pointmap, "args") match { case m: JMap[_, _] => args = m.asInstanceOf[JMap[String, Object]]; case _ => }
    if (args == null) {
      args = new LinkedHashMap[String, Object]()
      args.put("params", new ArrayList[Object]())
    }

    Struct.getprop(pointmap, "rename") match { case m: JMap[_, _] => rename = m.asInstanceOf[JMap[String, Object]]; case _ => }
    if (rename == null) {
      rename = new LinkedHashMap[String, Object]()
      rename.put("params", new LinkedHashMap[String, Object]())
    }

    Struct.getprop(pointmap, "method") match { case s: String => method = s; case _ => }
    Struct.getprop(pointmap, "orig") match { case s: String => orig = s; case _ => }
    Struct.getprop(pointmap, "parts") match { case l: JList[_] => parts = l.asInstanceOf[JList[Object]]; case _ => }
    Struct.getprop(pointmap, "params") match { case l: JList[_] => params = l.asInstanceOf[JList[Object]]; case _ => }
    Struct.getprop(pointmap, "select") match { case m: JMap[_, _] => select = m.asInstanceOf[JMap[String, Object]]; case _ => }
    Struct.getprop(pointmap, "active") match { case b: java.lang.Boolean => active = b.booleanValue(); case _ => }
    Struct.getprop(pointmap, "relations") match { case l: JList[_] => relations = l.asInstanceOf[JList[Object]]; case _ => }
    Struct.getprop(pointmap, "alias") match { case m: JMap[_, _] => alias = m.asInstanceOf[JMap[String, Object]]; case _ => }
    Struct.getprop(pointmap, "transform") match { case m: JMap[_, _] => transform = m.asInstanceOf[JMap[String, Object]]; case _ => }
  }
}
