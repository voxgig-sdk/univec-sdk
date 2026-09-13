package SCALAPACKAGE.feature

import java.util.{LinkedHashMap, List => JList, Map => JMap}
import java.util.function.{BiFunction, Supplier}

import scala.collection.immutable.ListMap
import scala.collection.mutable.ListBuffer

import SCALAPACKAGE.core.{Config, Context, FetcherFn, SdkClient}
import SCALAPACKAGE.utility.Fetcher
import SCALAPACKAGE.utility.struct.Struct

import com.voxgig.sekreto.{Provider, ProviderSpec, Sekreto, SekretoError}
import voxgig.plugin.{Definition, VBool, VList, VMap, VNull, VNum, VStr, Value}

// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The scala port of
// tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, and
// structurally the GO port (tm/go/feature/secrets_feature.go), for the two
// reasons below.
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider - a `memory` store named `options` - so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
//
// WHY THE CREDENTIAL LIVES IN FEATURE STATE. The ts reference writes the
// resolved value into the client's live options map, where the synchronous
// prepareAuth already looks. Scala cannot: prepareAuth calls
// `ctx.client.optionsMap()` (utility/Prepare.scala), which deep-clones the
// options map on every request from whatever thread the caller is on, so a
// feature mutating that map would race every concurrent operation. With the
// feature as sole holder, the options map is FROZEN after construction and
// every read stays safe; the header the wire sees is identical, because the
// transport wrapper below rewrites it from this value exactly the way
// prepareAuth builds it.
//
// WHY RESOLUTION HAPPENS AT THE TRANSPORT SEAM. `direct()` and `graphql()`
// run NO feature hooks at all (core/SdkClient.scala) - they go straight from
// prepare() to `utility.fetcher`. A PreSpec hook would leave both raw paths
// sending unauthenticated requests and never notice. The transport is the
// ONE seam every wire path crosses - entity ops (utility/Make.scala's
// makeRequest), direct, graphql and the exchange retries alike - so
// resolving there covers all of them with one rule.
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
// vault never degrades into an unauthenticated request. The wrapper refuses
// to call `inner` while resolution stands failed, and the SekretoError
// travels out as the operation's own error (rawRequest and makeRequest both
// catch a RuntimeException from the fetcher).
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What the
// chain resolves is then a REFRESH token, which buys a short-lived ACCESS
// token from a token endpoint (`exchange.path`, relative to options.base);
// the access token is what every request carries, and when a response status
// in `exchange.statuses` (401) says it is spent the wrapper buys another and
// retries the same request once. Test mode buys nothing and answers with a
// deterministic fake token.
class SecretsFeature extends BaseFeature("secrets", "0.1.0", true) {

  private var client: SdkClient = null

  // The LIVE options map (root ctx options). READ ONLY: this feature never
  // writes it - see the class note.
  private var liveopts: JMap[String, Object] = null

  private var secretname: String = "apikey"
  private var docache: Boolean = true
  private var sek: Sekreto = null

  // A chain that would not build. Held rather than thrown, because init
  // cannot fail construction the way ts's throwing init can; the transport
  // gate below refuses to send instead, which keeps a misconfigured chain
  // fail-closed rather than silently unauthenticated.
  private var initerr: RuntimeException = null

  // Exchange config, normalised once at init. `xactive` false means off, so
  // every later decision is one boolean rather than a repeated option read.
  private var xactive: Boolean = false
  private var xpath: String = "auth/token"
  private var xmethod: String = "POST"
  private var xrequest: String = "refresh_token"
  private var xresponse: String = "access_token"
  private var xstatuses: List[Int] = List(401)
  private var xretries: Int = 1

  // The refresh credential the chain resolved, for every later purchase.
  private var refresh: String = ""

  // The RESOLVED credential, injected into each request at the transport
  // seam and never written into the shared options map.
  private var cred: String = ""

  // Has a SUCCESSFUL resolution been kept? Only ever set when caching is on:
  // `cache: false` means every resolve asks the chain again, and a FAILURE
  // is never kept at all, so a transient vault outage cannot poison the
  // client permanently - the next operation asks the chain again.
  private var settled: Boolean = false

  // Concurrency: go shares one in-flight resolution over a channel; the
  // scala pipeline is blocking throughout, so the same contract is reached
  // by BLOCKING on one monitor - concurrent callers wait for the attempt in
  // flight and then see its result, instead of each opening their own. The
  // monitor is reentrant, which is what lets resolveonce() buy a token
  // through the same lock the retry path takes.
  private val lock = new Object()

  // The LIVE Sekreto instance, for callers who want arbitrary secrets or
  // redaction (the scala spelling of ts's public sekreto() accessor). Never
  // a clone: sekreto holds provider state that has to stay live to be worth
  // anything.
  def sekreto(): Sekreto = this.sek

  // The resolved credential (empty when none) - the state the transport
  // injects. Tests and callers read it here rather than from the options
  // map, which this feature never mutates.
  def credential(): String = lock.synchronized { this.cred }

  // Sync by feature contract: build the chain, never look anything up here.
  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.liveopts = ctx.options
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) return

    this.secretname = FeatureOptions.foptStr(options, "name", "apikey")
    this.docache = FeatureOptions.foptBool(options, "cache", true)

    val xopts = FeatureOptions.foptMap(options, "exchange")
    if (FeatureOptions.foptBool(xopts, "active", false)) {
      this.xactive = true
      this.xpath = FeatureOptions.foptStr(xopts, "path", "auth/token")
      this.xmethod = FeatureOptions.foptStr(xopts, "method", "POST")
      this.xrequest = FeatureOptions.foptStr(xopts, "request", "refresh_token")
      this.xresponse = FeatureOptions.foptStr(xopts, "response", "access_token")
      this.xretries = FeatureOptions.foptInt(xopts, "retries", 1)

      val statuses = ListBuffer.empty[Int]
      val slist = FeatureOptions.foptList(xopts, "statuses")
      if (slist != null) {
        val sit = slist.iterator()
        while (sit.hasNext) sit.next() match {
          case n: java.lang.Number => statuses += n.intValue()
          case _ =>
        }
      }
      if (statuses.nonEmpty) this.xstatuses = statuses.toList
    }

    // The explicit credential, when set, is the first store in the chain.
    //
    // WHICH option that is depends on the exchange. Without one, the secret
    // being resolved IS the credential the transport sends, so `apikey` is
    // it. With one, the secret is a REFRESH token and `apikey` means the
    // opposite thing - an access token the caller already holds - so the
    // explicit seat belongs to `exchange.refresh`, and apikey is left alone
    // to serve as the starting access token (see resolveonce).
    val explicit =
      if (!this.xactive) optstr(this.liveopts, "apikey")
      else FeatureOptions.foptStr(xopts, "refresh", "")

    // Widened to Any: an entry sekreto cannot use is handed to it anyway, so
    // the refusal is SEKRETO'S own ("not a provider or a provider spec"),
    // naming the entry. Dropping it here would leave a chain quietly shorter
    // than the one the caller wrote.
    val entries = ListBuffer.empty[Any]

    if ("" != explicit) {
      try
        entries += ProviderSpec(
          kind = "memory",
          name = Some("options"),
          values = Some(Map(com.voxgig.sekreto.envkey(this.secretname, None) -> explicit)),
        )
      catch {
        // An unusable secret NAME. Not fatal here: the same name is about to
        // be asked of the chain, where checkname raises it again and the
        // transport gate turns it into a refusal.
        case _: RuntimeException =>
      }
    }

    val plist = FeatureOptions.foptList(options, "providers")
    if (plist != null) {
      val pit = plist.iterator()
      while (pit.hasNext) pit.next() match {
        case spec: ProviderSpec => entries += spec
        case prov: Provider => entries += prov
        case m: JMap[_, _] =>
          // A spec given as a plain map - what a JSON config supplies. The
          // scala sekreto port has no map-taking SpecOf, so the map is
          // converted to plugin's value model and read back by specof, the
          // same function a plugin's own `define` uses.
          try entries += com.voxgig.sekreto.specof(tovalue(m.asInstanceOf[JMap[String, Object]]))
          catch { case err: RuntimeException => if (null == this.initerr) this.initerr = err }
        case other => entries += other
      }
    }

    // The plugin DEFINITIONS the model selected for this feature, emitted by
    // Config from the catalogue's active `plugin.def` entries. Upstream
    // sekreto's contract since the registry was retired: a kind not passed in
    // `plugins` is unknown to this Sekreto, so the model's choice of plugin
    // groups IS the SDK's provider vocabulary. Config types the list as
    // List[Any] so core never names a vendored type.
    val plugs = ListBuffer.empty[Definition]
    val dit = Config.featurePlugins(this.name).iterator
    while (dit.hasNext) dit.next() match {
      case one: Definition => plugs += one
      case _ =>
    }

    try
      this.sek = new Sekreto(
        providers = entries.toList.asInstanceOf[List[Provider | ProviderSpec]],
        plugins = plugs.toList,
        docache = this.docache,
      )
    catch { case err: RuntimeException => if (null == this.initerr) this.initerr = err }

    // Wrap the transport UNCONDITIONALLY, once the feature is active.
    //
    // Not only when exchanging, and not only when the chain built: the
    // fail-closed gate needs this seam precisely when init went wrong, and a
    // wrapper installed only on the happy path would let a client whose
    // chain refused to build send every request unauthenticated - the one
    // outcome this feature exists to prevent. (This is a DELIBERATE
    // divergence from the go port, whose Init returns before wrapping when
    // sekreto.New fails, so `initerr` is never consulted and a client with an
    // unbuildable chain sends unauthenticated. SecretsTestMain's
    // failClosedUnbuildableChain case pins the scala behaviour.)
    val inner: FetcherFn = ctx.utility.fetcher
    ctx.utility.fetcher = (ctx2, url, fetchdef) => transport(ctx2, url, fetchdef, inner)
  }

  // ---- the transport seam -------------------------------------------------

  private def transport(
    ctx: Context,
    url: String,
    fetchdef: JMap[String, Object],
    inner: FetcherFn,
  ): Object = {
    // Fail-closed, at the ONE seam every wire path crosses. A provider ERROR
    // refuses the request WITH THE PROVIDER'S OWN error - never an
    // unauthenticated send.
    if (this.initerr != null) throw this.initerr
    resolve()

    // Inject the resolved credential into THIS request's header. The header
    // was built by prepareAuth from the options apikey; the chain-resolved
    // value lives in feature state instead, so the wrapper writes it here -
    // same construction, same suppression rules - and the shared options map
    // stays untouched.
    val token = credential()
    if ("" != token) reauth(fetchdef, token)

    if (!this.xactive) inner(ctx, url, fetchdef)
    else withrefresh(ctx, url, fetchdef, inner)
  }

  // One resolution, shared by every concurrent caller. A settled HIT is
  // kept only when caching is on; a FAILURE is never kept, so the next
  // operation asks the chain again.
  //
  // A MISS is not kept either, however caching is set. That rule is
  // sekreto's, not this feature's: `A miss is never cached: the next read
  // asks again`, in sekreto's own source. Keeping a settled miss here would
  // override that from the layer above, and a secret provisioned after
  // startup - a mounted file, a policy granted a minute late - would never
  // be picked up for the life of the client. `cache` is about caching a
  // HIT; it was never a promise to keep saying no.
  private def resolve(): Unit = lock.synchronized {
    if (!this.settled) {
      val hit = resolveonce()
      if (this.docache && hit) this.settled = true
    }
  }

  // Resolve once, reporting whether a credential came out of it. That
  // boolean is the whole of what resolve() needs to tell a cacheable HIT
  // from a miss it must not keep.
  private def resolveonce(): Boolean = {
    if (this.sek == null) return false

    // tryget returns None for a MISS and RAISES for an ERROR. That is the
    // whole miss-vs-error rule, and it is sekreto's, not this feature's.
    val found = this.sek.tryget(this.secretname)

    if (!this.xactive) {
      // An UNCACHED miss after an earlier hit is a revocation: the chain now
      // says no provider has the secret, so the resolved value must not keep
      // going out on the wire. (An explicit apikey OPTION is never lost
      // here - it seats FIRST in the chain as a memory provider, so the
      // chain HITS while one is set and this branch is unreachable.)
      this.cred = found.getOrElse("")
      return found.isDefined
    }

    // Exchanging: what the chain resolved is the REFRESH token, kept for
    // every later purchase. A miss is not fatal here - an explicit `apikey`
    // may already hold a usable access token, and the API is what gets to
    // say whether it does.
    this.refresh = found.getOrElse("")

    if ("" == this.cred) this.cred = optstr(this.liveopts, "apikey")

    // A starting access token was supplied. Spend it: if it is stale the API
    // answers with an expiry status and the wrapper buys another, which is
    // the same path expiry takes anyway.
    if ("" != this.cred) return true

    // `auth: null` is the documented way to send NO credential, and a
    // purchase is a credential-bearing call: the refresh token goes to the
    // token endpoint in the request body. withrefresh honours suppression
    // for the RETRY, but it runs after this - by then the refresh token has
    // already left the process, and no later check can call it back. The
    // suppression has to be honoured here, before the first purchase, or it
    // only ever half-held.
    if (this.liveopts == null || this.liveopts.get("auth") == null) return false

    buyonce()

    true
  }

  // Buy a token and try the request again when the API says the current one
  // is spent.
  //
  // The retry rewrites the authorization header IN PLACE on the fetchdef,
  // because the header was built by the synchronous prepareAuth before this
  // request left and it carries the token that just failed. Rebuilt the way
  // prepareAuth builds it, from the same options auth.prefix, so the two
  // cannot drift.
  private def withrefresh(
    ctx: Context,
    url: String,
    fetchdef: JMap[String, Object],
    inner: FetcherFn,
  ): Object = {
    // `auth: null` is the documented way to send NO credential, and
    // prepareAuth honours it by removing the header. A refusal of a
    // deliberately unauthenticated request is not an expired token and
    // cannot be fixed by buying one - retrying would transmit exactly the
    // credential the caller suppressed.
    if (this.liveopts == null || this.liveopts.get("auth") == null) {
      return inner(ctx, url, fetchdef)
    }

    var attempt = 0
    while (true) {
      // The credential THIS attempt goes out with, captured before it
      // leaves: it is what tells a stale refusal apart from a fresh one.
      val used = credential()

      val res = inner(ctx, url, fetchdef)

      if (attempt >= this.xretries || !spent(res)) return res

      // Another request may have bought a token while this one was in
      // flight. Spend what is current before buying: a second exchange for a
      // token that is already fresh is wasted, and on a provider that
      // invalidates the previous credential on issuance it breaks the first
      // request's own retry.
      var token: String = null
      lock.synchronized {
        val current = this.cred
        if ("" != current && current != used) token = current
        else {
          try token = buyonce()
          catch {
            // The purchase failed: answer with the API's own refusal rather
            // than this one. The caller asked for data, and the refusal is
            // the more useful of the two - the exchange error is a symptom.
            case _: RuntimeException => token = null
          }
        }
      }

      if (token == null) return res

      reauth(fetchdef, token)
      attempt += 1
    }

    null
  }

  private def spent(res: Object): Boolean = {
    val status = FeatureOptions.fresStatus(res)
    if (0 > status) false else this.xstatuses.contains(status)
  }

  // Write the credential the way prepareAuth writes it. CALLED UNDER NO
  // LOCK: it touches this request's own fetchdef and reads the frozen
  // options map, neither of which is shared mutable state.
  private def reauth(fetchdef: JMap[String, Object], token: String): Unit = {
    if (fetchdef == null) return
    val headers = fetchdef.get("headers") match {
      case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
      case _ => null
    }
    if (headers == null) return

    // Suppressed auth means NO header, the same answer prepareAuth gives.
    // Reached defensively on the exchange path - withrefresh does not retry
    // at all when auth is null - but this is the function that writes the
    // credential, so it is where the rule has to hold.
    val rawauth = if (this.liveopts == null) null else this.liveopts.get("auth")
    rawauth match {
      case authmap: JMap[_, _] =>
        val prefix = authmap.asInstanceOf[JMap[String, Object]].get("prefix") match {
          case s: String => s
          case _ => ""
        }
        if ("" == prefix) headers.put("authorization", token)
        else headers.put("authorization", prefix + " " + token)
      case _ => headers.remove("authorization")
    }
  }

  // ---- the access-token exchange -----------------------------------------

  // Buy an access token with the refresh token, and publish it. ALWAYS
  // called holding `lock`, which is what makes concurrent expiries share one
  // purchase: the second caller blocks, then finds a credential that differs
  // from the one it spent and reuses it (see withrefresh).
  private def buyonce(): String = {
    // TEST MODE BUYS NOTHING. The test feature replaces the transport so no
    // request leaves the process; an exchange here would be the one HTTP
    // call it could not stop, and it would need a live token endpoint for a
    // suite whose whole point is not needing one. A deterministic,
    // obviously-fake token instead - the same answer makeOptions gives a
    // required server variable, for the same reason.
    if ("live" != this.client.mode) {
      this.cred = "test-" + this.xresponse
      return this.cred
    }

    if ("" == this.refresh) {
      throw new SekretoError(
        "secrets: no refresh token: the provider chain has no '" +
          this.secretname + "', and feature.secrets.exchange.refresh is unset")
    }

    // The token endpoint is RELATIVE to the base, which already carries
    // whatever account or tenant segment the server URL declares.
    val base = optstr(this.liveopts, "base").replaceAll("/+$", "")
    val url = base + "/" + this.xpath.replaceAll("^/+", "")

    // The body is MARSHALLED, never concatenated: a refresh token (or a
    // configured request-field name) carrying a quote, backslash or newline
    // must arrive as that literal value, not as malformed JSON.
    val bodymap = new LinkedHashMap[String, Object]()
    bodymap.put(this.xrequest, this.refresh)
    val flags = new LinkedHashMap[String, Object]()
    flags.put("indent", java.lang.Integer.valueOf(0))

    val headers = new LinkedHashMap[String, Object]()
    headers.put("content-type", "application/json")

    val fetchdef = new LinkedHashMap[String, Object]()
    fetchdef.put("method", this.xmethod)
    fetchdef.put("headers", headers)
    fetchdef.put("body", Struct.jsonify(bodymap, flags))

    val res = exchangefetch(url, fetchdef)
    if (res == null) {
      throw new SekretoError("secrets: token exchange failed: no response from " + url)
    }

    val status = res.get("status") match {
      case n: java.lang.Number => n.intValue()
      case _ => 0
    }
    if (200 > status || 300 <= status) {
      throw new SekretoError(
        "secrets: token exchange failed: " + status + " from " + url)
    }

    val body = res.get("json") match {
      case sup: Supplier[_] => sup.asInstanceOf[Supplier[Object]].get()
      case _ => res.get("body")
    }

    val token = body match {
      case m: JMap[_, _] =>
        m.asInstanceOf[JMap[String, Object]].get(this.xresponse) match {
          case s: String => s
          case _ => ""
        }
      case _ => ""
    }

    if ("" == token) {
      throw new SekretoError(
        "secrets: token exchange returned no '" + this.xresponse +
          "' field from " + url)
    }

    this.cred = token
    token
  }

  // Deliberately NOT the SDK transport. The transport is what this feature
  // wraps, and sending the token request back through it would recurse on
  // the first expiry - and would route the exchange through the test mock,
  // which knows nothing about it. `system.fetch` when the caller supplied
  // one, else the platform fetcher directly: Fetcher.defaultHttpFetch
  // already answers in the {status, headers, json} shape the seam promises
  // and, unlike Fetcher.fetcher, is gated on neither mode nor the test
  // feature.
  private def exchangefetch(
    url: String,
    fetchdef: JMap[String, Object],
  ): JMap[String, Object] = {
    var sysfetch: Object = null
    if (this.liveopts != null) {
      sysfetch = Struct.getpath(this.liveopts, java.util.List.of("system", "fetch"))
      if (sysfetch eq Struct.UNDEF) sysfetch = null
    }

    sysfetch match {
      case bf: BiFunction[_, _, _] =>
        bf.asInstanceOf[BiFunction[String, JMap[String, Object], Object]]
          .apply(url, fetchdef) match {
            case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
            case _ => null
          }
      case _ => Fetcher.defaultHttpFetch(url, fetchdef)
    }
  }

  // ---- support ------------------------------------------------------------

  private def optstr(map: JMap[String, Object], key: String): String = {
    if (map == null) return ""
    map.get(key) match {
      case s: String => s
      case _ => ""
    }
  }

  // A java.util value tree as voxgig/plugin's value model, so `specof` can
  // read a provider spec that arrived as a plain map. The scala sekreto port
  // has no map-taking SpecOf of its own (go does), and this is the whole of
  // the gap: nothing here interprets a spec, it only changes its
  // representation.
  private def tovalue(value: Object): Value = value match {
    case null => VNull
    case s: String => VStr(s)
    case b: java.lang.Boolean => VBool(b.booleanValue())
    case n: java.lang.Number => VNum(n.doubleValue())
    case m: JMap[_, _] =>
      var out = ListMap.empty[String, Value]
      val it = m.asInstanceOf[JMap[Object, Object]].entrySet().iterator()
      while (it.hasNext) {
        val e = it.next()
        out = out.updated(String.valueOf(e.getKey), tovalue(e.getValue))
      }
      VMap(out)
    case l: JList[_] =>
      val out = ListBuffer.empty[Value]
      val it = l.asInstanceOf[JList[Object]].iterator()
      while (it.hasNext) out += tovalue(it.next())
      VList(out.toList)
    // Anything else is not part of the spec vocabulary (which is strings,
    // numbers, booleans and maps). Stringified rather than dropped, so a
    // wrong-typed field is rejected by the provider that reads it instead of
    // silently reading as absent.
    case other => VStr(String.valueOf(other))
  }
}
