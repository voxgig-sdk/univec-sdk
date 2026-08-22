package SCALAPACKAGE.feature

import java.util.{ArrayList, List => JList, Map => JMap}
import java.util.function.{IntConsumer, LongSupplier}

// Shared option readers for the feature implementations.
object FeatureOptions {

  def foptBool(options: JMap[String, Object], key: String, dflt: Boolean): Boolean = {
    if (options == null) return dflt
    options.get(key) match { case b: java.lang.Boolean => b.booleanValue(); case _ => dflt }
  }

  def foptInt(options: JMap[String, Object], key: String, dflt: Int): Int = {
    if (options == null) return dflt
    options.get(key) match { case n: java.lang.Number => n.intValue(); case _ => dflt }
  }

  def foptNum(options: JMap[String, Object], key: String, dflt: Double): Double = {
    if (options == null) return dflt
    options.get(key) match { case n: java.lang.Number => n.doubleValue(); case _ => dflt }
  }

  def foptStr(options: JMap[String, Object], key: String, dflt: String): String = {
    if (options == null) return dflt
    options.get(key) match { case s: String if s != "" => s; case _ => dflt }
  }

  def foptMap(options: JMap[String, Object], key: String): JMap[String, Object] = {
    if (options == null) return null
    options.get(key) match { case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]; case _ => null }
  }

  def foptList(options: JMap[String, Object], key: String): JList[Object] = {
    if (options == null) return null
    options.get(key) match { case l: JList[_] => l.asInstanceOf[JList[Object]]; case _ => null }
  }

  def foptStrList(options: JMap[String, Object], key: String): JList[String] = {
    val raw = foptList(options, key)
    if (raw == null) return null
    val out = new ArrayList[String]()
    val it = raw.iterator()
    while (it.hasNext) it.next() match { case s: String => out.add(s); case _ => }
    out
  }

  // Injectable sleep (option "sleep": IntConsumer of ms), defaulting to a
  // real Thread.sleep.
  def foptSleep(options: JMap[String, Object]): IntConsumer = {
    if (options != null) options.get("sleep") match { case ic: IntConsumer => return ic; case _ => }
    (ms: Int) => if (ms > 0) {
      try Thread.sleep(ms.toLong)
      catch { case _: InterruptedException => Thread.currentThread().interrupt() }
    }
  }

  // Injectable clock (option "now": LongSupplier of ms), defaulting to the
  // wall clock.
  def foptNow(options: JMap[String, Object]): LongSupplier = {
    if (options != null) options.get("now") match { case ls: LongSupplier => return ls; case _ => }
    () => System.currentTimeMillis()
  }

  def fheaderGet(headers: JMap[String, Object], name: String): Object = {
    if (headers == null) return null
    val it = headers.entrySet().iterator()
    while (it.hasNext) {
      val e = it.next()
      if (e.getKey != null && e.getKey.equalsIgnoreCase(name)) return e.getValue
    }
    null
  }

  def fheaderHas(headers: JMap[String, Object], name: String): Boolean = {
    if (headers == null) return false
    val it = headers.keySet().iterator()
    while (it.hasNext) {
      val k = it.next()
      if (k != null && k.equalsIgnoreCase(name)) return true
    }
    false
  }

  def fheaderSetDefault(headers: JMap[String, Object], name: String, value: String): Unit = {
    if (headers == null) return
    if (fheaderHas(headers, name)) return
    headers.put(name, value)
  }

  def fresStatus(res: Object): Int = res match {
    case m: JMap[_, _] =>
      m.asInstanceOf[JMap[String, Object]].get("status") match { case n: java.lang.Number => n.intValue(); case _ => -1 }
    case _ => -1
  }

  def fresHeader(res: Object, name: String): String = res match {
    case m: JMap[_, _] =>
      m.asInstanceOf[JMap[String, Object]].get("headers") match {
        case hm: JMap[_, _] =>
          fheaderGet(hm.asInstanceOf[JMap[String, Object]], name) match { case s: String => s; case _ => "" }
        case _ => ""
      }
    case _ => ""
  }

  def fparseInt(s: String, dflt: Int): Int = {
    try Integer.parseInt(s.trim)
    catch { case _: RuntimeException => dflt }
  }
}
