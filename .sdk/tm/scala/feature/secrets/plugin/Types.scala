// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Types.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** The error type, the sort key, and the handful of helpers every module needs.
  */

/** Every error carries a section 12 code. Ports compare by CODE and never by
  * message: wording is a port's own business, and pinning the words would make
  * every translation a corpus change. The FORMAT, however, is pinned - a
  * parseable message is what makes a log searchable across twenty languages.
  *
  * AN EXCEPTION, NOT AN `Either`. Scala offers both and the canonical raises;
  * threading a `Left` through `Host.ready` would change the shape of every
  * call in the port for a difference no corpus entry can see, and would make
  * this the one port whose control flow does not read like the design.
  */
final class PluginError(
    val code: String,
    val text: String,
    val details: Map[String, Value]
) extends RuntimeException(Types.formatError(code, text, details))

object Types {

  /** Section 5.1's seven statuses, and no more. */
  val statuses = List(
    "declared", "loaded", "pending", "live", "failed", "loading", "closing"
  )

  /** Section 12's detail keys, in the order a message renders them. FIXED, not
    * the map's: a message is a searchable log line, and a line whose fields
    * move between runs is not.
    */
  val detailOrder = List(
    "ref", "point", "name", "key", "spec", "refs", "kind", "directive",
    "cycle", "holders", "cause"
  )

  /** `plugin/<code>: <text> [<key>=<value> ...]`
    *
    * Values render as COMPACT JSON, so a value containing a space or a bracket
    * cannot break the parse, and a list renders as a JSON array. The bracket is
    * absent entirely when no field applies.
    */
  def formatError(code: String, text: String, details: Map[String, Value]): String = {
    val parts = detailOrder.filter(details.contains).map(k => k + "=" + details(k).json)
    val tail = if (parts.isEmpty) "" else parts.mkString(" [", " ", "]")
    "plugin/" + code + ": " + text + tail
  }

  /** Throw a section 12 error. One spelling, so every raise site reads the
    * same. `Nothing` is the return type, so the compiler knows a call is a
    * terminator and no caller needs a redundant value after one.
    */
  def fail(
      code: String, text: String, details: Map[String, Value] = Map.empty
  ): Nothing = throw new PluginError(code, text, details)

  /** The section 12 code of an error, or "" for one this library did not throw.
    * The corpus compares by code, so the driver needs one place that knows how
    * to read it.
    */
  def codeOf(e: Throwable): String = e match {
    case p: PluginError => p.code
    case _              => ""
  }

  def messageOf(e: Throwable): String =
    Option(e.getMessage).getOrElse(e.toString)

  /** A STABLE sort by a comparable key.
    *
    * Scala's `sortBy` IS stable and says so - it is `java.util.Arrays.sort` on
    * an object array, a TimSort, and `SeqLike.sortBy` documents the guarantee.
    * Stability is load-bearing: section 7's comparators fall through to a `pos`
    * or ref tie-break that javascript's stable sort resolves BY POSITION, and a
    * port that shuffled equal keys would order a teardown differently between
    * two runs of one process. THE NAME IS WHAT THIS FUNCTION IS FOR: every sort
    * in the port goes through one place that says stability is required.
    */
  def stableSortBy[T](list: List[T])(keyOf: T => List[SortKey]): List[T] =
    list.sortWith((a, b) => SortKey.compare(keyOf(a), keyOf(b)) < 0)
}

/** A sort key element. A key is a list of numbers, strings and nested lists,
  * which is what lets `Capability.rankKey` express "absent version sorts last"
  * as a leading flag rather than as a comparator.
  */
sealed trait SortKey
final case class KNum(n: Double) extends SortKey
final case class KText(s: String) extends SortKey
final case class KList(l: List[SortKey]) extends SortKey

object SortKey {

  def compare(a: List[SortKey], b: List[SortKey]): Int = {
    val pairs = a.zip(b)
    pairs.map { case (x, y) => compareOne(x, y) }.find(_ != 0)
      .getOrElse(a.length.compare(b.length))
  }

  def compareOne(a: SortKey, b: SortKey): Int = (a, b) match {
    case (KNum(x), KNum(y))   => x.compare(y)
    case (KText(x), KText(y)) => x.compare(y)
    case (KList(x), KList(y)) => compare(x, y)
    case _                    => 0
  }
}
