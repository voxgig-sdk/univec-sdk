package JAVAPACKAGE.feature;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.function.BiFunction;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Config;
import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.feature.secrets.plugin.Definition;
import JAVAPACKAGE.feature.secrets.sekreto.Json;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;

// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The java port of
// tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, java idiom,
// and structurally the go port (tm/go/feature/secrets_feature.go) because
// java's request path has go's two properties: a synchronous hook
// pipeline, and a shared options map read raw on every caller thread.
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
// WHERE THE CREDENTIAL LIVES. In feature state, never in the options map.
// utility/PrepareAuth.java reads `ctx.client.optionsMap()` - a fresh clone
// of the shared `this.options` - on every request, and java operations run
// on the CALLER's thread, so a feature that wrote the resolved value into
// that shared map would race every concurrent operation. With the feature
// as sole holder the options map stays frozen after construction, every
// raw read is safe, and the header the wire sees is identical because the
// transport wrapper rewrites it from this value the way prepareAuth builds
// it.
//
// WHERE RESOLUTION HAPPENS. At the TRANSPORT seam - core/Utility.java's
// mutable `fetcher` field, which this feature wraps at init exactly as
// RetryFeature does. That is the ONE place every wire path crosses:
// core/SdkClient.java's `direct` and `graphql` funnel into `rawRequest`,
// which runs NO feature hook at all, so a PreSpec-only resolution would
// send those two raw paths out unauthenticated and never notice. Resolving
// at the transport is also what makes the fail-closed gate reachable from
// them.
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
// vault never degrades into an unauthenticated request. java's feature
// hooks return void and cannot fail an operation the way ts's awaited hook
// rejection can, so the transport wrapper is installed WHENEVER the
// feature is active and refuses to send while resolution stands failed.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when
// a response status in `exchange.statuses` (401) says it is spent the
// wrapper buys another and retries the same request once. Concurrent
// purchases share the one in-flight exchange; test mode buys nothing and
// answers with a deterministic fake token.
@SuppressWarnings({"unchecked"})
public class SecretsFeature extends BaseFeature {

  private SdkClient client;

  // The LIVE options map (the root context's options, which IS the map the
  // client clones for optionsMap). READ ONLY: this feature never writes it.
  private Map<String, Object> liveopts;

  private String secretname = "apikey";
  private boolean cache = true;
  private Sekreto sek;

  // Exchange state: null config when off; the refresh credential the chain
  // resolved; the single in-flight purchase.
  private SecretsExchange exchange;
  private String refresh = "";

  // Construction failures (a bad provider spec, an unknown plugin kind)
  // are held rather than thrown: init cannot fail the client construction
  // the way ts's throwing init does, so the transport gate below refuses
  // to send instead - a misconfigured chain stays fail-closed rather than
  // silently unauthenticated.
  //
  // volatile: written on the constructing thread, read by the transport
  // wrapper on every caller thread.
  private volatile RuntimeException initerr;

  private final Object lock = new Object();
  private SecretsCall resolving;
  private SecretsBuy buying;

  // The RESOLVED credential, injected into each request at the transport
  // seam. Guarded by `lock`; see WHERE THE CREDENTIAL LIVES above.
  private String cred = "";

  public SecretsFeature() {
    super("secrets", "0.1.0", true);
  }

  // Normalised exchange config: null when off, so every later decision is
  // a null check rather than a repeated `true == ...active`.
  private static final class SecretsExchange {
    String path;
    String method;
    String request;
    String response;
    List<Integer> statuses;
    int retries;
  }

  // One shared in-flight resolution: late arrivals await the latch and
  // read the outcome.
  private static final class SecretsCall {
    final CountDownLatch done = new CountDownLatch(1);
    RuntimeException err;
  }

  private static final class SecretsBuy {
    final CountDownLatch done = new CountDownLatch(1);
    String token;
    RuntimeException err;
  }

  // init is sync by feature contract: build the chain, never look anything
  // up here. (featureInit only calls it when the feature options say
  // active, so there is no active check to repeat.)
  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.liveopts = ctx.options == null ? new LinkedHashMap<>() : ctx.options;
    this.active = true;

    this.secretname = FeatureOptions.foptStr(options, "name", "apikey");
    this.cache = FeatureOptions.foptBool(options, "cache", true);

    Map<String, Object> xopts = FeatureOptions.foptMap(options, "exchange");
    if (FeatureOptions.foptBool(xopts, "active", false)) {
      SecretsExchange x = new SecretsExchange();
      x.path = FeatureOptions.foptStr(xopts, "path", "auth/token");
      x.method = FeatureOptions.foptStr(xopts, "method", "POST");
      x.request = FeatureOptions.foptStr(xopts, "request", "refresh_token");
      x.response = FeatureOptions.foptStr(xopts, "response", "access_token");
      x.retries = FeatureOptions.foptInt(xopts, "retries", 1);
      x.statuses = new ArrayList<>();
      List<Object> rawstatuses = FeatureOptions.foptList(xopts, "statuses");
      if (rawstatuses != null) {
        for (Object s : rawstatuses) {
          if (s instanceof Number) {
            x.statuses.add(((Number) s).intValue());
          }
        }
      }
      if (x.statuses.isEmpty()) {
        x.statuses.add(401);
      }
      this.exchange = x;
    }

    // The explicit credential, when set, is the first store in the chain.
    //
    // WHICH option that is depends on the exchange. Without one, the
    // secret being resolved IS the credential the transport sends, so
    // `apikey` is it. With one, the secret is a REFRESH token and `apikey`
    // means the opposite thing - an access token the caller already holds
    // - so the explicit seat belongs to `exchange.refresh`, and apikey is
    // left alone to serve as the starting access token (see resolveonce).
    String explicit = "";
    if (this.exchange == null) {
      Object raw = this.liveopts.get("apikey");
      explicit = raw instanceof String ? (String) raw : "";
    }
    else {
      explicit = FeatureOptions.foptStr(xopts, "refresh", "");
    }

    List<Object> specs = new ArrayList<>();

    if (!"".equals(explicit)) {
      String key = null;
      try {
        key = Sekreto.envkey(this.secretname, null);
      }
      catch (RuntimeException err) {
        // A malformed secret name: the chain refuses it at lookup with the
        // same message, so seating a store keyed by nothing helps nobody.
        key = null;
      }
      if (key != null) {
        Map<String, Object> values = new LinkedHashMap<>();
        values.put(key, explicit);
        Map<String, Object> spec = new LinkedHashMap<>();
        spec.put("kind", "memory");
        spec.put("name", "options");
        spec.put("values", values);
        specs.add(spec);
      }
    }

    List<Object> given = FeatureOptions.foptList(options, "providers");
    if (given != null) {
      // Verbatim: a spec map and a live Provider object are both what
      // sekreto's own constructor takes, and anything else it REFUSES
      // loudly - which is better than this feature dropping it in silence.
      specs.addAll(given);
    }

    // The plugin DEFINITIONS the model selected for this feature, emitted
    // by Config generically from the catalogue's active `plugin.def`
    // entries. Upstream sekreto's contract since the registry was retired:
    // a kind not passed in `plugins` is unknown to that Sekreto, so the
    // model's choice of plugin groups IS the SDK's provider vocabulary.
    List<Definition> plugs = new ArrayList<>();
    for (Object d : Config.featurePlugins(this.name)) {
      if (d instanceof Definition) {
        plugs.add((Definition) d);
      }
    }

    try {
      this.sek = new Sekreto(new Sekreto.Options()
          .providers(specs)
          .plugins(plugs)
          .cache(this.cache));
    }
    catch (RuntimeException err) {
      // HELD, NOT RETURNED ON. The gate that reads initerr lives in the
      // transport wrapper installed below, so `return`ing here would leave
      // the wrapper uninstalled and the field unread by anything: a
      // misconfigured chain would then send an ordinary UNAUTHENTICATED
      // request, which is fail-OPEN and the exact opposite of what this
      // field exists for. Construction failure is the one path where the
      // seam matters MOST, so it is the one path that must not skip it.
      this.initerr = err;
    }

    // Wrap the transport: the fail-closed gate needs the seam whenever the
    // feature is active, and the exchange (when on) additionally needs to
    // SEE responses - expiry is only ever discovered from one, and this is
    // the one place a response can be seen and the request tried again.
    //
    // Installed unconditionally, INCLUDING after a construction failure
    // above: this wrapper is the only reader of initerr.
    final Utility.FetcherFn inner = ctx.utility.fetcher;
    ctx.utility.fetcher = (ctx2, url, fetchdef) -> transport(ctx2, url, fetchdef, inner);
  }

  /**
   * The LIVE Sekreto instance, for callers who want arbitrary secrets or
   * redaction:
   *
   * <pre>
   *   sdk.secrets().get("db.password")
   *   sdk.secrets().redact(logline)
   * </pre>
   *
   * <p>Never a clone: sekreto holds provider state (caches, vault leases)
   * that has to stay live to be worth anything.
   */
  public Sekreto sekreto() {
    return this.sek;
  }

  /**
   * The resolved credential ("" when none) - the state the transport
   * injects. Tests and callers read it here rather than from the options
   * map, which this feature never mutates.
   */
  public String credential() {
    synchronized (this.lock) {
      return this.cred;
    }
  }

  // transport wraps whatever transport was current at init.
  private Object transport(Context ctx, String url, Map<String, Object> fetchdef,
      Utility.FetcherFn inner) {

    // Fail-closed, at the ONE seam every wire path crosses. Entity ops,
    // direct(), graphql() and the exchange retries all come through this
    // wrapper, so resolving HERE is what gives the raw paths - which run
    // no feature hooks at all - the same credential the entity pipeline
    // gets. resolve() is shared and cached: concurrent callers join the
    // in-flight attempt, a cached success is free, and with `cache: false`
    // the chain is asked once per REQUEST, which is that option's meaning.
    // A provider ERROR refuses the request WITH THE PROVIDER'S OWN error -
    // never an unauthenticated send.
    if (this.initerr != null) {
      throw this.initerr;
    }
    resolve();

    // Inject the resolved credential into THIS request's header. The
    // header was built by prepareAuth from the options apikey; the
    // chain-resolved value lives in feature state instead, so the wrapper
    // writes it here - same construction, same suppression rules - and the
    // shared options map stays untouched.
    String token = credential();
    if (!"".equals(token)) {
      reauth(fetchdef, token);
    }

    if (this.exchange == null) {
      return inner.fetch(ctx, url, fetchdef);
    }

    return withrefresh(ctx, url, fetchdef, inner);
  }

  // resolve runs one resolution, shared by every concurrent caller. A
  // settled HIT is kept only when caching is on (`cache: false` means every
  // resolve asks the chain again); a FAILURE is always cleared, so a
  // transient vault outage never poisons the client permanently - the next
  // operation asks the chain again.
  //
  // A MISS is cleared too, however caching is set. That rule is sekreto's,
  // not this feature's: `A miss is never cached: the next read asks again`,
  // in sekreto's own source. Keeping a settled miss here would override
  // that from the layer above, and a secret provisioned after startup - a
  // mounted file, a policy granted a minute late - would never be picked up
  // for the life of the client. `cache` is about caching a HIT; it was
  // never a promise to keep saying no.
  private void resolve() {
    SecretsCall call;
    boolean mine = false;

    synchronized (this.lock) {
      if (this.resolving != null) {
        call = this.resolving;
      }
      else {
        call = new SecretsCall();
        this.resolving = call;
        mine = true;
      }
    }

    if (!mine) {
      awaitLatch(call.done);
      if (call.err != null) {
        throw call.err;
      }
      return;
    }

    RuntimeException err = null;
    boolean hit = false;
    try {
      hit = resolveonce();
    }
    catch (RuntimeException e) {
      err = e;
    }

    synchronized (this.lock) {
      call.err = err;
      if (err != null || !this.cache || !hit) {
        this.resolving = null;
      }
    }
    call.done.countDown();

    if (err != null) {
      throw err;
    }
  }

  // resolveonce resolves once, reporting whether a credential came out of
  // it. That boolean is the whole of what resolve() needs to tell a
  // cacheable HIT from a miss it must not keep.
  private boolean resolveonce() {
    if (this.sek == null) {
      return false;
    }

    // tryget: null is a MISS (the chain had nothing), an exception is an
    // ERROR and propagates to the gate above.
    String found = this.sek.tryget(this.secretname);

    if (this.exchange == null) {
      synchronized (this.lock) {
        // An UNCACHED miss after an earlier hit is a revocation: the chain
        // now says no provider has the secret, so the resolved value must
        // not keep going out on the wire. (An explicit apikey OPTION is
        // never lost here - it seats FIRST in the chain as a memory
        // provider, so the chain HITS while one is set and this branch is
        // unreachable.)
        this.cred = found == null ? "" : found;
      }
      return found != null;
    }

    // Exchanging: what the chain resolved is the REFRESH token, kept for
    // every later purchase. A miss is not fatal here - an explicit
    // `apikey` may already hold a usable access token, and the API is what
    // gets to say whether it does.
    this.refresh = found == null ? "" : found;

    String apikey = credential();
    if ("".equals(apikey)) {
      // A starting access token supplied as the OPTION: read from the
      // frozen options map (no feature ever writes it).
      Object raw = this.liveopts.get("apikey");
      apikey = raw instanceof String ? (String) raw : "";
      synchronized (this.lock) {
        this.cred = apikey;
      }
    }

    if (!"".equals(apikey)) {
      // A starting access token was supplied. Spend it: if it is stale the
      // API answers with an expiry status and the transport wrapper buys
      // another, which is the same path expiry takes anyway.
      return true;
    }

    // `auth: null` is the documented way to send NO credential, and a
    // purchase is a credential-bearing call: the refresh token goes to the
    // token endpoint in the request body. withrefresh honours suppression
    // for the RETRY, but it runs after this - by then the refresh token has
    // already left the process, and no later check can call it back. The
    // suppression has to be honoured here, before the first purchase, or it
    // only ever half-held.
    if (this.liveopts.get("auth") == null) {
      return false;
    }

    buy();

    return true;
  }

  // withrefresh buys a token and tries the request again when the API says
  // the current one is spent.
  //
  // The retry rewrites the authorization header IN PLACE on the fetchdef,
  // because the header was built by the synchronous prepareAuth before this
  // request left, and it carries the token that just failed. Rebuilt the
  // way prepareAuth builds it, from the same options auth.prefix, so the
  // two cannot drift.
  private Object withrefresh(Context ctx, String url, Map<String, Object> fetchdef,
      Utility.FetcherFn inner) {

    // `auth: null` is the documented way to send NO credential, and
    // prepareAuth honours it by removing the header. A refusal of a
    // deliberately unauthenticated request is not an expired token and
    // cannot be fixed by buying one - retrying would transmit exactly the
    // credential the caller suppressed.
    if (this.liveopts.get("auth") == null) {
      return inner.fetch(ctx, url, fetchdef);
    }

    int max = this.exchange.retries;
    int attempt = 0;

    while (true) {
      // The credential THIS attempt goes out with, captured before it
      // leaves: it is what tells a stale refusal apart from a fresh one.
      String used = credential();

      Object res = inner.fetch(ctx, url, fetchdef);

      if (attempt >= max || !spent(res)) {
        return res;
      }

      // Another request may have bought a token while this one was in
      // flight. Concurrent expiries share the in-flight purchase, but
      // STAGGERED ones do not - so spend what is current before buying: a
      // second exchange for a token that is already fresh is wasted, and
      // on a provider that invalidates the previous credential on issuance
      // it breaks the first request's own retry.
      String current = credential();
      String token;

      if (!"".equals(current) && !current.equals(used)) {
        token = current;
      }
      else {
        try {
          token = buy();
        }
        catch (RuntimeException err) {
          // The purchase failed: answer with the API's own refusal rather
          // than this one. The caller asked for data, and the refusal is
          // the more useful of the two - the exchange error is a symptom.
          return res;
        }
      }

      reauth(fetchdef, token);

      attempt++;
    }
  }

  private boolean spent(Object res) {
    int status = FeatureOptions.fresStatus(res);
    if (0 > status) {
      return false;
    }
    for (int s : this.exchange.statuses) {
      if (s == status) {
        return true;
      }
    }
    return false;
  }

  private void reauth(Map<String, Object> fetchdef, String token) {
    if (fetchdef == null) {
      return;
    }
    Object headersRaw = fetchdef.get("headers");
    if (!(headersRaw instanceof Map)) {
      return;
    }
    Map<String, Object> headers = (Map<String, Object>) headersRaw;

    // Suppressed auth means NO header, the same answer prepareAuth gives.
    // Reached defensively - withrefresh does not retry at all when auth is
    // null - but this is the function that writes the credential, so it is
    // where the rule has to hold.
    //
    // The options map is FROZEN after construction (this feature never
    // writes it), so the raw read is safe on any thread.
    Object rawauth = this.liveopts.get("auth");
    if (!(rawauth instanceof Map)) {
      headers.remove("authorization");
      return;
    }

    Object prefixRaw = ((Map<String, Object>) rawauth).get("prefix");
    String prefix = prefixRaw instanceof String ? (String) prefixRaw : "";

    if ("".equals(prefix)) {
      headers.put("authorization", token);
    }
    else {
      headers.put("authorization", prefix + " " + token);
    }
  }

  // buy an access token with the refresh token. Concurrent callers share
  // the ONE in-flight purchase; the slot is cleared once settled, so the
  // next expiry buys a fresh token rather than replaying this result.
  private String buy() {
    // TEST MODE BUYS NOTHING. The test feature replaces the transport so
    // no request leaves the process; an exchange here would be the one HTTP
    // call it could not stop, and it would need a live token endpoint for a
    // suite whose whole point is not needing one. A deterministic,
    // obviously-fake token instead - the same answer makeOptions gives a
    // required server variable, for the same reason.
    if (!"live".equals(this.client.mode)) {
      String token = "test-" + this.exchange.response;
      synchronized (this.lock) {
        this.cred = token;
      }
      return token;
    }

    SecretsBuy b;
    boolean mine = false;

    synchronized (this.lock) {
      if (this.buying != null) {
        b = this.buying;
      }
      else {
        b = new SecretsBuy();
        this.buying = b;
        mine = true;
      }
    }

    if (!mine) {
      awaitLatch(b.done);
      if (b.err != null) {
        throw b.err;
      }
      return b.token;
    }

    String token = null;
    RuntimeException err = null;
    try {
      token = buyonce();
    }
    catch (RuntimeException e) {
      err = e;
    }

    synchronized (this.lock) {
      b.token = token;
      b.err = err;
      this.buying = null;
      if (err == null) {
        // Publish HERE, before the waiters wake: one writer, under the
        // lock - waiters consume the returned value.
        this.cred = token;
      }
    }
    b.done.countDown();

    if (err != null) {
      throw err;
    }
    return token;
  }

  private String buyonce() {
    SecretsExchange x = this.exchange;

    if ("".equals(this.refresh)) {
      throw new Sekreto.SekretoError(
          "secrets: no refresh token: the provider chain has no '"
          + this.secretname + "', and feature.secrets.exchange.refresh is unset");
    }

    Map<String, Object> opts = this.client.optionsMap();

    // The token endpoint is RELATIVE to the base, which already carries
    // whatever account or tenant segment the server URL declares.
    Object baseRaw = opts.get("base");
    String base = baseRaw instanceof String ? (String) baseRaw : "";
    while (base.endsWith("/")) {
      base = base.substring(0, base.length() - 1);
    }
    String path = x.path;
    while (path.startsWith("/")) {
      path = path.substring(1);
    }
    String url = base + "/" + path;

    Object sysRaw = opts.get("system");
    Object fetchRaw = sysRaw instanceof Map
        ? ((Map<String, Object>) sysRaw).get("fetch") : null;

    // The body is SERIALISED, never concatenated: a refresh token (or a
    // configured request-field name) carrying a quote, backslash or
    // newline must arrive as that literal value, not as malformed JSON.
    Map<String, Object> payload = new LinkedHashMap<>();
    payload.put(x.request, this.refresh);

    Map<String, Object> headers = new LinkedHashMap<>();
    headers.put("content-type", "application/json");

    Map<String, Object> fetchdef = new LinkedHashMap<>();
    fetchdef.put("method", x.method);
    fetchdef.put("headers", headers);
    fetchdef.put("body", Json.stringify(payload));

    // Deliberately NOT the SDK transport. The transport is what this
    // feature wraps, and sending the token request back through it would
    // recurse on the first expiry - and would route the exchange through
    // the test mock, which knows nothing about it.
    Object res;
    if (fetchRaw instanceof BiFunction) {
      res = ((BiFunction<String, Map<String, Object>, Object>) fetchRaw)
          .apply(url, fetchdef);
    }
    else {
      // No custom transport supplied - the ordinary case. makeOptions
      // leaves system.fetch unset, so the exchange gets its own raw HTTP
      // path: requiring a custom transport for the COMMON case would
      // reject every live token purchase before a request was made.
      res = rawExchangeFetch(url, fetchdef);
    }

    int status = FeatureOptions.fresStatus(res);
    if (200 > status || 300 <= status) {
      throw new Sekreto.SekretoError(
          "secrets: token exchange failed: " + status + " from " + url);
    }

    Object body = null;
    if (res instanceof Map) {
      Object jsonRaw = ((Map<String, Object>) res).get("json");
      if (jsonRaw instanceof Supplier) {
        body = ((Supplier<Object>) jsonRaw).get();
      }
      else {
        Object bodyRaw = ((Map<String, Object>) res).get("body");
        body = bodyRaw instanceof String ? Json.parse((String) bodyRaw) : bodyRaw;
      }
    }

    String token = "";
    if (body instanceof Map) {
      Object t = ((Map<String, Object>) body).get(x.response);
      token = t instanceof String ? (String) t : "";
    }

    if ("".equals(token)) {
      throw new Sekreto.SekretoError(
          "secrets: token exchange returned no '" + x.response + "' field from " + url);
    }

    return token;
  }

  // rawExchangeFetch is the token-exchange transport of last resort: plain
  // java.net.http, in the same result shape the system.fetch seam promises
  // ("status" + "json"). utility/Fetcher.defaultHttpFetch is
  // package-private in JAVAPACKAGE.utility and unreachable from here, and
  // reaching for it would put the exchange back on the SDK's own transport
  // stack - which is the thing this must not use.
  private static Map<String, Object> rawExchangeFetch(String fullurl,
      Map<String, Object> fetchdef) {

    Object methodRaw = fetchdef.get("method");
    String method = methodRaw instanceof String && !"".equals(methodRaw)
        ? (String) methodRaw : "POST";

    Object bodyRaw = fetchdef.get("body");
    String body = bodyRaw instanceof String ? (String) bodyRaw : "";

    HttpRequest.Builder reqb = HttpRequest.newBuilder(URI.create(fullurl))
        .method(method, "".equals(body)
            ? HttpRequest.BodyPublishers.noBody()
            : HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));

    Object headersRaw = fetchdef.get("headers");
    if (headersRaw instanceof Map) {
      for (Map.Entry<String, Object> h : ((Map<String, Object>) headersRaw).entrySet()) {
        if (h.getValue() instanceof String) {
          reqb.setHeader(h.getKey(), (String) h.getValue());
        }
      }
    }

    HttpResponse<String> resp;
    try {
      resp = HttpClient.newBuilder()
          .connectTimeout(Duration.ofSeconds(30))
          .build()
          .send(reqb.build(), HttpResponse.BodyHandlers.ofString());
    }
    catch (IOException | InterruptedException e) {
      if (e instanceof InterruptedException) {
        Thread.currentThread().interrupt();
      }
      throw new Sekreto.SekretoError(
          "secrets: token exchange transport failed: " + e.getMessage());
    }

    String text = resp.body() == null ? "" : resp.body();
    Object parsed;
    try {
      parsed = "".equals(text) ? null : Json.parse(text);
    }
    catch (RuntimeException e) {
      parsed = null;
    }
    final Object jsonBody = parsed;

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("status", resp.statusCode());
    out.put("headers", new LinkedHashMap<String, Object>());
    out.put("json", (Supplier<Object>) () -> jsonBody);
    out.put("body", text);
    return out;
  }

  private static void awaitLatch(CountDownLatch latch) {
    try {
      latch.await();
    }
    catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new Sekreto.SekretoError("secrets: interrupted while resolving");
    }
  }
}
