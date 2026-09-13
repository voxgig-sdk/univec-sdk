// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Resolve.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** Dynamic resolution (section 10.2) - name to candidate module ids.
  *
  * PURE. It returns the ids a host WOULD try, in order; it does not load
  * anything. That separation is what lets the corpus pin resolution in every
  * language including those with no dynamic loading at all, and it is why
  * section 15.4 puts real module loading in per-port integration tests rather
  * than here.
  */
object Resolve {

  val defaultSources: Value = Value.list(
    Value.map(
      "kind" -> VStr("module"),
      "prefix" -> Value.list(
        VStr("@voxgig/plugin-"), VStr("voxgig-plugin-"), VStr("plugin-"), VStr("")
      )
    )
  )

  def resolveCandidates(name: String, sources: Value = VNull): List[String] = {
    // A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing` is
    // already a package id; prefixing it produces `@voxgig/plugin-@acme/thing`,
    // which is not a thing that can exist.
    if (name.startsWith("@")) return List(name)

    val list = if (sources.items.isEmpty) defaultSources else sources
    val ids = list.items.flatMap { src =>
      src.at("kind").asString match {
        case Some("module") =>
          val declared = src.at("prefix").items
          val prefixes = if (declared.isEmpty) List(VStr("")) else declared
          prefixes.map(p => p.asString.getOrElse("") + name)
        case Some("path") =>
          List(src.at("dir").asString.getOrElse("").replaceAll("/+$", "") + "/" + name)
        case _ => Nil
      }
    }
    ids.distinct
  }

  /** A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a name
    * with a letter or `@`, so `./local/thing` is not a ref and never reaches
    * candidate generation - seneca allows a path where a plugin name goes, and
    * this design deliberately does not, because a ref is an ADDRESS WITHIN A
    * HOST and a path is a LOCATION ON A DISK.
    */
  def resolveFrom(from: Value): List[Value] = List(from)
}
