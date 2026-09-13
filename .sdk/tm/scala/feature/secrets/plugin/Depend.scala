// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Depend.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

import scala.collection.mutable

/** Dependency cardinality, policy, and the restart graph (section 11.3).
  *
  * TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT, because
  * only it knows what it can cope with:
  *
  *                | static (default)          | dynamic
  *   -------------|---------------------------|--------------------------
  *   mandatory    | unmet -> pending;         | unmet -> pending;
  *   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
  *                |          recursively      |          notified
  *   -------------|---------------------------|--------------------------
  *   optional:true| never gates activation;   | never gates activation;
  *                | a change deactivates and  | a change is a
  *                | reactivates               | notification, nothing else
  *
  * `dynamic` means the plugin has said, IN WRITING, that it can survive its
  * provider being swapped underneath it. It is not the default because most
  * plugins cannot, and the cost of wrongly assuming they can is a live instance
  * holding a dead reference.
  *
  * The rebinding-preference axis is deliberately omitted. OSGi has reluctant vs
  * greedy and it is a knob every author must understand to read anyone else's
  * component; we take always-reluctant. Three axes were more than the model can
  * carry across twenty ports.
  */

/** One node of the requirement graph. An internal shape, never a corpus value. */
final case class GraphNode(ref: String, provides: List[String], requires: List[Value])

object Depend {

  /** A bare string is shorthand for `{name}`. */
  def normRequire(raw: Value): Value = raw match {
    case VStr(s) => Value.map("name" -> VStr(s))
    case VMap(_) => raw
    case _       => VMap(Map.empty)
  }

  /** The requirements a definition declared, normalized.
    *
    * BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
    *
    * The instance-level `policy` and `optional` list are how a DOCUMENT states
    * the axis without editing the definition, and they apply to every
    * requirement. The per-requirement form is the one section 11.1's object
    * syntax exists for, and it is strictly more expressive: an instance that is
    * `static` on its store and `dynamic` on its metrics cannot be written at
    * all at the instance level.
    *
    * `optional` unions rather than overriding - both spellings are statements
    * that this requirement need not gate activation, and there is no reading
    * under which one of them means "actually, mandatory".
    */
  def requirements(options: Value): List[Value] = {
    val marked = options.at("optional")
    val fallback = options.at("policy")

    options.at("requires").items.map { item =>
      val req = normRequire(item)
      val listed = marked.isList && marked.items.contains(req.at("name"))
      val withOptional =
        if (req.at("optional").truthy || listed) req.setting("optional", VBool(true))
        else req
      if (!withOptional.has("policy") && !fallback.isNull) {
        withOptional.setting("policy", fallback)
      } else {
        withOptional
      }
    }
  }

  /** Does losing this requirement's SELECTED provider restart the consumer? The
    * mandatory ones under `static`, and the `static` optional ones - both make
    * a capability change deactivate and reactivate. `dynamic` never restarts.
    */
  def restartsOnLoss(req: Value): Boolean = req.at("policy") match {
    case VNull => true
    case p     => p != VStr("dynamic")
  }

  /** Does an unmet requirement keep the consumer out of `live`?
    *
    * Cardinality alone decides this, NOT policy. `dynamic` is a statement about
    * surviving a SWAP, not about starting without the thing at all - a
    * mandatory-dynamic consumer still waits in `pending` for its first
    * provider.
    */
  def gatesActivation(req: Value): Boolean = req.at("optional") != VBool(true)

  /** Edges that can cause a restart, which is exactly the set a cycle must be
    * detected over (section 11.3).
    *
    * ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
    * exclusion was for: two plugins that optionally and dynamically consume
    * each other's capabilities both activate happily, neither gates on the
    * other, and each is merely notified when the other appears. Nothing
    * restarts, so nothing oscillates. An earlier draft of section 11.3 excluded
    * EVERY optional edge and thereby admitted the non-terminating case it was
    * trying to permit.
    */
  def restartCausing(req: Value): Boolean = gatesActivation(req) || restartsOnLoss(req)

  /** A cycle through restart-causing requirements is `plugin_dependency_cycle`,
    * detected AT LOAD - before anything runs, because the failure it describes
    * is a non-terminating reconcile and the only safe time to report that is
    * before it starts.
    *
    * The graph is over capabilities, not refs: an edge runs from a consumer to
    * EVERY node that provides what it needs, because any of them could be the
    * one selected and a cycle through any is a cycle. A node also satisfies its
    * own name as a ref (section 11.1), which is why the ref is a provider of
    * itself here.
    */
  def dependencyCycle(nodes: List[GraphNode]): Option[List[String]] = {
    // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    // matched differently - a capability by its exact name, a ref through
    // the canonical spelling (section 4 rule 5) - and one map keyed by
    // both can only do one of them. Keyed by both and looked up raw, as
    // this was, a cycle spelled `a$`/`b$` found no providers and EVADED
    // the load-time check that exists to catch a non-terminating
    // reconcile.
    val bycap = mutable.Map[String, mutable.ListBuffer[String]]()
    val isref = nodes.map(_.ref).toSet
    nodes.foreach { n =>
      n.provides.foreach { cap =>
        bycap.getOrElseUpdate(cap, mutable.ListBuffer.empty) += n.ref
      }
    }

    val edges = nodes.map { n =>
      val out = n.requires
        .filter(restartCausing)
        .flatMap { req =>
          val reqname = req.at("name").asString.getOrElse("")
          val from = bycap.getOrElse(reqname, Nil).toList
          // A node satisfies its own name AS A REF (section 11.1),
          // canonically - exactly what `providersOf` does at runtime.
          // `canon` hands back a name no ref could have unchanged, and no
          // instance ref can equal one.
          val asref = Refs.canon(VStr(reqname))
          if (isref.contains(asref)) from :+ asref else from
        }
        .filter(_ != n.ref)
        .distinct
        .sorted
      n.ref -> out
    }.toMap

    // Iterative DFS with an explicit stack: twenty ports, and several of them
    // have no recursion budget worth relying on.
    val white = 0
    val grey = 1
    val black = 2
    val colour = mutable.Map[String, Int]()
    nodes.foreach(n => colour(n.ref) = white)

    // NO `return` OUT OF A LAMBDA. Scala 2 compiles one into a
    // `NonLocalReturnControl` thrown through the closure; scala 3 deprecates
    // that and points at `boundary`/`boundary.break`, which 2.11 has no port
    // of. A `found` cell that both loop conditions read is the one shape both
    // compilers take, and it leaves the walk at the same instant the `return`
    // did -- the DFS state is never observed again once it is set.
    var found: Option[List[String]] = None
    val starts = edges.keys.toList.sorted.iterator

    while (found.isEmpty && starts.hasNext) {
      val start = starts.next()
      if (colour(start) == white) {
        val path = mutable.ListBuffer[String](start)
        val stack = mutable.ArrayBuffer[(String, Int)]((start, 0))
        colour(start) = grey

        while (found.isEmpty && stack.nonEmpty) {
          val (node, cursor) = stack(stack.length - 1)
          val outs = edges(node)
          if (cursor >= outs.length) {
            colour(node) = black
            stack.remove(stack.length - 1)
            path.remove(path.length - 1)
          } else {
            val next = outs(cursor)
            stack(stack.length - 1) = (node, cursor + 1)
            if (colour(next) == grey) {
              // Report the cycle itself, not the walk that found it.
              found = Some(path.drop(path.indexOf(next)).toList :+ next)
            } else if (colour(next) != black) {
              colour(next) = grey
              path += next
              stack += ((next, 0))
            }
          }
        }
      }
    }
    found
  }

  /** Raise on a cycle, naming it. Separate from the detector so the detector
    * stays pure and corpus-testable.
    */
  def checkCycle(nodes: List[GraphNode]): Unit = dependencyCycle(nodes) match {
    case None => ()
    case Some(cycle) =>
      Types.fail(
        "plugin_dependency_cycle", "requirements cycle: " + cycle.mkString(" -> "),
        Map("cycle" -> VList(cycle.map(VStr.apply)))
      )
  }
}
