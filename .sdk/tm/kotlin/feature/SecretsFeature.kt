package KOTLINPACKAGE.feature

import java.util.concurrent.locks.ReentrantLock
import java.util.function.BiFunction
import java.util.function.Supplier

import kotlin.concurrent.withLock

import KOTLINPACKAGE.core.Config
import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.SdkClient
import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.ProviderSpec
import KOTLINPACKAGE.feature.secrets.sekreto.Sekreto
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.envkey
import KOTLINPACKAGE.feature.secrets.sekreto.specof
import KOTLINPACKAGE.feature.secrets.sekreto.Json as SekJson
import KOTLINPACKAGE.utility.defaultHttpFetch
import KOTLINPACKAGE.utility.struct.Struct

// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The kotlin port of
// tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, and (for
// the reasons below) the go file's structure rather than the ts one's.
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider - a `memory` store named `options` - so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
// When the option is unset, the remaining providers (env, dotenv, a vault)
// are asked in order, and moving a credential from code to a vault becomes
// a configuration change.
//
// WHERE THE CREDENTIAL LIVES. Not in the options map. utility/Prepare.kt's
// prepareAuth calls `ctx.client.optionsMap()`, which is `Struct.clone(this
// .options)`, on EVERY request - so a feature that wrote the resolved value
// into the live options map (the ts design) would have one thread walking a
// LinkedHashMap while another mutated it: a ConcurrentModificationException,
// not merely a torn read. The credential is therefore held in FEATURE STATE
// behind a lock, the options map stays frozen after construction, and the
// authorization header is rewritten per request at the transport - built
// the same way prepareAuth builds it, from the same options.auth.prefix, so
// the two cannot drift. This is go's structural deviation, adopted for a
// sharper version of go's own reason.
//
// WHERE RESOLUTION HAPPENS. At the TRANSPORT SEAM, not in the PreSpec hook.
// Resolution is effectively async (providers do IO) while prepareAuth is
// synchronous, and kotlin's feature hooks cannot fail an operation the way
// ts's awaited hook rejection can. More decisively, SdkClient.direct() and
// SdkClient.graphql() run NO feature hooks at all - both funnel through
// rawRequest, which calls `utility.fetcher` directly. The transport is the
// ONE seam every wire path crosses, so resolving there is what gives the
// raw paths the same credential the entity pipeline gets, and the same
// refusal when the chain is broken.
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad creds) FAILS the op: the wrapper
// throws, and both wire paths catch it in-band (SdkClient.rawRequest ->
// `ok: false` + `err`; utility/MakeReqRes.makeRequest -> `response.err`).
// A broken vault never degrades into an unauthenticated request.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when a
// response status in `exchange.statuses` (401) says it is spent the wrapper
// buys another and retries the same request once. Concurrent purchases
// share the one in-flight exchange; test mode buys nothing and answers with
// a deterministic fake token.
@Suppress("UNCHECKED_CAST")
class SecretsFeature : BaseFeature("secrets", "0.1.0", true) {

  private var client: SdkClient? = null
  private var fopts: MutableMap<String, Any?>? = null

  // The LIVE options map (the root context's options - the same instance
  // SdkClient holds). READ ONLY: this feature never writes to it.
  private var liveopts: MutableMap<String, Any?> = linkedMapOf()

  private var secretname: String = "apikey"
  private var cache: Boolean = true
  private var sek: Sekreto? = null

  // Exchange state: null config when off; the refresh credential the chain
  // resolved; the single in-flight purchase.
  private var exchange: SecretsExchange? = null
  private var refresh: String = ""

  // Anything that made construction impossible (a bad chain spec, an
  // unknown plugin kind). Held rather than thrown, because init cannot fail
  // the constructor the way ts's throwing init does - the transport gate
  // refuses to send instead, which keeps a misconfigured chain fail-closed
  // rather than silently unauthenticated.
  private var initerr: RuntimeException? = null

  private val lock = ReentrantLock()
  private val settled = lock.newCondition()
  private val purchased = lock.newCondition()
  private var resolving: SecretsCall? = null
  private var buying: SecretsBuy? = null

  // The RESOLVED credential, injected into each request at the transport
  // seam. Guarded by `lock`; see the note at the head of this file.
  private var cred: String = ""

  // Normalised exchange config: null when off, so every later decision is a
  // null check rather than a repeated `true == ...active`.
  private class SecretsExchange(
    val path: String,
    val method: String,
    val request: String,
    val response: String,
    val statuses: List<Int>,
    val retries: Int,
  )

  // One shared in-flight resolution: late arrivals wait on `done` and read
  // `err`.
  private class SecretsCall {
    var done: Boolean = false
    var err: RuntimeException? = null
  }

  private class SecretsBuy {
    var done: Boolean = false
    var token: String = ""
    var err: RuntimeException? = null
  }

  // The LIVE Sekreto instance, for callers who want arbitrary secrets or
  // redaction:
  //
  //   client.secretsFeature()?.sekreto()?.get("db.password")
  //   client.secretsFeature()?.sekreto()?.redact(logline)
  //
  // Never a clone: sekreto holds provider state (caches, vault leases) that
  // has to stay live to be worth anything.
  fun sekreto(): Sekreto? = this.sek

  // The resolved credential ("" when none) - the state the transport
  // injects. Tests and callers read it HERE rather than from the options
  // map, which this feature never mutates.
  fun credential(): String = getcred()

  // Sync by feature contract: build the chain, never look anything up here.
  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.fopts = options
    this.liveopts = ctx.options ?: linkedMapOf()
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) {
      return
    }

    this.secretname = FeatureOptions.foptStr(options, "name", "apikey")
    this.cache = FeatureOptions.foptBool(options, "cache", true)

    val xopts = FeatureOptions.foptMap(options, "exchange")
    if (FeatureOptions.foptBool(xopts, "active", false)) {
      val statuses = mutableListOf<Int>()
      for (s in (FeatureOptions.foptList(xopts, "statuses") ?: mutableListOf())) {
        if (s is Number) {
          statuses.add(s.toInt())
        }
      }
      if (statuses.isEmpty()) {
        statuses.add(401)
      }
      this.exchange = SecretsExchange(
        path = FeatureOptions.foptStr(xopts, "path", "auth/token"),
        method = FeatureOptions.foptStr(xopts, "method", "POST"),
        request = FeatureOptions.foptStr(xopts, "request", "refresh_token"),
        response = FeatureOptions.foptStr(xopts, "response", "access_token"),
        statuses = statuses,
        retries = FeatureOptions.foptInt(xopts, "retries", 1),
      )
    }

    // The explicit credential, when set, is the first store in the chain.
    //
    // WHICH option that is depends on the exchange. Without one, the secret
    // being resolved IS the credential the transport sends, so `apikey` is
    // it. With one, the secret is a REFRESH token and `apikey` means the
    // opposite thing - an access token the caller already holds - so the
    // explicit seat belongs to `exchange.refresh`, and apikey is left alone
    // to serve as the starting access token (see resolveonce).
    var explicit = ""
    if (null == this.exchange) {
      val given = this.liveopts["apikey"]
      if (given is String) {
        explicit = given
      }
    } else {
      explicit = FeatureOptions.foptStr(xopts, "refresh", "")
    }

    val providers = mutableListOf<Any?>()

    if ("" != explicit) {
      try {
        providers.add(ProviderSpec(
          kind = "memory",
          name = "options",
          values = mapOf(envkey(this.secretname) to explicit),
        ))
      } catch (err: RuntimeException) {
        this.initerr = err
      }
    }

    for (p in (FeatureOptions.foptList(options, "providers") ?: mutableListOf())) {
      when (p) {
        // A live provider, or a declarative spec, joins the chain as it is:
        // the vendored Sekreto constructor takes both.
        is Provider -> providers.add(p)
        is ProviderSpec -> providers.add(p)
        is Map<*, *> -> {
          try {
            providers.add(specof(p as Map<String, Any?>))
          } catch (err: RuntimeException) {
            this.initerr = err
          }
        }
        // ANYTHING ELSE goes through to the constructor as well - a bare
        // kind name ("hashicorp"), a null, a number. Sekreto refuses it with
        // ITS OWN message ("not a provider or a provider spec"), which lands
        // in `initerr` below and closes the transport gate. This is ts's
        // shape: every entry is pushed through. A `when` without this arm
        // silently DROPPED the entry, which SHORTENED the chain instead of
        // failing it - a misconfigured providers list then sent ordinary
        // unauthenticated requests, the exact fail-open the gate exists to
        // prevent, and the one input the constructor was written to refuse
        // was the one it never saw.
        else -> providers.add(p)
      }
    }

    // The plugin DEFINITIONS the model selected for this feature, emitted by
    // Config generically from the catalogue's active `plugin.def` entries.
    // Upstream sekreto's contract since the registry was retired: a kind not
    // passed in `plugins` is unknown to that Sekreto, so the model's choice
    // of plugin groups IS the SDK's provider vocabulary.
    val plugs = mutableListOf<Definition>()
    for (d in Config.featurePlugins(this.name)) {
      if (d is Map<*, *>) {
        plugs.add(d as Definition)
      }
    }

    try {
      this.sek = Sekreto(providers = providers, plugins = plugs, docache = this.cache)
    } catch (err: RuntimeException) {
      this.initerr = err
    }

    // Wrap the transport WHENEVER the feature is active - including when
    // construction failed above. The fail-closed gate needs the seam on
    // every request, and the exchange (when on) additionally needs to SEE
    // responses: expiry is only ever discovered from one, and this is the
    // one place a response can be seen and the request tried again.
    val inner: FetcherFn = ctx.utility!!.fetcher
    ctx.utility!!.fetcher = { ctx2, url, fetchdef -> transport(ctx2, url, fetchdef, inner) }
  }

  // One resolution, shared by every concurrent caller. A settled HIT is
  // kept only when caching is on (`cache: false` means every resolve asks
  // the chain again); a FAILURE is always cleared, so a transient vault
  // outage never poisons the client permanently - the next operation asks
  // the chain again.
  //
  // A MISS is cleared too, however caching is set. That rule is sekreto's,
  // not this feature's: `A miss is never cached: the next read asks again`,
  // in sekreto's own source. Keeping a settled miss here would override
  // that from the layer above, and a secret provisioned after startup - a
  // mounted file, a policy granted a minute late - would never be picked up
  // for the life of the client. `cache` is about caching a HIT; it was
  // never a promise to keep saying no.
  fun resolve() {
    val ie = this.initerr
    if (null != ie) {
      throw ie
    }

    var mine: SecretsCall? = null
    var waited: SecretsCall? = null

    this.lock.withLock {
      val cur = this.resolving
      if (null != cur) {
        waited = cur
      } else {
        val call = SecretsCall()
        this.resolving = call
        mine = call
      }
    }

    val join = waited
    if (null != join) {
      this.lock.withLock {
        while (!join.done) {
          this.settled.await()
        }
      }
      val jerr = join.err
      if (null != jerr) {
        throw jerr
      }
      return
    }

    val call = mine!!
    var err: RuntimeException? = null
    var hit = false
    try {
      hit = resolveonce()
    } catch (e: RuntimeException) {
      err = e
    } catch (e: Exception) {
      // A provider written in Java may throw a checked exception; the wire
      // paths only catch RuntimeException, so normalise it here rather than
      // letting it escape the operation uncaught.
      err = SekretoError("secrets: " + (e.message ?: e.toString()))
    }

    this.lock.withLock {
      call.err = err
      call.done = true
      if (null != err || !this.cache || !hit) {
        this.resolving = null
      }
      this.settled.signalAll()
    }

    if (null != err) {
      throw err
    }
  }

  // Resolve once, reporting whether a credential came out of it. That
  // boolean is the whole of what resolve() needs to tell a cacheable HIT
  // from a miss it must not keep.
  private fun resolveonce(): Boolean {
    val s = this.sek ?: return false

    // A provider ERROR throws out of here and fails the op (via the
    // transport gate); only a MISS (null) falls through.
    val found = s.tryget(this.secretname)

    if (null == this.exchange) {
      this.lock.withLock {
        // An UNCACHED miss after an earlier hit is a revocation: the chain
        // now says no provider has the secret, so the resolved value must
        // not keep going out on the wire. (An explicit apikey OPTION is
        // never lost here - it seats FIRST in the chain as a memory
        // provider, so the chain HITS while one is set and this branch is
        // unreachable.)
        this.cred = found ?: ""
      }
      return null != found
    }

    // Exchanging: what the chain resolved is the REFRESH token, kept for
    // every later purchase. A miss is not fatal here - an explicit `apikey`
    // may already hold a usable access token, and the API is what gets to
    // say whether it does.
    this.refresh = found ?: ""

    var apikey = getcred()
    if ("" == apikey) {
      // A starting access token supplied as the OPTION: read from the
      // frozen options map (no feature ever writes it).
      val given = this.liveopts["apikey"]
      if (given is String) {
        apikey = given
      }
      this.lock.withLock { this.cred = apikey }
    }
    if ("" != apikey) {
      // A starting access token was supplied. Spend it: if it is stale the
      // API answers with an expiry status and the transport wrapper buys
      // another, which is the same path expiry takes anyway.
      return true
    }

    // `auth: null` is the documented way to send NO credential, and a
    // purchase is a credential-bearing call: the refresh token goes to the
    // token endpoint in the request body. withrefresh honours suppression
    // for the RETRY, but it runs after this - by then the refresh token has
    // already left the process, and no later check can call it back. The
    // suppression has to be honoured here, before the first purchase, or it
    // only ever half-held.
    if (null == this.liveopts["auth"]) {
      return false
    }

    buy()

    return true
  }

  // transport wraps whatever transport was current at init.
  private fun transport(
    ctx: Context,
    url: String,
    fetchdef: MutableMap<String, Any?>,
    inner: FetcherFn,
  ): Any? {
    // Fail-closed, at the ONE seam every wire path crosses. Entity ops,
    // direct(), graphql() and the exchange retries all come through this
    // wrapper. resolve() is shared and cached: concurrent callers join the
    // in-flight attempt, a cached success is free, and with `cache: false`
    // the chain is asked once per REQUEST, which is that option's meaning.
    // A provider ERROR refuses the request WITH THE PROVIDER'S OWN ERROR -
    // never an unauthenticated send.
    val ie = this.initerr
    if (null != ie) {
      throw ie
    }
    resolve()

    // Inject the resolved credential into THIS request's header. The header
    // was built by prepareAuth from the options apikey; the chain-resolved
    // value lives in feature state instead (see `cred`), so the wrapper
    // writes it here - same construction, same suppression rules - and the
    // shared options map stays untouched.
    val token = getcred()
    if ("" != token) {
      reauth(fetchdef, token)
    }

    if (null == this.exchange) {
      return inner(ctx, url, fetchdef)
    }

    return withrefresh(ctx, url, fetchdef, inner)
  }

  // withrefresh buys a token and tries the request again when the API says
  // the current one is spent.
  //
  // The retry rewrites the authorization header IN PLACE on the fetchdef,
  // because the header was built by the synchronous prepareAuth before this
  // request left, and it carries the token that just failed.
  private fun withrefresh(
    ctx: Context,
    url: String,
    fetchdef: MutableMap<String, Any?>,
    inner: FetcherFn,
  ): Any? {
    // `auth: null` is the documented way to send NO credential, and
    // prepareAuth honours it by removing the header. A refusal of a
    // deliberately unauthenticated request is not an expired token and
    // cannot be fixed by buying one - retrying would transmit exactly the
    // credential the caller suppressed.
    if (null == this.liveopts["auth"]) {
      return inner(ctx, url, fetchdef)
    }

    val x = this.exchange!!
    var attempt = 0

    while (true) {
      // The credential THIS attempt goes out with, captured before it
      // leaves: it is what tells a stale refusal apart from a fresh one.
      val used = getcred()

      val res = inner(ctx, url, fetchdef)

      if (attempt >= x.retries || !spent(res)) {
        return res
      }

      // Another request may have bought a token while this one was in
      // flight. Concurrent expiries share the in-flight purchase, but
      // STAGGERED ones do not - so spend what is current before buying: a
      // second exchange for a token that is already fresh is wasted, and on
      // a provider that invalidates the previous credential on issuance it
      // breaks the first request's own retry.
      val current = getcred()
      val token: String

      if ("" != current && current != used) {
        token = current
      } else {
        try {
          token = buy()
        } catch (err: RuntimeException) {
          // The purchase failed: answer with the API's own refusal rather
          // than this one. The caller asked for data, and the refusal is
          // the more useful of the two - the exchange error is a symptom.
          return res
        }
      }

      reauth(fetchdef, token)

      attempt++
    }
  }

  private fun spent(res: Any?): Boolean {
    val status = FeatureOptions.fresStatus(res)
    if (status < 0) {
      return false
    }
    return this.exchange!!.statuses.contains(status)
  }

  private fun getcred(): String {
    return this.lock.withLock { this.cred }
  }

  private fun reauth(fetchdef: MutableMap<String, Any?>, token: String) {
    val headers = Helpers.toMapAny(fetchdef["headers"]) ?: return

    // Suppressed auth means NO header, the same answer prepareAuth gives.
    // Reached defensively - withrefresh does not retry at all when auth is
    // null - but this is the function that writes the credential, so it is
    // where the rule has to hold. The options map is FROZEN after
    // construction (this feature never writes it), so the raw read is safe
    // on any thread.
    val auth = this.liveopts["auth"]
    if (auth !is Map<*, *>) {
      headers.remove("authorization")
      return
    }

    val prefix = (auth as Map<String, Any?>)["prefix"]
    headers["authorization"] =
      if (prefix is String && "" != prefix) "$prefix $token" else token
  }

  // buy an access token with the refresh token. Concurrent callers share the
  // ONE in-flight purchase; the slot is cleared once settled, so the next
  // expiry buys a fresh token rather than replaying this result.
  private fun buy(): String {
    // TEST MODE BUYS NOTHING. The test feature replaces the transport so no
    // request leaves the process; an exchange here would be the one HTTP
    // call it could not stop, and it would need a live token endpoint for a
    // suite whose whole point is not needing one. A deterministic,
    // obviously-fake token instead - the same answer makeOptions gives a
    // required server variable, for the same reason.
    if ("live" != this.client!!.mode) {
      val token = "test-" + this.exchange!!.response
      this.lock.withLock { this.cred = token }
      return token
    }

    var mine: SecretsBuy? = null
    var waited: SecretsBuy? = null

    this.lock.withLock {
      val cur = this.buying
      if (null != cur) {
        waited = cur
      } else {
        val b = SecretsBuy()
        this.buying = b
        mine = b
      }
    }

    val join = waited
    if (null != join) {
      this.lock.withLock {
        while (!join.done) {
          this.purchased.await()
        }
      }
      val jerr = join.err
      if (null != jerr) {
        throw jerr
      }
      return join.token
    }

    val b = mine!!
    var token = ""
    var err: RuntimeException? = null
    try {
      token = buyonce()
    } catch (e: RuntimeException) {
      err = e
    } catch (e: Exception) {
      err = SekretoError("secrets: " + (e.message ?: e.toString()))
    }

    this.lock.withLock {
      b.token = token
      b.err = err
      b.done = true
      this.buying = null
      if (null == err) {
        // Publish HERE, before the waiters wake: one writer, under the lock
        // - waiters consume the returned value.
        this.cred = token
      }
      this.purchased.signalAll()
    }

    if (null != err) {
      throw err
    }
    return token
  }

  private fun buyonce(): String {
    val x = this.exchange!!

    if ("" == this.refresh) {
      throw SekretoError(
        "secrets: no refresh token: the provider chain has no '" +
          this.secretname + "', and feature.secrets.exchange.refresh is unset")
    }

    val options = this.client!!.optionsMap()

    // The token endpoint is RELATIVE to the base, which already carries
    // whatever account or tenant segment the server URL declares.
    val baseraw = options["base"]
    val base = (if (baseraw is String) baseraw else "").trimEnd('/')
    val url = base + "/" + x.path.trimStart('/')

    // The body is MARSHALLED, never concatenated: a refresh token (or a
    // configured request-field name) carrying a quote, backslash or newline
    // must arrive as that literal value, not as malformed JSON.
    val body = SekJson.stringify(SekJson.obj(x.request to SekJson.str(this.refresh)))

    val fetchdef = linkedMapOf<String, Any?>(
      "method" to x.method,
      "headers" to linkedMapOf<String, Any?>("content-type" to "application/json"),
      "body" to body,
    )

    // Deliberately NOT the SDK transport. The transport is what this feature
    // wraps, and sending the token request back through it would recurse on
    // the first expiry - and would route the exchange through the test mock,
    // which knows nothing about it. utility/Fetcher.kt's defaultHttpFetch is
    // the SAME raw HTTP path the SDK uses, taken BELOW the mode/test gate,
    // so the ordinary case needs no custom transport; a supplied
    // system.fetch is honoured so a test can intercept the purchase.
    var sysFetch = Struct.getpath(options, listOf("system", "fetch"))
    if (sysFetch === Struct.UNDEF) {
      sysFetch = null
    }

    val res: Any? = if (sysFetch is BiFunction<*, *, *>) {
      (sysFetch as BiFunction<String, MutableMap<String, Any?>, Any?>).apply(url, fetchdef)
    } else {
      defaultHttpFetch(url, fetchdef)
    }

    val status = FeatureOptions.fresStatus(res)
    if (200 > status || 300 <= status) {
      throw SekretoError(
        "secrets: token exchange failed: " + status + " from " + url)
    }

    val resmap = Helpers.toMapAny(res)
    var payload: Any? = null
    if (resmap != null) {
      val jf = resmap["json"]
      payload = if (jf is Supplier<*>) (jf as Supplier<Any?>).get() else resmap["body"]
    }

    val token = Struct.getprop(payload, x.response, null)

    if (token !is String || "" == token) {
      throw SekretoError(
        "secrets: token exchange returned no '" + x.response + "' field from " + url)
    }

    return token
  }
}
