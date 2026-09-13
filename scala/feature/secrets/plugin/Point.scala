// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Point.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** Extension points (section 6). Three kinds, chosen because they are what the
  * two existing systems actually needed, and no more.
  *
  * A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes deactivation
  * possible: sdkgen's `utility.fetcher = wrapped` is not undoable, but "this
  * instance holds slot 3 of the request chain" is undoable in O(1). OSGi named
  * it the whiteboard pattern in 2004, in a paper called *Listeners Considered
  * Harmful*, and for exactly this reason.
  */

/** A live binding. An internal shape, never a corpus value.
  *
  * EVERY BINDING IS ARITY TWO, `(next, arg)`, hook and chain alike. `next` is
  * None for a hook. One signature means `Point` does not have to know which
  * kind of point it is holding - and the kind is the HOST's property, not the
  * binding's.
  */
final case class Binding(
    ref: String,
    point: String,
    fn: (Option[Value => Value], Value) => Value,
    band: Int
)

/** The winner and the losers on a provider point. */
final case class Picked(winner: Option[Binding], shadowed: List[String])

object Point {

  /** Section 6.1: "fan-out" is not one answer but four. In a language with
    * asynchrony, "call every binding" hides a decision - start them all and
    * wait, await each in turn, or do not wait - and a design that leaves it
    * unsaid gets four different answers from four ports, in the concurrency
    * behaviour of production code no corpus entry happens to cover.
    *
    * SCALA IS A PORT WHERE THAT IS LOUD: `Future` and an implicit
    * `ExecutionContext` are one import away, and using either for `emit` would
    * make every hook point a scheduling decision and every ordering assertion a
    * race. The host stays synchronous (section 5.2) and the modes stay data.
    */
  val modes = List("emit", "parallel", "serial", "bail")

  /** Fan-out. Return values are ignored except in `bail`. */
  def pointEmit(bindings: List[Binding], mode: String, arg: Value): Value = {
    if (mode == "bail") {
      // Stops at the first binding that RETURNS A VALUE - the "handled, stop"
      // case. A `VNull` RETURN DECLINES (section 6.1): scala has one way to say
      // nothing here, and the model's rule is written to that rather than to
      // JavaScript's null/undefined pair. `!isNull`, NOT truthiness - `false`
      // is a value.
      return bindings.view.map(b => b.fn(None, arg)).find(!_.isNull).getOrElse(VNull)
    }

    val errors = List.newBuilder[Value]
    bindings.foreach { b =>
      try b.fn(None, arg)
      catch {
        case e: Exception =>
          // `emit` raises synchronously; the collecting modes gather.
          if (mode == "emit") throw e
          errors += VStr(Types.messageOf(e))
      }
    }
    if (mode == "emit") VNull else VList(errors.result())
  }

  /** Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).
    *
    * Recomputed by the host whenever the live set changes, and cached between
    * changes. Plugins receive `next` as an argument; they never see or store
    * the previous value of anything. A plugin that stashes `next` and calls it
    * after deactivation is a bug the host cannot prevent, and this says so
    * rather than pretending otherwise.
    */
  def compose(bindings: List[Binding], base: Value => Value): Value => Value =
    // `foldRight` builds the chain outermost-LAST, so the fold runs from the
    // base outward and the FIRST binding ends up the outermost call. Each layer
    // closes over its own `inner`, which a `var` reused across iterations would
    // not.
    bindings.foldRight(base) { (b, inner) => (arg: Value) => b.fn(Some(inner), arg) }

  /** At most one live implementation (section 6.3). The winner is the highest
    * band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
    * silently ignored.
    */
  def pointProvider(bindings: List[Binding], spec: Value): Picked = {
    if (bindings.isEmpty) return Picked(None, Nil)

    if (spec.at("exclusive").truthy && bindings.length > 1) {
      val refs = bindings.map(_.ref).sorted
      Types.fail(
        "plugin_point_exclusive",
        "point is exclusive and has " + bindings.length + " bindings: " +
          refs.mkString(", "),
        Map("refs" -> VList(refs.map(VStr.apply)))
      )
    }

    val ranked = Types.stableSortBy(bindings)(b => List(KNum(-b.band), KText(b.ref)))
    Picked(Some(ranked.head), ranked.tail.map(_.ref))
  }
}
