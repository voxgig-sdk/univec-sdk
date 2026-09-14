// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The swift port of
// tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, and (for the
// reasons below) the go file's structure rather than the ts one's.
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
// WHERE THE CREDENTIAL LIVES. Not in the options map. utility/Prepare.swift's
// prepareAuth calls `ctx.client!.optionsMap()`, which is `clone(options)`,
// on EVERY request, and VMap is a reference type over an ordered dictionary
// - so a feature that wrote the resolved value into the live options map
// (the ts design) would have one thread walking the map while another
// mutated it. The credential is therefore held in FEATURE STATE behind a
// lock, the options map stays frozen after construction, and the
// authorization header is rewritten per request at the transport - built
// the same way prepareAuth builds it, from the same options.auth.prefix, so
// the two cannot drift. This is go's structural deviation, adopted for a
// sharper version of go's own reason.
//
// WHERE RESOLUTION HAPPENS. At the TRANSPORT SEAM, not in the PreSpec hook.
// Resolution is effectively async (providers do IO) while prepareAuth is
// synchronous, and swift's feature hooks cannot fail an operation the way
// ts's awaited hook rejection can. More decisively, UnivecSDK.direct()
// and .graphql() run NO feature hooks at all - both funnel through
// rawRequest, which calls `utility.fetcher` directly. The transport is the
// ONE seam every wire path crosses (utility/Make.swift's makeRequest reaches
// it with the identical line), so resolving there is what gives the raw
// paths the same credential the entity pipeline gets, and the same refusal
// when the chain is broken.
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad creds) FAILS the op: the wrapper
// throws, and both wire paths catch it in-band (rawRequest -> `ok: false` +
// `err`; makeRequest -> `response.err`). A broken vault never degrades into
// an unauthenticated request.
//
// FAIL-CLOSED ON CONSTRUCTION TOO. initFeature cannot fail the client
// constructor the way ts's throwing init does, so anything that made the
// chain impossible (a malformed providers entry, an unknown plugin kind) is
// HELD in `initerr` and the transport gate refuses to send. For that to
// mean anything the wrapper has to be installed BEFORE the chain is built -
// wrap first, build second. Java shipped the opposite order, and its gate
// was dead code: a construction failure returned before the wrap, and a
// misconfigured chain sent ordinary unauthenticated requests.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when a
// response status in `exchange.statuses` (401) says it is spent the wrapper
// buys another and retries the same request once. Concurrent purchases
// share the one in-flight exchange; test mode buys nothing and answers with
// a deterministic fake token.
//
// FetcherFunc is synchronous `throws`, so go's channel-based shared
// in-flight resolution collapses to a condition variable, and a provider
// ERROR is simply a `throw` out of the wrapper.

import Foundation

import Sekreto
import VoxgigPlugin

public final class SecretsFeature: BaseFeature {
  private var client: UnivecSDK?
  private var fopts: VMap?

  // The LIVE options map (the root context's options - the same instance
  // the client holds). READ ONLY: this feature never writes to it.
  private var liveopts: VMap = VMap()

  private var secretname = "apikey"
  private var cache = true
  private var sek: Sekreto?

  // Exchange state: nil config when off; the refresh credential the chain
  // resolved; the single in-flight purchase.
  private var exchange: SecretsExchange?
  private var refresh = ""

  // Anything that made construction impossible (a bad chain spec, an
  // unknown plugin kind, a providers entry that is neither a provider nor
  // a spec). Held rather than thrown - see the note at the head of this
  // file - and read by the transport gate on every request.
  private var initerr: Error?

  // `mu` guards `cred`; `cond` coordinates the shared in-flight resolution
  // and purchase (waiters block on it until the one caller doing the work
  // publishes the outcome).
  private let mu = NSLock()
  private let cond = NSCondition()
  private var resolving: SecretsCall?
  private var buying: SecretsBuy?

  // The RESOLVED credential, injected into each request at the transport
  // seam. Guarded by `mu`; see the note at the head of this file.
  private var cred = ""

  // Normalised exchange config: nil when off, so every later decision is a
  // nil check rather than a repeated `true == ...active`.
  private struct SecretsExchange {
    let path: String
    let method: String
    let request: String
    let response: String
    let statuses: [Int]
    let retries: Int
  }

  // One shared in-flight resolution: late arrivals wait on `done` and read
  // `err`.
  private final class SecretsCall {
    var done = false
    var err: Error?
  }

  private final class SecretsBuy {
    var done = false
    var token = ""
    var err: Error?
  }

  public override init() {
    super.init()
    version = "0.1.0"
    name = "secrets"
    active = true
  }

  // The LIVE Sekreto instance, for callers who want arbitrary secrets or
  // redaction:
  //
  //   feature.sekreto()?.get("db.password")
  //   feature.sekreto()?.redact(logline)
  //
  // Never a clone: sekreto holds provider state (caches, vault leases) that
  // has to stay live to be worth anything.
  public func sekreto() -> Sekreto? {
    return sek
  }

  // The resolved credential ("" when none) - the state the transport
  // injects. Tests and callers read it HERE rather than from the options
  // map, which this feature never mutates.
  public func credential() -> String {
    return getcred()
  }

  // Sync by feature contract: build the chain, never look anything up here.
  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    fopts = options
    liveopts = ctx.options ?? VMap()
    active = foptBool(options, "active", false)

    if !active {
      return
    }

    secretname = foptStr(options, "name", "apikey")
    cache = foptBool(options, "cache", true)

    let xopts = foptMap(options, "exchange")
    if foptBool(xopts, "active", false) {
      var statuses: [Int] = []
      if let list = foptList(xopts, "statuses") {
        for s in list.items {
          let n = toInt(s)
          if 0 <= n { statuses.append(n) }
        }
      }
      if statuses.isEmpty {
        statuses = [401]
      }
      exchange = SecretsExchange(
        path: foptStr(xopts, "path", "auth/token"),
        method: foptStr(xopts, "method", "POST"),
        request: foptStr(xopts, "request", "refresh_token"),
        response: foptStr(xopts, "response", "access_token"),
        statuses: statuses,
        retries: foptInt(xopts, "retries", 1))
    }

    // WRAP FIRST, BUILD SECOND. The transport wrapper is the fail-closed
    // gate AND the credential injector, so it is installed WHENEVER the
    // feature is active - before anything below can fail - and the
    // exchange (when on) additionally needs to SEE responses: expiry is
    // only ever discovered from one, and this is the one place a response
    // can be seen and the request tried again. Installing it after the
    // chain is built would make a construction failure fail-OPEN: the
    // error would be held and nothing would ever read it.
    let inner = ctx.utility!.fetcher!
    ctx.utility!.fetcher = { ctx2, url, fetchdef in
      try self.transport(ctx2, url, fetchdef, inner)
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
    if nil == exchange {
      explicit = gp(liveopts, "apikey").asString ?? ""
    } else {
      explicit = foptStr(xopts, "refresh", "")
    }

    var chain: [Sekreto.ChainItem] = []

    if "" != explicit {
      do {
        let key = try envkey(secretname)
        chain.append(.spec(ProviderSpec(
          kind: "memory",
          name: "options",
          values: Ordered<String>([(key, explicit)]))))
      } catch {
        initerr = error
      }
    }

    if let providers = foptList(options, "providers") {
      for p in providers.items {
        if let raw = p.asNative {
          if let provider = raw as? Provider {
            // A live provider joins the chain as it is - the vendored
            // Sekreto's `chain:` initialiser holds providers and specs in
            // ONE ordered list, which is what keeps the explicit seat
            // first and the configured chain behind it.
            chain.append(.provider(provider))
            continue
          }
          if let spec = raw as? ProviderSpec {
            chain.append(.spec(spec))
            continue
          }
          initerr = initerr ?? SekretoError(
            "sekreto: not a provider or a provider spec: " + String(describing: raw))
          continue
        }

        if let m = p.asMap {
          // A declarative spec (the shape a config file produces), read by
          // sekreto's own `specof`. An unknown or empty `kind` is refused
          // by the constructor below, which is exactly the wording the
          // shared spec pins.
          chain.append(.spec(specof(pluginValue(.map(m)))))
          continue
        }

        // ANYTHING ELSE is refused, fail-closed - a bare kind name
        // ("hashicorp"), a null, a number. Swift's `providers` is a typed
        // Value list, so there is nothing to push a string through to the
        // constructor; the feature raises the library's own error here
        // instead, with the constructor's own wording, and the transport
        // gate refuses to send. A loop without this arm silently DROPPED
        // the entry, which SHORTENED the chain instead of failing it - a
        // misconfigured providers list then sent ordinary unauthenticated
        // requests, the exact fail-open the gate exists to prevent. Never
        // drop an entry.
        initerr = initerr ?? SekretoError(
          "sekreto: not a provider or a provider spec: " + stringify(p))
      }
    }

    // The plugin DEFINITIONS the model selected for this feature, emitted by
    // Config generically from the catalogue's active `plugin.def` entries.
    // Upstream sekreto's contract since the registry was retired: a kind not
    // passed in `plugins:` is unknown to that Sekreto, so the model's choice
    // of plugin groups IS the SDK's provider vocabulary.
    var plugs: [Definition] = []
    for d in SdkConfig.featurePlugins(name) {
      if let def = d as? Definition {
        plugs.append(def)
      }
    }

    do {
      sek = try Sekreto(chain: chain, plugins: plugs, cache: cache)
    } catch {
      // The FIRST failure is the one reported: a malformed entry above is a
      // more useful message than whatever the shortened chain then failed
      // on, and the gate closes either way.
      initerr = initerr ?? error
    }
  }

  // One resolution, shared by every concurrent caller. A settled SUCCESS is
  // kept only when caching is on (`cache: false` means every resolve asks
  // the chain again); a FAILURE is always cleared, so a transient vault
  // outage never poisons the client permanently - the next operation asks
  // the chain again.
  func resolve() throws {
    if let e = initerr {
      throw e
    }

    cond.lock()
    if let call = resolving {
      while !call.done {
        cond.wait()
      }
      let err = call.err
      cond.unlock()
      if let e = err {
        throw e
      }
      return
    }
    let call = SecretsCall()
    resolving = call
    cond.unlock()

    var err: Error? = nil
    do {
      try resolveonce()
    } catch {
      err = error
    }

    cond.lock()
    call.err = err
    call.done = true
    if nil != err || !cache {
      resolving = nil
    }
    cond.broadcast()
    cond.unlock()

    if let e = err {
      throw e
    }
  }

  private func resolveonce() throws {
    guard let s = sek else {
      return
    }

    // A provider ERROR throws out of here and fails the op (via the
    // transport gate); only a MISS (nil) falls through.
    let found = try s.tryget(secretname)

    if nil == exchange {
      // An UNCACHED miss after an earlier hit is a revocation: the chain
      // now says no provider has the secret, so the resolved value must
      // not keep going out on the wire. (An explicit apikey OPTION is
      // never lost here - it seats FIRST in the chain as a memory
      // provider, so the chain HITS while one is set and this branch is
      // unreachable.)
      setcred(found ?? "")
      return
    }

    // Exchanging: what the chain resolved is the REFRESH token, kept for
    // every later purchase. A miss is not fatal here - an explicit `apikey`
    // may already hold a usable access token, and the API is what gets to
    // say whether it does.
    refresh = found ?? ""

    var apikey = getcred()
    if "" == apikey {
      // A starting access token supplied as the OPTION: read from the
      // frozen options map (no feature ever writes it).
      apikey = gp(liveopts, "apikey").asString ?? ""
      setcred(apikey)
    }
    if "" != apikey {
      // A starting access token was supplied. Spend it: if it is stale the
      // API answers with an expiry status and the transport wrapper buys
      // another, which is the same path expiry takes anyway.
      return
    }

    _ = try buy()
  }

  // transport wraps whatever transport was current at init.
  private func transport(_ ctx: Context, _ url: String, _ fetchdef: VMap,
                         _ inner: FetcherFunc) throws -> Value {
    // Fail-closed, at the ONE seam every wire path crosses. Entity ops,
    // direct(), graphql() and the exchange retries all come through this
    // wrapper. resolve() is shared and cached: concurrent callers join the
    // in-flight attempt, a cached success is free, and with `cache: false`
    // the chain is asked once per REQUEST, which is that option's meaning.
    // A provider ERROR refuses the request WITH THE PROVIDER'S OWN ERROR -
    // never an unauthenticated send.
    if let e = initerr {
      throw e
    }
    try resolve()

    // Inject the resolved credential into THIS request's header. The header
    // was built by prepareAuth from the options apikey; the chain-resolved
    // value lives in feature state instead (see `cred`), so the wrapper
    // writes it here - same construction, same suppression rules - and the
    // shared options map stays untouched.
    let token = getcred()
    if "" != token {
      reauth(fetchdef, token)
    }

    if nil == exchange {
      return try inner(ctx, url, fetchdef)
    }

    return try withrefresh(ctx, url, fetchdef, inner)
  }

  // withrefresh buys a token and tries the request again when the API says
  // the current one is spent.
  //
  // The retry rewrites the authorization header IN PLACE on the fetchdef,
  // because the header was built by the synchronous prepareAuth before this
  // request left, and it carries the token that just failed.
  private func withrefresh(_ ctx: Context, _ url: String, _ fetchdef: VMap,
                           _ inner: FetcherFunc) throws -> Value {
    // `auth: null` is the documented way to send NO credential, and
    // prepareAuth honours it by removing the header. A refusal of a
    // deliberately unauthenticated request is not an expired token and
    // cannot be fixed by buying one - retrying would transmit exactly the
    // credential the caller suppressed.
    if isNil(gp(liveopts, "auth")) {
      return try inner(ctx, url, fetchdef)
    }

    let x = exchange!
    var attempt = 0

    while true {
      // The credential THIS attempt goes out with, captured before it
      // leaves: it is what tells a stale refusal apart from a fresh one.
      let used = getcred()

      let res = try inner(ctx, url, fetchdef)

      if attempt >= x.retries || !spent(res) {
        return res
      }

      // Another request may have bought a token while this one was in
      // flight. Concurrent expiries share the in-flight purchase, but
      // STAGGERED ones do not - so spend what is current before buying: a
      // second exchange for a token that is already fresh is wasted, and on
      // a provider that invalidates the previous credential on issuance it
      // breaks the first request's own retry.
      let current = getcred()
      var token = ""

      if "" != current && current != used {
        token = current
      } else {
        do {
          token = try buy()
        } catch {
          // The purchase failed: answer with the API's own refusal rather
          // than this one. The caller asked for data, and the refusal is
          // the more useful of the two - the exchange error is a symptom.
          return res
        }
      }

      reauth(fetchdef, token)

      attempt += 1
    }
  }

  private func spent(_ res: Value) -> Bool {
    let (status, has) = fresStatus(res)
    if !has {
      return false
    }
    return exchange!.statuses.contains(status)
  }

  private func getcred() -> String {
    mu.lock()
    defer { mu.unlock() }
    return cred
  }

  private func setcred(_ value: String) {
    mu.lock()
    cred = value
    mu.unlock()
  }

  private func reauth(_ fetchdef: VMap, _ token: String) {
    guard let headers = gp(fetchdef, "headers").asMap else {
      return
    }

    // Suppressed auth means NO header, the same answer prepareAuth gives.
    // Reached defensively - withrefresh does not retry at all when auth is
    // nil - but this is the function that writes the credential, so it is
    // where the rule has to hold. The options map is FROZEN after
    // construction (this feature never writes it), so the raw read is safe
    // on any thread.
    guard let auth = gp(liveopts, "auth").asMap else {
      headers.entries.removeValue(forKey: "authorization")
      return
    }

    let prefix = gp(auth, "prefix").asString ?? ""
    // Empty prefix (raw apiKey credential) must not add a leading space -
    // prepareAuth's rule, repeated here because this is the other writer.
    headers.entries["authorization"] = .string("" == prefix ? token : prefix + " " + token)
  }

  // buy an access token with the refresh token. Concurrent callers share the
  // ONE in-flight purchase; the slot is cleared once settled, so the next
  // expiry buys a fresh token rather than replaying this result.
  private func buy() throws -> String {
    // TEST MODE BUYS NOTHING. The test feature replaces the transport so no
    // request leaves the process; an exchange here would be the one HTTP
    // call it could not stop, and it would need a live token endpoint for a
    // suite whose whole point is not needing one. A deterministic,
    // obviously-fake token instead - the same answer makeOptions gives a
    // required server variable, for the same reason.
    if "live" != client!.mode {
      let token = "test-" + exchange!.response
      setcred(token)
      return token
    }

    cond.lock()
    if let b = buying {
      while !b.done {
        cond.wait()
      }
      let err = b.err
      let token = b.token
      cond.unlock()
      if let e = err {
        throw e
      }
      return token
    }
    let b = SecretsBuy()
    buying = b
    cond.unlock()

    var token = ""
    var err: Error? = nil
    do {
      token = try buyonce()
    } catch {
      err = error
    }

    cond.lock()
    b.token = token
    b.err = err
    b.done = true
    buying = nil
    if nil == err {
      // Publish HERE, before the waiters wake: one writer, under the lock
      // - waiters consume the returned value.
      setcred(token)
    }
    cond.broadcast()
    cond.unlock()

    if let e = err {
      throw e
    }
    return token
  }

  private func buyonce() throws -> String {
    let x = exchange!

    if "" == refresh {
      throw SekretoError(
        "secrets: no refresh token: the provider chain has no '" +
          secretname + "', and feature.secrets.exchange.refresh is unset")
    }

    let options = client!.optionsMap()

    // The token endpoint is RELATIVE to the base, which already carries
    // whatever account or tenant segment the server URL declares.
    var base = gp(options, "base").asString ?? ""
    while base.hasSuffix("/") { base = String(base.dropLast()) }
    var path = x.path
    while path.hasPrefix("/") { path = String(path.dropFirst()) }
    let url = base + "/" + path

    // The body is ENCODED, never concatenated: a refresh token (or a
    // configured request-field name) carrying a quote, backslash or newline
    // must arrive as that literal value, not as malformed JSON.
    let body = JSON.stringify(.map(vm((x.request, .string(refresh)))))

    let fetchdef = VMap()
    fetchdef.entries["method"] = .string(x.method)
    fetchdef.entries["headers"] = .map(vm(("content-type", .string("application/json"))))
    fetchdef.entries["body"] = .string(body)

    // Deliberately NOT the SDK transport. The transport is what this feature
    // wraps, and sending the token request back through it would recurse on
    // the first expiry - and would route the exchange through the test mock,
    // which knows nothing about it. utility/Fetcher.swift's defaultHttpFetch
    // is the SAME raw HTTP path the SDK uses, taken BELOW the mode/test
    // gate, so the ordinary case needs no custom transport (and no
    // rawExchangeFetch twin, unlike go); a supplied system.fetch is honoured
    // so a test can intercept the purchase.
    let sysFetch = gpath(options, "system", "fetch")
    let res: Value
    if let fn = sysFetch.asNative as? SystemFetch {
      res = fn(url, fetchdef)
    } else {
      res = try defaultHttpFetch(url, fetchdef)
    }

    let (status, _) = fresStatus(res)
    if 200 > status || 300 <= status {
      throw SekretoError(
        "secrets: token exchange failed: " + String(status) + " from " + url)
    }

    var payload: Value = .noval
    if let jf = gp(res, "json").asNative as? NativeCall0 {
      payload = jf()
    } else {
      payload = gp(res, "body")
    }

    let token = gp(payload, x.response).asString ?? ""

    if "" == token {
      throw SekretoError(
        "secrets: token exchange returned no '" + x.response + "' field from " + url)
    }

    return token
  }

  // An SDK Value (a plain map from the options) as the plugin host's own
  // value model, which is what sekreto's `specof` reads. QUALIFIED, because
  // this file sees both libraries' `Value` and the SDK's own wins unqualified.
  private func pluginValue(_ v: Value) -> VoxgigPlugin.Value {
    switch v {
    case .bool(let b): return .bool(b)
    case .int(let n): return .num(Double(n))
    case .double(let d): return .num(d)
    case .string(let s): return .str(s)
    case .list(let l): return .list(l.items.map { pluginValue($0) })
    case .map(let m):
      var out: [String: VoxgigPlugin.Value] = [:]
      for (k, x) in m.entries { out[k] = pluginValue(x) }
      return .map(out)
    default: return .null
    }
  }
}
