// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Env.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

import scala.collection.mutable

/** Environment overrides (section 9.5) - level 7 of the ladder.
  *
  * One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
  *
  *   VOXGIG_PLUGIN_PROFILE            the profile name
  *   VOXGIG_PLUGIN_<REF>_<PATH>       one option
  *   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
  *
  * THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING OTHERWISE.
  * Ref and path are upper-snake with `$` -> `__` and `.` -> `_`. But `_` is
  * legal in a name and in a tag, and the mapping folds case, so `retry$fast`
  * and `retry__fast` both encode to `RETRY__FAST`.
  *
  * Rather than restrict a grammar the rest of the stack already uses, the host
  * DETECTS THE COLLISION: it encodes every ref it holds, and a key two refs
  * claim is `plugin_env_ambiguous`, naming both.
  */
object Env {

  private val prefix = "VOXGIG_PLUGIN_"

  /** `retry$fast` -> `RETRY__FAST`. */
  def encodeRef(ref: String): String =
    ref.replace("$", "__").replace(".", "_").toUpperCase

  /** Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
    * `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
    * looks like rather than a parse error.
    */
  private def parseValue(value: Value): Value = value.asString match {
    case None => value
    case Some(s) =>
      try Json.parse(s)
      catch { case _: Exception => value }
  }

  private def split(value: Value): List[String] =
    value.asString.getOrElse(value.json).split(",", -1)
      .map(_.trim).filter(_.nonEmpty).toList

  private def checkReserved(ref: String, reserved: Value): Unit = {
    if (reserved.items.contains(VStr(Refs.refName(VStr(ref))))) {
      Types.fail(
        "plugin_ref_reserved", "ref is reserved by the host: " + ref,
        Map("ref" -> VStr(ref))
      )
    }
  }

  def applyEnv(input: Value): Value = {
    val env = input.at("env")
    val refs = input.at("refs").items.map(Refs.canonRef)
    val reserved = input.at("reserved")

    var options = Map.empty[String, Value]
    val active = mutable.ListBuffer[Value]()
    val inactive = mutable.ListBuffer[Value]()
    var profile: Option[Value] = None

    // Encode every ref the host holds, and refuse a key that two of them claim.
    // Done up front so the collision is reported even when no environment
    // variable exercises it - a latent ambiguity is still an ambiguity, and
    // finding it at deploy time is the failure this exists to prevent.
    val byencoded = mutable.LinkedHashMap[String, mutable.ListBuffer[String]]()
    refs.foreach(ref =>
      byencoded.getOrElseUpdate(encodeRef(ref), mutable.ListBuffer.empty) += ref
    )
    byencoded.keys.toList.sorted.foreach { e =>
      if (byencoded(e).length > 1) {
        val pair = byencoded(e).toList.sorted
        Types.fail(
          "plugin_env_ambiguous",
          "refs collide in the environment encoding as " + e + ": " + pair.mkString(", "),
          Map("encoded" -> VStr(e), "refs" -> VList(pair.map(VStr.apply)))
        )
      }
    }

    // Longest encoded ref first, so `retry$fast` wins over `retry` on
    // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    val encoded = Types.stableSortBy(byencoded.keys.toList.sorted)(e =>
      List(KNum(-e.length))
    )

    env.keys.foreach { key =>
      if (key.startsWith(prefix)) {
        val rest = key.substring(prefix.length)

        if (rest == "PROFILE") {
          profile = Some(env.at(key))
        } else if (rest == "ACTIVE" || rest == "INACTIVE") {
          split(env.at(key)).foreach { raw =>
            val ref = Refs.canonRef(VStr(raw))
            // The reservation covers EVERY input layer (section 9.1).
            // VOXGIG_PLUGIN_INACTIVE=station is easier to set than editing a
            // config file, and INACTIVE has the final word - so guarding
            // documents alone would leave the one lever this mechanism exists
            // to deny wide open.
            checkReserved(ref, reserved)
            if (rest == "ACTIVE") active += VStr(ref) else inactive += VStr(ref)
          }
        } else {
          encoded.find(e => rest == e || rest.startsWith(e + "_")) match {
            // Not for any ref this host holds.
            case None => ()
            case Some(enc) =>
              val ref = byencoded(enc).head
              checkReserved(ref, reserved)
              // A ref with no path sets nothing.
              if (rest != enc) {
                val path = rest.substring(enc.length + 1).toLowerCase.split("_", -1).toList
                options = options + (ref ->
                  write(options.getOrElse(ref, VMap(Map.empty)), path, parseValue(env.at(key))))
              }
          }
        }
      }
    }

    val out = Map[String, Value](
      "options" -> VMap(options),
      "active" -> VList(active.toList),
      "inactive" -> VList(inactive.toList)
    )
    VMap(profile.map(p => out + ("profile" -> p)).getOrElse(out))
  }

  /** Write one option at a dotted path, creating maps as it goes. A step whose
    * current value is not a map is REPLACED, because a scalar written by a
    * shallower variable cannot also be a container.
    */
  private def write(node: Value, path: List[String], value: Value): Value = {
    val base = if (node.isMap) node else VMap(Map.empty)
    if (path.length == 1) base.setting(path.head, value)
    else base.setting(path.head, write(base.at(path.head), path.tail, value))
  }
}
