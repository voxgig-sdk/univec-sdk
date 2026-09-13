// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Capability.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** Capabilities (section 11.1).
  *
  * A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a dependency
  * on something that can do the job, and which instance is doing it is exactly
  * the configuration detail a plugin must not care about.
  *
  * But A BINDING IS TO AN INSTANCE, not to a capability, which is what decides
  * behaviour when the bound provider leaves while another match remains.
  */
object Capability {

  /** Rank the matching live providers and return them best-first: highest
    * `version`, then LOWEST `priority` (default 0), then declaration position
    * `pos` ascending.
    *
    * `priority` is a field on the capability rather than section 7's `order`
    * band, because bands live on POINT BINDINGS: a provider may have several
    * bindings with different bands, or none at all, so a rank reaching for one
    * would be undefined in the common case.
    *
    * Without a total rank, "any provider satisfies" is true of the GRAPH and
    * useless to the PLUGIN - two ports could bind different `store` instances,
    * both resolve green, and behave differently, which is precisely the
    * divergence a shared corpus exists to catch.
    */
  def resolveCapability(req: Value, candidates: Value): List[Value] =
    Types.stableSortBy(candidates.items.filter(c => matches(req, c.at("provides"))))(rankKey)

  /** An ABSENT version sorts LAST, whatever the other is - "no version" loses
    * to every version rather than being read as 0.0.0. The leading flag is what
    * expresses that in a sort KEY rather than a comparator.
    */
  def rankKey(cand: Value): List[SortKey] = {
    val prov = cand.at("provides")
    val version = prov.at("version")
    val absent = version.isNull
    List(
      KNum(if (absent) 1 else 0),
      KList(
        if (absent) List(KNum(0), KNum(0), KNum(0))
        else Version.versionParts(version).map(n => KNum(-n))
      ),
      KNum(prov.at("priority").asDouble.getOrElse(0.0)),
      KNum(cand.at("pos").asDouble.getOrElse(0.0))
    )
  }

  def matches(req: Value, prov: Value): Boolean = {
    if (req.at("name") != prov.at("name")) return false

    val range = req.at("range")
    if (!range.isNull) {
      val version = prov.at("version")
      if (version.isNull) return false
      if (!Version.satisfiesq(version, range)) return false
    }

    // `match` is checked against the provider's `attrs`, key by key. A key the
    // provider does not carry is a miss, not a pass: a requirement asking for
    // `transactional: true` must not be satisfied by a provider that never said.
    val want = req.at("match")
    if (!want.isNull) {
      val attrs = prov.at("attrs")
      return want.keys.forall(k => attrs.has(k) && matchValue(want.at(k), attrs.at(k)))
    }
    true
  }

  /** PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).
    *
    * Every leaf in the requirement must be present and equal in the capability,
    * keys not mentioned are not checked. Equality is by JSON TYPE as well as
    * value: `transactional: 1` does not satisfy `transactional: true`. SCALA
    * NEEDS NO GUARD FOR THAT - `Value` is a sealed hierarchy, and `VBool(true)`
    * and `VNum(1)` are different case classes that cannot compare equal however
    * hard a reading tries. Python, PHP, Perl and Lua all need one, and
    * `capability/match` pins the behaviour for every port rather than trusting
    * each language's equality.
    *
    * A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
    */
  def matchValue(want: Value, got: Value): Boolean = (want, got) match {
    case (VMap(_), VMap(_)) =>
      want.keys.forall(k => got.has(k) && matchValue(want.at(k), got.at(k)))
    case (VMap(_), _) => false
    case (VList(w), VList(g)) =>
      w.length == g.length && w.zip(g).forall { case (x, y) => matchValue(x, y) }
    case (VList(_), _) => false
    case _             => want == got
  }
}
