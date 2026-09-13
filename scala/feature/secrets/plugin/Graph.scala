// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Graph.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** Whole-graph resolution (section 11.4) - a phase, not a discovery.
  *
  * "Activate, and wait in `pending` if you must" is correct and, on its own,
  * produces a terrible experience: apply twenty instances against a registry
  * missing one thing and you get NINETEEN pending rows and no statement of what
  * is actually wrong.
  *
  * `resolveGraph` is a PURE FUNCTION of the registry and the intended
  * activation set. No callbacks run, no state changes, nothing is touched. It
  * answers for the whole graph at once which instances can be live, and for
  * each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
  *
  * The failure mode being designed against is a famous one: OSGi's resolver is
  * correct and its diagnostics are legendarily unusable. A resolver that says
  * "blocked" without saying WHY has moved the problem rather than solved it, so
  * `why` is part of the contract and the corpus pins its shape.
  */
object Graph {

  def resolveGraph(nodes: Value): Value = {
    val list = nodes.items
    val byref = list.map(n => n.at("ref").asString.getOrElse("") -> n).toMap

    // Fixed point: a node resolves when every mandatory requirement is met by
    // an ALREADY-RESOLVED provider. Iterating to a fixed point is what makes a
    // provider that is itself blocked propagate, rather than each node being
    // judged against the raw registry.
    def settle(resolved: Set[String]): Set[String] = {
      val next = list.foldLeft(resolved) { (acc, n) =>
        val ref = n.at("ref").asString.getOrElse("")
        if (acc.contains(ref) || firstUnmet(n, byref, acc).isDefined) acc else acc + ref
      }
      if (next.size == resolved.size) resolved else settle(next)
    }
    val resolved = settle(Set.empty)

    val blocked = list
      .filterNot(n => resolved.contains(n.at("ref").asString.getOrElse("")))
      .flatMap(n => firstUnmet(n, byref, resolved).map(w => n.at("ref").asString.getOrElse("") -> w))
      .sortBy(_._1)
      .map(_._2)

    Value.map(
      "resolved" -> VList(resolved.toList.sorted.map(VStr.apply)),
      "blocked" -> VList(blocked)
    )
  }

  /** The FIRST unmet requirement, with the most specific explanation available.
    * Order matters: "no provider at all" and "a provider at the wrong version"
    * are different problems and a reader must not have to guess which they
    * have.
    */
  def firstUnmet(node: Value, byref: Map[String, Value], resolved: Set[String])
      : Option[Value] =
    node.at("requires").items
      .filterNot(_.at("optional").truthy)
      .flatMap(req => unmet(node, req, byref, resolved))
      .headOption

  private def unmet(
      node: Value, req: Value, byref: Map[String, Value], resolved: Set[String]
  ): Option[Value] = {
    val name = req.at("name").asString.getOrElse("")
    val all = graphCandidates(byref, name)
    if (all.isEmpty) return Some(why(node, name, Value.map("kind" -> VStr("absent"))))

    val ok = Capability.resolveCapability(req, VList(all))
    if (ok.nonEmpty) {
      // A provider exists and matches - but if none of them is itself resolved,
      // this node is blocked BEHIND it, and the chain is the useful answer
      // rather than "unmet".
      if (ok.exists(c => resolved.contains(c.at("ref").asString.getOrElse("")))) {
        return None
      }
      val chain = ok.map(_.at("ref").asString.getOrElse("")).sorted
      return Some(why(node, name, Value.map(
        "kind" -> VStr("blocked"), "chain" -> VList(chain.map(VStr.apply))
      )))
    }

    // Providers exist and none matched. Say which test failed.
    val range = req.at("range")
    if (!range.isNull) {
      val versions = all.map(_.at("provides").at("version"))
        .filter(v => v.isNull || !Version.satisfiesq(v, range))
        .map(v => v.asString.getOrElse("(none)"))
      if (versions.nonEmpty) {
        return Some(why(node, name, Value.map(
          "kind" -> VStr("version"), "range" -> range,
          "found" -> VList(versions.sorted.map(VStr.apply))
        )))
      }
    }

    val matchSpec = req.at("match")
    if (!matchSpec.isNull) {
      val bad = all.flatMap { c =>
        val attrs = c.at("provides").at("attrs")
        matchSpec.keys
          .filterNot(k => attrs.has(k) && Capability.matchValue(matchSpec.at(k), attrs.at(k)))
          .map(k => why(node, name, Value.map(
            "kind" -> VStr("match"), "failing" -> VStr(k),
            "want" -> matchSpec.at(k), "found" -> attrs.at(k)
          )))
      }
      if (bad.nonEmpty) return Some(bad.head)
    }

    Some(why(node, name, Value.map("kind" -> VStr("absent"))))
  }

  private def why(node: Value, name: String, reason: Value): Value =
    Value.map("ref" -> node.at("ref"), "unmet" -> VStr(name), "why" -> reason)

  // A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned it
  // here. Considering only declared capabilities made `resolve` answer
  // `absent` about a provider sitting right there and live - section
  // 11.4's job is explaining the graph the runtime reconciles, and it was
  // explaining a different one. The ref match WINS OUTRIGHT for that node,
  // as at runtime: one candidate, not two, for a node both named `b` and
  // providing `b`.
  def graphCandidates(byref: Map[String, Value], name: String): List[Value] = {
    val asref = Refs.canon(VStr(name))
    byref.keys.toList.sorted.flatMap { ref =>
      val node = byref(ref)
      if (ref == asref) {
        List(Value.map(
          "ref" -> node.at("ref"),
          "pos" -> node.get("pos").getOrElse(VNum(0)),
          "provides" -> Value.map("name" -> VStr(name))
        ))
      } else {
        node.at("provides").items
          .filter(_.at("name").asString.contains(name))
          .map(prov => Value.map(
            "ref" -> node.at("ref"),
            "pos" -> node.get("pos").getOrElse(VNum(0)),
            "provides" -> prov
          ))
      }
    }
  }
}
