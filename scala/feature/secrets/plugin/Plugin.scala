// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Plugin.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** The canonical surface `make parity` checks (AGENTS.md section 4). Small on
  * purpose (section 19): everything else is methods on the host and instance
  * types, because a library that grows a second public entry point per feature
  * is a library twenty ports pay for twice.
  *
  * ELEVEN NAMES, AND THEY FORWARD. The implementation lives in the object named
  * for its design section, so a reader who arrives at `resolveOrder` from the
  * corpus lands in `Order` where section 7 is quoted.
  */
object Plugin {

  // host construction
  def makeHost(options: HostOptions = HostOptions()): Host = new Host(options)

  def makeCatalog(definitions: List[Definition] = Nil): Catalog = {
    val catalog = new Catalog
    definitions.foreach(catalog.add)
    catalog
  }

  // refs - the first thing a new port implements (section 4)
  def parseRef(str: Value): Value = Refs.parseRef(str)

  def formatRef(name: Value, tag: Value = VNull): String = Refs.formatRef(name, tag)

  def checkName(name: Value): Boolean = Refs.checkName(name)

  def checkTag(tag: Value): Boolean = Refs.checkTag(tag)

  // pure functions over documents and definitions
  def normalizeConfig(input: Value): Value = Config.normalizeConfig(input)

  def resolveOptions(input: Value): Value = Config.resolveOptions(input)

  def resolveOrder(bindings: List[OrderNode], pin: Value = VNull): List[String] =
    Order.resolveOrder(bindings, pin)

  def resolveCandidates(name: String, sources: Value = VNull): List[String] =
    Resolve.resolveCandidates(name, sources)

  def applyEnv(input: Value): Value = Env.applyEnv(input)
}
