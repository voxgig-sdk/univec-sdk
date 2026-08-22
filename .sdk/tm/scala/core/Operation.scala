package SCALAPACKAGE.core

import java.util.{ArrayList, List => JList, Map => JMap}
import SCALAPACKAGE.utility.struct.Struct

// A resolved entity operation (name, input kind, endpoint definitions).
class Operation(opmap: JMap[String, Object]) {

  var entity: String = "_"
  var name: String = "_"
  var input: String = "_"
  var points: JList[JMap[String, Object]] = new ArrayList[JMap[String, Object]]()
  var alias: JMap[String, Object] = null

  locally {
    Struct.getprop(opmap, "entity") match { case s: String if s != "" => entity = s; case _ => }
    Struct.getprop(opmap, "name") match { case s: String if s != "" => name = s; case _ => }
    Struct.getprop(opmap, "input") match { case s: String if s != "" => input = s; case _ => }

    Struct.getprop(opmap, "points") match {
      case rawPoints: JList[_] =>
        val it = rawPoints.asInstanceOf[JList[Object]].iterator()
        while (it.hasNext) {
          it.next() match {
            case m: JMap[_, _] => points.add(m.asInstanceOf[JMap[String, Object]])
            case _ =>
          }
        }
      case _ =>
    }

    Struct.getprop(opmap, "alias") match {
      case m: JMap[_, _] => alias = m.asInstanceOf[JMap[String, Object]]
      case _ =>
    }
  }
}
