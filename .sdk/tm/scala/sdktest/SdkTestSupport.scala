// Shared support for the generated per-entity SDK tests — a dependency-free
// scala-cli harness that mirrors the java RunnerSupport. Lives in the default
// package alongside SdkTestMain / Runner so the generated *EntityTest and
// *DirectTest objects (also default package) can use it. The aggregating
// SdkEntityTestMain drives every generated test object through one shared
// SdkTestReport and exits non-zero on any failure.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}

import SCALAPACKAGE.core.{Entity, Helpers}
import SCALAPACKAGE.utility.Json

// Pass/fail accumulator shared by all generated entity/direct test objects.
class SdkTestReport {
  var npass: Int = 0
  val failures = new ArrayList[String]()

  def pass(): Unit = { npass += 1 }
  def fail(name: String, msg: String): Unit = failures.add(name + ": " + msg)
  def check(name: String, cond: Boolean, msg: String): Unit =
    if (cond) pass() else fail(name, msg)

  def eq(name: String, exp: Object, act: Object): Unit =
    check(name, SdkTestSupport.jeq(exp, act), "expected " + exp + ", got " + act)
  def eqI(name: String, exp: Int, act: Int): Unit =
    check(name, exp == act, "expected " + exp + ", got " + act)

  // Run one logical test; a thrown exception is recorded as a single failure
  // so a crash in one test never aborts the whole suite.
  def scope(name: String)(body: => Unit): Unit =
    try body
    catch { case e: Throwable => fail(name, "THREW: " + e) }

  def finish(label: String): Unit = {
    val it = failures.iterator()
    while (it.hasNext) println("FAIL " + it.next())
    println("\n" + label + " PASS " + npass + "  FAIL " + failures.size())
    if (failures.size() > 0) System.exit(1)
  }
}

object SdkTestSupport {

  def om(kv: (String, Object)*): JMap[String, Object] = {
    val m = new LinkedHashMap[String, Object]()
    kv.foreach { case (k, v) => m.put(k, v) }
    m
  }

  def jl(xs: Object*): JList[Object] = {
    val l = new ArrayList[Object]()
    xs.foreach(l.add)
    l
  }

  def I(n: Int): java.lang.Integer = java.lang.Integer.valueOf(n)
  def B(b: Boolean): java.lang.Boolean = java.lang.Boolean.valueOf(b)

  def jeq(a: Object, b: Object): Boolean = (a, b) match {
    case (null, null) => true
    case (x: java.lang.Number, y: java.lang.Number) => x.doubleValue() == y.doubleValue()
    case (null, _) => false
    case _ => a.equals(b)
  }

  // Read a JSON file into the runtime's map/list/scalar shapes.
  def readJson(path: String): Object = {
    val src = new String(
      java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(path)), "UTF-8")
    Json.parse(src)
  }

  // Convert a list of Entity wrappers (or plain maps) to their data maps so
  // Struct.select can query them (mirrors java RunnerSupport.entityListToData).
  def entityListToData(list: Object): JList[Object] = {
    val out = new ArrayList[Object]()
    list match {
      case l: JList[_] =>
        val it = l.asInstanceOf[JList[Object]].iterator()
        while (it.hasNext) {
          it.next() match {
            case e: Entity =>
              val dm = Helpers.toMapAny(e.data())
              if (dm != null) out.add(dm)
            case m: JMap[_, _] => out.add(m)
            case _ =>
          }
        }
      case _ =>
    }
    out
  }
}
