// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (voxgig.omni.Runner.makeRunner / RunPack.runsetflagsargs), presented to
// the corpus drivers in the shape they already use (run.spec, run.set,
// run.runset, run.runsetargs, run.compare). No compatibility shim is
// vendored: the adapter below IS the whole bridge, per language, per the
// vendor-tag rollout (docs/design/vendor-tag-rollout.md, Decision 4).
//
// It supersedes, IN PLACE, the hand-written corpus ENGINE that used to live
// fused inside sdktest/StructCorpus.scala (`object Runner`'s jsonRead,
// fixJson, eqv, matchval, doMatch, resolveArgs, checkResult, handleError and
// runSet). Both corpus drivers keep their file names — StructCorpus.scala
// and PrimaryCorpus.scala — so no emitted call site moved and there is no
// orphan file for `doctor prune` to delete. It is the Scala peer of
// tm/java/test/OmniResolver.java, tm/rust/tests/omni_resolver/mod.rs and
// tm/swift/Tests/UnivecSDKTests/OmniResolver.swift.
//
// Lives in the DEFAULT package alongside SdkTestMain / Runner /
// SdkTestSupport, which is where scala-cli's generated test mains live.
//
// Scala-specific decisions, each load-bearing:
//
// 1. TWO VALUE MODELS, ONE CONVERSION PAIR. omni's `Json` is a closed,
//    IMMUTABLE enum (ListMap-backed); this SDK's struct port uses a MUTABLE
//    `Value` ADT (ArrayBuffer / LinkedHashMap). Every crossing is an explicit
//    `tostruct` / `toomni`. `Json.Absent` <-> `Noval` and `Json.Null` <->
//    `VNull` keep apart the two no-value states the corpus distinguishes —
//    which is also why Scala needs neither go's `novalargs` spec rewrite nor
//    lua/php's compat shim for the corpus's ZERO-ARGUMENT entries: an entry
//    with no `in`/`args`/`ctx` arrives from omni as one `Json.Absent`
//    argument and becomes exactly this port's own `Noval`, which is what the
//    retired hand-written `resolveArgs` produced for the same entry.
//
// 2. ARGUMENTS ARE WRITTEN BACK. `SubjectArgs` (List[Json] => (List[Json],
//    Json)) is the channel omni provides for a subject that MUTATES its
//    arguments, which `match: {args: ...}` then asserts on —
//    `struct/minor/setpath` (7 entries) and `struct/merge/integrity` (6) turn
//    on it. Decision 1 handed the subject a CONVERTED COPY, so EVERY subject
//    here runs through `runsetflagsargs` and the wrapper converts the
//    (possibly mutated) `Value` arguments back into omni's own list after the
//    call. A dynamic port's shim gets this free from shared object identity;
//    Scala cannot, because omni's Json has no mutable variant.
//
// 3. `match: {ctx: ...}` IS RETARGETED ONTO `match: {args: {"0": ...}}`.
//    The one place this port cannot follow canonical omni as written, and a
//    VALUE-SEMANTICS consequence, not a choice. omni's `resolveargs` stores
//    `entry.ctx` and `args[0]` as two COPIES of the contextified map, and
//    `checkresult` reads `entry.get("ctx")` for the ctx base — so a subject's
//    post-call writes (decision 2) can never reach the copy `entry.ctx`
//    holds, and eight `primary` entries assert exactly that post-call state.
//    args[0] IS the ctx of a ctx entry (omni itself sets
//    `args = List(entry.get("ctx"))`), so moving the assertion from `ctx` to
//    `args.0` reads the SAME map, post-call, and preserves every leaf:
//    nothing is dropped, weakened or skipped. `retargetctx` below does that
//    rewrite on the spec handed to the engine. Rust and Swift face the
//    identical problem and answer it identically; the upstream fix is for the
//    port's `drive` to re-point `entry.ctx` at the returned `args[0]`, the way
//    JS object identity does implicitly — a follow-up, not a hand-edit of a
//    vendored file.
//
// 4. NUMBERS NEED NOTHING HERE. omni's parser reads every JSON number as
//    Double and this port's `VNum` is also Double. The PRIMARY corpus still
//    narrows an integral Double to a java.lang.Long on its own Java bridge
//    (PrimaryCorpus.toJava) — that is a struct-to-SDK concern, not an
//    omni-to-struct one, and it stays where it was.
//
// 5. KEY ORDER SURVIVES. omni's Scala port models a map as an insertion-
//    ordered `ListMap`, and this port's `VMap` is a `LinkedHashMap`, so the
//    round trip preserves author order. (The Rust port needed a sortedness
//    tripwire because its omni maps are `BTreeMap`; Scala needs none.)
//
// 6. FAILURES ARE ACCUMULATED, NOT RAISED. omni stops a GROUP at its first
//    bad entry and throws an `OmniError`; the corpus mains report the whole
//    corpus in one banner at the end and exit non-zero. `drive` records the
//    message and carries on, so one run still names every broken group.
//
// 7. ABSENCE HAS TWO KINDS, AND ONLY ONE OF THEM IS BENIGN. Every group is
//    looked up as an `OmniGroup`, which keeps the PARENT node beside the
//    group, because the parent is what tells them apart:
//
//      * the whole SECTION is missing — a project corpus that predates it.
//        Fleet-wide this is real and load-bearing: `struct.nullsem` is absent
//        from every project corpus checked (399 of 399), so failing on it
//        would turn the fleet red for a corpus-version skew nobody caused.
//        SKIPPED, and NAMED in the banner.
//
//      * the section IS carried and the GROUP is gone. Nothing legitimate
//        does that: across 691 project corpora, every group these drivers ask
//        for is present and non-empty whenever its section is. It is a corpus
//        regression, so it FAILS. It used to be a skip, and for the four
//        single-node groups `compare` drives it was not even that — `compare`
//        had no guard at all, so deleting `struct/merge/basic`,
//        `struct/inject/basic` or `struct/transform/basic` left a run
//        BIT-IDENTICAL to a healthy one (`PASS 1216  FAIL 0`, exit 0): the
//        absent node became `Noval` on both sides, `fixjson` rendered both as
//        NULLMARK, and NULLMARK deep-equals NULLMARK.
//
// 8. THE PASS COUNT IS WHAT THE ENGINE RAN, NOT WHAT THE CORPUS DECLARES.
//    `drive` counts the times omni invoked the subject wrapper — omni calls
//    it exactly once per entry — and reports THAT. A count read off the spec
//    cannot tell a working engine from a disconnected one: with the
//    `runsetflagsargs` call commented out, the old `report.pass(entrycount)`
//    still printed `PASS 1216  FAIL 0` and exited 0. A number that survives
//    the engine being unplugged is worse than no number, because it reads as
//    evidence. The declared count is kept only as a TRIPWIRE: if the engine
//    ran a different number of entries than the group declares, that
//    mismatch is itself a failure.

import scala.collection.immutable.ListMap
import scala.collection.mutable.{ArrayBuffer, LinkedHashMap}

import voxgig.omni.{
  Flags,
  Json as OJson,
  OmniError,
  Provider,
  RunPack,
  RunnerPack,
  Runner as OmniRunner,
  Util as OmniUtil
}
import voxgig.omni.{
  EXISTSMARK as OMNI_EXISTSMARK,
  NULLMARK as OMNI_NULLMARK,
  UNDEFMARK as OMNI_UNDEFMARK
}

import voxgig.struct.{
  Noval,
  VBool,
  VFunc,
  VList,
  VMap,
  VNull,
  VNum,
  VSentinel,
  VStr,
  Value
}

import voxgig.univecsdk.core.SdkError


// Pass/fail/skip accumulator shared by every section of one corpus run
// (decision 6). `prefix` is the banner the main prints, so the two mains stay
// distinguishable in a mixed log.
final class OmniReport(val prefix: String) {

  var passed: Int = 0
  val failures = ArrayBuffer.empty[String]
  val skipped = ArrayBuffer.empty[String]

  def pass(n: Int): Unit = { passed += n }

  def fail(label: String, msg: String): Unit =
    failures.append("FAIL " + label + " - " + msg.replace('\n', ' '))

  /**
   * A group that did not run for a reason that is NOT a defect. `why` is
   * carried into the banner beside the label, because "skipped" on its own
   * cannot be read: a section this corpus predates and a group that declares
   * no entries are different facts and the reader has to be able to tell.
   */
  def skip(label: String, why: String): Unit =
    skipped.append(label + " (" + why + ")")

  /**
   * A run that checked NOTHING is a failure, not a pass. Every group of a
   * section this project's corpus does not carry is skipped (see
   * OmniRun.drive), so a corpus whose whole section went missing would
   * otherwise finish green with zero checks — the exact silent-pass this
   * migration exists to prevent. The corpus mains call this before finish().
   */
  def requireran(what: String): Unit =
    if (0 == passed && failures.isEmpty) {
      fail(what, "no corpus entries ran at all - the section is missing or " +
        "empty (skipped: " + skipped.mkString(", ") + ")")
    }

  /** Print the banner; the process exit code (0 clean, 1 on any failure). */
  def finish(): Int = {
    failures.foreach(println)
    // Each entry carries its own reason now, so the header does not claim
    // one: "absent from this corpus" was wrong for a group that is present
    // and declares no entries.
    if (skipped.nonEmpty) {
      println("SKIPPED (nothing ran, and why): " + skipped.mkString(", "))
    }
    println(s"\n${prefix}PASS $passed  FAIL ${failures.length}")
    if (failures.nonEmpty) 1 else 0
  }
}


/**
 * One named corpus group: the node the drivers hand to the engine, the PATH
 * that named it, and the PARENT it was looked up in. The parent is not
 * decoration — it is the only thing that separates a section this project's
 * corpus does not carry (benign) from a group that vanished out of a section
 * it does carry (a regression). See decision 7.
 */
final case class OmniGroup(path: List[String], node: OJson, parent: OJson) {
  def pathname: String = path.mkString(".")
}


/** What the runner returns for one named spec section. */
final class OmniRun(
    pack: RunPack,
    val all: OJson,
    val report: OmniReport,
    val sectionname: String = "") {

  /** The resolved section. */
  val spec: OJson = pack.spec

  /** A raw node of the resolved section, by path. */
  def set(keys: String*): OJson = keys.foldLeft(spec)((node, key) => node.get(key))

  /**
   * The same lookup, keeping the PARENT so the two kinds of absence stay
   * distinguishable (decision 7). Every group a corpus driver runs comes
   * through here.
   */
  def group(keys: String*): OmniGroup = {
    val parent = keys.dropRight(1).foldLeft(spec)((node, key) => node.get(key))
    // The section name leads the path, so a message naming the group names
    // it the way the corpus file does — `struct.merge.basic`, not `basic`.
    val path = if (sectionname.isEmpty) keys.toList else sectionname :: keys.toList
    OmniGroup(path, if (keys.isEmpty) spec else parent.get(keys.last), parent)
  }

  /**
   * Run one group whose subject takes the single corpus argument. The
   * converted argument is written back after the call (decision 2), so
   * `match: {args: ...}` sees what the subject did to it.
   */
  def runset(label: String, grp: OmniGroup, nulls: Boolean = true)(
      subject: Value => Value): Unit =
    drive(label, grp, nulls, args => {
      val input = OmniResolver.tostruct(args.headOption.getOrElse(OJson.Absent))
      val out = subject(input)
      val back = OmniResolver.toomni(input)
      (if (args.isEmpty) List(back) else back :: args.tail, OmniResolver.toomni(out))
    })

  /**
   * Run one group whose subject takes omni's WHOLE argument list — the shape
   * the `primary` suite needs, where a ctx entry arrives as args(0), a MAP,
   * which the call site turns into a typed Context and writes observable
   * state back into (decisions 2 and 3).
   */
  def runsetargs(label: String, grp: OmniGroup, nulls: Boolean = true)(
      subject: Seq[Value] => Value): Unit =
    drive(label, grp, nulls, args => {
      val input = args.map(OmniResolver.tostruct)
      val out = subject(input)
      (input.map(OmniResolver.toomni), OmniResolver.toomni(out))
    })

  /**
   * Compare one expected/actual pair directly, for the handful of corpus
   * nodes that are a single `{in, out}` object rather than a `set` and so
   * never reach omni at all (`merge/basic`, `inject/basic`,
   * `transform/basic`, `walk/log`). Both sides go through omni's own
   * `fixjson`, which is exactly what it does to everything it runs.
   *
   * The group is required, not just its label: unlike `drive`, which hands a
   * node to the engine, the CALL SITE here reads the node to build both
   * sides. An absent or hollowed-out node therefore does not compare nothing
   * — it compares `Noval` with `Noval`, which `fixjson` renders as NULLMARK
   * on both sides, and NULLMARK deep-equals NULLMARK. That is a PASS with no
   * subject and no data behind it, which is why the shape check below runs
   * before the comparison and both sides are by-name (decision 7).
   */
  def compare(label: String, grp: OmniGroup, expected: => Value, actual: => Value,
      nulls: Boolean = true): Unit = {

    if (absent(label, grp)) return

    if (!grp.node.ismap || !grp.node.has("in") || !grp.node.has("out")) {
      report.fail(label, "corpus node " + grp.pathname + " carries no in/out " +
        "pair - there is nothing to compare, and both sides would read as null")
      return
    }

    try {
      val want = OmniResolver.fixjson(OmniResolver.toomni(expected), nulls)
      val got = OmniResolver.fixjson(OmniResolver.toomni(actual), nulls)
      if (OmniUtil.deepequal(want, got)) report.pass(1)
      else report.fail(label,
        s"Expected: ${OmniUtil.stringify(want)}, got: ${OmniUtil.stringify(got)}")
    }
    catch { case e: Throwable => report.fail(label, OmniResolver.errtext(e)) }
  }

  // Hand one group to omni and record the outcome (decisions 6, 7 and 8).
  private def drive(
      label: String,
      grp: OmniGroup,
      nulls: Boolean,
      call: List[OJson] => (List[OJson], OJson)): Unit = {

    if (absent(label, grp)) return

    val declared = OmniResolver.entrycount(grp.node)
    val flags = Flags(nulls = nulls, name = Some(label))

    // What the ENGINE actually ran. omni's own drive loop invokes this
    // wrapper exactly once per entry, so `ran` counts real work; the
    // declared count is only the tripwire it is checked against
    // (decision 8).
    var ran = 0
    val counted: List[OJson] => (List[OJson], OJson) = args => { ran += 1; call(args) }

    try {
      pack.runsetflagsargs(OmniResolver.retargetctx(grp.node), flags, counted)

      if (ran != declared) {
        report.fail(label, "the engine ran " + ran + " of the " + declared +
          " entries " + grp.pathname + " declares - the pass count reports " +
          "what RAN, so it will not paper over the gap")
      }
      else if (0 == declared) report.skip(label, "declares no entries")
      else report.pass(ran)
    }
    catch {
      case e: OmniError => report.fail(label, e.text)
      case e: Throwable => report.fail(label, OmniResolver.errtext(e))
    }
  }

  /**
   * The two kinds of absence (decision 7). Returns true when the group did
   * not run and the outcome has already been recorded.
   */
  private def absent(label: String, grp: OmniGroup): Boolean =
    if (!grp.node.isabsent) false
    else if (grp.parent.isabsent) {
      // The whole section is missing: a project corpus older than the
      // section. Real fleet-wide (struct.nullsem), and not a defect — but
      // NAMED in the banner, never passed over in silence.
      report.skip(label, "section absent from this corpus")
      true
    }
    else {
      // The section is carried and the group is not. Nothing legitimate does
      // that, so it is a corpus regression: a skip here would let the group
      // stop running behind a green banner.
      report.fail(label, "corpus group " + grp.pathname + " is absent from a " +
        "section this corpus DOES carry - the group stopped running and " +
        "checked nothing")
      true
    }
}


object OmniResolver {

  // The sentinels, under the names the corpus drivers already use.
  val NULLMARK: String = OMNI_NULLMARK
  val UNDEFMARK: String = OMNI_UNDEFMARK
  val EXISTSMARK: String = OMNI_EXISTSMARK

  // ---- the two value models (decision 1) ---------------------------------

  /** omni's model -> this SDK's struct model. */
  def tostruct(val0: OJson): Value = val0 match {
    case OJson.Absent      => Noval
    case OJson.Null        => VNull
    case OJson.Bool(flag)  => VBool(flag)
    case OJson.Num(num)    => VNum(num)
    case OJson.Str(text)   => VStr(text)
    case OJson.JList(xs)   => VList(ArrayBuffer.from(xs.map(tostruct)))
    case OJson.JMap(xs)    =>
      val out = LinkedHashMap.empty[String, Value]
      xs.foreach { case (key, entry) => out.put(key, tostruct(entry)) }
      VMap(out)
  }

  /**
   * This SDK's struct model -> omni's.
   *
   * `VFunc` and `VSentinel` have no JSON shape at all. They reach here only
   * when a corpus entry puts a callable in data (`getelem` with a callable
   * `alt`, `$APPLY`, a user `$FORMAT`) or a walker returns SKIP/DELETE, and
   * in every such case the corpus asserts on what the call RETURNED, not on
   * the callable. `Json.Absent` is the honest answer — it is what omni's own
   * model says about a value that is not JSON, and omni's `fixjson` then
   * renders it as NULLMARK under the null flag, the same place the retired
   * hand-written `fixJson` put it.
   */
  def toomni(val0: Value): OJson = val0 match {
    case Noval            => OJson.Absent
    case VNull            => OJson.Null
    case VBool(flag)      => OJson.Bool(flag)
    case VNum(num)        => OJson.Num(num)
    case VStr(text)       => OJson.Str(text)
    case VList(buf)       => OJson.JList(buf.toList.map(toomni))
    case VMap(map)        =>
      OJson.JMap(ListMap.from(map.toSeq.map { case (key, entry) => (key, toomni(entry)) }))
    case VFunc(_)         => OJson.Absent
    case VSentinel(_)     => OJson.Absent
  }

  // ---- spec access -------------------------------------------------------

  /**
   * Load the shared corpus. omni's docs say a port must resolve the spec path
   * itself, so it is absolutized against the working directory here.
   */
  def loadspec(path: String): OJson =
    OmniRunner.loadspec(
      java.nio.file.Paths.get(path).toAbsolutePath.normalize.toString)

  /** How many entries a group declares. */
  def entrycount(node: OJson): Int =
    node.get("set").aslist.map(_.length).getOrElse(0)

  /** omni's own null normalisation, for values that never reach the engine. */
  def fixjson(val0: OJson, nulls: Boolean): OJson = OmniRunner.fixjson(val0, nulls)

  def errtext(err: Throwable): String = err match {
    case e: OmniError => e.text
    case e            => Option(e.getMessage).getOrElse(String.valueOf(e))
  }

  // ---- the runner --------------------------------------------------------

  /**
   * Wrap a live SDK client as an omni provider.
   *
   * Only `errify` is hooked. There is no subject-by-name hook: this port's
   * utilities are typed methods on `Utility`, so a generic name lookup cannot
   * produce omni's `List[Json] => Json` subject without a per-name adapter,
   * and every call site passes its subject explicitly. The corpus carries no
   * `DEF.client` block for the sections these mains drive — a section that
   * needs differently-optioned defaults declares `DEF.setup`, which
   * PrimaryCorpus reads directly to build its own client.
   *
   * `errify` keeps the SDK error's CODE beside its message, so a corpus
   * `match: {err: {code: ...}}` can assert on it rather than pattern-matching
   * prose (the Scala analogue of the java/csharp resolvers' same hook).
   */
  def sdkProvider(): Provider = Provider(
    errify = Some((err: Throwable) => err match {
      case e: SdkError =>
        var out = ListMap(
          "name" -> OJson.Str("SdkError"),
          "message" -> OJson.Str(String.valueOf(e.getMessage)))
        if (e.code != null && e.code.nonEmpty) {
          out = out.updated("code", OJson.Str(e.code))
        }
        OJson.JMap(out)
      case other => OmniRunner.errify(other)
    })
  )

  /** A runner over an already-parsed spec (omni's own capability, which keeps
    * the smoke test free of a fixture file). */
  def makeRunner(spec: OJson): RunnerPack = OmniRunner.makeRunner(spec, sdkProvider())

  /** A runner over the shared corpus at `path`. */
  def makeRunner(path: String): RunnerPack = makeRunner(loadspec(path))

  /** Resolve one named section (`primary.<name>`, then `<name>`). */
  def section(pack: RunnerPack, all: OJson, name: String, report: OmniReport): OmniRun =
    new OmniRun(pack.runner(name), all, report, name)

  // ---- decision 3 --------------------------------------------------------

  /**
   * Retarget `match: {ctx: ...}` onto `match: {args: {"0": ...}}`, and only
   * when the entry HAS a ctx or args (so args(0) IS that map) and the check
   * does not already assert on `args`. See decision 3 above.
   */
  def retargetctx(testspec: OJson): OJson = testspec.get("set").aslist match {
    case None => testspec
    case Some(entries) =>
      val out = entries.map { entry =>
        val check = entry.get("match")
        if (entry.ismap && check.ismap && check.has("ctx") && !check.has("args") &&
            (entry.has("ctx") || entry.has("args"))) {
          var newcheck = ListMap.empty[String, OJson]
          check.asmap.get.foreach { case (key, sub) =>
            // Drop the original leaf: it would read the stale pre-call copy
            // omni keeps in `entry.ctx`.
            if ("ctx" != key) newcheck = newcheck.updated(key, sub)
          }
          newcheck = newcheck.updated("args",
            OJson.JMap(ListMap("0" -> check.get("ctx"))))
          entry.set("match", OJson.JMap(newcheck))
        }
        else entry
      }
      testspec.set("set", OJson.JList(out))
  }
}
