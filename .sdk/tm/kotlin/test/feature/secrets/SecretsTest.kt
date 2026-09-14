package KOTLINPACKAGE.sdktest

// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
// the kotlin port of tm/ts/test/feature/secrets/Secrets.test.ts.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because SecretsFeature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic.
// With the feature inactive nothing changes at all. With it active and the
// option unset, the chain (a memory store, a custom provider, a vault)
// supplies the credential instead.
//
// This file lives in the test `feature/` container on purpose: `target add`
// trims it, along with the feature source and the vendored library, for a
// project whose model does not select `secrets`.
//
// THE CLIENT IS LIVE AND THE TRANSPORT IS THE THING COUNTED. Every wire
// assertion here runs against a real client whose `system.fetch` is the
// recorder - never `testSDK`, whose test feature REPLACES the fetcher with
// its own in-memory mock and would leave a `system.fetch` counter at zero
// for a healthy SDK carrying no secrets feature at all. An assertion that
// cannot fail pins no rule, so each fail-closed case additionally carries a
// CONTROL leg: the same construction with a WORKING provider must reach the
// same recorder exactly once, carrying the credential. Only then does a
// zero from the broken provider mean REFUSED rather than UNWIRED. And the
// refusal is matched on the PROVIDER'S OWN message, so an unrelated failure
// (a missing route, a blocked op) cannot stand in for fail-closed.
//
// The feature is CONSTRUCTED DIRECTLY and adopted through the `extend`
// option ONLY when the generated Config did not already install it, so
// these tests hold in any generated tree - and never double the feature
// (two transport wraps, two purchases) in one that did.
//
// NO ENVIRONMENT VARIABLES. The JVM has no supported way to set one for the
// current process, so the ts/go/js suites' `env` chains become `memory`
// chains and custom Provider objects here. The rule under test - the chain
// answers when the option does not - is identical either way.

import java.lang.reflect.Method
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.function.BiFunction
import java.util.function.Supplier

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assertions.fail
import org.junit.jupiter.api.Test

import KOTLINPACKAGE.core.Config
import KOTLINPACKAGE.core.UnivecSDK
import KOTLINPACKAGE.core.SdkEntity
import KOTLINPACKAGE.feature.SecretsFeature
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.ProviderSpec

@Suppress("UNCHECKED_CAST")
class SecretsTest {

  // -------------------------------------------------------------------
  // The recording transport: system.fetch for a LIVE client, scripting one
  // status per API call (the last repeating) and a token endpoint for the
  // exchange tests.

  class Call(
    val url: String,
    val auth: String,
    val hasAuth: Boolean,
    val body: String,
  )

  class Wire {
    private val lock = Object()
    private val recorded = mutableListOf<Call>()

    var apistatus: List<Int> = listOf(200)
    var tokens: List<String> = listOf("ACCESS01", "ACCESS02", "ACCESS03")
    var tokenpath: String = "auth/token"
    var respfield: String = "access_token"

    // A token endpoint that starts refusing after `tokenok` successful
    // purchases (0 refuses the first).
    var tokenok: Int = Int.MAX_VALUE

    private var issued = 0
    private var apicalls = 0

    // A java.util.function.BiFunction, not a bare kotlin lambda: that is the
    // shape utility/Fetcher.kt dispatches on, and a Function2 would be
    // silently ignored.
    val fetch: BiFunction<String, MutableMap<String, Any?>, Any?> =
      BiFunction { url, fetchdef -> serve(url, fetchdef) }

    private fun serve(url: String, fetchdef: MutableMap<String, Any?>): Any? {
      synchronized(lock) {
        // The header value is SNAPSHOT here, not referenced: the retry path
        // rewrites the same headers map in place, so a stored reference
        // would make every earlier record show the newest token.
        var auth = ""
        var hasAuth = false
        val headers = fetchdef["headers"]
        if (headers is Map<*, *>) {
          for (e in headers.entries) {
            if ("authorization".equals(e.key.toString(), ignoreCase = true)) {
              hasAuth = true
              auth = e.value?.toString() ?: ""
            }
          }
        }
        val body = fetchdef["body"]
        recorded.add(Call(url, auth, hasAuth, if (body is String) body else ""))

        if (url.endsWith("/$tokenpath")) {
          if (issued >= tokenok) {
            issued++
            return response(500, linkedMapOf<String, Any?>("error" to "nope"))
          }
          val token = tokens[minOf(issued, tokens.size - 1)]
          issued++
          return response(200, linkedMapOf<String, Any?>(respfield to token))
        }

        val status = apistatus[minOf(apicalls, apistatus.size - 1)]
        apicalls++
        return response(status, linkedMapOf<String, Any?>("ok" to (status < 400)))
      }
    }

    private fun response(status: Int, payload: Any?): MutableMap<String, Any?> =
      linkedMapOf(
        "status" to status,
        "statusText" to if (status < 400) "OK" else "ERR",
        "headers" to linkedMapOf<String, Any?>(),
        "json" to Supplier<Any?> { payload },
      )

    fun calls(): List<Call> = synchronized(lock) { recorded.toList() }

    /** The recorded calls that did NOT go to the token endpoint. */
    fun api(): List<Call> = calls().filter { !it.url.endsWith("/$tokenpath") }

    fun token(): List<Call> = calls().filter { it.url.endsWith("/$tokenpath") }

    /** What went out, for a message that names the leak rather than counting it. */
    fun wire(): String = calls().joinToString(", ") { it.url + " auth=" + it.auth }
  }

  // -------------------------------------------------------------------
  // Support.

  companion object {
    const val BASE = "http://secrets.test/api"
  }

  // A sekreto Provider built in code.
  class TestProvider(
    private val onlookup: (String) -> String?,
    private val label: String = "custom:test",
  ) : Provider {
    override fun lookup(name: String): String? = onlookup(name)
    override fun describe(): String = label
  }

  // The Authorization header carries the SPEC's credential prefix, which a
  // TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
  // `Bearer <token>`, an apiKey scheme the raw token. So assert on the
  // CREDENTIAL and let the prefix be whatever this SDK's API declares.
  private fun credentialIs(header: String?, token: String) {
    val got = header ?: ""
    assertTrue(got == token || got.endsWith(" $token"),
      "expected the authorization header to carry $token, got: \"$got\"")
  }

  private fun map(vararg pairs: Pair<String, Any?>): MutableMap<String, Any?> =
    linkedMapOf(*pairs)

  private fun secretsFeatureOf(client: UnivecSDK): SecretsFeature? =
    client.features.firstOrNull { it is SecretsFeature } as? SecretsFeature

  // Build the client, and ADOPT the feature via `extend` ONLY when the
  // generated Config did not already install it: when this SDK was generated
  // with `secrets` model-active, the ordinary factory path builds the
  // instance, and adding a second via extend would DOUBLE the feature - two
  // transport wraps, two resolutions, and a token purchase the assertions
  // cannot account for.
  private fun withSecrets(build: (Boolean) -> UnivecSDK): UnivecSDK {
    val client = build(false)
    if (null != secretsFeatureOf(client)) {
      return client
    }
    return build(true)
  }

  // A LIVE client carrying the secrets feature, wired to the recorder.
  private fun secretsClient(w: Wire, sdkopts: MutableMap<String, Any?>): UnivecSDK {
    val opts = map(
      "base" to BASE,
      "system" to map("fetch" to w.fetch),
    )
    opts.putAll(sdkopts)

    return withSecrets { extend ->
      val use = LinkedHashMap(opts)
      if (extend) {
        use["extend"] = mutableListOf<Any?>(SecretsFeature())
      }
      UnivecSDK(use)
    }
  }

  // The feature options block: one provider (a live Provider object, or a
  // declarative spec / plain map), plus any extra feature options.
  private fun chainOpts(
    provider: Any?,
    extra: MutableMap<String, Any?>? = null,
  ): MutableMap<String, Any?> {
    val fopts = map(
      "active" to true,
      "providers" to mutableListOf<Any?>(provider),
    )
    if (extra != null) {
      fopts.putAll(extra)
    }
    return map("secrets" to fopts)
  }

  private val BROKEN = TestProvider(
    { throw RuntimeException("vault unreachable") }, "broken:test")

  private fun working(value: String) =
    TestProvider({ name -> if ("apikey" == name) value else null }, "working:test")

  // -------------------------------------------------------------------
  // Driving real entity operations - which is what runs the whole pipeline
  // and reaches the transport. Entity accessors are discovered by SHAPE (one
  // Map argument, an SdkEntity return) rather than by name, because this
  // file is a TEMPLATE and no project's entity names are known here. An op
  // the API does not define fails BEFORE the transport, which is why several
  // may need driving.

  private fun accessors(client: UnivecSDK): List<Method> =
    client.javaClass.methods
      .filter {
        1 == it.parameterCount &&
          SdkEntity::class.java.isAssignableFrom(it.returnType) &&
          java.util.Map::class.java.isAssignableFrom(it.parameterTypes[0])
      }
      .sortedBy { it.name }

  // Drives ops until `stop` reports the observable state a test waits for,
  // and returns the last error an op raised (the operation's own outcome is
  // otherwise irrelevant: no seeded data, a scripted response). `stop` is
  // handed that last error too, so a fail-closed case can stop on EITHER
  // outcome - the refusal it wants, or a request going out, which is the
  // failure it exists to catch; stopping only on the refusal would report
  // "nothing to assert on" for the leak.
  private fun driveEntityOpUntil(
    client: UnivecSDK,
    what: String,
    stop: (Throwable?) -> Boolean,
  ): Throwable? {
    var last: Throwable? = null

    for (m in accessors(client)) {
      val ent = m.invoke(client, null) as? SdkEntity ?: continue

      for (op in listOf<(SdkEntity) -> Any?>(
        { it.list(null, null) },
        { it.load(null, null) },
      )) {
        try {
          op(ent)
        } catch (err: Throwable) {
          last = err
        }
        if (stop(last)) {
          return last
        }
      }
    }

    fail<Unit>("no entity operation $what - nothing to assert on")
    return last
  }

  private fun driveEntityOp(client: UnivecSDK, w: Wire): Throwable? {
    val before = w.api().size
    return driveEntityOpUntil(client, "reached the transport") { before < w.api().size }
  }

  private fun messageOf(err: Throwable?): String {
    var e = err
    val parts = mutableListOf<String>()
    while (null != e) {
      parts.add(e.message ?: e.toString())
      e = e.cause
    }
    return parts.joinToString(" <- ")
  }

  // ===================================================================
  // The feature-inactive baseline: bit-identical behaviour.

  @Test
  fun inactiveApikeyOptionBehavesExactlyAsBefore() {
    val client = UnivecSDK.testSDK(null, map("apikey" to "OPTKEY01"))
    val fetchdef = client.prepare(map("path" to "/"))
    val headers = fetchdef["headers"] as MutableMap<String, Any?>
    credentialIs(headers["authorization"] as? String, "OPTKEY01")

    // No runtime activation, no extend: the feature must not be installed,
    // whatever this project's model says.
    assertNull(secretsFeatureOf(client),
      "the feature must not install itself without feature.secrets.active")
  }

  @Test
  fun inactiveNoApikeyMeansNoAuthorizationHeader() {
    val client = UnivecSDK.testSDK(null, null)
    val fetchdef = client.prepare(map("path" to "/"))
    val headers = fetchdef["headers"] as MutableMap<String, Any?>
    assertFalse(headers.containsKey("authorization"),
      "unexpected authorization header: " + headers["authorization"])
  }

  // ===================================================================
  // Active: the provider chain, driven through real entity operations.

  @Test
  fun apikeyOptionStillWinsOverTheChain() {
    val w = Wire()
    val client = secretsClient(w, map(
      "apikey" to "OPTKEY01",
      "feature" to chainOpts(working("CHAINKEY01")),
    ))

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "OPTKEY01")

    // The explicit option is a real store, not a special case: a directed
    // read names it like any other.
    val sf = secretsFeatureOf(client)
    assertNotNull(sf, "the extend seam did not install the feature")
    assertEquals("OPTKEY01", sf!!.sekreto()!!.getfrom("options", "apikey"))
  }

  @Test
  fun anOmittedApikeyDefersToTheChainAtTheTransportSeam() {
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(working("CHAINKEY02")),
    ))

    // Before any op, nothing has been resolved.
    assertEquals("", secretsFeatureOf(client)!!.credential(),
      "the chain was consulted before any operation")

    driveEntityOp(client, w)

    // Resolution happens AT THE TRANSPORT - the one seam every wire path
    // crosses - so the credential is ON THE WIRE, not merely resolved.
    credentialIs(w.api()[0].auth, "CHAINKEY02")
    assertEquals("CHAINKEY02", secretsFeatureOf(client)!!.credential())

    // And the shared options map stays FROZEN: prepareAuth clones it on
    // every request, so a feature writing to it would race every concurrent
    // operation.
    assertEquals("", client.optionsMap()["apikey"],
      "the options map must stay unwritten after construction")
  }

  @Test
  fun anExplicitlyEmptyApikeyAlsoDefersToTheChain() {
    val w = Wire()
    val client = secretsClient(w, map(
      "apikey" to "",
      "feature" to chainOpts(working("CHAINKEY03")),
    ))

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "CHAINKEY03")
  }

  @Test
  fun customProviderObjectsAreAcceptedVerbatim() {
    val asked = mutableListOf<String>()
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(TestProvider({ name ->
        synchronized(asked) { asked.add(name) }
        "CUSTOM01"
      })),
    ))

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "CUSTOM01")
    assertTrue(asked.contains("apikey"),
      "the custom provider was asked $asked, want it to include apikey")
  }

  @Test
  fun typedProviderSpecsAreAcceptedVerbatim() {
    // The typed arm of the providers list: a ProviderSpec built in code
    // joins the chain without going through `specof`.
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(ProviderSpec(
        kind = "memory",
        values = mapOf("APIKEY" to "SPECKEY01"),
      )),
    ))

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "SPECKEY01")
  }

  @Test
  fun declarativeMemorySpecsAreAcceptedAsMaps() {
    // A chain given as plain maps (the shape a config file produces) is
    // turned into ProviderSpecs by sekreto's own `specof`.
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(map(
        "kind" to "memory",
        "values" to map("APIKEY" to "MAPKEY01"),
      )),
    ))

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "MAPKEY01")
  }

  @Test
  fun aMissEverywhereLeavesTheHeaderOff() {
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(TestProvider({ null }, "empty:test")),
    ))

    driveEntityOp(client, w)

    // A MISS falls through to an unauthenticated request - and leaves the
    // header ABSENT rather than empty, which is what prepareAuth does.
    assertFalse(w.api()[0].hasAuth,
      "a chain MISS must leave the header off, got \"" + w.api()[0].auth + "\"")
  }

  // A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
  // feature used to override from the layer above.
  //
  // DEFAULT caching here, which is the whole point: `cache: true` is about
  // holding a HIT, and keeping the settled resolution after a miss meant
  // the chain was never asked again for the life of the client. A secret
  // provisioned after startup (a mounted file, a vault policy granted a
  // minute late) was invisible forever, and the only workaround was giving
  // up hit caching entirely.
  @Test
  fun aCachedMissIsReasked() {
    var present = false
    var calls = 0
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(TestProvider({ _ ->
        synchronized(this) {
          calls++
          if (present) "LATEKEY01" else null
        }
      }, "late:test")),
    ))

    driveEntityOp(client, w)
    val first = w.api()[0]
    assertFalse(first.hasAuth && "" != first.auth,
      "the chain has nothing yet, so no credential should go out")

    val asked = synchronized(this) { calls }
    assertTrue(0 < asked)

    // The secret is provisioned while the client is live.
    synchronized(this) { present = true }

    driveEntityOp(client, w)
    credentialIs(w.api().last().auth, "LATEKEY01")

    assertTrue(asked < synchronized(this) { calls },
      "the MISS was cached: a secret that appears later can never be picked up")
  }

  // The other half of the same rule: a HIT is still cached by default, so
  // the fix above must not turn every request into a chain walk.
  @Test
  fun aCachedHitIsKept() {
    var calls = 0
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(TestProvider({ _ ->
        synchronized(this) { calls++ }
        "STABLEKEY01"
      }, "counting:test")),
    ))

    driveEntityOp(client, w)
    driveEntityOp(client, w)

    assertEquals(1, synchronized(this) { calls },
      "a hit must be cached under the default cache: true")
  }

  @Test
  fun authNullSuppressesTheCredentialChainOrNoChain() {
    val w = Wire()
    val client = secretsClient(w, map(
      "auth" to null,
      "apikey" to "OPTKEY01",
      "feature" to chainOpts(working("CHAINKEY04")),
    ))

    driveEntityOp(client, w)

    // Nothing on the wire, even though the chain would have resolved AND an
    // explicit apikey was given.
    assertFalse(w.api()[0].hasAuth,
      "auth null must suppress the credential, got \"" + w.api()[0].auth + "\"")

    // The suppression survives option validation rather than being replaced
    // by the optspec's default auth map.
    val opts = client.optionsMap()
    assertTrue(opts.containsKey("auth"), "options.auth must stay present")
    assertNull(opts["auth"], "options.auth must stay a null")
  }

  @Test
  fun secretNameIsConfigurable() {
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(
        map("kind" to "memory", "values" to map("API_TOKEN" to "TOKKEY01")),
        map("name" to "api.token")),
    ))

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "TOKKEY01")
  }

  @Test
  fun sekretoIsLiveForArbitrarySecretsAndRedaction() {
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(map(
        "kind" to "memory",
        "values" to map("DB_PASSWORD" to "dbpass01"),
      )),
    ))

    val secrets = secretsFeatureOf(client)!!.sekreto()!!
    assertEquals("dbpass01", secrets.get("db.password"))
    assertEquals("the password is [redacted], keep it safe",
      secrets.redact("the password is dbpass01, keep it safe"))
  }

  // THE PROVIDER VOCABULARY IS NON-EMPTY.
  //
  // The model's choice of plugin groups IS the SDK's provider vocabulary:
  // Config emits the selected definitions and the feature hands them to
  // Sekreto, which refuses at CONSTRUCTION any kind it was not given. A
  // feature that dropped them on the floor would carry every selected plugin
  // FILE and refuse every one of their kinds at runtime, while every test
  // using only built-in kinds stayed green.
  //
  // Conditional on this project selecting a group at all.
  @Test
  fun aSelectedPluginKindIsInTheSdkVocabulary() {
    val plugins = Config.featurePlugins("secrets")
    if (plugins.isEmpty()) {
      return
    }

    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(map(
        "kind" to "memory", "values" to map("APIKEY" to "VOCAB01"))),
    ))

    val catalog = secretsFeatureOf(client)!!.sekreto()!!.catalog
    for (d in plugins) {
      val kind = (d as? Map<String, Any?>)?.get("name") as? String
      assertNotNull(kind, "a selected plugin definition has no kind: $d")
      assertTrue(catalog.has(kind!!),
        "the model selected plugin kind '$kind' but the feature's Sekreto " +
          "does not know it - the definitions never reached the chain")
    }

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "VOCAB01")
  }

  // ===================================================================
  // FAIL CLOSED. sekreto's miss-vs-error invariant: a MISS falls through, an
  // ERROR does not. A broken vault must never degrade into an
  // unauthenticated request.

  @Test
  fun aProviderErrorFailsTheEntityOpAndNothingReachesTheWire() {
    // THE RULE, asserted first so a regression reports the leak itself.
    val w = Wire()
    val client = secretsClient(w, map("feature" to chainOpts(BROKEN)))

    // Stop on EITHER outcome - the refusal, or a request going out. Stopping
    // on the first op driven would report an op the API does not define
    // (which fails BEFORE the transport) as the provider's refusal.
    val err = driveEntityOpUntil(client, "refused the operation or sent one") {
      last -> 0 < w.api().size || messageOf(last).contains("vault unreachable")
    }

    assertEquals(0, w.api().size,
      "a request must not go out unauthenticated because a provider broke," +
        " but one reached the transport: " + w.wire())
    assertNotNull(err, "the operation must fail rather than proceed")
    assertTrue(messageOf(err).contains("vault unreachable"),
      "the failure must carry the PROVIDER'S own message, got: " + messageOf(err))

    // CONTROL, which makes that zero mean REFUSED rather than UNWIRED: the
    // same construction with a WORKING provider must reach the same
    // transport, once, carrying the credential.
    val control = Wire()
    val ok = secretsClient(control, map("feature" to chainOpts(working("RAWKEY01"))))
    driveEntityOp(ok, control)

    assertEquals(1, control.api().size,
      "the control operation did not reach system.fetch exactly once, so " +
        "this test cannot observe a request going out at all: " + control.wire())
    credentialIs(control.api()[0].auth, "RAWKEY01")
  }

  // THE RAW PATHS, which run NO feature hooks at all. If resolution lived in
  // the PreSpec hook these would send an unauthenticated request and never
  // notice; they are covered because the TRANSPORT is where resolution
  // happens.
  //
  // `allow.op` is named explicitly: a project that narrows the default set
  // would otherwise turn these into a false RED (the control leg refused
  // before it reached the transport).

  @Test
  fun directCarriesTheChainCredentialAndFailsClosed() {
    val w = Wire()
    val client = secretsClient(w, map(
      "allow" to map("op" to "direct,graphql"),
      "feature" to chainOpts(working("DIRECTKEY01")),
    ))

    val res = client.direct(map("path" to "/direct-probe"))
    assertEquals(true, res["ok"], "direct refused: " + res["err"])
    assertEquals(1, w.api().size, "expected one direct call on the wire: " + w.wire())
    credentialIs(w.api()[0].auth, "DIRECTKEY01")

    // And fail-closed holds for raw access too: a broken chain refuses the
    // direct call before anything reaches the wire, IN BAND.
    val broken = Wire()
    val bclient = secretsClient(broken, map(
      "allow" to map("op" to "direct,graphql"),
      "feature" to chainOpts(BROKEN),
    ))

    val bres = bclient.direct(map("path" to "/direct-probe"))
    assertEquals(0, broken.api().size,
      "a broken chain must not yield a raw request: " + broken.wire())
    assertEquals(false, bres["ok"], "a broken chain must refuse the raw path")
    assertTrue(messageOf(bres["err"] as? Throwable).contains("vault unreachable"),
      "direct must report the PROVIDER'S own refusal, got: " +
        messageOf(bres["err"] as? Throwable))
  }

  @Test
  fun graphqlCarriesTheChainCredentialAndFailsClosed() {
    val w = Wire()
    val client = secretsClient(w, map(
      "allow" to map("op" to "direct,graphql"),
      "feature" to chainOpts(working("GQLKEY01")),
    ))

    val res = client.graphql("{ thing }", null, null)
    assertEquals(true, res["ok"], "graphql refused: " + res["err"])
    assertEquals(1, w.api().size, "expected one graphql call on the wire: " + w.wire())
    credentialIs(w.api()[0].auth, "GQLKEY01")

    val broken = Wire()
    val bclient = secretsClient(broken, map(
      "allow" to map("op" to "direct,graphql"),
      "feature" to chainOpts(BROKEN),
    ))

    val bres = bclient.graphql("{ thing }", null, null)
    assertEquals(0, broken.api().size,
      "a broken chain must not yield a graphql request: " + broken.wire())
    assertEquals(false, bres["ok"], "a broken chain must refuse graphql")
    assertTrue(messageOf(bres["err"] as? Throwable).contains("vault unreachable"),
      "graphql must report the PROVIDER'S own refusal, got: " +
        messageOf(bres["err"] as? Throwable))
  }

  // ===================================================================
  // FAIL CLOSED ON A CONSTRUCTION FAILURE. The chain a project configures
  // can be wrong before a single lookup happens, and init() cannot fail the
  // client construction the way ts's throwing init does - so it HOLDS the
  // error (`initerr`) and the transport gate refuses to send.
  //
  // The entry pinned here is one the constructor refuses but init used to
  // never SHOW it: a bare kind name where a spec belongs. init's `when`
  // over the providers list had arms for a Provider, a ProviderSpec and a
  // Map, and no `else` - so the entry was silently DROPPED, the chain got
  // SHORTER rather than broken, and every request went out unauthenticated
  // while the gate had nothing to refuse. That is fail-open by omission,
  // and it survived every other case in this file because each of them
  // configures the chain correctly.
  //
  // Three cases for the three wire paths - the entity pipeline, direct()
  // and graphql() - each with its own CONTROL leg through the SAME live
  // transport, so a zero means REFUSED and not UNWIRED. The refusal is
  // matched on sekreto's OWN message, so an unrelated failure cannot
  // stand in for it.

  // A kind NAME where a provider or spec belongs - the natural slip for a
  // reader of the ts docs. sekreto's constructor refuses exactly this.
  private val MALFORMED: Any? = "hashicorp"
  private val NOTAPROVIDER = "not a provider or a provider spec"

  private fun saysNotAProvider(err: Any?): Boolean =
    (if (err is Throwable) messageOf(err) else err?.toString() ?: "")
      .contains(NOTAPROVIDER)

  @Test
  fun aMalformedProviderEntryFailsTheEntityOpAndNothingReachesTheWire() {
    // CONTROL FIRST, so the zero below is known to be observable at all.
    val control = Wire()
    val ok = secretsClient(control, map("feature" to chainOpts(working("INITKEY01"))))
    driveEntityOp(ok, control)
    assertEquals(1, control.api().size,
      "the control operation did not reach system.fetch exactly once, so " +
        "this test cannot observe a request going out at all: " + control.wire())
    credentialIs(control.api()[0].auth, "INITKEY01")

    // THE RULE.
    val w = Wire()
    val client = secretsClient(w, map("feature" to chainOpts(MALFORMED)))

    // The feature must still be INSTALLED: a construction failure that
    // silently uninstalled it would be the same fail-open by another route,
    // with nothing downstream gating anything.
    assertNotNull(secretsFeatureOf(client),
      "the secrets feature must stay installed on a construction failure")

    val err = driveEntityOpUntil(client, "refused the operation or sent one") {
      last -> 0 < w.api().size || saysNotAProvider(last)
    }

    assertEquals(0, w.api().size,
      "a malformed providers entry was DROPPED and the shortened chain sent " +
        "an UNAUTHENTICATED request: " + w.wire())
    assertNotNull(err, "the entity op must fail when the chain cannot be built")
    assertTrue(saysNotAProvider(err),
      "the refusal must carry sekreto's own message ($NOTAPROVIDER), got: " +
        messageOf(err))
  }

  @Test
  fun aMalformedProviderEntryFailsDirectRatherThanSending() {
    // CONTROL FIRST.
    val control = Wire()
    val res = secretsClient(control, map(
      "allow" to map("op" to "direct,graphql"),
      "feature" to chainOpts(working("INITKEY01")),
    )).direct(map("path" to "/thing"))
    assertEquals(true, res["ok"], "the control request failed: " + res["err"])
    assertEquals(1, control.api().size,
      "the control request did not reach system.fetch exactly once, so " +
        "this test cannot observe a request going out at all: " + control.wire())
    credentialIs(control.api()[0].auth, "INITKEY01")

    // THE RULE. direct() runs no feature hook at all, so the ONLY thing
    // that can refuse it is the transport gate.
    val w = Wire()
    val out = secretsClient(w, map(
      "allow" to map("op" to "direct,graphql"),
      "feature" to chainOpts(MALFORMED),
    )).direct(map("path" to "/thing"))

    assertEquals(0, w.api().size,
      "a malformed providers entry was DROPPED and the shortened chain sent " +
        "an UNAUTHENTICATED direct request: " + w.wire())
    assertEquals(false, out["ok"],
      "a chain that could not be built must refuse the raw path fail-closed")
    assertTrue(saysNotAProvider(out["err"]),
      "the refusal must carry sekreto's own message ($NOTAPROVIDER), got: " +
        messageOf(out["err"] as? Throwable))
  }

  @Test
  fun aMalformedProviderEntryFailsGraphqlRatherThanSending() {
    // CONTROL FIRST.
    val control = Wire()
    val res = secretsClient(control, map(
      "allow" to map("op" to "direct,graphql"),
      "feature" to chainOpts(working("INITKEY01")),
    )).graphql("{ thing }", null, null)
    assertEquals(true, res["ok"], "the control request failed: " + res["err"])
    assertEquals(1, control.api().size,
      "the control request did not reach system.fetch exactly once, so " +
        "this test cannot observe a request going out at all: " + control.wire())
    credentialIs(control.api()[0].auth, "INITKEY01")

    // THE RULE.
    val w = Wire()
    val out = secretsClient(w, map(
      "allow" to map("op" to "direct,graphql"),
      "feature" to chainOpts(MALFORMED),
    )).graphql("{ thing }", null, null)

    assertEquals(0, w.api().size,
      "a malformed providers entry was DROPPED and the shortened chain sent " +
        "an UNAUTHENTICATED graphql request: " + w.wire())
    assertEquals(false, out["ok"],
      "a chain that could not be built must refuse graphql fail-closed")
    assertTrue(saysNotAProvider(out["err"]),
      "the refusal must carry sekreto's own message ($NOTAPROVIDER), got: " +
        messageOf(out["err"] as? Throwable))
  }

  @Test
  fun aProviderRecoversAfterATransientFailure() {
    var calls = 0
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(TestProvider({ _ ->
        val n = synchronized(this) { ++calls }
        if (1 == n) {
          throw RuntimeException("vault unreachable")
        }
        "RECOVERED01"
      }, "flaky:test")),
    ))

    // A failed resolution is never cached, so the second op asks the chain
    // again and succeeds. Holding the failure would mean a transient vault
    // outage poisoned the client permanently.
    driveEntityOpUntil(client, "consulted the chain") { 0 < calls }
    assertEquals(0, w.api().size, "the first op must not reach the wire")

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "RECOVERED01")
  }

  @Test
  fun uncachedMissRetractsTheCredential() {
    var have = true
    val w = Wire()
    val client = secretsClient(w, map(
      "feature" to chainOpts(
        TestProvider({ _ -> if (synchronized(this) { have }) "REVOCABLE01" else null },
          "revocable:test"),
        map("cache" to false)),
    ))

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "REVOCABLE01")

    synchronized(this) { have = false }

    driveEntityOp(client, w)
    val last = w.api().last()
    assertFalse(last.hasAuth && "" != last.auth,
      "after the chain reports a miss the retracted credential must not go " +
        "out; the wire saw \"" + last.auth + "\"")
  }

  // A provider failure closes the transport gate; a later retry that
  // SUCCEEDS reopens it and every waiting operation goes out with the FRESH
  // credential - never the stale pre-failure header, and never nothing.
  @Test
  fun gateRecoveryLetsWaitingOperationsOutWithTheFreshCredential() {
    var mode = "fail"
    val release = CountDownLatch(1)
    val w = Wire()

    val client = secretsClient(w, map(
      "feature" to chainOpts(
        TestProvider({ _ ->
          val m = synchronized(this) { mode }
          if ("fail" == m) {
            throw RuntimeException("vault unreachable")
          }
          if ("slow" == m) {
            release.await(5, TimeUnit.SECONDS)
          }
          "FRESH01"
        }, "gate:test"),
        map("cache" to false)),
    ))

    // 1. The failure closes the gate: nothing reaches the wire. Stop on
    // EITHER outcome, so an op the API does not define (which fails before
    // the transport) is not mistaken for the gate's refusal.
    driveEntityOpUntil(client, "was refused by the gate or sent one") {
      last -> 0 < w.api().size || messageOf(last).contains("vault unreachable")
    }
    assertEquals(0, w.api().size,
      "a failed resolution must keep the wire silent, saw: " + w.wire())

    // 2. Recovery under concurrency: two operations race the slow retry;
    // both must come out carrying the fresh credential.
    synchronized(this) { mode = "slow" }

    // Each thread drives until SOMETHING reached the wire - its own op or
    // the other thread's - which is the state the assertion reads.
    val threads = (1..2).map {
      Thread { driveEntityOpUntil(client, "recovered") { 0 < w.api().size } }
    }
    threads.forEach { it.start() }
    Thread.sleep(50)
    release.countDown()
    threads.forEach { it.join(10000) }

    assertTrue(0 < w.api().size, "recovery must let the operations out")
    for (call in w.api()) {
      credentialIs(call.auth, "FRESH01")
    }
  }

  // ===================================================================
  // ACCESS-TOKEN EXCHANGE.
  //
  // What the chain resolves is a REFRESH token, which is POSTed to a token
  // endpoint for a short-lived ACCESS token; the access token is what the
  // Authorization header carries; and when the API answers 401 the client
  // buys another and tries the same request again, once.

  private fun exchangeClient(
    w: Wire,
    refresh: String,
    exchange: MutableMap<String, Any?>?,
    extra: MutableMap<String, Any?>?,
  ): UnivecSDK {
    val x = map("active" to true)
    if (exchange != null) {
      x.putAll(exchange)
    }

    val fopts = map(
      "active" to true,
      "name" to "refresh_token",
      "providers" to mutableListOf<Any?>(
        if ("" == refresh) TestProvider({ null }, "norefresh:test")
        else TestProvider(
          { name -> if ("refresh_token" == name) refresh else null }, "refresh:test")),
      "exchange" to x,
    )

    val opts = map("allow" to map("op" to "direct,graphql"), "feature" to map("secrets" to fopts))
    if (extra != null) {
      opts.putAll(extra)
    }
    return secretsClient(w, opts)
  }

  private fun bodyField(body: String, field: String): String? {
    val parsed = KOTLINPACKAGE.utility.Json.parse(body)
    return (parsed as? Map<String, Any?>)?.get(field) as? String
  }

  @Test
  fun theRefreshTokenBuysAnAccessTokenAndTheRequestCarriesIt() {
    val w = Wire()
    val client = exchangeClient(w, "REFRESH01", null, null)

    client.direct(map("path" to "/thing"))

    assertEquals(1, w.token().size, "expected exactly one token purchase")
    assertEquals("REFRESH01", bodyField(w.token()[0].body, "refresh_token"),
      "the refresh token is sent in the request field")
    assertEquals(1, w.api().size)
    credentialIs(w.api()[0].auth, "ACCESS01")
  }

  @Test
  fun theRefreshTokenIsMarshalledNotConcatenated() {
    // A refresh token carrying a quote, backslash or newline must arrive as
    // that literal value, not as malformed JSON.
    val tricky = "re\"fresh\\to\nken"
    val w = Wire()
    val client = exchangeClient(w, "", map("refresh" to tricky), null)

    client.direct(map("path" to "/thing"))

    assertEquals(1, w.token().size)
    assertEquals(tricky, bodyField(w.token()[0].body, "refresh_token"),
      "the refresh token must arrive as its literal value: " + w.token()[0].body)
  }

  @Test
  fun anExplicitExchangeRefreshWinsOverTheChain() {
    val w = Wire()
    val client = exchangeClient(w, "FROMCHAIN", map("refresh" to "EXPLICIT01"), null)

    client.direct(map("path" to "/thing"))
    assertEquals("EXPLICIT01", bodyField(w.token()[0].body, "refresh_token"))
  }

  @Test
  fun onePurchaseServesManyRequests() {
    val w = Wire()
    val client = exchangeClient(w, "REFRESH01", null, null)

    client.direct(map("path" to "/one"))
    client.direct(map("path" to "/two"))
    client.direct(map("path" to "/three"))

    assertEquals(1, w.token().size, "a token still working must not be re-bought")
    assertEquals(3, w.api().size)
  }

  @Test
  fun concurrentFirstRequestsShareOnePurchase() {
    val w = Wire()
    val client = exchangeClient(w, "REFRESH01", null, null)

    val threads = listOf("/a", "/b", "/c", "/d").map { p ->
      Thread { client.direct(map("path" to p)) }
    }
    threads.forEach { it.start() }
    threads.forEach { it.join(10000) }

    assertEquals(1, w.token().size,
      "four operations at once must not open four token requests")
    assertEquals(4, w.api().size)
  }

  @Test
  fun anExpiryBuysAnotherTokenAndRetriesTheSameRequest() {
    val w = Wire()
    w.apistatus = listOf(401, 200)
    val client = exchangeClient(w, "REFRESH01", null, null)

    val res = client.direct(map("path" to "/thing"))

    assertEquals(2, w.token().size, "expected a second token purchase")
    assertEquals(2, w.api().size, "expected the request to be retried")
    credentialIs(w.api()[0].auth, "ACCESS01")
    // The retry must carry the NEW token, not the spent one.
    credentialIs(w.api()[1].auth, "ACCESS02")
    assertEquals(true, res["ok"], "the caller sees the successful retry")
  }

  @Test
  fun theRetryHappensOnceNotInALoop() {
    val w = Wire()
    w.apistatus = listOf(401)
    val client = exchangeClient(w, "REFRESH01", null, null)

    client.direct(map("path" to "/thing"))

    assertEquals(2, w.api().size, "exactly one retry")
    assertEquals(2, w.token().size)
  }

  @Test
  fun aStatusOutsideExchangeStatusesIsNotAnExpiry() {
    val w = Wire()
    w.apistatus = listOf(403)
    val client = exchangeClient(w, "REFRESH01", null, null)

    client.direct(map("path" to "/thing"))

    assertEquals(1, w.api().size, "403 is not in the default statuses")
    assertEquals(1, w.token().size)
  }

  @Test
  fun exchangeStatusesIsConfigurable() {
    val w = Wire()
    w.apistatus = listOf(403, 200)
    val client = exchangeClient(w, "REFRESH01",
      map("statuses" to mutableListOf<Any?>(403)), null)

    client.direct(map("path" to "/thing"))
    assertEquals(2, w.api().size, "403 was declared an expiry")
  }

  @Test
  fun theRequestAndResponseFieldNamesAndPathAreConfigurable() {
    val w = Wire()
    w.tokenpath = "oauth/grant"
    w.respfield = "token"
    val client = exchangeClient(w, "REFRESH01", map(
      "path" to "oauth/grant",
      "request" to "grant",
      "response" to "token",
    ), null)

    client.direct(map("path" to "/thing"))

    assertEquals(1, w.token().size)
    assertTrue(w.token()[0].url.endsWith("/oauth/grant"),
      "the token endpoint is relative to base: " + w.token()[0].url)
    assertEquals("REFRESH01", bodyField(w.token()[0].body, "grant"))
    credentialIs(w.api()[0].auth, "ACCESS01")
  }

  @Test
  fun anExplicitApikeyIsSpentBeforeAnythingIsBought() {
    val w = Wire()
    val client = exchangeClient(w, "REFRESH01", null, map("apikey" to "HELDTOKEN01"))

    client.direct(map("path" to "/thing"))

    assertEquals(0, w.token().size, "nothing needed buying")
    credentialIs(w.api()[0].auth, "HELDTOKEN01")
  }

  @Test
  fun aHeldApikeyThatHasExpiredFallsThroughToTheExchange() {
    val w = Wire()
    w.apistatus = listOf(401, 200)
    val client = exchangeClient(w, "REFRESH01", null, map("apikey" to "STALETOKEN01"))

    client.direct(map("path" to "/thing"))

    credentialIs(w.api()[0].auth, "STALETOKEN01")
    credentialIs(w.api()[1].auth, "ACCESS01")
  }

  @Test
  fun noRefreshTokenAnywhereIsAnErrorNotAnUnauthenticatedCall() {
    val w = Wire()
    val client = exchangeClient(w, "", null, null)

    val res = client.direct(map("path" to "/thing"))

    assertEquals(false, res["ok"], "expected a failure, got: $res")
    assertEquals(0, w.api().size,
      "a request must not go out unauthenticated because the chain was " +
        "empty: " + w.wire())
    assertTrue(messageOf(res["err"] as? Throwable).contains("no refresh token"),
      "expected the no-refresh-token refusal, got: " +
        messageOf(res["err"] as? Throwable))
  }

  @Test
  fun aFailingTokenEndpointSurfacesTheApiRefusalNotASpin() {
    val w = Wire()
    w.apistatus = listOf(401)
    // The first purchase succeeds; the second (after the 401) does not.
    w.tokenok = 1
    val client = exchangeClient(w, "REFRESH01", null, null)

    val res = client.direct(map("path" to "/thing"))

    assertNotNull(res, "the caller got an answer rather than a hang")
    assertEquals(1, w.api().size, "no retry after a failed purchase")
    assertEquals(false, res["ok"], "the API's own 401 is what the caller sees")
  }

  @Test
  fun authNullSuppressesTheCredentialRefusalOrNot() {
    val w = Wire()
    w.apistatus = listOf(401)
    val client = exchangeClient(w, "REFRESH01", null, map("auth" to null))

    client.direct(map("path" to "/thing"))

    assertEquals(1, w.api().size, "a suppressed request must not be retried")
    assertFalse(w.api()[0].hasAuth,
      "no credential may be sent when auth is suppressed, got \"" +
        w.api()[0].auth + "\"")

    // AND NO PURCHASE. resolve() runs before withrefresh's suppression
    // check, so the refresh token used to go to the token endpoint in a
    // request body even here. Stopping the retry does not unsend it, and
    // only the token endpoint can see this.
    assertEquals(0, w.token().size,
      "auth null suppressed the credential but the refresh token was still " +
        "POSTed to the exchange endpoint")
  }

  @Test
  fun testModeBuysNothingAndNeedsNoTokenEndpoint() {
    val w = Wire()

    val client = withSecrets { extend ->
      val opts = map(
        "base" to BASE,
        "allow" to map("op" to "direct,graphql"),
        "system" to map("fetch" to w.fetch),
        "feature" to map("secrets" to map(
          "active" to true,
          "name" to "refresh_token",
          "providers" to mutableListOf<Any?>(TestProvider(
            { name -> if ("refresh_token" == name) "REFRESH01" else null })),
          "exchange" to map("active" to true),
        )),
      )
      if (extend) {
        opts["extend"] = mutableListOf<Any?>(SecretsFeature())
      }
      UnivecSDK.testSDK(null, opts)
    }

    client.direct(map("path" to "/thing"))

    assertEquals(0, w.calls().size, "test mode must not do IO: " + w.wire())
    // A deterministic placeholder, so offline suites need no configuration.
    assertEquals("test-access_token", secretsFeatureOf(client)!!.credential())
  }
}
