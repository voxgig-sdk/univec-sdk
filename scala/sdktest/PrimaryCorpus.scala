// Primary-utility corpus driver.
//
// Drives every `primary` section of the shared corpus (../.sdk/test/test.json)
// through this SDK's utilities, the way the ts reference harness does.
//
// The ENGINE is the vendored @voxgig/omni runner (sdktest/vendor/omni),
// reached through sdktest/OmniResolver.scala — this file was REWRITTEN IN
// PLACE by the vendor-tag rollout and keeps its name, so no emitted call site
// moved. What it still owns is the bridge only this SDK can supply: the
// corpus Value ADT <-> the SDK's Java-collection world, plus a live Context
// built from each corpus entry and published back for `match` to read.

import voxgig.struct.{clone as sclone, *}
import voxgig.univecsdk.core.*

import java.util.{ArrayList, LinkedHashMap, List as JList, Map as JMap}
import scala.collection.mutable.{ArrayBuffer, LinkedHashMap as MLinkedHashMap}
import scala.jdk.CollectionConverters.*

object PrimaryCorpus {

  // ---- Value <-> Java bridge ---------------------------------------------

  def toJava(v: Value): Object = v match {
    case VMap(m) =>
      val out = new LinkedHashMap[String, Object]()
      m.foreach { case (k, x) => out.put(k, toJava(x)) }
      out
    case VList(b) =>
      val out = new ArrayList[Object]()
      b.foreach { x => out.add(toJava(x)) }
      out
    case VStr(s)  => s
    case VBool(b) => java.lang.Boolean.valueOf(b)
    case VNum(n)  =>
      // The corpus writes whole numbers as JSON integers; handing the SDK a
      // Double turned "1" into "1.0" everywhere it reached a URL or header.
      // (omni parses every JSON number as a Double, so the narrowing has to
      // happen on THIS boundary, not the omni one.)
      if (n == Math.floor(n) && !n.isInfinite) java.lang.Long.valueOf(n.toLong)
      else java.lang.Double.valueOf(n)
    case _ => null
  }

  def toValue(o: Object): Value = o match {
    case null => VNull
    // Struct.UNDEF is the library's "no value" sentinel, not a value: an
    // unresolved transform path returns it, and without this it reached the
    // corpus as the string "java.lang.Object@..." instead of null.
    case x if x eq voxgig.univecsdk.utility.struct.Struct.UNDEF => VNull
    case m: JMap[_, _] =>
      val out = MLinkedHashMap.empty[String, Value]
      m.asInstanceOf[JMap[String, Object]].asScala.foreach { case (k, x) => out.put(k, toValue(x)) }
      VMap(out)
    case l: JList[_] =>
      val out = ArrayBuffer.empty[Value]
      l.asInstanceOf[JList[Object]].asScala.foreach { x => out += toValue(x) }
      VList(out)
    case s: String            => VStr(s)
    case b: java.lang.Boolean => VBool(b.booleanValue())
    case n: java.lang.Number  => VNum(n.doubleValue())
    case e: RuntimeException  =>
      val m = MLinkedHashMap.empty[String, Value]
      m.put("message", VStr(String.valueOf(e.getMessage)))
      VMap(m)
    case x => VStr(String.valueOf(x))
  }

  private def jmap(v: Value): JMap[String, Object] = toJava(v) match {
    case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
    case _             => new LinkedHashMap[String, Object]()
  }

  private def vget(v: Value, k: String): Value = v match {
    case VMap(m) => m.getOrElse(k, Noval)
    case _       => Noval
  }

  // ---- corpus access -----------------------------------------------------

  // The whole corpus, and the omni runner built over it. One RunnerPack for
  // the run; a section is resolved from it on demand (omni's own
  // `primary.<name>` lookup, so the section names below ARE the corpus
  // lookup keys).
  private var ALL: voxgig.omni.Json = voxgig.omni.Json.Absent
  private var PACK: voxgig.omni.RunnerPack = null
  private var REPORT: OmniReport = null

  private def sectionRun(name: String): OmniRun =
    OmniResolver.section(PACK, ALL, name, REPORT)

  // makeSpec and prepareAuth read defaults off the CLIENT, as the ts reference
  // does via client.options(), so a section's DEF.setup cannot reach them
  // through ctx.options — those sections get their own client.
  private def sectionSetup(run: OmniRun): Value =
    OmniResolver.tostruct(run.set("DEF", "setup", "a"))

  // ---- live context from a corpus map ------------------------------------

  private def corpusCtx(client: UnivecSDK, ctxmap: Value): Context = {
    val utility = client.getUtility()
    val cm = new LinkedHashMap[String, Object]()
    // Only when the corpus names one: defaulting to "load" made the SDK report
    // the wrong operation in the error messages the corpus matches on.
    vget(ctxmap, "opname") match {
      case VStr(s) => cm.put("opname", s)
      case _       =>
    }
    val ctx = utility.makeContext(cm, client.getRootCtx())

    vget(ctxmap, "spec") match {
      case m @ VMap(_) => ctx.spec = new Spec(jmap(m))
      case _           =>
    }

    vget(ctxmap, "result") match {
      case m @ VMap(_) =>
        val r = new Result(jmap(m))
        // Result does not carry an err in from the map, so a corpus result
        // holding one arrived empty and resultBasic had no previous message
        // to prepend.
        vget(vget(m, "err"), "message") match {
          case VStr(msg) if msg.nonEmpty => r.err = new SdkError("", msg, null)
          case _                         =>
        }
        ctx.result = r
      case _ =>
    }

    vget(ctxmap, "response") match {
      case m @ VMap(_) =>
        val resp = new Response(jmap(m))
        // resultBody reads response.json and requires it to be CALLABLE; the
        // corpus supplies a plain `body`.
        vget(m, "body") match {
          case Noval => ()
          case b =>
            val bj = toJava(b)
            resp.body = bj
            resp.jsonFunc = new java.util.function.Supplier[Object] { def get(): Object = bj }
        }
        // Header names arrive from the wire in any case and the contract is
        // lowercase; resultHeaders copies them verbatim.
        vget(m, "headers") match {
          case VMap(hm) =>
            val low = new LinkedHashMap[String, Object]()
            hm.foreach { case (k, x) => low.put(k.toLowerCase, toJava(x)) }
            resp.headers = low
          case _ =>
        }
        ctx.response = resp
      case _ =>
    }

    vget(ctxmap, "point") match { case m @ VMap(_) => ctx.point = jmap(m); case _ => }
    vget(ctxmap, "reqdata") match { case Noval => (); case v => ctx.reqdata = jmap(v) }
    vget(ctxmap, "reqmatch") match { case Noval => (); case v => ctx.reqmatch = jmap(v) }
    vget(ctxmap, "data") match { case Noval => (); case v => ctx.data = jmap(v) }
    vget(ctxmap, "match") match { case Noval => (); case v => ctx.matchData = jmap(v) }
    vget(ctxmap, "options") match { case m @ VMap(_) => ctx.options = jmap(m); case _ => }
    vget(ctxmap, "config") match { case m @ VMap(_) => ctx.config = jmap(m); case _ => }
    ctx
  }

  // The match reads the corpus map while the utilities mutate the live objects
  // hanging off the context, so without this every ctx.* assertion reads null.
  //
  // The map written here is args(0), which the resolver converts BACK into
  // omni's own argument list after the call — that is why the `match: {ctx:
  // ...}` assertions are retargeted onto `match: {args: {"0": ...}}`
  // (OmniResolver decision 3): omni's Json is an immutable value model, so
  // the copy it keeps in `entry.ctx` can never see these writes.
  private def publishCtx(ctxmap: Value, ctx: Context): Unit = ctxmap match {
    case VMap(m) =>
      if (ctx.spec != null) m.put("spec", specValue(ctx.spec))
      if (ctx.result != null) m.put("result", resultValue(ctx.result))
      if (ctx.response != null) m.put("response", VStr(OmniResolver.EXISTSMARK))
    case _ =>
  }

  private def specValue(s: Spec): Value = {
    val m = MLinkedHashMap.empty[String, Value]
    m.put("base", VStr(s.base)); m.put("prefix", VStr(s.prefix)); m.put("suffix", VStr(s.suffix))
    m.put("path", VStr(s.path)); m.put("url", VStr(s.url)); m.put("step", VStr(s.step))
    m.put("method", VStr(s.method))
    m.put("headers", toValue(s.headers)); m.put("params", toValue(s.params))
    m.put("query", toValue(s.query)); m.put("alias", toValue(s.alias))
    if (s.parts != null) m.put("parts", toValue(s.parts))
    if (s.body != null) m.put("body", toValue(s.body))
    VMap(m)
  }

  private def resultValue(r: Result): Value = {
    val m = MLinkedHashMap.empty[String, Value]
    m.put("ok", VBool(r.ok)); m.put("status", VNum(r.status.toDouble))
    m.put("statusText", VStr(r.statusText))
    m.put("headers", toValue(r.headers))
    if (r.body != null) m.put("body", toValue(r.body))
    if (r.resdata != null) m.put("resdata", toValue(r.resdata))
    if (r.resmatch != null) m.put("resmatch", toValue(r.resmatch))
    if (r.err != null) {
      val e = MLinkedHashMap.empty[String, Value]
      e.put("message", VStr(String.valueOf(r.err.getMessage)))
      m.put("err", VMap(e))
    }
    VMap(m)
  }

  // ---- section runners ---------------------------------------------------

  private def argAt(args: Seq[Value], i: Int): Value = if (i < args.length) args(i) else Noval

  // A section driven with a ctx built from the corpus entry. `run.group`
  // rather than `run.set`: the group carries its parent, so a `basic` that
  // has gone missing out of a section this corpus carries FAILS instead of
  // being skipped past (OmniResolver decision 7).
  private def runset(name: String, client: UnivecSDK)(f: (Context, Seq[Value]) => Value): Unit = {
    val run = sectionRun(name)
    run.runsetargs(name, run.group("basic")) { args =>
      val ctxmap = argAt(args, 0)
      val ctx = corpusCtx(client, ctxmap)
      val out = f(ctx, args)
      publishCtx(ctxmap, ctx)
      out
    }
  }

  // A section that takes a bare map or explicit args rather than a ctx.
  private def runsetArgs(name: String)(f: Seq[Value] => Value): Unit = {
    val run = sectionRun(name)
    run.runsetargs(name, run.group("basic"))(f)
  }

  private def clientFor(name: String, shared: UnivecSDK): UnivecSDK =
    sectionSetup(sectionRun(name)) match {
      case m @ VMap(_) => UnivecSDK.testSDK(null, jmap(m))
      case _           => shared
    }

  def run(testfile: String): Int = {
    ALL = OmniResolver.loadspec(testfile)
    PACK = OmniResolver.makeRunner(ALL)
    REPORT = new OmniReport("PRIMARY CORPUS: ")

    val sdk = UnivecSDK.testSDK()
    val u = sdk.getUtility()

    runset("done", sdk) { (c, _) => toValue(u.done(c)) }
    runset("makeUrl", sdk) { (c, _) => toValue(u.makeUrl(c)) }
    runset("makeRequest", sdk) { (c, _) => u.makeRequest(c); resultValue(c.result) }
    runset("makeResponse", sdk) { (c, _) => u.makeResponse(c); resultValue(c.result) }
    runset("makeSpec", clientFor("makeSpec", sdk)) { (c, _) =>
      val s = u.makeSpec(c); if (s != null) c.spec = s; specValue(c.spec)
    }
    runset("prepareAuth", clientFor("prepareAuth", sdk)) { (c, _) =>
      u.prepareAuth(c); specValue(c.spec)
    }
    runset("prepareBody", sdk) { (c, _) => toValue(u.prepareBody(c)) }
    runset("prepareHeaders", sdk) { (c, _) => toValue(u.prepareHeaders(c)) }
    runset("prepareMethod", sdk) { (c, _) =>
      val m = u.prepareMethod(c); if (m == null || m.isEmpty) VNull else VStr(m)
    }
    runset("prepareParams", sdk) { (c, _) => toValue(u.prepareParams(c)) }
    runset("preparePath", sdk) { (c, _) => toValue(u.preparePath(c)) }
    runset("prepareQuery", sdk) { (c, _) => toValue(u.prepareQuery(c)) }
    runset("resultBasic", sdk) { (c, _) =>
      val r = u.resultBasic(c); if (r != null) c.result = r; resultValue(c.result)
    }
    runset("resultBody", sdk) { (c, _) =>
      val r = u.resultBody(c); if (r != null) c.result = r; resultValue(c.result)
    }
    runset("resultHeaders", sdk) { (c, _) =>
      val r = u.resultHeaders(c); if (r != null) c.result = r; resultValue(c.result)
    }
    runset("transformRequest", sdk) { (c, _) => toValue(u.transformRequest(c)) }
    runset("transformResponse", sdk) { (c, _) => toValue(u.transformResponse(c)) }
    runset("param", sdk) { (c, args) => toValue(u.param(c, toJava(argAt(args, 1)))) }
    runset("makeError", sdk) { (c, args) =>
      val msg = vget(argAt(args, 1), "message") match { case VStr(s) => s; case _ => "" }
      val in = if (msg.isEmpty) null else new SdkError("", msg, null)
      toValue(u.makeError(c, in))
    }

    runsetArgs("makeContext") { args =>
      val c = corpusCtx(sdk, argAt(args, 0))
      val op = MLinkedHashMap.empty[String, Value]
      if (c.op != null) {
        op.put("entity", VStr(c.op.entity)); op.put("name", VStr(c.op.name))
        op.put("input", VStr(c.op.input)); op.put("points", toValue(c.op.points))
      }
      val out = MLinkedHashMap.empty[String, Value]
      out.put("op", VMap(op))
      VMap(out)
    }
    runsetArgs("makeOptions") { args =>
      val in = argAt(args, 0)
      val c = corpusCtx(sdk, VMap(MLinkedHashMap.empty[String, Value]))
      vget(in, "config") match { case Noval => (); case v => c.config = jmap(v) }
      vget(in, "options") match { case Noval => (); case v => c.options = jmap(v) }
      toValue(u.makeOptions(c))
    }
    runsetArgs("operator") { args =>
      val in = argAt(args, 0)
      val m = MLinkedHashMap.empty[String, Value]
      m.put("entity", vget(in, "entity") match { case Noval => VStr("_"); case v => v })
      m.put("input", vget(in, "input") match { case Noval => VStr("_"); case v => v })
      m.put("name", vget(in, "name") match { case Noval => VStr("_"); case v => v })
      m.put("points", vget(in, "points") match { case l @ VList(_) => l; case _ => VList(ArrayBuffer.empty[Value]) })
      VMap(m)
    }

    REPORT.requireran("primary")
    REPORT.finish()
  }
}

object PrimaryCorpusMain {
  def main(args: Array[String]): Unit = {
    val testfile = if (args.length > 0) args(0) else "../.sdk/test/test.json"
    System.exit(PrimaryCorpus.run(testfile))
  }
}
