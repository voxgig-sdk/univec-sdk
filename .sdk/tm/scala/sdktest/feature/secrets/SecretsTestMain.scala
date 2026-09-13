// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) - the
// scala port of tm/go/test/feature/secrets/secrets_feature_test.go.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because SecretsFeature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls out
// of sekreto's first-hit rule rather than from special-case logic. With the
// feature inactive nothing changes at all. With it active and the option
// unset, the chain supplies the credential instead.
//
// EVERY ASSERTION IS ON THE WIRE. Each case builds a LIVE client whose
// `system.fetch` is the recorder below, so the thing being counted IS the
// transport - not a harness mock that replaced it. That distinction is the
// whole difference between a fail-closed test and a test that would pass on
// an SDK with no secrets feature at all: under the test-mode harness the
// TestFeature swaps `ctx.utility.fetcher` for its own in-memory mock, so a
// counter hung off `system.fetch` is never reached and "no request went out"
// holds vacuously. So each fail-closed case carries a CONTROL leg - the same
// construction with a WORKING provider - which must reach the same recorder
// exactly once, and the refusal is matched on the PROVIDER'S OWN message so
// that an unrelated failure cannot stand in for fail-closed.
//
// The feature is CONSTRUCTED DIRECTLY and handed in through the `extend`
// option when the generated config did not already install it, so these
// tests hold in any generated tree - whether or not the project's model
// activated the feature.
//
// This file lives in the `feature/` container on purpose: it is per-feature
// source, and travels with the feature.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.function.{BiFunction, Supplier}

import scala.collection.mutable.ListBuffer

import SCALAPACKAGE.core._
import SCALAPACKAGE.feature._
import SCALAPACKAGE.utility.Json

object SecretsTestMain {

  // ---- assertion harness --------------------------------------------------

  private var npass = 0
  private val failures = new ArrayList[String]()

  private def pass(): Unit = { npass += 1 }
  private def fail(name: String, msg: String): Unit = failures.add(name + ": " + msg)
  private def check(name: String, cond: Boolean, msg: String): Unit =
    if (cond) pass() else fail(name, msg)
  private def eqs(name: String, exp: String, act: String): Unit =
    check(name, exp == act, "expected \"" + exp + "\", got \"" + act + "\"")
  private def eqs(name: String, exp: String, act: String, why: String): Unit =
    check(name, exp == act,
      "expected \"" + exp + "\", got \"" + act + "\" - " + why)
  private def eqi(name: String, exp: Int, act: Int): Unit =
    check(name, exp == act, "expected " + exp + ", got " + act)

  // The Authorization header carries the SPEC's credential prefix, which a
  // TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives `Bearer
  // <token>`, an apiKey scheme the raw token. So assert on the CREDENTIAL and
  // let the prefix be whatever this SDK's API declares - pinning the whole
  // header value passes only for a prefix-less API, and this file ships to
  // every project that selects the feature.
  private def credentialIs(name: String, header: String, token: String): Unit = {
    val got = if (header == null) "" else header
    check(name, got == token || got.endsWith(" " + token),
      "expected the authorization header to carry " + token + ", got \"" + got + "\"")
  }

  // ---- the recording transport --------------------------------------------
  //
  // system.fetch for a LIVE client: one status per API call (the last
  // repeating), plus a token endpoint for the exchange cases.

  final class Wire {
    val calls = new ArrayList[JMap[String, Object]]()
    var apistatus: List[Int] = List(200)
    var tokens: List[String] = List("ACCESS01", "ACCESS02", "ACCESS03")
    var tokenpath: String = "auth/token"
    var respfield: String = "access_token"
    var tokenstatus: List[Int] = List(200)

    private var issued = 0
    private var apicalls = 0
    private var tokencalls = 0

    val fetch: BiFunction[String, JMap[String, Object], Object] =
      (url: String, fetchdef: JMap[String, Object]) => this.synchronized {
        val headers = fetchdef.get("headers") match {
          case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
          case _ => new LinkedHashMap[String, Object]()
        }
        val call = new LinkedHashMap[String, Object]()
        call.put("url", url)
        call.put("has", java.lang.Boolean.valueOf(headers.containsKey("authorization")))
        call.put("auth", headers.get("authorization") match {
          case s: String => s
          case _ => ""
        })
        call.put("body", fetchdef.get("body") match { case s: String => s; case _ => "" })
        calls.add(call)

        if (url.endsWith("/" + tokenpath)) {
          val status = tokenstatus(math.min(tokencalls, tokenstatus.length - 1))
          tokencalls += 1
          val token = tokens(math.min(issued, tokens.length - 1))
          issued += 1
          val payload = new LinkedHashMap[String, Object]()
          if (200 <= status && 300 > status) payload.put(respfield, token)
          else payload.put("error", "nope")
          response(status, payload)
        } else {
          val status = apistatus(math.min(apicalls, apistatus.length - 1))
          apicalls += 1
          val payload = new LinkedHashMap[String, Object]()
          payload.put("ok", java.lang.Boolean.valueOf(400 > status))
          response(status, payload)
        }
      }

    private def response(status: Int, data: JMap[String, Object]): JMap[String, Object] = {
      val js: Supplier[Object] = () => data
      val out = new LinkedHashMap[String, Object]()
      out.put("status", java.lang.Integer.valueOf(status))
      out.put("statusText", if (400 <= status) "ERR" else "OK")
      out.put("headers", new LinkedHashMap[String, Object]())
      out.put("json", js)
      out
    }

    private def matching(token: Boolean): List[JMap[String, Object]] = {
      val out = ListBuffer.empty[JMap[String, Object]]
      val it = calls.iterator()
      while (it.hasNext) {
        val c = it.next()
        val url = c.get("url") match { case s: String => s; case _ => "" }
        if (url.endsWith("/" + tokenpath) == token) out += c
      }
      out.toList
    }

    // Only the calls that went to the API, and only those that went to the
    // token endpoint.
    def api(): List[JMap[String, Object]] = matching(false)
    def token(): List[JMap[String, Object]] = matching(true)

    def authof(call: JMap[String, Object]): String =
      call.get("auth") match { case s: String => s; case _ => "" }
    def hasauth(call: JMap[String, Object]): Boolean =
      java.lang.Boolean.TRUE == call.get("has")

    // What went out, for a failure message that names the leak rather than
    // just its count.
    def report(): String =
      api().map(c => String.valueOf(c.get("url")) + " auth=\"" + authof(c) + "\"")
        .mkString(", ")
  }

  // ---- small builders ------------------------------------------------------

  private val ENVPREFIX = "PROJECTENV_TEST_SECRETS_"
  private val BASE = "http://secrets.test/api"

  private def jmap(kv: (String, Object)*): JMap[String, Object] = {
    val m = new LinkedHashMap[String, Object]()
    kv.foreach { case (k, v) => m.put(k, v) }
    m
  }

  private def jlist(xs: Object*): JList[Object] = {
    val l = new ArrayList[Object]()
    xs.foreach(l.add)
    l
  }

  private def sdkopts(w: Wire, extra: (String, Object)*): JMap[String, Object] = {
    val opts = jmap("base" -> BASE, "system" -> jmap("fetch" -> w.fetch))
    extra.foreach { case (k, v) => opts.put(k, v) }
    opts
  }

  // The feature options: a chain of one MEMORY store unless a case says
  // otherwise. `memory` rather than `env` because a JVM cannot set its own
  // environment - see the `env` case at the end, which proves the env
  // built-in is live by reading a variable that is already there.
  private def secretsOpts(providers: JList[Object], extra: (String, Object)*): JMap[String, Object] = {
    val fopts = jmap(
      "active" -> java.lang.Boolean.TRUE,
      "providers" -> providers,
    )
    extra.foreach { case (k, v) => fopts.put(k, v) }
    jmap("secrets" -> fopts)
  }

  private def memchain(values: (String, Object)*): JList[Object] =
    jlist(jmap("kind" -> "memory", "values" -> jmap(values*)))

  private def secretsFeatureOf(client: UnivecSDK): SecretsFeature = {
    val it = client.features.iterator()
    while (it.hasNext) it.next() match {
      case sf: SecretsFeature => return sf
      case _ =>
    }
    null
  }

  // Build the client and ADOPT the feature via `extend` ONLY when the
  // generated config did not already install it - when this SDK was
  // generated with `secrets` model-active the ordinary factory path builds
  // the instance, and adding a second via extend would DOUBLE the feature:
  // two transport wraps, two resolutions, and a token purchase the
  // assertions could not account for. (go's withSecrets and py's
  // _has_feature guard the same way.)
  private def withSecrets(build: Boolean => UnivecSDK): UnivecSDK = {
    val client = build(false)
    if (null == secretsFeatureOf(client)) build(true) else client
  }

  private def secretsClient(w: Wire, extra: (String, Object)*): UnivecSDK =
    withSecrets { extend =>
      val opts = sdkopts(w, extra*)
      if (extend) opts.put("extend", jlist(new SecretsFeature()))
      new UnivecSDK(opts)
    }

  private def testModeClient(w: Wire, extra: (String, Object)*): UnivecSDK =
    withSecrets { extend =>
      val opts = sdkopts(w, extra*)
      if (extend) opts.put("extend", jlist(new SecretsFeature()))
      UnivecSDK.testSDK(null, opts)
    }

  // ---- driving real entity operations --------------------------------------
  //
  // Entity names are unknown to a TEMPLATE, so the accessors are found by
  // SHAPE: a one-argument method taking a Map and returning an SdkEntity is
  // what MainEntity emits for every entity. Each op's own outcome is
  // irrelevant (no seeded data, a scripted response); an op the API does not
  // define fails before it reaches the transport, which is why several may
  // need driving.

  private def entities(client: UnivecSDK): List[SdkEntity] = {
    val out = ListBuffer.empty[SdkEntity]
    for (m <- client.getClass.getMethods) {
      if (1 == m.getParameterCount &&
        classOf[JMap[_, _]].isAssignableFrom(m.getParameterTypes()(0)) &&
        classOf[SdkEntity].isAssignableFrom(m.getReturnType)) {
        try m.invoke(client, Array[Object](null)*) match {
          case e: SdkEntity => out += e
          case _ =>
        }
        catch { case _: Throwable => }
      }
    }
    out.toList
  }

  // Drive entity ops until `stop` reports the state the case is waiting for.
  // Returns the last error thrown by an op, which is where a fail-closed
  // refusal surfaces on the entity path.
  private def driveUntil(client: UnivecSDK, stop: () => Boolean): (Boolean, String) = {
    var lasterr = ""
    var done = false
    // A plain while, not a for-comprehension: a `return` out of a
    // for-comprehension is a NON-LOCAL return, which scala 3 has deprecated.
    val ops = entities(client).flatMap(ent => List(() => ent.list(null, null), () => ent.load(null, null)))
    var index = 0
    while (!done && index < ops.length) {
      try ops(index)()
      catch { case err: Throwable => lasterr = errtext(err) }
      if (stop()) done = true
      index += 1
    }
    (done, lasterr)
  }

  // An op's failure, with its causes: an SdkError names the operation and
  // carries the underlying refusal beneath it.
  private def errtext(err: Throwable): String = {
    val out = new StringBuilder()
    var cur: Throwable = err
    var depth = 0
    while (cur != null && depth < 8) {
      out.append(String.valueOf(cur.getMessage)).append(" | ")
      cur = cur.getCause
      depth += 1
    }
    out.toString
  }

  // Drive until ONE request reaches the recorder.
  private def driveOneCall(client: UnivecSDK, w: Wire): Boolean = {
    val before = w.api().length
    driveUntil(client, () => before < w.api().length)._1
  }

  // ---- providers written in code -------------------------------------------

  final class CodeProvider(
    val answer: String => Option[String],
    val label: String = "custom",
  ) extends com.voxgig.sekreto.Provider {
    val asked = new ArrayList[String]()
    override def lookup(name: String): Option[String] = {
      asked.add(name)
      answer(name)
    }
    override def describe(): String = label + ":test"
  }

  private def broken(): CodeProvider =
    new CodeProvider(_ => throw new com.voxgig.sekreto.SekretoError("vault unreachable"), "broken")

  private def working(token: String): CodeProvider =
    new CodeProvider(name => if ("apikey" == name) Some(token) else None, "working")

  // =========================================================================
  // The feature-inactive baseline: bit-identical behaviour.

  private def testInactive(): Unit = {
    val client = UnivecSDK.testSDK(null, jmap("apikey" -> "OPTKEY01"))
    val fetchdef = client.prepare(jmap("path" -> "/"))
    val headers = fetchdef.get("headers").asInstanceOf[JMap[String, Object]]
    credentialIs("inactive.apikey", headers.get("authorization").asInstanceOf[String], "OPTKEY01")

    check("inactive.nofeature", null == secretsFeatureOf(client),
      "no model activation and no extend: the feature must not be installed")

    val bare = UnivecSDK.testSDK(null, null)
    val bareheaders = bare.prepare(jmap("path" -> "/"))
      .get("headers").asInstanceOf[JMap[String, Object]]
    check("inactive.noapikey", !bareheaders.containsKey("authorization"),
      "unexpected authorization header: " + bareheaders.get("authorization"))
  }

  // =========================================================================
  // The chain, driven through real entity operations.

  private def testOptionWins(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "apikey" -> "OPTKEY01",
      "feature" -> secretsOpts(memchain("APIKEY" -> "CHAINKEY01")))

    check("chain.optionwins.drive", driveOneCall(client, w), "no entity op reached the transport")
    if (w.api().nonEmpty) {
      credentialIs("chain.optionwins", w.authof(w.api().head), "OPTKEY01")
    }

    // The explicit option is a real STORE, not a special case: a directed
    // read names it like any other.
    val sf = secretsFeatureOf(client)
    check("chain.optionwins.feature", null != sf, "the extend seam did not install the feature")
    if (null != sf && null != sf.sekreto()) {
      eqs("chain.optionwins.store", "OPTKEY01",
        sf.sekreto().tryfrom("options", "apikey").getOrElse(""))
    }
  }

  private def testOmittedDefers(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "feature" -> secretsOpts(memchain("APIKEY" -> "CHAINKEY02")))

    // Before any op, nothing has been resolved.
    eqs("chain.omitted.unresolved", "", secretsFeatureOf(client).credential())

    check("chain.omitted.drive", driveOneCall(client, w), "no entity op reached the transport")
    if (w.api().nonEmpty) credentialIs("chain.omitted", w.authof(w.api().head), "CHAINKEY02")

    // Resolution happens AT THE TRANSPORT - the one seam every wire path
    // crosses - so the credential is on the wire, not merely resolved. It is
    // held in FEATURE STATE; the options map is never mutated, so it stays
    // safe to read from every concurrent operation.
    eqs("chain.omitted.state", "CHAINKEY02", secretsFeatureOf(client).credential())
    eqs("chain.omitted.optionsfrozen", "",
      client.optionsMap().get("apikey") match { case s: String => s; case _ => "" })
  }

  private def testCustomProvider(): Unit = {
    val w = new Wire()
    val prov = working("CUSTOM01")
    val client = secretsClient(w, "feature" -> secretsOpts(jlist(prov)))

    check("chain.custom.drive", driveOneCall(client, w), "no entity op reached the transport")
    if (w.api().nonEmpty) credentialIs("chain.custom", w.authof(w.api().head), "CUSTOM01")
    check("chain.custom.asked", !prov.asked.isEmpty && "apikey" == prov.asked.get(0),
      "the custom provider was asked " + prov.asked)
  }

  // A spec given as a plain MAP - what a JSON config supplies. The scala
  // sekreto port has no map-taking SpecOf, so SecretsFeature converts the map
  // to plugin's value model itself; a shape that converter mishandles would
  // be lost in silence, which is why it is pinned here.
  private def testSpecFromMap(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "feature" -> secretsOpts(jlist(jmap(
        "kind" -> "memory",
        "name" -> "config",
        "prefix" -> "CFG_",
        "values" -> jmap("CFG_APIKEY" -> "MAPPED01"),
      ))))

    check("chain.specmap.drive", driveOneCall(client, w), "no entity op reached the transport")
    if (w.api().nonEmpty) credentialIs("chain.specmap", w.authof(w.api().head), "MAPPED01")

    // Every field crossed: `name` made the store addressable, `prefix`
    // reached the provider (without it the value would not have been found).
    val sf = secretsFeatureOf(client)
    if (null != sf && null != sf.sekreto()) {
      eqs("chain.specmap.store", "MAPPED01",
        sf.sekreto().tryfrom("config", "apikey").getOrElse(""))
    }
  }

  private def testMissLeavesHeaderOff(): Unit = {
    val w = new Wire()
    val client = secretsClient(w, "feature" -> secretsOpts(memchain("OTHER" -> "x")))

    check("chain.miss.drive", driveOneCall(client, w), "no entity op reached the transport")
    if (w.api().nonEmpty) {
      check("chain.miss", !w.hasauth(w.api().head),
        "a chain MISS must fall through to an unauthenticated request, got header \"" +
          w.authof(w.api().head) + "\"")
    }
  }

  private def testAuthNullSuppresses(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "auth" -> null,
      "apikey" -> "OPTKEY01",
      "feature" -> secretsOpts(memchain("APIKEY" -> "CHAINKEY03")))

    check("chain.authnull.drive", driveOneCall(client, w), "no entity op reached the transport")
    if (w.api().nonEmpty) {
      check("chain.authnull", !w.hasauth(w.api().head),
        "auth null must suppress the credential, got header \"" + w.authof(w.api().head) + "\"")
    }

    // The suppression survives option validation rather than being replaced
    // by the optspec's default auth map.
    val opts = client.optionsMap()
    check("chain.authnull.survives", opts.containsKey("auth") && null == opts.get("auth"),
      "options.auth must stay a present null, got " + opts.get("auth"))
  }

  // =========================================================================
  // FAIL CLOSED. A provider MISS falls through; a provider ERROR must fail
  // the operation. Conflating them turns a broken vault into a silent
  // unauthenticated request.

  private def testFailClosedEntity(): Unit = {
    val prov = broken()
    val w = new Wire()
    val client = secretsClient(w, "feature" -> secretsOpts(jlist(prov)))

    // THE RULE, asserted first so a regression reports the leak itself.
    val (_, err) = driveUntil(client, () => !prov.asked.isEmpty)
    check("failclosed.entity.asked", !prov.asked.isEmpty,
      "the chain was never consulted - this case proves nothing")
    eqi("failclosed.entity.silent " + w.report(), 0, w.api().length)
    check("failclosed.entity.message", err.contains("vault unreachable"),
      "the operation must fail with the PROVIDER'S OWN error, got: " + err)

    // CONTROL, which makes that zero mean REFUSED rather than UNWIRED: the
    // same construction with a WORKING provider must reach the same
    // transport, once, carrying the credential.
    val cw = new Wire()
    val control = secretsClient(cw, "feature" -> secretsOpts(jlist(working("RAWKEY01"))))
    check("failclosed.entity.control.drive", driveOneCall(control, cw),
      "the control request never reached system.fetch, so this case cannot " +
        "observe a request going out at all")
    eqi("failclosed.entity.control.count", 1, cw.api().length)
    if (cw.api().nonEmpty) {
      credentialIs("failclosed.entity.control.auth", cw.authof(cw.api().head), "RAWKEY01")
    }
  }

  // THE RAW PATHS, which run NO feature hooks at all. If resolution lived in
  // a PreSpec hook these would send an unauthenticated request and never
  // notice; they are covered because resolution is at the TRANSPORT.
  private def testFailClosedRaw(): Unit = {
    val allow = jmap("op" -> "direct,graphql")

    // ---- direct()
    val w = new Wire()
    val client = secretsClient(w,
      "allow" -> allow,
      "feature" -> secretsOpts(jlist(broken())))
    val res = client.direct(jmap("path" -> "/thing"))

    eqi("failclosed.direct.silent " + w.report(), 0, w.api().length)
    check("failclosed.direct.refused", java.lang.Boolean.FALSE == res.get("ok"),
      "a broken chain must refuse the raw path fail-closed, got " + res)
    check("failclosed.direct.message",
      errtext(res.get("err").asInstanceOf[Throwable]).contains("vault unreachable"),
      "direct must report the PROVIDER'S OWN error, got: " + res.get("err"))

    // ---- graphql()
    val gw = new Wire()
    val gclient = secretsClient(gw,
      "allow" -> allow,
      "feature" -> secretsOpts(jlist(broken())))
    val gres = gclient.graphql("{ thing }", null, null)

    eqi("failclosed.graphql.silent " + gw.report(), 0, gw.api().length)
    check("failclosed.graphql.refused", java.lang.Boolean.FALSE == gres.get("ok"),
      "a broken chain must refuse graphql fail-closed, got " + gres)
    check("failclosed.graphql.message",
      errtext(gres.get("err").asInstanceOf[Throwable]).contains("vault unreachable"),
      "graphql must report the PROVIDER'S OWN error, got: " + gres.get("err"))

    // ---- CONTROL: the same construction, a working provider, one call each,
    // carrying the credential. Without this the two zeros above would also
    // hold for an SDK that never wires system.fetch at all.
    val cw = new Wire()
    val control = secretsClient(cw,
      "allow" -> allow,
      "feature" -> secretsOpts(jlist(working("RAWKEY02"))))

    val ok = control.direct(jmap("path" -> "/thing"))
    check("failclosed.direct.control.ok", java.lang.Boolean.TRUE == ok.get("ok"),
      "the control direct() failed: " + ok)
    eqi("failclosed.direct.control.count", 1, cw.api().length)
    if (cw.api().nonEmpty) {
      credentialIs("failclosed.direct.control.auth", cw.authof(cw.api().head), "RAWKEY02")
    }

    val gcw = new Wire()
    val gcontrol = secretsClient(gcw,
      "allow" -> allow,
      "feature" -> secretsOpts(jlist(working("RAWKEY03"))))
    gcontrol.graphql("{ thing }", null, null)
    eqi("failclosed.graphql.control.count", 1, gcw.api().length)
    if (gcw.api().nonEmpty) {
      credentialIs("failclosed.graphql.control.auth", gcw.authof(gcw.api().head), "RAWKEY03")
    }
  }

  // A chain that will not BUILD at all - an unknown provider kind, the shape
  // a typo or a plugin group the model did not select produces. Init cannot
  // fail construction the way ts's throwing init can, so the refusal has to
  // come from the transport gate; a feature that skipped wrapping on a failed
  // init would send every request unauthenticated instead, and no other case
  // here would notice.
  private def testFailClosedUnbuildableChain(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "allow" -> jmap("op" -> "direct"),
      "feature" -> secretsOpts(jlist(jmap("kind" -> "nosuchkind"))))

    val res = client.direct(jmap("path" -> "/thing"))

    eqi("failclosed.unbuildable.silent " + w.report(), 0, w.api().length)
    check("failclosed.unbuildable.refused", java.lang.Boolean.FALSE == res.get("ok"),
      "a chain that would not build must refuse, got " + res)
    check("failclosed.unbuildable.message",
      errtext(res.get("err").asInstanceOf[Throwable]).contains("nosuchkind"),
      "the refusal must name the unknown kind, got: " + res.get("err"))
  }

  // A failed resolution is NEVER kept: a transient vault outage must not
  // poison the client permanently.
  private def testTransientRecovery(): Unit = {
    var calls = 0
    val prov = new CodeProvider(_ => {
      calls += 1
      if (1 == calls) throw new com.voxgig.sekreto.SekretoError("vault unreachable")
      Some("RECOVERED01")
    }, "flaky")

    val w = new Wire()
    val client = secretsClient(w, "feature" -> secretsOpts(jlist(prov)))

    driveUntil(client, () => 0 < calls)
    eqi("recovery.firstsilent", 0, w.api().length)

    check("recovery.drive", driveOneCall(client, w), "the second op never reached the transport")
    if (w.api().nonEmpty) credentialIs("recovery.fresh", w.authof(w.api().head), "RECOVERED01")
  }

  // `cache: false` is documented as "every resolve asks the chain again", and
  // an uncached MISS after an earlier hit is a REVOCATION: the resolved value
  // must stop going out.
  private def testUncachedMissRetracts(): Unit = {
    var have = true
    var calls = 0
    val prov = new CodeProvider(_ => {
      calls += 1
      if (have) Some("REVOCABLE01") else None
    }, "revocable")

    val w = new Wire()
    val client = secretsClient(w,
      "feature" -> secretsOpts(jlist(prov), "cache" -> java.lang.Boolean.FALSE))

    check("uncached.drive", driveOneCall(client, w), "no entity op reached the transport")
    if (w.api().nonEmpty) credentialIs("uncached.first", w.authof(w.api().head), "REVOCABLE01")

    val asked = calls
    have = false
    check("uncached.drive2", driveOneCall(client, w), "the second op never reached the transport")
    check("uncached.reasked", asked < calls,
      "the chain was asked once and cached, despite cache: false")

    val last = w.api().last
    check("uncached.retracted", !w.hasauth(last) || "" == w.authof(last),
      "after the chain reports a miss, the retracted credential must not go " +
        "out; the wire saw \"" + w.authof(last) + "\"")
  }

  // A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
  // feature used to override from the layer above.
  //
  // DEFAULT caching here, which is the whole point: `cache: true` is about
  // holding a HIT, and keeping the settled resolution after a miss meant the
  // chain was never asked again for the life of the client. A secret
  // provisioned after startup (a mounted file, a vault policy granted a
  // minute late) was invisible forever, and the only workaround was giving
  // up hit caching entirely.
  private def testCachedMissIsReasked(): Unit = {
    var present = false
    var calls = 0
    val prov = new CodeProvider(_ => {
      calls += 1
      if (present) Some("LATEKEY01") else None
    }, "late")

    val w = new Wire()
    val client = secretsClient(w, "feature" -> secretsOpts(jlist(prov)))

    check("cachedmiss.drive", driveOneCall(client, w),
      "no entity op reached the transport")
    if (w.api().nonEmpty) {
      val first = w.api().head
      check("cachedmiss.nocred", !w.hasauth(first) || "" == w.authof(first),
        "the chain has nothing yet, so no credential should go out")
    }

    val asked = calls
    check("cachedmiss.asked", 0 < asked, "the chain was never asked")

    // The secret is provisioned while the client is live.
    present = true
    check("cachedmiss.drive2", driveOneCall(client, w),
      "the second op never reached the transport")

    check("cachedmiss.reasked", asked < calls,
      "the MISS was cached: a secret that appears later can never be picked up")
    if (w.api().nonEmpty) {
      credentialIs("cachedmiss.late", w.authof(w.api().last), "LATEKEY01")
    }
  }

  // The other half of the same rule: a HIT is still cached by default, so
  // the fix above must not turn every request into a chain walk.
  private def testCachedHitIsKept(): Unit = {
    var calls = 0
    val prov = new CodeProvider(_ => {
      calls += 1
      Some("STABLEKEY01")
    }, "counting")

    val w = new Wire()
    val client = secretsClient(w, "feature" -> secretsOpts(jlist(prov)))

    check("cachedhit.drive", driveOneCall(client, w),
      "no entity op reached the transport")
    check("cachedhit.drive2", driveOneCall(client, w),
      "the second op never reached the transport")

    eqi("cachedhit.once", 1, calls)
  }

  private def testSecretNameConfigurable(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "feature" -> secretsOpts(memchain("API_TOKEN" -> "TOKKEY01"), "name" -> "api.token"))

    check("name.drive", driveOneCall(client, w), "no entity op reached the transport")
    if (w.api().nonEmpty) credentialIs("name.configurable", w.authof(w.api().head), "TOKKEY01")
  }

  // The live Sekreto: arbitrary secrets and redaction, the scala spelling of
  // ts's sdk.secrets().
  private def testSekretoIsLive(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "feature" -> secretsOpts(memchain("APIKEY" -> "KEY01", "DB_PASSWORD" -> "dbpass01")))

    val sek = secretsFeatureOf(client).sekreto()
    check("sekreto.live", null != sek, "no live Sekreto instance")
    if (null != sek) {
      eqs("sekreto.get", "dbpass01", sek.get("db.password"))
      eqs("sekreto.redact", "the password is [redacted], keep it safe",
        sek.redact("the password is dbpass01, keep it safe"))
    }
  }

  // Every vendored provider MODULE, and the kinds it defines. The pairing is
  // the model's `plugin.<group>.def.scala` map read from the other side, and
  // it is written out here on purpose: a test that asked Config for the
  // mapping would be asking the thing under test.
  //
  // plugins/Httpjson.scala and plugins/Sigv4.scala are absent because they
  // define no kind - they are the two UNGROUPED helper files that ship with
  // the feature core whatever the model selects.
  private val PLUGINMODULES: List[(String, List[String])] = List(
    "Aws" -> List("awsparams", "awssecrets"),
    "Azuresecrets" -> List("azuresecrets"),
    "Boru" -> List("boru"),
    "Doppler" -> List("doppler"),
    "Gcpsecrets" -> List("gcpsecrets"),
    "Hashicorp" -> List("hashicorp"),
    "Infisical" -> List("infisical"),
    "Onepassword" -> List("onepassword"),
    "Secretspec" -> List("secretspec"),
  )

  // A kind no module defines and no model can select, for the negative
  // control. Deliberately not a plausible provider name.
  private val CONTROLKIND = "vocabulary-control-kind"

  // Did this SDK compile plugins/<file>.scala? A scala 3 top-level `val`
  // lives in the synthetic `<File>$package` class, so the classloader answers
  // for the FILE - which is what the generate-time plugin trim adds or
  // removes. Asked by name and not by reference: a direct mention of
  // `com.voxgig.sekreto.plugins.hashicorp` would stop this file compiling in
  // every tree the trim did its job on.
  private def moduleShipped(file: String): Boolean =
    try {
      Class.forName("com.voxgig.sekreto.plugins." + file + "$package",
        false, getClass.getClassLoader)
      true
    }
    catch { case _: Throwable => false }

  // Did the MODEL activate the feature in this SDK? Config's `feature` map is
  // built from the model's active features alone, so the key is present only
  // where an activation put it - which is exactly when the plugin trim ran.
  private def secretsInConfig(): Boolean =
    Config.sharedConfig().get("feature") match {
      case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]].containsKey("secrets")
      case _ => false
    }

  // THE PROVIDER VOCABULARY. Since sekreto retired its import-time registry a
  // kind not passed in `plugins` is unknown to that Sekreto, so an SDK whose
  // model selected plugin groups but whose Config failed to hand them over
  // would compile, ship every plugin module, and refuse every one of their
  // kinds at runtime while the built-in cases stayed green.
  //
  // THE EXPECTATION IS DERIVED FROM THE SHIPPED MODULES, NOT FROM CONFIG.
  // The first cut of this read Config.featurePlugins for both sides and
  // looped over it - so on a model selecting no plugin group the list was
  // empty, the loop ran zero times, and deleting the whole emission from
  // Config_scala left the suite green on the same score. Config is the thing
  // under test; it cannot also be the oracle.
  //
  // The independent oracle is the generate-time plugin trim. It deletes an
  // inactive group's FILES, so the set of provider modules compiled into
  // this SDK records what the model selected, and Config's list has to name
  // exactly their kinds - no more (a symbol the trim deleted is a build
  // break) and no fewer (a module whose kind never reaches the feature is
  // refused at runtime).
  private def testPluginVocabulary(): Unit = {
    // (1) The table below has to cover the whole vendored vocabulary, or a
    // kind added upstream would be invisible to every check under it.
    // KINDS.plugin is sekreto's own list, so it answers for upstream.
    val tabled = PLUGINMODULES.flatMap(_._2).toSet
    val untabled = com.voxgig.sekreto.KINDS.plugin.filterNot(tabled.contains)
    check("vocabulary.table", untabled.isEmpty,
      "sekreto ships provider kinds this test does not know about: " +
        untabled.mkString(", ") + " - add them to PLUGINMODULES, and to a " +
        "`plugin` group in model/feature/secrets.aon")

    val w = new Wire()
    val client = secretsClient(w, "feature" -> secretsOpts(memchain("APIKEY" -> "VOCAB01")))
    val sek = secretsFeatureOf(client).sekreto()
    check("vocabulary.live", null != sek, "no live Sekreto instance")
    if (null == sek) return

    // (2) CONTROL, both ways. Without these a green run below could mean
    // "catalog.has says yes to anything" or "the `plugins` seam is dead", and
    // on an SDK that selected no group there would be nothing else asserted
    // at all. So: the catalog must be able to say NO to a kind nothing
    // defines, and a definition handed to the SAME constructor parameter
    // Config.featurePlugins feeds must make it say YES.
    check("vocabulary.control.unknown", !sek.catalog.has(CONTROLKIND),
      "the catalog claims to know \"" + CONTROLKIND + "\", which nothing " +
        "defines - catalog.has cannot witness anything")

    val probe = new com.voxgig.sekreto.Sekreto(
      plugins = List(com.voxgig.sekreto.providerplugin(
        CONTROLKIND, _ => new CodeProvider(_ => None, CONTROLKIND))))
    check("vocabulary.control.handedin", probe.catalog.has(CONTROLKIND),
      "a definition passed in `plugins` did not reach the catalog - the seam " +
        "Config.featurePlugins feeds is dead, so every check here is vacuous")

    // (3) What Config actually emitted.
    val names = ListBuffer.empty[String]
    for (one <- Config.featurePlugins("secrets")) one match {
      case d: voxgig.plugin.Definition => names += d.name
      case other => fail("vocabulary.type", "not a plugin definition: " + other)
    }
    for (name <- names) {
      check("vocabulary." + name, sek.catalog.has(name),
        "the model selected the " + name + " plugin, but this SDK's Sekreto " +
          "does not know that kind - Config.featurePlugins is not reaching the feature")
      check("vocabulary.known." + name, tabled.contains(name),
        "Config declares a kind no vendored module defines: " + name)
    }

    // (4) THE SEAM. Both halves of the model are asserted, because the trim
    // that produces the oracle has a half for each: Main_scala excludes an
    // ACTIVE feature's inactive groups, and every group of a feature that is
    // itself off. Each branch names its own failure - a mismatch means
    // something different on either side.
    val shipped = PLUGINMODULES.filter(one => moduleShipped(one._1))
    val here = if (shipped.isEmpty) "(none)" else shipped.map(_._1).mkString(", ")
    val got = names.toList.sorted.mkString(",")

    if (secretsInConfig()) {
      eqs("vocabulary.matchesmodules", shipped.flatMap(_._2).sorted.mkString(","), got,
        "this SDK compiled the provider modules " + here + ", so " +
          "Config.featurePlugins must name exactly their kinds - it is the " +
          "model's plugin selection that put those modules here")
    }
    else {
      // The model never activated secrets, so it selected no provider kind.
      eqs("vocabulary.off.notrimmed", "", shipped.map(_._1).mkString(","),
        "this SDK's model left secrets off, so no provider client should have " +
          "reached it - Main_scala's inactive-feature plugin trim did not run")
      eqs("vocabulary.off.nodefs", "", got,
        "this SDK's model left secrets off, so Config.featurePlugins must " +
          "declare nothing for it")
    }
  }

  // The `env` built-in is LIVE. A JVM cannot set its own environment, so this
  // reads a variable that is already there rather than staging one.
  private def testEnvBuiltin(): Unit = {
    val path = System.getenv("PATH")
    if (null == path || path.isEmpty) return

    val w = new Wire()
    val client = secretsClient(w,
      "feature" -> secretsOpts(jlist(jmap("kind" -> "env")), "name" -> "path"))
    val sek = secretsFeatureOf(client).sekreto()
    eqs("env.builtin", path, if (null == sek) "" else sek.tryget("path").getOrElse(""))
  }

  // =========================================================================
  // The access-token exchange.

  private def exchangeOpts(extra: (String, Object)*): JMap[String, Object] = {
    val x = jmap("active" -> java.lang.Boolean.TRUE)
    extra.foreach { case (k, v) => x.put(k, v) }
    secretsOpts(
      memchain("REFRESH_TOKEN" -> "REFRESH01"),
      "name" -> "refresh_token",
      "exchange" -> x)
  }

  private def testExchangeBuysAndRetries(): Unit = {
    val w = new Wire()
    // First API call is refused, the retry succeeds.
    w.apistatus = List(401, 200)

    val client = secretsClient(w, "allow" -> jmap("op" -> "direct"), "feature" -> exchangeOpts())
    val res = client.direct(jmap("path" -> "/thing"))

    eqi("exchange.purchases", 2, w.token().length)
    eqi("exchange.retried", 2, w.api().length)
    if (2 <= w.api().length) {
      credentialIs("exchange.first", w.authof(w.api()(0)), "ACCESS01")
      // The retry must carry the NEW token, not the spent one.
      credentialIs("exchange.retry", w.authof(w.api()(1)), "ACCESS02")
    }
    check("exchange.result", java.lang.Boolean.TRUE == res.get("ok"),
      "the caller sees the successful retry, got " + res)
  }

  private def testExchangeOnePurchaseManyRequests(): Unit = {
    val w = new Wire()
    val client = secretsClient(w, "allow" -> jmap("op" -> "direct"), "feature" -> exchangeOpts())

    client.direct(jmap("path" -> "/one"))
    client.direct(jmap("path" -> "/two"))
    client.direct(jmap("path" -> "/three"))

    eqi("exchange.onepurchase", 1, w.token().length)
    eqi("exchange.threecalls", 3, w.api().length)
  }

  // The body is MARSHALLED, never concatenated: a refresh token carrying a
  // quote, backslash or newline must arrive as that literal value.
  private def testExchangeBodyIsJson(): Unit = {
    val tricky = "re\"fresh\\to\nken"
    val w = new Wire()
    val client = secretsClient(w,
      "allow" -> jmap("op" -> "direct"),
      "feature" -> exchangeOpts("refresh" -> tricky))

    client.direct(jmap("path" -> "/thing"))

    check("exchange.body.purchased", 1 <= w.token().length, "no token purchase was made")
    if (w.token().nonEmpty) {
      val body = w.token().head.get("body") match { case s: String => s; case _ => "" }
      val parsed = Json.parse(body) match {
        case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
        case _ => null
      }
      check("exchange.body.json", null != parsed,
        "the exchange body must be valid JSON, got: " + body)
      if (null != parsed) {
        eqs("exchange.body.literal", tricky,
          parsed.get("refresh_token") match { case s: String => s; case _ => "" })
      }
    }
  }

  // An explicit exchange.refresh takes the first seat in the chain, so it
  // wins by sekreto's own first-hit rule.
  private def testExchangeExplicitRefreshWins(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "allow" -> jmap("op" -> "direct"),
      "feature" -> exchangeOpts("refresh" -> "EXPLICIT01"))

    client.direct(jmap("path" -> "/thing"))

    if (w.token().nonEmpty) {
      val body = w.token().head.get("body") match { case s: String => s; case _ => "" }
      check("exchange.explicitrefresh", body.contains("EXPLICIT01"),
        "an explicit exchange.refresh must win over the chain, body was: " + body)
    } else {
      fail("exchange.explicitrefresh", "no token purchase was made")
    }
  }

  // A refusal of a deliberately unauthenticated request is not an expired
  // token: buying one and retrying would transmit exactly the credential the
  // caller suppressed.
  private def testExchangeAuthNullNotRetried(): Unit = {
    val w = new Wire()
    w.apistatus = List(401)

    val client = secretsClient(w,
      "auth" -> null,
      "allow" -> jmap("op" -> "direct"),
      "feature" -> exchangeOpts())

    client.direct(jmap("path" -> "/thing"))

    eqi("exchange.authnull.noretry", 1, w.api().length)
    if (w.api().nonEmpty) {
      check("exchange.authnull.nocred", !w.hasauth(w.api().head),
        "no credential may be sent when auth is suppressed, got \"" +
          w.authof(w.api().head) + "\"")
    }

    // AND NO PURCHASE. resolve() runs before withrefresh's suppression
    // check, so the refresh token used to go to the token endpoint in a
    // request body even here. Stopping the retry does not unsend it, and
    // only the token endpoint can see this.
    eqi("exchange.authnull.nobuy", 0, w.token().length)
  }

  // No refresh token anywhere is an ERROR, not an unauthenticated call.
  private def testExchangeNoRefresh(): Unit = {
    val w = new Wire()
    val client = secretsClient(w,
      "allow" -> jmap("op" -> "direct"),
      "feature" -> secretsOpts(
        memchain("SOMETHINGELSE" -> "x"),
        "name" -> "refresh_token",
        "exchange" -> jmap("active" -> java.lang.Boolean.TRUE)))

    val res = client.direct(jmap("path" -> "/thing"))

    eqi("exchange.norefresh.silent", 0, w.api().length)
    check("exchange.norefresh.refused", java.lang.Boolean.FALSE == res.get("ok"),
      "an empty chain must refuse rather than send unauthenticated, got " + res)
  }

  // TEST MODE BUYS NOTHING and needs no token endpoint.
  private def testExchangeTestMode(): Unit = {
    val w = new Wire()
    val client = testModeClient(w, "feature" -> exchangeOpts())

    driveUntil(client, () => "" != secretsFeatureOf(client).credential())

    eqi("exchange.testmode.noio", 0, w.calls.size())
    eqs("exchange.testmode.token", "test-access_token", secretsFeatureOf(client).credential())
  }

  // =========================================================================

  def main(args: Array[String]): Unit = {
    val cases: List[(String, () => Unit)] = List(
      "inactive" -> testInactive,
      "optionWins" -> testOptionWins,
      "omittedDefers" -> testOmittedDefers,
      "customProvider" -> testCustomProvider,
      "specFromMap" -> testSpecFromMap,
      "missLeavesHeaderOff" -> testMissLeavesHeaderOff,
      "authNullSuppresses" -> testAuthNullSuppresses,
      "failClosedEntity" -> testFailClosedEntity,
      "failClosedRaw" -> testFailClosedRaw,
      "failClosedUnbuildableChain" -> testFailClosedUnbuildableChain,
      "transientRecovery" -> testTransientRecovery,
      "uncachedMissRetracts" -> testUncachedMissRetracts,
      "cachedMissIsReasked" -> testCachedMissIsReasked,
      "cachedHitIsKept" -> testCachedHitIsKept,
      "secretNameConfigurable" -> testSecretNameConfigurable,
      "sekretoIsLive" -> testSekretoIsLive,
      "pluginVocabulary" -> testPluginVocabulary,
      "envBuiltin" -> testEnvBuiltin,
      "exchangeBuysAndRetries" -> testExchangeBuysAndRetries,
      "exchangeOnePurchaseManyRequests" -> testExchangeOnePurchaseManyRequests,
      "exchangeBodyIsJson" -> testExchangeBodyIsJson,
      "exchangeExplicitRefreshWins" -> testExchangeExplicitRefreshWins,
      "exchangeAuthNullNotRetried" -> testExchangeAuthNullNotRetried,
      "exchangeNoRefresh" -> testExchangeNoRefresh,
      "exchangeTestMode" -> testExchangeTestMode,
    )

    for ((name, body) <- cases) {
      try body()
      catch { case err: Throwable => fail(name, "threw " + errtext(err)) }
    }

    println("SECRETS PASS " + npass + " FAIL " + failures.size())
    val it = failures.iterator()
    while (it.hasNext) println("  FAIL " + it.next())
    if (!failures.isEmpty) System.exit(1)
  }
}
