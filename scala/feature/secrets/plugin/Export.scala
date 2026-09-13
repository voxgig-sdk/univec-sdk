// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Export.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** Exports (section 11).
  *
  * An instance publishes values for other plugins and for the application. Read
  * with `host.exports("retry$fast/client")`.
  *
  * THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves to
  * the UNTAGGED instance if one exists; if not, and exactly one tagged instance
  * exports that key, it resolves to that one; if two do, it is
  * `plugin_export_ambiguous` - deliberately diverging from seneca's silent
  * last-wins, because with multi-instance as a headline feature an ambiguous
  * alias is a defect waiting for production.
  */
object Export {

  /** One published value. An internal shape, never a corpus value. */
  final case class Exported(ref: String, key: String, value: Value)

  def resolveExport(spec: String, exported: List[Exported]): Value = {
    val cut = spec.indexOf('/')
    if (cut < 0) {
      Types.fail(
        "plugin_export_ambiguous", "export spec needs a key: " + spec,
        Map("spec" -> VStr(spec))
      )
    }
    val head = spec.substring(0, cut)
    val key = spec.substring(cut + 1)

    // A fully qualified ref: exactly one answer or none.
    val want = Refs.canon(VStr(head))
    exported.find(e => e.ref == want && e.key == key) match {
      case Some(e) => e.value
      case None =>
        // An alias: the name, not a ref. Look at every instance of it.
        val byname = exported.filter(e => Refs.refName(VStr(e.ref)) == head && e.key == key)
        if (byname.isEmpty) {
          VNull
        } else {
          byname.find(e => Refs.parseRef(VStr(e.ref)).at("tag") == VStr("")) match {
            case Some(e)                    => e.value
            case None if byname.length == 1 => byname.head.value
            case None =>
              val refs = byname.map(_.ref).sorted
              Types.fail(
                "plugin_export_ambiguous",
                "alias " + spec + " matches " + refs.length + " instances: " +
                  refs.mkString(", "),
                Map("spec" -> VStr(spec), "refs" -> VList(refs.map(VStr.apply)))
              )
          }
        }
    }
  }
}
