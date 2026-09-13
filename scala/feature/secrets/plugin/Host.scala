// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Host.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

import scala.collection.mutable

/** The host: the lifecycle state machine (section 5), extension points
  * (section 6), and resource capture (section 8) - and the definition and
  * instance types the callbacks see.
  *
  * TWO RULES SHAPE EVERY METHOD BELOW.
  *
  * Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
  * never interleaved; a transition triggered from inside a lifecycle callback
  * is `plugin_reentrant`. A hard rule, because it is the only way the semantics
  * can be identical in Go, in Ruby and in single-threaded JavaScript.
  *
  * Reconciliation is EAGER (section 18's portability budget). A transition
  * settles by running the state machine to a fixed point, not by suspending on
  * a promise. NOTHING HERE RETURNS A `Future`, and that is the decision scala
  * most invites you to get wrong: a `Future`-returning transition would make
  * section 5.2's "one at a time, in call order" a claim about an
  * `ExecutionContext` rather than about the code.
  *
  * THE HOST AND ITS ENTRIES ARE MUTABLE, and nothing else in the port is. Every
  * value here is immutable and every `Value` is a case class; these two classes
  * are the state machine, and threading a rebuilt registry through every method
  * would make a callback's writes land in a copy nobody reads back.
  */

/** A plugin definition. A CASE CLASS WITH NAMED CALLBACKS, not a `Value` map:
  * scala cannot hold a function in the sealed JSON hierarchy, and pretending
  * otherwise would mean a `VOpaque` per callback and a cast at every call. The
  * shape every port has - a name, four lifecycle callbacks, `reconfigure` and
  * an option shape - is written in the type system rather than in a comment.
  */
final case class Definition(
    name: String,
    define: Option[Inst => Unit] = None,
    activate: Option[Inst => Unit] = None,
    deactivate: Option[Inst => Unit] = None,
    close: Option[Inst => Unit] = None,
    reconfigure: Option[(Inst, Value, Value) => Unit] = None,
    shape: Value = VNull
) {
  def callback(at: String): Option[Inst => Unit] = at match {
    case "define"     => define
    case "activate"   => activate
    case "deactivate" => deactivate
    case "close"      => close
    case _            => None
  }
}

/** One declared extension point. */
final case class PointSpec(
    kind: String = "hook",
    mode: String = "emit",
    base: Option[Value => Value] = None,
    pin: Value = VNull,
    exclusive: Boolean = false,
    dflt: Value = VNull
)

/** Host construction options. */
final case class HostOptions(
    catalog: Option[Catalog] = None,
    reserved: List[String] = Nil,
    points: Map[String, PointSpec] = Map.empty,
    dependency: String = "restart",
    keys: Value = VNull,
    defaults: Value = VNull,
    profile: Option[String] = None
)

/** The definition catalog (section 10.1).
  *
  * A definition is registered once and may back many instances. Option shapes
  * are validated AT REGISTRATION, not when a document happens to exercise a key
  * - so a malformed shape fails once, and in the same place everywhere
  * (section 9.4).
  *
  * MUTABLE, because the host and its caller share one catalog and the driver's
  * section 6.5 nest case adds to a live host's.
  */
final class Catalog {

  private val defs = mutable.Map[String, Definition]()

  def add(definition: Definition): Unit = {
    if (!Refs.checkName(VStr(definition.name))) {
      Types.fail("plugin_definition_name", "invalid definition name: " + definition.name)
    }
    // Validate the shape HERE. Deferring it to resolution time means a
    // malformed shape surfaces at a different moment in every host that loads
    // it, which is the divergence the stated domain exists to prevent.
    if (!definition.shape.isNull) Config.checkShape(definition.shape)
    defs(definition.name) = definition
  }

  def get(name: String): Option[Definition] = defs.get(name)

  def has(name: String): Boolean = defs.contains(name)

  def names: List[String] = defs.keys.toList.sorted
}

/** One registered instance. The INTERNAL record: a plugin sees `Inst`. */
final class Entry(
    val ref: String,
    val definition: Definition,
    var status: String,
    var pos: Int,
    val seq: Int,
    var options: Value,
    var order: Value
) {
  var state: Value = VMap(Map.empty)
  var unmet: List[String] = Nil
  val scope = mutable.ListBuffer[() => Unit]()

  /** Section 11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider ref
    * this instance's activation actually chose, per requirement name.
    * Re-ranking on every question silently re-points a live consumer at any
    * better newcomer, and then losing the provider it was really using does not
    * restart it.
    */
  var selected: Map[String, String] = Map.empty

  val bindings = mutable.ListBuffer[Binding]()
  var exports: Map[String, Value] = Map.empty
  val provides = mutable.ListBuffer[Value]()
  var inner: Option[Host] = None
  var barred: Boolean = false
}

/** What a definition's callbacks see. Deliberately not the internal record: a
  * plugin that could reach `status` could also write it.
  */
final class Inst(val host: Host, private val entry: Entry) {

  val ref: String = entry.ref
  val name: String = Refs.parseRef(VStr(entry.ref)).at("name").asString.getOrElse(entry.ref)
  val tag: String = Refs.parseRef(VStr(entry.ref)).at("tag").asString.getOrElse("")

  def options: Value = entry.options

  def state: Value = entry.state

  /** The state map is a VALUE, so a callback cannot mutate what it reads; this
    * is the write. Every other port spells it `i.state[k] = v` because its maps
    * are objects.
    */
  def statePut(key: String, value: Value): Unit = {
    entry.state = entry.state.setting(key, value)
  }

  /** Foreign resources the host did not hand out are registered explicitly
    * (section 8.3); host calls are recorded automatically.
    *
    * SYMMETRIC WITH `acquire`, and it has to be: `open` counts the resources
    * CURRENTLY HELD, so an entry that is registered and then unwound must leave
    * the count where it found it.
    */
  def release(fn: () => Unit): Unit = {
    // Section 8.3: "`inst.release` outside `activate` is
    // `plugin_release_scope`". `intransition` is true in `define` too, and a
    // scope entry registered there is never unwound.
    if (host.phase != Some("activate")) {
      Types.fail("plugin_release_scope", "release called outside activate")
    }
    var done = false
    entry.scope += (() => {
      if (!done) {
        done = true
        host.open -= 1
        fn()
      }
    })
    host.open += 1
  }

  /** The synthetic counter the driver owns, so "what is open" is data rather
    * than an assertion each port words differently.
    *
    * Returns its own release, so a plugin can hand one back early. The scope
    * still holds the entry and unwinding it twice is a no-op - releasing early
    * must not make teardown wrong.
    */
  def acquire(): () => Unit = {
    // Section 8.1: resources are "acquired during `activate` - the scope's
    // actual job". Same reason as `release` above.
    if (host.phase != Some("activate")) {
      Types.fail("plugin_release_scope", "acquire called outside activate")
    }
    var done = false
    val rel = () => {
      if (!done) {
        done = true
        host.open -= 1
      }
    }
    entry.scope += rel
    host.open += 1
    rel
  }

  /** Bind into a host point. Declared in `define`; the host inserts it only
    * after `activate` returns successfully (section 8.1), which is why a
    * failing activate leaves no live binding behind.
    *
    * Section 12 has carried `plugin_bind_scope` - "binding declared outside
    * `define`" - since before anything raised it, and it was the half nobody
    * wrote: a binding added from `activate` went live without being part of the
    * loaded definition, and a deactivate/activate cycle appended it again.
    */
  def bind(
      point: String,
      fn: (Option[Value => Value], Value) => Value,
      band: Value = VNull
  ): Unit = {
    if (host.phase != Some("define")) {
      Types.fail(
        "plugin_bind_scope", "bind called outside define: " + point,
        Map("ref" -> VStr(ref), "point" -> VStr(point))
      )
    }
    if (!host.hasPoint(point)) {
      Types.fail(
        "plugin_point_unknown", "no such point: " + point, Map("point" -> VStr(point))
      )
    }
    entry.bindings += Binding(ref, point, fn, band.asInt.getOrElse(0))
  }

  /** Published for other plugins and for the application (section 11).
    *
    * BACKTICKED BECAUSE `export` IS A HARD KEYWORD IN SCALA 3 -- it introduces
    * an export clause, so a bare `def export` is a SYNTAX error there, not a
    * deprecation. The name is the one every other port uses (section 11), so
    * the backticks buy parity with canonical rather than a scala-only alias.
    */
  def `export`(key: String, value: Value): Unit = {
    entry.exports = entry.exports + (key -> value)
  }

  /** What this instance can do for others (section 11.1). */
  def provides(prov: Value): Unit = { entry.provides += prov; () }

  /** Where this binding landed (section 6.6) - the plugin-side counterpart to a
    * host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact available.
    * Verification tells a plugin it was misplaced; a pin (section 7) stops the
    * misplacement from being expressible at all. The two are not substitutes.
    */
  def position(point: String): Value = host.positionOf(VStr(ref), point)

  /** AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE OWNS THE
    * INNER ONE'S LIFETIME. Registering the teardown in the instance scope is
    * what makes that true rather than aspirational.
    */
  def nest(nestopts: HostOptions = HostOptions()): Host = {
    if (!host.intransition) {
      Types.fail("plugin_release_scope", "nest called outside a lifecycle callback")
    }
    val innerHost = new Host(nestopts)
    // NOT counted: `open` must read the same before and after a nested host is
    // created.
    entry.scope += (() => innerHost.close())
    entry.inner = Some(innerHost)
    innerHost
  }
}

final class Host(opts: HostOptions = HostOptions()) {

  private val dependency = opts.dependency

  /** Set for the duration of a bulk teardown, so `held` knows this is a
    * coordinated operation rather than an ad-hoc deactivation.
    */
  private var coordinated = false

  val catalog: Catalog = opts.catalog.getOrElse(new Catalog)
  private val reserved = opts.reserved
  private val points = opts.points

  private val inst = mutable.Map[String, Entry]()
  private val log = mutable.ListBuffer[String]()

  /** Section 14: the lifecycle event record. `seq` distinguishes ONE INCARNATION
    * of stripe$test from the next, which is the whole reason it is not `pos`
    * (section 4 rule 4).
    */
  private val events = mutable.ListBuffer[Value]()
  private var seqn = 0
  var open = 0
  var intransition = false

  /** WHICH callback is running, not merely that one is. Section 8.1 puts
    * resource capture in `activate` and 8.3 says `release` outside `activate`
    * is `plugin_release_scope` - and `intransition` alone cannot tell
    * `activate` from `define`, so it admitted an acquire in `define` whose
    * scope `unload` would never unwind.
    */
  var phase: Option[String] = None

  def hasPoint(name: String): Boolean = points.contains(name)

  // --- observation -----------------------------------------------------

  /** Introspection NEVER advances the state (section 5.2). A status page must
    * not be a way to accidentally import twenty packages.
    */
  def list: Value = VMap(inst.map { case (ref, e) => ref -> VStr(e.status) }.toMap)

  def instance(ref: Value): Option[Entry] = inst.get(Refs.canonRef(ref))

  def trace: Value = VList(events.toList)

  def observable(result: Value = VNull): Value = Value.map(
    "status" -> list,
    "open" -> VNum(open.toDouble),
    "log" -> VList(log.toList.map(VStr.apply)),
    "result" -> result
  )

  private def refs: List[String] = inst.keys.toList.sorted

  // --- the state machine -------------------------------------------------

  private def guardTransition(): Unit = {
    if (intransition) {
      Types.fail(
        "plugin_reentrant", "transition attempted from inside a lifecycle callback"
      )
    }
  }

  private def need(ref: Value): Entry = {
    val rf = Refs.canonRef(ref)
    inst.getOrElse(rf, Types.fail(
      "plugin_not_loaded", "no such instance: " + rf, Map("ref" -> VStr(rf))
    ))
  }

  private def checkReserved(ref: String): Unit = {
    if (reserved.contains(Refs.refName(VStr(ref)))) {
      Types.fail(
        "plugin_ref_reserved", "ref is reserved by the host: " + ref,
        Map("ref" -> VStr(ref))
      )
    }
  }

  private def run(entry: Entry, callback: String, at: String): Unit = {
    val fn = entry.definition.callback(callback)
    log += (entry.ref + ":" + at)
    events += Value.map(
      "ref" -> VStr(entry.ref), "event" -> VStr(at),
      "seq" -> VNum(entry.seq.toDouble), "status" -> VStr(entry.status)
    )
    fn.foreach { f =>
      intransition = true
      phase = Some(at)
      try {
        f(new Inst(this, entry))
      } catch {
        case e: Exception =>
          // Section 12: `plugin_define_failed` and its three siblings are "a
          // callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A
          // CODE KEEPS IT - the code is the error's identity, and a plugin
          // raising `store_unreachable` must not have it rewritten. Only a
          // code-less error is wrapped.
          if (Types.codeOf(e) != "") throw e
          Types.fail(
            "plugin_" + at + "_failed",
            entry.ref + " raised in " + at + ": " + Types.messageOf(e),
            Map("ref" -> VStr(entry.ref), "cause" -> VStr(Types.messageOf(e)))
          )
      } finally {
        intransition = false
        phase = None
      }
    }
  }

  /** AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare("stripe", tag "?")`
    * assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the assigned
    * pair. Without `"?"`, a collision is an error.
    */
  private def autotag(name: String): String =
    // `Iterator.from`, NOT `Stream.from`: `Stream` is deprecated from 2.13 in
    // favour of `LazyList`, and `LazyList` does not exist before it. `Iterator`
    // is in every version, is deprecated in none, and is lazy enough -- `find`
    // stops at the first free tag either way.
    Iterator.from(1).map(n => Refs.formatRef(VStr(name), VStr(n.toString)))
      .find(cand => !inst.contains(cand)).get

  def declare(ref: Value, spec: Value = VMap(Map.empty)): Entry = {
    val target =
      if (spec.at("tag") == VStr("?")) VStr(autotag(Refs.refName(VStr(Refs.canon(ref)))))
      else ref
    val rf = Refs.canonRef(target)
    if (!spec.at("hostowned").truthy) checkReserved(rf)

    val defname = spec.at("definition").asString.getOrElse(Refs.refName(VStr(rf)))
    val definition = catalog.get(defname).getOrElse(Types.fail(
      "plugin_unknown_definition", "not in catalog: " + defname,
      Map("name" -> VStr(defname))
    ))

    inst.get(rf) match {
      // Section 4 rule 1: a pair addresses at most one instance. Re-declaring
      // the SAME definition is the idempotent case; a different one is a
      // duplicate, not a silent overwrite (seneca) and not an impossibility
      // (sdkgen).
      case Some(existing) if existing.definition.name != definition.name =>
        Types.fail(
          "plugin_ref_duplicate", "instance already declared: " + rf,
          Map("ref" -> VStr(rf))
        )
      case Some(existing) => existing
      case None =>
        val entry = new Entry(
          rf, definition, "declared",
          spec.at("pos").asInt.getOrElse(inst.size), seqn,
          // PRESENT AND NOT NULL, not merely present. Every port's driver builds
          // its spec with all four keys and a null for each absent one, so
          // testing presence would read an omitted `options` as an authored
          // empty.
          if (spec.at("options").isNull) VMap(Map.empty) else spec.at("options"),
          spec.at("order")
        )
        seqn += 1
        inst(rf) = entry
        entry
    }
  }

  /** Section 9.1: a host that reserves a name MUST still be able to declare the
    * instance it reserved - "The host declares those instances itself, after
    * the user merge, and always wins."
    *
    * THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit: no
    * language here can tell the embedding host from a plugin holding the same
    * host object. What reservation protects is CONFIGURATION - documents,
    * overlays, `VOXGIG_PLUGIN_*`, construction options and ordinary
    * declare/load/options - and all of that still checks.
    */
  def hostdeclare(ref: Value, spec: Value = VMap(Map.empty)): Entry = {
    guardTransition()
    declare(ref, spec.setting("hostowned", VBool(true)))
  }

  def load(ref: Value, spec: Value = VMap(Map.empty)): Entry = {
    guardTransition()
    val entry = declare(ref, spec)
    if (entry.status != "declared") return entry // idempotent trivially

    if (!spec.at("options").isNull) entry.options = spec.at("options")
    try run(entry, "define", "define")
    catch { case e: Exception => entry.status = "failed"; throw e }
    entry.status = "loaded"

    // AT LOAD, and before anything runs: a cycle through restart-causing
    // requirements does not settle, and the only safe time to report a
    // non-terminating reconcile is before it starts (section 11.3). `provides`
    // is populated by `define`, which has just run, so this is the first moment
    // the graph is complete.
    try Depend.checkCycle(graphNodes)
    catch { case e: Exception => entry.status = "failed"; throw e }
    entry
  }

  /** The requirement graph as plain data, for the pure detector. */
  private def graphNodes: List[GraphNode] = refs.map { rf =>
    GraphNode(
      rf,
      inst(rf).provides.toList.map(_.at("name").asString.getOrElse("")),
      Depend.requirements(inst(rf).options)
    )
  }

  def activate(ref: Value): Entry = {
    guardTransition()
    val entry = need(ref)
    if (entry.status == "live") return entry // no-op returning success

    if (entry.status == "failed") {
      Types.fail(
        "plugin_bad_state", "instance has failed: " + entry.ref,
        Map("ref" -> VStr(entry.ref))
      )
    }
    // Section 9.6: `active: false` bars the instance from running, and the bar
    // is on the INSTANCE rather than on the apply that set it. `ready` reaches
    // this through `activate`, so one guard covers both verbs the design names.
    if (entry.barred) {
      Types.fail(
        "plugin_inactive", "instance is barred by active: false: " + entry.ref,
        Map("ref" -> VStr(entry.ref))
      )
    }
    if (entry.status == "declared") load(VStr(entry.ref))

    // A declared requirement that is not live means `pending`: activation is a
    // STANDING REQUEST, not a one-shot event.
    val unmet = unmetOf(entry)
    if (unmet.nonEmpty) {
      entry.unmet = unmet
      entry.status = "pending"
      return entry
    }

    try run(entry, "activate", "activate")
    catch {
      case e: Exception =>
        // Unwind whatever the partial activation captured, in reverse.
        unwind(entry)
        entry.status = "failed"
        throw e
    }
    // Section 11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
    // later question - the cascade, `hold`, `unmet` - reads it back rather than
    // re-ranking, which is what "always-reluctant" means.
    Depend.requirements(entry.options).foreach(req => chosen(entry, req, remember = true))
    entry.status = "live"
    reconcile()
    entry
  }

  def deactivate(ref: Value): Entry = {
    guardTransition()
    val entry = need(ref)
    if (entry.status == "loaded" || entry.status == "declared") return entry

    // Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
    if (entry.status == "failed") {
      Types.fail(
        "plugin_bad_state", "instance has failed: " + entry.ref,
        Map("ref" -> VStr(entry.ref))
      )
    }

    if (entry.status == "pending") {
      // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2). It
      // never reached activate, so it holds no scope and no live bindings;
      // running the definition's deactivate there would be teardown without
      // matching setup, which plugins are not written to survive and which
      // could fail an instance that had done nothing wrong. It cannot fail.
      entry.status = "loaded"
      entry.unmet = Nil
      return entry
    }

    held(entry)
    cascade(entry, Set.empty)
    teardown(entry)
    entry.status = "loaded"
    reconcile()
    entry
  }

  /** The live half of leaving `live`: the callback, then the scope. */
  private def teardown(entry: Entry): Unit = {
    try run(entry, "deactivate", "deactivate")
    catch {
      case e: Exception =>
        unwind(entry)
        entry.status = "failed"
        throw e
    }
    releaseCheck(entry, unwind(entry))
  }

  def unload(ref: Value): Unit = {
    guardTransition()
    val entry = need(ref)
    if (entry.status == "live" || entry.status == "pending") {
      // Section 5.2: ANY failure during a transition lands the instance in
      // `failed`, with the scope STILL FULLY UNWOUND - and the instance STAYS
      // REGISTERED, because `failed` is a state an operator has to be able to
      // see.
      if (entry.status == "live") {
        held(entry)
        cascade(entry, Set.empty)
        teardown(entry)
      }
      entry.status = "loaded"
    }
    if (entry.status == "loaded" || entry.status == "failed") {
      try run(entry, "close", "close")
      finally inst.remove(entry.ref)
    } else {
      inst.remove(entry.ref)
    }
  }

  /** Runs the whole forward path in one call (section 5.1). */
  def ready(ref: Value): Entry = {
    guardTransition()
    val rf = Refs.canonRef(ref)
    if (!inst.contains(rf)) declare(VStr(rf))
    if (inst(rf).status == "declared") load(VStr(rf))
    activate(VStr(rf))
  }

  /** Bindings go live only when activation succeeds (section 8.1), so the
    * teardown is the exact inverse: reverse order, always.
    *
    * Returns the errors the scope raised. Section 8.3: "A failing release does
    * not stop the rest. Every entry runs, in reverse order, whatever any of
    * them does; the errors are collected and raised as one
    * `plugin_release_failed`."
    *
    * A selection belongs to ONE activation (section 11.4). Leaving `live` by
    * any door drops it, so the next activation ranks afresh - keeping it would
    * make a consumer prefer a provider it never actually ran against.
    */
  private def unwind(entry: Entry): List[Throwable] = {
    entry.selected = Map.empty
    val errors = mutable.ListBuffer[Throwable]()
    entry.scope.reverse.foreach { fn =>
      try fn()
      catch { case e: Exception => errors += e }
    }
    entry.scope.clear()
    errors.toList
  }

  /** Section 8.3: "A failed release ends the instance in `failed`, exactly as a
    * failed callback does (5.2) - a release that raised may have leaked, and an
    * instance that may be holding resources it cannot account for must not be
    * reactivated."
    */
  private def releaseCheck(entry: Entry, errors: List[Throwable]): Unit = {
    if (errors.isEmpty) return
    entry.status = "failed"
    val causes = errors.map(Types.messageOf)
    Types.fail(
      "plugin_release_failed",
      "release failed for " + entry.ref + ": " + causes.mkString("; "),
      Map("ref" -> VStr(entry.ref), "cause" -> VList(causes.map(VStr.apply)))
    )
  }

  /** A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A bare
    * string is shorthand for `{name}`. A ref satisfies too, because a host that
    * genuinely needs a specific instance should not have to invent a capability
    * for it.
    */
  private def unmetOf(entry: Entry): List[String] =
    Depend.requirements(entry.options)
      .filter(Depend.gatesActivation)
      .filter(req => providersOf(req).isEmpty)
      .map(_.at("name").asString.getOrElse(""))

  /** Section 11.4's always-reluctant selection, and the ONE place a provider is
    * picked for a live instance. If this instance already selected a provider
    * for `req` and that provider is STILL a candidate, it keeps it - a
    * better-ranked newcomer does not take it.
    *
    * `remember` is false for the questions asked ABOUT an instance rather than
    * BY it: introspection must not create a binding.
    */
  private def chosen(entry: Entry, req: Value, remember: Boolean): Option[String] = {
    val cands = providersOf(req)
    if (cands.isEmpty) return None
    val name = req.at("name").asString.getOrElse("")
    entry.selected.get(name) match {
      case Some(held) if cands.exists(_.at("ref").asString.contains(held)) => Some(held)
      case _ =>
        val pick = cands.head.at("ref").asString.getOrElse("")
        if (remember) entry.selected = entry.selected + (name -> pick)
        Some(pick)
    }
  }

  /** The instances currently SELECTED for this one's restart-causing
    * requirements. A BINDING IS TO AN INSTANCE, not to a capability (section
    * 11.1): the selected one going away restarts a `static` consumer even
    * though a survivor is available.
    */
  private def boundProviders(entry: Entry): List[String] =
    Depend.requirements(entry.options)
      .filter(Depend.restartsOnLoss)
      .flatMap(req => chosen(entry, req, remember = false))
      .distinct

  /** Live instances whose selected provider is `ref` and which would be
    * restarted by losing it.
    */
  private def consumersOf(ref: String): List[String] = refs.filter { rf =>
    rf != ref && inst(rf).status == "live" && boundProviders(inst(rf)).contains(ref)
  }

  /** Section 11.3's `hold` asks a DIFFERENT question from the cascade, and
    * reading it off `consumersOf` answered the cascade's.
    *
    * The cascade wants the edges that RESTART - mandatory-static and
    * optional-static - because a restart is what it performs. `hold` says
    * "deactivating a REQUIRED instance is `plugin_dependency_held`", and
    * required is cardinality: `gatesActivation`, not `restartsOnLoss`. The two
    * sets differ in both directions and each difference was a real bug.
    *
    * A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy let a
    * provider go that a live consumer could not do without - `dynamic` promises
    * survival of a SWAP, and under `hold` there is no swap, so the consumer
    * falls back to `pending`.
    *
    * An OPTIONAL-STATIC consumer was included, so `hold` refused a deactivation
    * on behalf of an instance that had said in writing it does not need the
    * thing.
    */
  private def holdersOf(ref: String): List[String] = refs.filter { rf =>
    val c = inst(rf)
    rf != ref && c.status == "live" && Depend.requirements(c.options).exists { req =>
      Depend.gatesActivation(req) && chosen(c, req, remember = false).contains(ref)
    }
  }

  private def providersOf(req: Value): List[Value] = {
    val name = req.at("name")
    val want = Refs.canon(name)
    val cands = refs.flatMap { ref =>
      val target = inst(ref)
      if (target.status != "live") {
        Nil
      } else if (ref == want) {
        // A ref satisfies directly.
        List(Value.map(
          "ref" -> VStr(ref), "pos" -> VNum(target.pos.toDouble),
          "provides" -> Value.map("name" -> name)
        ))
      } else {
        target.provides.toList.filter(_.at("name") == name).map(prov => Value.map(
          "ref" -> VStr(ref), "pos" -> VNum(target.pos.toDouble), "provides" -> prov
        ))
      }
    }
    Capability.resolveCapability(req, VList(cands))
  }

  /** CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
    *
    * The cascade is part of the provider's own deactivation and runs BEFORE the
    * provider's `deactivate` callback and scope unwind, so a consumer's
    * teardown can still call the thing it depends on - flushing a buffer to the
    * store it is about to lose is exactly what a `deactivate` callback is for,
    * and a cascade that fired after the provider was already gone would make
    * that impossible.
    */
  private def cascade(provider: Entry, seenIn: Set[String]): Unit = {
    if (seenIn.contains(provider.ref)) return
    val seen = seenIn + provider.ref

    consumersOf(provider.ref).foreach { rf =>
      val consumer = inst(rf)
      if (consumer.status == "live") {
        cascade(consumer, seen) // deepest-first
        demote(consumer)
      }
    }
  }

  /** Leaving `live` for `pending` - or for `failed`, because section 5.2 says
    * ANY failure during a transition lands the instance there. Marking it
    * `pending` handed it straight back to `reconcile`, which would activate it
    * again the moment the provider returned.
    */
  private def demote(entry: Entry): Unit = {
    var bad = false
    try run(entry, "deactivate", "deactivate")
    catch { case _: Exception => bad = true }
    val errors = unwind(entry)
    if (bad || errors.nonEmpty) {
      entry.status = "failed"
    } else {
      entry.status = "pending"
      entry.unmet = unmetOf(entry)
    }
  }

  /** The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
    * TEARDOWN. In a bulk operation that is removing the holders too - `close`,
    * or an `apply` plan whose own steps deactivate them - it is suspended for
    * exactly those holders, and the teardown still runs consumers before
    * providers.
    */
  private def held(entry: Entry): Unit = {
    if (dependency != "hold" || coordinated) return
    val holders = holdersOf(entry.ref)
    if (holders.isEmpty) return
    Types.fail(
      "plugin_dependency_held",
      "instance is required by live consumers: " + entry.ref,
      Map("ref" -> VStr(entry.ref), "holders" -> VList(holders.map(VStr.apply)))
    )
  }

  /** EAGER reconciliation: run to a fixed point rather than scheduling.
    *
    * Two directions, and both are the reason `pending` exists. Activation is a
    * STANDING REQUEST, not a one-shot event.
    */
  private def reconcile(): Unit = {
    var moved = true
    var rounds = 0
    while (moved && rounds <= 1000) {
      moved = false
      rounds += 1

      // Losses first, so a cascade settles in one pass rather than alternating
      // with re-activations.
      refs.foreach { rf =>
        inst.get(rf).filter(_.status == "live").foreach { entry =>
          // POLICY IS PER REQUIREMENT, not per instance (section 11.3). A
          // `dynamic` requirement whose provider is gone leaves the consumer
          // LIVE and notified.
          val lost = Depend.requirements(entry.options)
            .filter(Depend.gatesActivation)
            .filter(q => providersOf(q).isEmpty)
          if (lost.nonEmpty && lost.exists(Depend.restartsOnLoss)) {
            demote(entry)
            moved = true
          }
        }
      }

      refs.foreach { rf =>
        inst.get(rf).filter(_.status == "pending").foreach { entry =>
          if (unmetOf(entry).isEmpty) {
            try {
              run(entry, "activate", "activate")
              entry.status = "live"
              entry.unmet = Nil
            } catch {
              case _: Exception =>
                unwind(entry)
                entry.status = "failed"
            }
            moved = true
          }
        }
      }
    }
  }

  // --- ordering ----------------------------------------------------------

  def order(point: Option[String] = None): List[String] = {
    // Sorted by declaration SEQUENCE, which is what makes the section 7 sort's
    // fall-through deterministic in a language whose maps have no order at all.
    // Section 7 breaks ties by `pos`; two instances CAN share one - `declare`
    // defaults `pos` to the registry size, so an unload followed by a fresh
    // declare reuses a surviving instance's - and past that this was falling
    // through to map order. `seq` is that order, made explicit.
    val bindings = refs.filter(rf => inst(rf).status == "live")
      .sortBy(rf => inst(rf).seq)
      .map(rf => OrderNode(rf, inst(rf).pos, inst(rf).order))
    val pin = point.flatMap(points.get).map(_.pin).getOrElse(VNull)
    Order.resolveOrder(bindings, pin)
  }

  // --- points ------------------------------------------------------------

  /** Live bindings on a point, in resolved order. Recomputed on any change to
    * the live set (section 7) rather than cached at startup - the bug a host
    * discovers only when something deactivates in production.
    */
  private def bound(point: String): List[Binding] =
    order(Some(point)).flatMap { ref =>
      val entry = inst(ref)
      // The band is the INSTANCE's ordering block (section 7), stamped by the
      // host. A plugin passing its own would be ranking itself above the order
      // its document declared.
      val band = entry.order.at("band").asInt.getOrElse(0)
      entry.bindings.toList.filter(_.point == point).map(_.copy(band = band))
    }

  private def pointSpec(point: String, want: String): PointSpec = {
    val spec = points.getOrElse(point, Types.fail(
      "plugin_point_unknown", "no such point: " + point, Map("point" -> VStr(point))
    ))
    if (spec.kind != want) {
      Types.fail(
        "plugin_point_kind", "point is not a " + want + ": " + point,
        Map("point" -> VStr(point), "kind" -> VStr(spec.kind))
      )
    }
    spec
  }

  def emit(point: String, arg: Value = VNull): Value =
    Point.pointEmit(bound(point), pointSpec(point, "hook").mode, arg)

  def call(point: String, arg: Value = VNull): Value = {
    val spec = pointSpec(point, "chain")
    Point.compose(bound(point), spec.base.getOrElse((a: Value) => a))(arg)
  }

  def provider(point: String, arg: Value = VNull): Value = {
    val spec = pointSpec(point, "provider")
    val pick = Point.pointProvider(
      bound(point), Value.map("exclusive" -> VBool(spec.exclusive))
    )
    pick.winner match {
      case None    => spec.dflt
      case Some(w) => w.fn(None, arg)
    }
  }

  /** The losers are VISIBLE rather than silently ignored (section 6.3). */
  def shadowed(point: String): List[String] = points.get(point) match {
    case None => Nil
    case Some(spec) =>
      Point.pointProvider(
        bound(point), Value.map("exclusive" -> VBool(spec.exclusive))
      ).shadowed
  }

  def exports(spec: String): Value = {
    val all = refs.flatMap { ref =>
      val entry = inst(ref)
      // Exports of a `loaded` (not live) instance are VISIBLE (11).
      if (entry.status == "declared" || entry.status == "failed") {
        Nil
      } else {
        entry.exports.keys.toList.sorted
          .map(k => Export.Exported(ref, k, entry.exports(k)))
      }
    }
    Export.resolveExport(spec, all)
  }

  /** The live providers of a capability, best-first (section 11.1). */
  def capability(name: String): List[String] = {
    val cands = refs.flatMap { ref =>
      val entry = inst(ref)
      if (entry.status != "live") {
        Nil
      } else {
        entry.provides.toList.filter(_.at("name").asString.contains(name))
          .map(prov => Value.map(
            "ref" -> VStr(ref), "pos" -> VNum(entry.pos.toDouble), "provides" -> prov
          ))
      }
    }
    Capability.resolveCapability(Value.map("name" -> VStr(name)), VList(cands))
      .map(_.at("ref").asString.getOrElse(""))
  }

  // --- documents ---------------------------------------------------------

  private def shapeOf(ref: String): Value =
    catalog.get(Refs.refName(VStr(ref))).map(_.shape).getOrElse(VNull)

  /** Section 9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
    * changed, and move activation state to match", with the stated ordering -
    * "deactivations and unloads first (reverse load order), then loads, then
    * activations in load order".
    *
    * FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
    * document once, which never looked at instances the new document had
    * DROPPED - so an integration removed from a config reload stayed live with
    * its bindings and resources.
    */
  def apply(doc: Value, profile: Option[String] = None): Unit = {
    guardTransition()
    val useProfile = profile.orElse(opts.profile)
    val norm = Config.normalizeConfig(Value.map(
      "doc" -> doc,
      "profile" -> useProfile.map(VStr.apply).getOrElse(VNull),
      "keys" -> opts.keys,
      "reserved" -> VList(reserved.map(VStr.apply))
    ))

    val want = norm.at("order").items.map(_.asString.getOrElse(""))
    val optionsof = want.map { ref =>
      ref -> Config.resolveOptions(Value.map(
        "ref" -> VStr(ref), "doc" -> doc,
        "profile" -> useProfile.map(VStr.apply).getOrElse(VNull),
        "shape" -> shapeOf(ref),
        "hostdefaults" -> opts.defaults.at(Refs.refName(VStr(ref)))
      ))
    }.toMap

    // Should this ref be LIVE after the apply? False for a ref the document
    // declares lazy or inactive AND for one it does not name at all - which is
    // what makes "unload what is gone" and "unload what was toggled off" one
    // rule rather than two.
    def wantlive(ref: String): Boolean = norm.at("instance").get(ref) match {
      case None      => false
      case Some(ent) => ent.at("active").truthy && ent.at("start") == VStr("eager")
    }

    // --- phase 1: deactivations and unloads, REVERSE load order -----------
    // Highest `pos` first, ref-descending for a tie, so a consumer declared
    // after its provider goes down first.
    refs.filter(rf => inst(rf).status != "declared" && !wantlive(rf))
      .sortWith { (a, b) =>
        val pa = inst(a).pos
        val pb = inst(b).pos
        if (pa == pb) a > b else pa > pb
      }
      .foreach(ref => unload(VStr(ref)))

    // --- phase 2: declare and patch EVERYTHING, in load order -------------
    want.foreach { ref =>
      val ent = norm.at("instance").at(ref)
      declare(VStr(ref), Value.map(
        "options" -> optionsof(ref), "order" -> ent.at("order"), "pos" -> ent.at("pos")
      ))
      val entry = inst(ref)
      // The bar is REASSERTED ON EVERY APPLY, in both directions - a document
      // that turns the instance back on clears it, which is the whole point of
      // a config switch.
      entry.barred = !ent.at("active").truthy
      entry.options = optionsof(ref)
      entry.order = ent.at("order")
      entry.pos = ent.at("pos").asInt.getOrElse(0)
    }

    // --- phase 3: loads, in load order ------------------------------------
    // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances is
    // twenty map entries and no executed code" (9.6).
    want.filter(wantlive).foreach(ref => load(VStr(ref)))

    // --- phase 4: activations, in load order ------------------------------
    want.filter(wantlive).foreach(ref => activate(VStr(ref)))
  }

  def options(ref: Value, patch: Value): Unit = {
    guardTransition()
    val entry = need(ref)
    val previous = entry.options
    val merged = patch.keys.foldLeft(previous.entries)((acc, k) => acc + (k -> patch.at(k)))

    val resolved = Config.resolveOptions(Value.map(
      "ref" -> VStr(entry.ref), "shape" -> shapeOf(entry.ref),
      "doc" -> VMap(Map.empty), "patch" -> VMap(merged)
    ))
    entry.options = resolved
    if (entry.status != "live") return

    entry.definition.reconfigure match {
      case Some(fn) =>
        intransition = true
        try fn(new Inst(this, entry), resolved, previous)
        finally intransition = false
      case None =>
        // Always correct and sometimes expensive; `reconfigure` exists to make
        // the common case cheap (section 9.4).
        deactivate(VStr(entry.ref))
        activate(VStr(entry.ref))
    }
  }

  def close(): Unit = {
    // A bulk teardown removing the holders too, so `hold` is suspended for
    // exactly those holders (section 11.3) - while the consumers-first cascade
    // still runs, which is the half that matters.
    coordinated = true
    try refs.reverse.foreach(rf => unload(VStr(rf)))
    finally coordinated = false
  }

  /** The same record section 6.6 gives a plugin about itself, reachable from
    * outside for the corpus.
    */
  def positionOf(ref: Value, point: String): Value = {
    val entry = inst.getOrElse(Refs.canon(ref), Types.fail(
      "plugin_not_loaded", "no such instance: " + Refs.show(ref), Map("ref" -> ref)
    ))
    val ranked = order(Some(point))
    val index = ranked.indexOf(entry.ref)
    Value.map(
      "index" -> VNum(index.toDouble),
      "count" -> VNum(ranked.length.toDouble),
      // Section 6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST,
      // so these are not index 0 and index count-1 the other way round.
      "outermost" -> VBool(index == 0),
      "innermost" -> VBool(index == ranked.length - 1)
    )
  }

  def define(definition: Definition): Unit = catalog.add(definition)
}
