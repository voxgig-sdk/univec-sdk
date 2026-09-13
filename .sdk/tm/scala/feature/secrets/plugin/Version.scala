// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Version.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** Versions and ranges (section 11.2).
  *
  * TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a concrete
  * version. A requirement declares `range`. A requirement is satisfied when the
  * names match, the `match` passes, and the provider's `version` falls inside
  * the requirement's `range`.
  *
  * That is the whole rule. There is no third field and no second comparison -
  * an earlier draft added a provider-side `compat` range, which left three
  * values and no statement of how they combine, and three defensible readings
  * of one declaration is worse than the ambiguity it was introduced to fix.
  */
object Version {

  /** A COMPONENT IS BOUNDED, and the bound is the model's, not the host
    * language's. A scala `Long` is 64-bit and javascript stops being exact past
    * 2**53, so `9223372036854775808.0.0` parsed to an exact value here and a
    * rounded one there. 2**31-1 is the smallest bound every target language
    * holds exactly, which makes it the model's.
    */
  val componentMax: Double = 2147483647.0

  /** The three dot-separated numeric parts, or None - written as a scan for the
    * same reason `Refs` is: no regex, and nothing to get wrong about anchoring.
    */
  def scan(s: String): Option[List[String]] = {
    val parts = s.split("\\.", -1).toList
    if (parts.length <= 3 && parts.forall(p => p.nonEmpty && p.forall(_.isDigit))) {
      Some(parts)
    } else {
      None
    }
  }

  /** A component parses as a `Double` so that `major + 1` at `componentMax` is
    * 2147483648 rather than an overflow, and so that every number in this port
    * is one type. `BigInt` first, because a forty-digit component read straight
    * into a `Long` would wrap past the check meant to reject it.
    */
  def component(digits: String, whole: String, field: String): Double = {
    val value = BigInt(digits)
    if (BigInt(componentMax.toLong) < value) {
      Types.fail(
        "plugin_bad_range",
        "version component out of range in " + whole + ": " + digits,
        Map(field -> VStr(whole))
      )
    }
    value.toDouble
  }

  /** Two forms and no more (section 11.2):
    *
    *   '2.1'    >= 2.1.0 and < 3.0.0
    *   '~2.1'   >= 2.1.0 and < 2.2.0
    */
  def parseRange(range: Value): Value = {
    val s = range.asString.getOrElse(
      Types.fail(
        "plugin_bad_range", "invalid range: " + Refs.show(range), Map("range" -> range)
      )
    )
    if (s.isEmpty) {
      Types.fail("plugin_bad_range", "invalid range: " + s, Map("range" -> range))
    }
    val tilde = s.startsWith("~")
    val body = if (tilde) s.substring(1) else s
    val parts = scan(body).getOrElse(
      Types.fail("plugin_bad_range", "invalid range: " + s, Map("range" -> range))
    )
    val major = component(parts.head, s, "range")
    val minor = if (parts.length > 1) component(parts(1), s, "range") else 0.0
    val patch = if (parts.length > 2) component(parts(2), s, "range") else 0.0

    Value.map(
      "lo" -> Value.list(VNum(major), VNum(minor), VNum(patch)),
      "hi" -> (if (tilde) Value.list(VNum(major), VNum(minor + 1), VNum(0))
               else Value.list(VNum(major + 1), VNum(0), VNum(0)))
    )
  }

  def parseVersion(version: Value): List[Double] = {
    val s = version.asString.getOrElse(
      Types.fail(
        "plugin_bad_range", "invalid version: " + Refs.show(version),
        Map("version" -> version)
      )
    )
    val parts = scan(s).getOrElse(
      Types.fail(
        "plugin_bad_range", "invalid version: " + s, Map("version" -> version)
      )
    )
    List(
      component(parts.head, s, "version"),
      if (parts.length > 1) component(parts(1), s, "version") else 0.0,
      if (parts.length > 2) component(parts(2), s, "version") else 0.0
    )
  }

  def versionCmp(a: List[Double], b: List[Double]): Int = {
    val diffs = (0 until 3).map { i =>
      val x = if (i < a.length) a(i) else 0.0
      val y = if (i < b.length) b(i) else 0.0
      x.compare(y)
    }
    diffs.find(_ != 0).getOrElse(0)
  }

  /** The one satisfaction predicate: lo <= version < hi. */
  def satisfies(version: Value, range: Value): Boolean = {
    val v = parseVersion(version)
    val r = parseRange(range)
    val lo = r.at("lo").items.flatMap(_.asDouble)
    val hi = r.at("hi").items.flatMap(_.asDouble)
    versionCmp(v, lo) >= 0 && versionCmp(v, hi) < 0
  }

  /** `satisfies` for the internal callers that treat an unparseable version or
    * range as "does not satisfy" - Capability and Graph, both of which run over
    * data the corpus has already admitted.
    */
  def satisfiesq(version: Value, range: Value): Boolean =
    try satisfies(version, range)
    catch { case _: PluginError => false }

  /** The numeric parts of a version, or zeros - a SORT KEY, never a check. */
  def versionParts(text: Value): List[Double] =
    try parseVersion(text)
    catch { case _: PluginError => List(0.0, 0.0, 0.0) }
}
