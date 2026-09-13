// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Order.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

import scala.collection.mutable

/** Ordering (section 7) - one rule, one place.
  *
  * sdkgen grew two special cases in `makeOptions` (`test`, then `station`) and
  * the third was not far off. This sort is the whole replacement, and the tiers
  * are in this order for a reason:
  *
  *   1 constraints   before/after edges, by ref or by name
  *   2 bands         integer, lower first, default 0
  *   3 declaration   ties break by `pos`
  *
  * CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
  * present. A band expresses a genuine cross-cutting layer; a constraint
  * expresses a relationship between two specific things; and a band chosen by
  * trial and error to fix an ordering bug is a bug wearing a number.
  */

/** One node of the sort. An internal shape, never a corpus value. */
final case class OrderNode(ref: String, pos: Int, order: Value)

object Order {

  def orderBand(b: OrderNode): Int = b.order.at("band").asInt.getOrElse(0)

  /** Was a constraint stated? An absent value and an EMPTY LIST are both
    * no-constraint - and an empty list is TRUTHY in most languages, which is
    * exactly how this class of bug survives a reading.
    */
  def orderDeclared(spec: Value): Boolean = spec match {
    case VNull    => false
    case VList(l) => l.exists(_ != VStr(""))
    case other    => other != VStr("")
  }

  /** One spelling or a LIST of them. A list fans out to the UNION of what each
    * names, so after: ['a','b'] means after BOTH, and the same instance named
    * twice - once by name, once by ref - is one edge.
    *
    * Matching is by REF, or by NAME across all of that definition's instances
    * (section 7) - which is the whole reason the two spellings exist.
    */
  def orderTargets(spec: Value, nodes: List[OrderNode]): List[String] = {
    val specs = spec match {
      case VList(l) => l
      case other    => List(other)
    }
    specs.flatMap { one =>
      nodes
        .filter(b => VStr(b.ref) == one || VStr(Refs.refName(VStr(b.ref))) == one)
        .map(_.ref)
    }.distinct
  }

  def resolveOrder(bindings: List[OrderNode], pin: Value = VNull): List[String] = {
    val byref = bindings.map(b => b.ref -> b).toMap

    // Constraints are edges. A constraint naming an ABSENT binding is satisfied
    // VACUOUSLY (section 7) - a plugin ordered `after: 'test'` must load in a
    // host with no test plugin. That is sdkgen's __after__ behaviour, kept.
    val edges = mutable.LinkedHashMap[String, mutable.ListBuffer[String]]()
    bindings.foreach(b => edges(b.ref) = mutable.ListBuffer.empty)

    bindings.foreach { b =>
      val block = b.order
      if (orderDeclared(block.at("after"))) {
        orderTargets(block.at("after"), bindings).foreach(t => edges(t) += b.ref)
      }
      if (orderDeclared(block.at("before"))) {
        edges(b.ref) ++= orderTargets(block.at("before"), bindings)
      }
    }

    val indeg = mutable.Map[String, Int]()
    bindings.foreach(b => indeg(b.ref) = 0)
    edges.values.foreach(_.foreach(to => indeg(to) = indeg(to) + 1))

    // Stable topological sort. Among ready nodes, band first (lower runs
    // first), then `pos` - the position the DOCUMENT visibly states, not the
    // order instances happened to load and not the incarnation `seq`.
    val out = mutable.ListBuffer[String]()
    var ready = bindings.filter(b => indeg(b.ref) == 0)

    while (ready.nonEmpty) {
      val sorted = Types.stableSortBy(ready)(b => List(KNum(orderBand(b)), KNum(b.pos)))
      val next = sorted.head
      var rest = sorted.tail
      out += next.ref
      edges(next.ref).foreach { to =>
        indeg(to) = indeg(to) - 1
        if (indeg(to) == 0) rest = rest :+ byref(to)
      }
      ready = rest
    }

    if (out.length != bindings.length) {
      val stuck = bindings.filterNot(b => out.contains(b.ref)).map(_.ref)
      Types.fail(
        "plugin_order_cycle",
        "before/after constraints cycle: " + stuck.mkString(" -> "),
        Map("cycle" -> VList(stuck.map(VStr.apply)))
      )
    }

    applyPin(out.toList, edges.map { case (k, v) => k -> v.toList }.toMap, pin)
  }

  /** A PIN IS NOT A CONSTRAINT (section 7).
    *
    * Constraints and bands are negotiable by definition - they are what plugins
    * and documents say they want, and the sort's job is to satisfy them all. A
    * pin is the host stating a structural invariant of its own architecture,
    * which is a different kind of claim and must not lose a tie to a document.
    *
    * So a pin PLACES the binding at the named end, and an ordering that would
    * move it away is `plugin_order_pinned` - rejected, not honoured into a
    * broken wrap.
    */
  def applyPin(order: List[String], edges: Map[String, List[String]], pin: Value)
      : List[String] = {
    if (pin.isNull) return order

    // SORTED, not insertion order. A pin map is data - it can arrive from a
    // host's own construction options in any order, and two names pinned to the
    // same end are order-sensitive (`{b:'first', a:'first'}` and
    // `{a:'first', b:'first'}` give different results). A scala `Map` past four
    // entries has no order at all, so leaving it unstated made the same
    // declaration mean different things in different ports.
    val out = pin.keys.foldLeft(order) { (acc, name) =>
      val want = pin.at(name).asString
      acc.indexWhere(ref => Refs.refName(VStr(ref)) == name) match {
        case -1 => acc
        case idx =>
          // `first`/`outermost` is index 0; `last`/`innermost` is the end.
          // Section 6.2 makes the first chain binding outermost, which is why
          // the vocabulary is positional and why the two spellings pair this
          // way.
          val ref = acc(idx)
          val rest = acc.patch(idx, Nil, 1)
          if (want.contains("first") || want.contains("outermost")) ref :: rest
          else rest :+ ref
      }
    }

    // Now check that the placement did not break a constraint. This is the half
    // that makes a pin a rejection rather than an override: the host wins on
    // position, but it does not get to silently discard a relationship a plugin
    // declared.
    val at = out.zipWithIndex.toMap
    edges.keys.toList.sorted.foreach { from =>
      edges(from).foreach { to =>
        if (at(from) > at(to)) {
          Types.fail(
            "plugin_order_pinned",
            "a pin would move a binding an ordering constrains: " +
              from + " must precede " + to,
            Map("before" -> VStr(from), "after" -> VStr(to))
          )
        }
      }
    }
    out
  }
}
