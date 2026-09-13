// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Refs.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** Identity: name+tag, written `name$tag` (section 4).
  *
  * The four pure functions, and the whole of what `ref` pins. They are the
  * first thing a new port implements and the first corpus section it passes.
  */
object Refs {

  val refMax = 1024

  /** Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
    *
    * A CHARACTER LOOP RATHER THAN A REGULAR EXPRESSION, for the same reason the
    * swift port uses one: a grammar this small is clearer as the two character
    * classes it actually is, and it removes the whole `^`/`$`-versus-`\A`/`\z`
    * trap that ruby, java and dart each document from a different side. There
    * is no anchor to get wrong, because there is no search, and `"abc\n"` fails
    * on the newline like any other character outside the class.
    */
  def checkName(name: Value): Boolean = name.asString match {
    // The parenthesis around the first-character test is LOAD-BEARING: scala
    // binds `match` tighter than `||`, so `a || b match {...}` reads as
    // `a || (b match {...})` and a name starting with a letter would
    // short-circuit to true without the rest ever being checked.
    case Some(s) if s.nonEmpty && s.length <= refMax =>
      (isAlpha(s.charAt(0)) || s.charAt(0) == '@') && s.drop(1).forall(nameChar)
    case _ => false
  }

  private def nameChar(c: Char): Boolean =
    isAlpha(c) || c.isDigit || c == '.' || c == '~' || c == '_' || c == '-' || c == '/'

  /** Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
    *
    * The asymmetry with a name is deliberate: a tag MAY start with a digit
    * because auto-tagging assigns integer tags (`stripe$1`), and a tag admits
    * neither `@` nor `/` because a name is a package specifier and a tag is not.
    */
  def checkTag(tag: Value): Boolean = tag.asString match {
    // The empty tag is an ordinary tag (section 4 rule 2). The single-instance
    // case writes no tag and never learns tags exist.
    case Some("")                        => true
    case Some(s) if s.length <= refMax   => s.forall(tagChar)
    case _                               => false
  }

  private def tagChar(c: Char): Boolean =
    isAlpha(c) || c.isDigit || c == '.' || c == '~' || c == '_' || c == '-'

  def isAlpha(c: Char): Boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

  /** `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both give
    * tag "".
    */
  def parseRef(str: Value): Value = {
    val s = str.asString.getOrElse(
      Types.fail("plugin_bad_name", "ref must be a string")
    )
    // Split on the FIRST `$`. Nothing in the grammar decides this - `$` is in
    // neither character class - so the corpus is the arbiter (section 4 rule
    // 5), and it picks the split that blames the part actually at fault:
    // `a$b$c` is a good name with a bad tag, not the reverse.
    val cut = s.indexOf('$')
    val name = if (cut < 0) s else s.substring(0, cut)
    val tag = if (cut < 0) "" else s.substring(cut + 1)

    if (!checkName(VStr(name))) {
      Types.fail(
        "plugin_bad_name", "invalid plugin name: " + name, Map("name" -> VStr(name))
      )
    }
    if (!checkTag(VStr(tag))) {
      Types.fail(
        "plugin_bad_tag", "invalid plugin tag: " + tag,
        Map("name" -> VStr(name), "tag" -> VStr(tag))
      )
    }
    Value.map("name" -> VStr(name), "tag" -> VStr(tag))
  }

  /** The pair -> `name$tag`. An empty tag NEVER writes the separator, which is
    * the half of canonicalization `formatRef` owns: parse tolerates `stripe$`,
    * format never produces it, so a round trip is idempotent.
    */
  def formatRef(name: Value, tag: Value = VNull): String = {
    val t = if (tag.isNull) VStr("") else tag
    if (!checkName(name)) {
      Types.fail(
        "plugin_bad_name", "invalid plugin name: " + show(name), Map("name" -> name)
      )
    }
    if (!checkTag(t)) {
      Types.fail(
        "plugin_bad_tag", "invalid plugin tag: " + show(t),
        Map("name" -> name, "tag" -> t)
      )
    }
    val n = name.asString.get
    val ts = t.asString.get
    if (ts.isEmpty) n else n + "$" + ts
  }

  /** A value as a message would show it: a string bare, anything else as JSON.
    * Interpolating a `Value` directly would print the case class.
    */
  def show(v: Value): String = v.asString.getOrElse(v.json)

  /** The canonical spelling of a ref. Section 4 rule 5: ports must canonicalize
    * before comparison.
    */
  def canonRef(str: Value): String = {
    val r = parseRef(str)
    formatRef(r.at("name"), r.at("tag"))
  }

  /** `canonRef` for the internal callers that want the input back unchanged
    * when it is not well formed. NEVER use it where a bad ref must be reported
    * - the corpus pins plugin_bad_name at every public entry.
    */
  def canon(str: Value): String =
    try canonRef(str)
    catch { case _: PluginError => show(str) }

  def refName(str: Value): String =
    try parseRef(str).at("name").asString.get
    catch { case _: PluginError => show(str) }
}
