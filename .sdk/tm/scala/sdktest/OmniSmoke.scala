// Smoke test for the vendored omni runner ITSELF.
//
// A runner that cannot FAIL a bad entry would turn every corpus suite
// vacuously green, so this pins the failure paths, not just the happy one:
// a wrong result must be reported, and an expected error that does NOT
// occur must be reported. It also exercises the whole adapter — the
// in-memory spec capability, the Json <-> Value bridge, and OmniReport's
// accumulation — because those are what stand between the vendored engine
// and the two corpus mains.
//
// The Scala peer of tm/java/test/OmniSmokeTest.java, tm/lua/test/
// omni_smoke_test.lua and tm/ts/test/omni.test.ts. There is no test
// framework in this target (see model/target/scala.aon), so it is a plain
// scala-cli main that exits non-zero on failure, like the corpus mains
// beside it.

import voxgig.omni.Json as OJson
import voxgig.struct.{Noval, VNum, Value}

object OmniSmoke {

  // A minimal in-memory spec: no fixture file, no OMNI block (lenient v0,
  // like the shared corpus). Built in omni's OWN value model - the runner
  // walks nothing else.
  def smokespec(): OJson = OJson.map(
    "primary" -> OJson.map(
      "smoke" -> OJson.map(
        "basic" -> OJson.map(
          "set" -> OJson.list(
            OJson.map("in" -> OJson.num(1), "out" -> OJson.num(2)),
            OJson.map("in" -> OJson.num(41), "out" -> OJson.num(42)))),
        "bad" -> OJson.map(
          "set" -> OJson.list(
            OJson.map("in" -> OJson.num(1), "out" -> OJson.num(999)))),
        "err" -> OJson.map(
          "set" -> OJson.list(
            OJson.map("in" -> OJson.num(0), "err" -> OJson.str("zero refused")))),
        // A single {in, out} node rather than a `set`: the shape the four
        // struct groups OmniRun.compare drives have.
        "node" -> OJson.map("in" -> OJson.num(7), "out" -> OJson.num(7)))))

  // The subject under test, in this SDK's struct value model - so a pass
  // here also proves the resolver's Json <-> Value bridge round-trips.
  def inc(v: Value): Value = v match {
    case VNum(n) if 0.0 == n => throw new RuntimeException("smoke: zero refused")
    case VNum(n)             => VNum(n + 1.0)
    case other               => other
  }

  def identity(v: Value): Value = v

  private var nfail = 0

  private def check(what: String, ok: Boolean, detail: String): Unit =
    if (ok) println("ok   " + what)
    else { nfail += 1; println("FAIL " + what + " - " + detail) }

  private def run(name: String, group: String, subject: Value => Value): OmniReport = {
    val report = new OmniReport("")
    val spec = smokespec()
    val run = OmniResolver.section(OmniResolver.makeRunner(spec), spec, "smoke", report)
    run.runset(name, run.group(group))(subject)
    report
  }

  private def freshrun(section: String, report: OmniReport): OmniRun = {
    val spec = smokespec()
    OmniResolver.section(OmniResolver.makeRunner(spec), spec, section, report)
  }

  def main(args: Array[String]): Unit = {
    // 0. The section and its groups resolve at all.
    val spec = smokespec()
    val resolved =
      OmniResolver.section(OmniResolver.makeRunner(spec), spec, "smoke",
        new OmniReport("")).set("basic")
    check("smoke section resolves", !resolved.isabsent, "primary.smoke did not resolve")

    // 1. A correct subject passes, and every entry is counted.
    val good = run("smoke.basic", "basic", inc)
    check("runset passes a correct subject", good.failures.isEmpty,
      good.failures.mkString(" | "))
    check("runset counts every entry", 2 == good.passed,
      "expected 2 checks, counted " + good.passed)

    // 1b. The count is what the ENGINE RAN, not what the spec declares
    //     (OmniResolver decision 8). Counted here at the subject, the far
    //     side of the engine: a number the engine cannot move is not
    //     evidence that the engine ran.
    var calls = 0
    val counted = run("smoke.basic", "basic", v => { calls += 1; inc(v) })
    check("the reported count is what the engine ran",
      2 == calls && calls == counted.passed,
      "the engine invoked the subject " + calls + " times but the report " +
        "counted " + counted.passed + " passes")

    // 2. A WRONG result is reported. Without this the corpus suites would be
    //    vacuously green.
    val bad = run("smoke.bad", "bad", inc)
    check("runset fails a wrong result", bad.failures.nonEmpty,
      "a wrong result went unreported - the corpus suites would be vacuously green")
    check("the failure names the mismatch",
      bad.failures.exists(_.contains("result mismatch")),
      "expected a result mismatch failure, got: " + bad.failures.mkString(" | "))
    check("a failed group counts nothing", 0 == bad.passed,
      "a failed group still counted " + bad.passed + " passes")

    // 3. An expected error is matched; a MISSING expected error is reported.
    val raised = run("smoke.err", "err", inc)
    check("an expected error is matched", raised.failures.isEmpty,
      raised.failures.mkString(" | "))

    val missed = run("smoke.err", "err", identity)
    check("a missing expected error fails", missed.failures.nonEmpty,
      "a missing expected error went unreported")
    check("the failure names the missing error",
      missed.failures.exists(_.contains("expected error did not occur")),
      "expected an expected-error failure, got: " + missed.failures.mkString(" | "))

    // 4. Absence, BOTH kinds (OmniResolver decision 7). Neither is ever a
    //    silent pass, and the two are not the same fact.
    //
    // 4a. The section is carried and the GROUP is gone. That is a corpus
    //     regression - it must FAIL, because a skip would let the group stop
    //     running behind a green banner.
    val gone = new OmniReport("")
    val gonerun = freshrun("smoke", gone)
    gonerun.runset("smoke.nosuch", gonerun.group("nosuch"))(inc)
    check("a group missing from a section this corpus carries fails",
      gone.failures.exists(_.contains("smoke.nosuch")) && 0 == gone.passed,
      "absent group: failures=" + gone.failures.mkString(" | ") +
        " passed=" + gone.passed + " skipped=" + gone.skipped.mkString(","))

    // 4b. The whole SECTION is missing - a project corpus older than the
    //     section (struct.nullsem, fleet-wide). SKIPPED and NAMED, not
    //     failed, and never counted as a pass.
    val older = new OmniReport("")
    val olderrun = freshrun("smoke", older)
    olderrun.runset("nosuch.basic", olderrun.group("nosuch", "basic"))(inc)
    check("a group whose whole section is absent is skipped, not passed",
      older.skipped.exists(_.startsWith("nosuch.basic")) && 0 == older.passed &&
        older.failures.isEmpty,
      "absent section: skipped=" + older.skipped.mkString(",") +
        " passed=" + older.passed + " failures=" + older.failures.mkString(" | "))

    // 4c. `compare` - the single-node groups (merge/basic, inject/basic,
    //     transform/basic, walk/log) - is held to the SAME rule. It used to
    //     have no guard at all: an absent node became Noval on both sides,
    //     fixjson rendered both as NULLMARK, and NULLMARK deep-equals
    //     NULLMARK, so three struct groups could stop running and leave a run
    //     bit-identical to a healthy one.
    val nonode = new OmniReport("")
    val nonoderun = freshrun("smoke", nonode)
    nonoderun.compare("smoke.nonode", nonoderun.group("nonode"), Noval, Noval)
    check("compare fails an absent single-node group, never passes it",
      nonode.failures.exists(_.contains("smoke.nonode")) && 0 == nonode.passed,
      "absent compare node: failures=" + nonode.failures.mkString(" | ") +
        " passed=" + nonode.passed + " skipped=" + nonode.skipped.mkString(","))

    // 4d. A node that IS there but carries no in/out pair compares nothing
    //     for the same reason, so the shape is checked before the values.
    val hollow = new OmniReport("")
    val hollowrun = freshrun("smoke", hollow)
    hollowrun.compare("smoke.hollow", hollowrun.group("bad"), Noval, Noval)
    check("compare fails a node with no in/out pair",
      hollow.failures.exists(_.contains("no in/out")) && 0 == hollow.passed,
      "hollow compare node: failures=" + hollow.failures.mkString(" | ") +
        " passed=" + hollow.passed)

    // 4e. And a WELL-FORMED single-node group still passes, so 4c/4d are a
    //     guard and not a blanket refusal.
    val onenode = new OmniReport("")
    val onenoderun = freshrun("smoke", onenode)
    onenoderun.compare("smoke.node", onenoderun.group("node"),
      OmniResolver.tostruct(onenoderun.group("node").node.get("out")),
      OmniResolver.tostruct(onenoderun.group("node").node.get("in")))
    check("compare passes a well-formed single-node group",
      onenode.failures.isEmpty && 1 == onenode.passed,
      "single node: failures=" + onenode.failures.mkString(" | ") +
        " passed=" + onenode.passed)

    // 5. A report that checked NOTHING must fail, not pass: a whole corpus
    //    section going missing is exactly how a suite goes vacuously green.
    val empty = new OmniReport("")
    empty.requireran("nothing")
    check("a run that checked nothing fails", empty.failures.nonEmpty,
      "an empty run passed - a missing corpus section would go unnoticed")

    println("\nOMNI SMOKE FAIL " + nfail)
    if (0 < nfail) System.exit(1)
  }
}
