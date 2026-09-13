// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Value.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** The JSON value, and the value model this port holds throughout.
  *
  * A `Value` IS A SEALED TRAIT, not `Any`. Scala can express the JSON model
  * exactly, and `Map[String, Any]` would throw away every guarantee the
  * language is for - starting with the one that matters most here, that a
  * pattern match over a sealed hierarchy is CHECKED FOR EXHAUSTIVENESS. Adding
  * a case to this file makes the compiler name every place that has to handle
  * it, which is a stronger discipline than any of the untyped ports can have.
  *
  * `VNum` is a `Double` because JSON HAS ONE NUMBER TYPE. The canonical is
  * javascript, `1` and `1.0` are the same value there, and a port that split
  * them would disagree with the corpus on which of two spellings a document
  * used.
  *
  * NO JSON LIBRARY, AND NO `libraryDependencies` (section 16). The library is
  * allowed exactly one runtime dependency, `voxgig/struct`, which has no scala
  * port; everything else is the standard library.
  */
sealed trait Value {

  /** The value at a key, or None. `None` is ABSENT; `Some(VNull)` is a present
    * null, and that is the whole reason this returns an `Option` rather than
    * `VNull` for both.
    */
  def get(key: String): Option[Value] = this match {
    case VMap(entries) => entries.get(key)
    case _             => None
  }

  /** PRESENCE, which is what distinguishes an authored null from absence. */
  def has(key: String): Boolean = get(key).isDefined

  /** The value at a key with an absent key flattened to `VNull` - for the many
    * sites that treat the two alike.
    */
  def at(key: String): Value = get(key).getOrElse(VNull)

  /** The keys of a map, SORTED - every walk of a map goes through here. A scala
    * `Map` past four entries is a `HashMap` and iterates in hash order, so this
    * is not tidiness: without it a teardown order changes between two runs of
    * the same process.
    */
  def keys: List[String] = this match {
    case VMap(entries) => entries.keys.toList.sorted
    case _             => Nil
  }

  def items: List[Value] = this match {
    case VList(l) => l
    case _        => Nil
  }

  def entries: Map[String, Value] = this match {
    case VMap(m) => m
    case _       => Map.empty
  }

  def isNull: Boolean = this == VNull

  def isMap: Boolean = this.isInstanceOf[VMap]

  def isList: Boolean = this.isInstanceOf[VList]

  def asString: Option[String] = this match {
    case VStr(s) => Some(s)
    case _       => None
  }

  def asDouble: Option[Double] = this match {
    case VNum(n) => Some(n)
    case _       => None
  }

  /** An INTEGER, and only when the value is one. Section 7's band is an integer
    * the document wrote as one, and every number here is a `Double`, so the
    * test is "a whole double" - `VBool(true)` and `VStr("2")` are different
    * cases and reach neither branch.
    */
  def asInt: Option[Int] = this match {
    case VNum(n) if n == math.floor(n) && !n.isInfinite => Some(n.toInt)
    case _                                              => None
  }

  /** JSON truthiness: null and false, and nothing else, are false. Scala has no
    * truthiness of its own - `if (0)` does not compile - so this is where the
    * model's rule is written down.
    */
  def truthy: Boolean = this match {
    case VNull    => false
    case VBool(b) => b
    case _        => true
  }

  /** Set a key, returning the new value. A `Value` is immutable, so every
    * mutation is explicit and nothing aliases.
    */
  def setting(key: String, value: Value): Value = VMap(entries + (key -> value))

  /** COMPACT JSON, map keys in sorted order. A whole double renders WITHOUT its
    * fraction, so `1.0` and `1` spell the same - the corpus writes both and a
    * message quoting one must not depend on which.
    */
  def json: String = this match {
    case VNull    => "null"
    case VBool(b) => if (b) "true" else "false"
    case VNum(n) =>
      if (n == math.floor(n) && !n.isInfinite) n.toLong.toString else n.toString
    case VStr(s)  => Value.quote(s)
    case VList(l) => l.map(_.json).mkString("[", ",", "]")
    case VMap(_) =>
      keys.map(k => Value.quote(k) + ":" + at(k).json).mkString("{", ",", "}")
    // Anything the model has no JSON spelling for - a host, an instance
    // handle, a callback the driver exported.
    case VOpaque(_) => "\"(opaque)\""
  }
}

case object VNull extends Value
final case class VBool(b: Boolean) extends Value
final case class VNum(n: Double) extends Value
final case class VStr(s: String) extends Value
final case class VList(l: List[Value]) extends Value
final case class VMap(m: Map[String, Value]) extends Value

/** A host object published through `exports` (section 11). The design lets a
  * plugin export "a client" - a thing the library never inspects - and in a
  * statically typed port that needs an escape hatch. It is never produced by
  * the parser and never compared as data: `AnyRef` equality is reference
  * equality unless the object overrides it, which no instance handle does.
  */
final case class VOpaque(obj: AnyRef) extends Value

object Value {

  def map(pairs: (String, Value)*): Value = VMap(pairs.toMap)

  def list(items: Value*): Value = VList(items.toList)

  def quote(s: String): String = {
    val out = new StringBuilder("\"")
    s.foreach {
      case '"'                    => out.append("\\\"")
      case '\\'                   => out.append("\\\\")
      case '\n'                   => out.append("\\n")
      case '\r'                   => out.append("\\r")
      case '\t'                   => out.append("\\t")
      case c if c < ' '           => out.append("\\u%04x".format(c.toInt))
      case c                      => out.append(c)
    }
    out.append('"').toString
  }
}
