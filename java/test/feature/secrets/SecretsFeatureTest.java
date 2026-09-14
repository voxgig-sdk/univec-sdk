// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
// the java port of tm/ts/test/feature/secrets/Secrets.test.ts and
// tm/go/test/feature/secrets/secrets_feature_test.go.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because SecretsFeature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic.
// With the feature inactive nothing changes at all. With it active and the
// option unset, the chain (memory, env, dotenv, a custom provider, a
// vault) supplies the credential instead.
//
// This file lives in the test `feature/` container on purpose: `target
// add` trims it, along with the feature source and the vendored library,
// for a project whose model does not select `secrets`.
//
// WHY A LIVE CLIENT, NEVER FeatureHarness. FeatureHarness builds its
// utility from client.getUtility(), which is Utility.copy() - a SNAPSHOT
// of the function fields. A harness-based suite would therefore wrap a
// fetcher the real client never consults, and every "nothing reached the
// wire" assertion would hold vacuously, on a healthy SDK carrying no
// secrets feature at all. An assertion that cannot fail pins no rule. So
// every case here builds a LIVE client with a recording `system.fetch` and
// counts what actually crossed the transport, and every fail-closed case
// carries a CONTROL leg - the same construction with a WORKING provider,
// which must reach that same transport exactly once - so that a zero means
// REFUSED rather than UNWIRED.
//
// The chain is driven from `memory` stores rather than `env`, because java
// cannot portably mutate its own environment: a memory store answers the
// same way through the same first-hit rule, and the store this suite has
// to tell apart from the options seat is named, not typed.

package voxgig.univecsdk.sdktest.feature.secrets;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.function.BooleanSupplier;
import java.util.function.Supplier;

import org.junit.jupiter.api.Test;

import voxgig.univecsdk.core.Config;
import voxgig.univecsdk.core.Feature;
import voxgig.univecsdk.core.UnivecSDK;
import voxgig.univecsdk.core.SdkEntity;
import voxgig.univecsdk.feature.SecretsFeature;
import voxgig.univecsdk.feature.secrets.plugin.Definition;
import voxgig.univecsdk.feature.secrets.sekreto.Provider;

@SuppressWarnings({"unchecked"})
public class SecretsFeatureTest {

  static final String BASE = "http://secrets.test/api";

  // ------------------------------------------------------------------
  // The recording transport: system.fetch for a LIVE client, scripting one
  // status per API call (the last repeating) and a token endpoint for the
  // exchange cases.

  static final class Call {
    final String url;
    final String auth;
    final boolean has;
    final String body;

    Call(String url, String auth, boolean has, String body) {
      this.url = url;
      this.auth = auth;
      this.has = has;
      this.body = body;
    }
  }

  static final class Wire implements BiFunction<String, Map<String, Object>, Object> {
    final List<Call> calls = Collections.synchronizedList(new ArrayList<>());
    List<Integer> apistatus = new ArrayList<>(List.of(200));
    List<String> tokens = new ArrayList<>(List.of("ACCESS01", "ACCESS02", "ACCESS03"));
    String tokenpath = "auth/token";
    String respfield = "access_token";
    int issued = 0;
    int apicalls = 0;

    @Override
    public synchronized Object apply(String url, Map<String, Object> fetchdef) {
      String auth = "";
      boolean has = false;
      Object headers = fetchdef == null ? null : fetchdef.get("headers");
      if (headers instanceof Map) {
        Map<String, Object> hm = (Map<String, Object>) headers;
        if (hm.containsKey("authorization")) {
          has = true;
          Object v = hm.get("authorization");
          auth = v instanceof String ? (String) v : "";
        }
      }
      Object bodyRaw = fetchdef == null ? null : fetchdef.get("body");
      calls.add(new Call(url, auth, has, bodyRaw instanceof String ? (String) bodyRaw : ""));

      if (url.endsWith("/" + tokenpath)) {
        String token = tokens.get(Math.min(issued, tokens.size() - 1));
        issued++;
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put(respfield, token);
        return response(200, payload);
      }

      int status = apistatus.get(Math.min(apicalls, apistatus.size() - 1));
      apicalls++;
      Map<String, Object> payload = new LinkedHashMap<>();
      payload.put("ok", status < 400);
      return response(status, payload);
    }

    static Map<String, Object> response(int status, Map<String, Object> payload) {
      final Object body = payload;
      Map<String, Object> out = new LinkedHashMap<>();
      out.put("status", status);
      out.put("statusText", "OK");
      out.put("headers", new LinkedHashMap<String, Object>());
      out.put("json", (Supplier<Object>) () -> body);
      return out;
    }

    // The calls that did NOT go to the token endpoint.
    List<Call> api() {
      List<Call> out = new ArrayList<>();
      synchronized (calls) {
        for (Call c : calls) {
          if (!c.url.endsWith("/" + tokenpath)) {
            out.add(c);
          }
        }
      }
      return out;
    }

    List<Call> token() {
      List<Call> out = new ArrayList<>();
      synchronized (calls) {
        for (Call c : calls) {
          if (c.url.endsWith("/" + tokenpath)) {
            out.add(c);
          }
        }
      }
      return out;
    }

    // What went out, for a failure message that names the leak rather than
    // just its count.
    String leak() {
      List<String> out = new ArrayList<>();
      for (Call c : api()) {
        out.add(c.url + " auth=" + (c.has ? "\"" + c.auth + "\"" : "<absent>"));
      }
      return String.join(", ", out);
    }
  }

  // ------------------------------------------------------------------
  // Support.

  // The Authorization header carries the SPEC's credential prefix, which a
  // TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
  // `Bearer <token>`, an apiKey scheme the raw token. So assert on the
  // CREDENTIAL and let the prefix be whatever this SDK's API declares -
  // pinning the whole header value passes only for a prefix-less API, and
  // this file ships to every project that selects the feature.
  static void credentialIs(String header, String token) {
    String got = header == null ? "" : header;
    assertTrue(got.equals(token) || got.endsWith(" " + token),
        "expected the authorization header to carry " + token + ", got: \"" + got + "\"");
  }

  static Map<String, Object> map(Object... kv) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int i = 0; i + 1 < kv.length; i += 2) {
      out.put((String) kv[i], kv[i + 1]);
    }
    return out;
  }

  // A LIVE client wired to the recording transport, with raw access
  // allowed. `allow.op` is named explicitly: a project that narrows the
  // default set would otherwise turn the raw cases into a false RED (the
  // control leg refused before it reached the transport), and the rule
  // under test lives at the transport, downstream of the allow gate either
  // way.
  static UnivecSDK liveClient(Wire wire, Map<String, Object> extra) {
    Map<String, Object> opts = map(
        "base", BASE,
        "allow", map("op", "direct,graphql,load,list"),
        "system", map("fetch", wire));
    if (extra != null) {
      opts.putAll(extra);
    }
    return withSecrets(opts, UnivecSDK::new);
  }

  // Construct the client, and ADOPT the feature through the `extend` seam
  // ONLY when the generated config did not already install it.
  //
  // When this SDK was generated with `secrets` model-ACTIVE the ordinary
  // factory path builds the instance, and adding a second through extend
  // would DOUBLE the feature: two transport wraps, two resolutions, and a
  // token purchase the assertions cannot account for. When the model
  // declares the feature but leaves it off, Config.makeFeature has no case
  // for it and extend is the only way in - which is what keeps this suite
  // meaningful in a tree that carries the source without switching it on.
  // (The go donor's withSecrets, same guard, same reason.)
  static UnivecSDK withSecrets(Map<String, Object> opts,
      java.util.function.Function<Map<String, Object>, UnivecSDK> build) {
    UnivecSDK client = build.apply(opts);
    if (featureOf(client) != null) {
      return client;
    }
    Map<String, Object> adopted = new LinkedHashMap<>(opts);
    adopted.put("extend", List.of(new SecretsFeature()));
    return build.apply(adopted);
  }

  // The secrets feature options: active, with the given provider chain.
  static Map<String, Object> secretsOpts(List<Object> providers, Object... extra) {
    Map<String, Object> fopts = map("active", true, "providers", providers);
    for (int i = 0; i + 1 < extra.length; i += 2) {
      fopts.put((String) extra[i], extra[i + 1]);
    }
    return map("feature", map("secrets", fopts));
  }

  // The live feature, dug back out of the client for assertions against
  // its Sekreto instance and its resolved credential.
  //
  // A null here is a real failure to REPORT, never a reason to skip - a
  // skipped fail-closed test is exactly the hole this suite exists to
  // close. withSecrets below has already tried both ways in.
  static SecretsFeature featureOf(UnivecSDK client) {
    for (Feature f : client.features) {
      if (f instanceof SecretsFeature) {
        return (SecretsFeature) f;
      }
    }
    return null;
  }

  static SecretsFeature requireFeature(UnivecSDK client) {
    SecretsFeature f = featureOf(client);
    assertNotNull(f, "the secrets feature is not installed on this client:"
        + " neither the generated config nor the `extend` seam produced one"
        + " (options.extend is dropped when the optspec does not declare it)");
    return f;
  }

  // driveEntityOpUntil performs real entity operations - the path that
  // runs the whole pipeline - until `stop` reports the observable state a
  // test is waiting for. Each op's own outcome is irrelevant (no seeded
  // data, a scripted response); an op the API does not define fails BEFORE
  // the transport, which is why several may need driving. Entity
  // accessors are found by SHAPE rather than by name, because this file is
  // a TEMPLATE and no project's entity names are known here.
  static void driveEntityOpUntil(UnivecSDK client, String what, BooleanSupplier stop) {
    for (Method m : client.getClass().getMethods()) {
      if (!SdkEntity.class.isAssignableFrom(m.getReturnType())) {
        continue;
      }
      if (1 != m.getParameterCount() || !Map.class.isAssignableFrom(m.getParameterTypes()[0])) {
        continue;
      }

      SdkEntity ent;
      try {
        ent = (SdkEntity) m.invoke(client, (Object) null);
      }
      catch (ReflectiveOperationException e) {
        continue;
      }
      if (ent == null) {
        continue;
      }

      for (int op = 0; op < 2; op++) {
        try {
          if (0 == op) {
            ent.list(null, null);
          }
          else {
            ent.load(map("id", "x"), null);
          }
        }
        catch (RuntimeException err) {
          lasterr.set(err);
        }

        if (stop.getAsBoolean()) {
          return;
        }
      }
    }

    fail("no entity operation " + what + " - nothing to assert on");
  }

  // The last error an entity op raised, for the fail-closed cases that
  // assert on the PROVIDER'S OWN message.
  static final ThreadLocal<RuntimeException> lasterr = new ThreadLocal<>();

  static void driveEntityOp(UnivecSDK client, Wire wire) {
    int before = wire.api().size();
    driveEntityOpUntil(client, "reached the transport", () -> before < wire.api().size());
  }

  // A sekreto Provider built in code: the interface is two methods, and a
  // null lookup is a MISS.
  static final class TestProvider implements Provider {
    final java.util.function.Function<String, String> fn;
    final List<String> asked = Collections.synchronizedList(new ArrayList<>());

    TestProvider(java.util.function.Function<String, String> fn) {
      this.fn = fn;
    }

    @Override
    public String lookup(String name) {
      asked.add(name);
      return fn.apply(name);
    }

    @Override
    public String describe() {
      return "custom:test";
    }
  }

  static final String BROKENMSG = "vault unreachable";

  static Provider brokenProvider() {
    return new TestProvider((name) -> {
      throw new IllegalStateException(BROKENMSG);
    });
  }

  static Provider workingProvider(String value) {
    return new TestProvider((name) -> "apikey".equals(name) ? value : null);
  }

  static Map<String, Object> memoryStore(String name, String key, String value) {
    return map("kind", "memory", "name", name, "values", map(key, value));
  }

  // ------------------------------------------------------------------
  // The feature-inactive baseline: bit-identical behaviour.

  @Test
  public void inactive_apikeyOptionBehavesExactlyAsBefore() {
    UnivecSDK client = UnivecSDK.testSDK(null, map(
        "apikey", "OPTKEY01",
        "feature", map("secrets", map("active", false))));

    Map<String, Object> fetchdef = client.prepare(map("path", "/"));
    Map<String, Object> headers = (Map<String, Object>) fetchdef.get("headers");
    credentialIs((String) headers.get("authorization"), "OPTKEY01");

    assertNull(featureOf(client),
        "the feature is switched off: it must not be installed");
  }

  @Test
  public void inactive_noApikeyMeansNoAuthorizationHeader() {
    UnivecSDK client = UnivecSDK.testSDK(null, map(
        "feature", map("secrets", map("active", false))));

    Map<String, Object> fetchdef = client.prepare(map("path", "/"));
    Map<String, Object> headers = (Map<String, Object>) fetchdef.get("headers");
    assertFalse(headers.containsKey("authorization"),
        "unexpected authorization header: " + headers.get("authorization"));
  }

  // ------------------------------------------------------------------
  // Active: the provider chain, driven through real entity operations.

  @Test
  public void active_apikeyOptionStillWinsOverTheChain() {
    Wire wire = new Wire();
    Map<String, Object> opts = secretsOpts(
        List.of(memoryStore("envlike", "APIKEY", "CHAINKEY01")));
    opts.put("apikey", "OPTKEY01");
    UnivecSDK client = liveClient(wire, opts);

    driveEntityOp(client, wire);
    credentialIs(wire.api().get(0).auth, "OPTKEY01");

    // The explicit option is a real store, not a special case: a directed
    // read names it like any other.
    assertEquals("OPTKEY01",
        requireFeature(client).sekreto().getfrom("options", "apikey"),
        "the explicit apikey must be a real `options` store in the chain");
  }

  @Test
  public void active_omittedApikeyDefersToTheChainAtTheTransportSeam() {
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(memoryStore("envlike", "APIKEY", "CHAINKEY02"))));

    // Before any op, nothing has been resolved.
    assertEquals("", client.optionsMap().get("apikey"),
        "the apikey resolved before any operation");

    driveEntityOp(client, wire);

    // Resolution happens AT THE TRANSPORT - the one seam every wire path
    // crosses - so the credential is ON THE WIRE, not merely resolved.
    // java holds it in FEATURE STATE and injects it there; the shared
    // options map is never mutated (it stays raced-read-safe for every
    // concurrent operation), so the state assertion reads the feature.
    credentialIs(wire.api().get(0).auth, "CHAINKEY02");
    assertEquals("CHAINKEY02", requireFeature(client).credential());
    assertEquals("", client.optionsMap().get("apikey"),
        "the shared options map must stay unwritten");
  }

  @Test
  public void active_customProviderObjectsAreAcceptedVerbatim() {
    Wire wire = new Wire();
    TestProvider provider = new TestProvider(
        (name) -> "apikey".equals(name) ? "CUSTOM01" : null);
    UnivecSDK client = liveClient(wire, secretsOpts(List.of(provider)));

    driveEntityOp(client, wire);
    credentialIs(wire.api().get(0).auth, "CUSTOM01");
    assertTrue(0 < provider.asked.size() && "apikey".equals(provider.asked.get(0)),
        "the custom provider was asked " + provider.asked + ", want [apikey ...]");
  }

  @Test
  public void active_aMissEverywhereLeavesTheHeaderOff() {
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(memoryStore("envlike", "SOMETHINGELSE", "x"))));

    driveEntityOp(client, wire);
    Call call = wire.api().get(0);
    assertFalse(call.has,
        "a chain MISS must fall through to an unauthenticated request,"
        + " got header \"" + call.auth + "\"");
  }

  // ------------------------------------------------------------------
  // FAIL CLOSED. sekreto's miss-vs-error invariant: a MISS falls through
  // to the next provider, an ERROR does not. A broken vault must never
  // degrade into an unauthenticated request.
  //
  // Each case proves its own counter FIRST, with the same construction and
  // a WORKING provider: one request must reach the recording transport
  // carrying the resolved credential. Only then does a zero from the
  // broken provider mean REFUSED rather than UNWIRED. And the failure is
  // matched on the PROVIDER'S OWN message, so an unrelated failure (a
  // missing route, a blocked op) cannot stand in for fail-closed.

  @Test
  public void active_aProviderErrorFailsTheEntityOpAndNothingReachesTheWire() {
    // CONTROL FIRST, so the zero below is known to be observable at all.
    Wire control = new Wire();
    UnivecSDK ok = liveClient(control,
        secretsOpts(List.of(workingProvider("RAWKEY01"))));
    driveEntityOp(ok, control);
    assertEquals(1, control.api().size(),
        "the control request never reached system.fetch, so this test cannot"
        + " observe a request going out at all");
    credentialIs(control.api().get(0).auth, "RAWKEY01");

    // THE RULE.
    Wire wire = new Wire();
    TestProvider broken = (TestProvider) brokenProvider();
    UnivecSDK client = liveClient(wire, secretsOpts(List.of(broken)));

    lasterr.set(null);
    driveEntityOpUntil(client, "consulted the chain", () -> 0 < broken.asked.size());

    assertEquals(0, wire.api().size(),
        "a request must not go out unauthenticated because a provider broke,"
        + " but one reached the transport: " + wire.leak());

    RuntimeException err = lasterr.get();
    assertNotNull(err, "the entity op must fail when the chain breaks");
    assertTrue(String.valueOf(err.getMessage()).contains(BROKENMSG),
        "the failure must carry the provider's own message (" + BROKENMSG
        + "), got: " + err.getMessage());
  }

  @Test
  public void active_aProviderErrorFailsDirectRatherThanSending() {
    // CONTROL FIRST.
    Wire control = new Wire();
    Map<String, Object> res = liveClient(control,
        secretsOpts(List.of(workingProvider("RAWKEY01"))))
        .direct(map("path", "/thing"));
    assertTrue(Boolean.TRUE.equals(res.get("ok")),
        "the control request failed: " + res.get("err"));
    assertEquals(1, control.api().size(),
        "the control request never reached system.fetch, so this test cannot"
        + " observe a request going out at all");
    credentialIs(control.api().get(0).auth, "RAWKEY01");

    // THE RULE. direct() runs NO feature hook at all: if resolution lived
    // only in a PreSpec hook this would send an unauthenticated request
    // and never notice.
    Wire wire = new Wire();
    Map<String, Object> out = liveClient(wire, secretsOpts(List.of(brokenProvider())))
        .direct(map("path", "/thing"));

    assertEquals(0, wire.api().size(),
        "a request must not go out unauthenticated because a provider broke,"
        + " but one reached the transport: " + wire.leak());
    assertFalse(Boolean.TRUE.equals(out.get("ok")),
        "a broken chain must refuse the raw path fail-closed");
    assertTrue(String.valueOf(errMessage(out)).contains(BROKENMSG),
        "the refusal must carry the provider's own message (" + BROKENMSG
        + "), got: " + errMessage(out));
  }

  @Test
  public void active_aProviderErrorFailsGraphqlRatherThanSending() {
    // CONTROL FIRST.
    Wire control = new Wire();
    Map<String, Object> res = liveClient(control,
        secretsOpts(List.of(workingProvider("RAWKEY01"))))
        .graphql("{ thing }", null, null);
    assertTrue(Boolean.TRUE.equals(res.get("ok")),
        "the control request failed: " + res.get("err"));
    assertEquals(1, control.api().size(),
        "the control request never reached system.fetch, so this test cannot"
        + " observe a request going out at all");
    credentialIs(control.api().get(0).auth, "RAWKEY01");

    // THE RULE.
    Wire wire = new Wire();
    Map<String, Object> out = liveClient(wire, secretsOpts(List.of(brokenProvider())))
        .graphql("{ thing }", null, null);

    assertEquals(0, wire.api().size(),
        "a graphql request must not go out unauthenticated,"
        + " but one reached the transport: " + wire.leak());
    assertFalse(Boolean.TRUE.equals(out.get("ok")),
        "a broken chain must refuse graphql fail-closed");
    assertTrue(String.valueOf(errMessage(out)).contains(BROKENMSG),
        "the refusal must carry the provider's own message (" + BROKENMSG
        + "), got: " + errMessage(out));
  }

  // ------------------------------------------------------------------
  // FAIL CLOSED ON A CONSTRUCTION FAILURE. The chain a project configures
  // can be wrong before a single lookup happens: a provider kind that does
  // not exist, or one whose plugin group the model did not select, and
  // sekreto's constructor refuses it. java's init() cannot fail the client
  // construction the way ts's throwing init does, so it HOLDS that error
  // and the transport gate refuses to send.
  //
  // That gate is worth exactly as much as the seam it lives behind: an
  // init() that returns early on the construction failure never installs
  // the wrapper, and a misconfigured chain then sends ordinary
  // UNAUTHENTICATED requests while the held error is read by nothing. The
  // three cases below are the three wire paths - the entity pipeline,
  // direct() and graphql() - each with its own CONTROL leg, so a zero
  // means REFUSED and not UNWIRED.

  // A provider kind sekreto has never heard of: its constructor throws
  // before this feature has a Sekreto at all.
  static final String UNKNOWNKIND = "unknown provider kind: nosuchkind";

  static List<Object> misconfiguredChain() {
    return List.of(map("kind", "nosuchkind", "name", "broken"));
  }

  static boolean saysUnknownKind(Object err) {
    String msg = err instanceof Throwable
        ? String.valueOf(((Throwable) err).getMessage()) : String.valueOf(err);
    return msg.contains(UNKNOWNKIND);
  }

  @Test
  public void active_aConstructionFailureFailsTheEntityOpAndNothingReachesTheWire() {
    // CONTROL FIRST, so the zero below is known to be observable at all.
    Wire control = new Wire();
    UnivecSDK ok = liveClient(control,
        secretsOpts(List.of(workingProvider("INITKEY01"))));
    driveEntityOp(ok, control);
    assertEquals(1, control.api().size(),
        "the control request never reached system.fetch, so this test cannot"
        + " observe a request going out at all");
    credentialIs(control.api().get(0).auth, "INITKEY01");

    // THE RULE.
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(misconfiguredChain()));

    // The feature must still be INSTALLED: a construction failure that
    // silently uninstalls the feature is the same fail-open by another
    // route, and nothing downstream would be gating anything.
    requireFeature(client);

    lasterr.set(null);
    // Stop on EITHER outcome - the refusal we want, or a request going out,
    // which is the failure this test exists to catch. Stopping only on the
    // refusal would report "nothing to assert on" for the leak.
    driveEntityOpUntil(client, "refused the operation or sent one",
        () -> 0 < wire.api().size() || saysUnknownKind(lasterr.get()));

    assertEquals(0, wire.api().size(),
        "a misconfigured chain sent an UNAUTHENTICATED request: " + wire.leak());

    RuntimeException err = lasterr.get();
    assertNotNull(err, "the entity op must fail when the chain cannot be built");
    assertTrue(saysUnknownKind(err),
        "the refusal must carry sekreto's own message (" + UNKNOWNKIND
        + "), got: " + err.getMessage());
  }

  @Test
  public void active_aConstructionFailureFailsDirectRatherThanSending() {
    // CONTROL FIRST.
    Wire control = new Wire();
    Map<String, Object> res = liveClient(control,
        secretsOpts(List.of(workingProvider("INITKEY01"))))
        .direct(map("path", "/thing"));
    assertTrue(Boolean.TRUE.equals(res.get("ok")),
        "the control request failed: " + res.get("err"));
    assertEquals(1, control.api().size(),
        "the control request never reached system.fetch, so this test cannot"
        + " observe a request going out at all");
    credentialIs(control.api().get(0).auth, "INITKEY01");

    // THE RULE. direct() runs no feature hook at all, so the ONLY thing
    // that can refuse it is the transport wrapper - the one init() skips
    // when it returns early on the construction failure.
    Wire wire = new Wire();
    Map<String, Object> out = liveClient(wire, secretsOpts(misconfiguredChain()))
        .direct(map("path", "/thing"));

    assertEquals(0, wire.api().size(),
        "a misconfigured chain sent an UNAUTHENTICATED direct request: " + wire.leak());
    assertFalse(Boolean.TRUE.equals(out.get("ok")),
        "a chain that could not be built must refuse the raw path fail-closed");
    assertTrue(saysUnknownKind(out.get("err")),
        "the refusal must carry sekreto's own message (" + UNKNOWNKIND
        + "), got: " + errMessage(out));
  }

  @Test
  public void active_aConstructionFailureFailsGraphqlRatherThanSending() {
    // CONTROL FIRST.
    Wire control = new Wire();
    Map<String, Object> res = liveClient(control,
        secretsOpts(List.of(workingProvider("INITKEY01"))))
        .graphql("{ thing }", null, null);
    assertTrue(Boolean.TRUE.equals(res.get("ok")),
        "the control request failed: " + res.get("err"));
    assertEquals(1, control.api().size(),
        "the control request never reached system.fetch, so this test cannot"
        + " observe a request going out at all");
    credentialIs(control.api().get(0).auth, "INITKEY01");

    // THE RULE.
    Wire wire = new Wire();
    Map<String, Object> out = liveClient(wire, secretsOpts(misconfiguredChain()))
        .graphql("{ thing }", null, null);

    assertEquals(0, wire.api().size(),
        "a misconfigured chain sent an UNAUTHENTICATED graphql request: " + wire.leak());
    assertFalse(Boolean.TRUE.equals(out.get("ok")),
        "a chain that could not be built must refuse graphql fail-closed");
    assertTrue(saysUnknownKind(out.get("err")),
        "the refusal must carry sekreto's own message (" + UNKNOWNKIND
        + "), got: " + errMessage(out));
  }

  static String errMessage(Map<String, Object> res) {
    Object err = res.get("err");
    if (err instanceof Throwable) {
      return String.valueOf(((Throwable) err).getMessage());
    }
    return String.valueOf(err);
  }

  // A failed resolution is never cached: holding it would mean a transient
  // vault outage poisoned the client permanently, every later operation
  // failing with the original error long after the vault recovered.
  @Test
  public void active_aProviderRecoversAfterATransientFailure() {
    final int[] calls = {0};
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(new TestProvider((name) -> {
          calls[0]++;
          if (1 == calls[0]) {
            throw new IllegalStateException(BROKENMSG);
          }
          return "RECOVERED01";
        }))));

    driveEntityOpUntil(client, "consulted the chain", () -> 0 < calls[0]);
    assertEquals(0, wire.api().size(), "the first op must not reach the wire");

    driveEntityOp(client, wire);
    credentialIs(wire.api().get(0).auth, "RECOVERED01");
  }

  // `cache: false` is documented as "every resolve asks the chain again".
  @Test
  public void active_cacheFalseAsksTheChainOnEveryRequest() {
    final int[] calls = {0};
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(new TestProvider((name) -> {
          calls[0]++;
          return "KEY" + calls[0];
        })),
        "cache", false));

    client.direct(map("path", "/one"));
    client.direct(map("path", "/two"));

    assertTrue(1 < calls[0],
        "the chain was asked once and cached, despite cache: false");
  }

  // With `cache: false`, a provider that answered once and then reports a
  // MISS (a revoked secret) must RETRACT the credential: the wire must
  // stop carrying it.
  @Test
  public void active_anUncachedMissRetractsTheCredential() {
    final boolean[] have = {true};
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(new TestProvider((name) -> have[0] ? "REVOCABLE01" : null)),
        "cache", false));

    client.direct(map("path", "/one"));
    credentialIs(wire.api().get(0).auth, "REVOCABLE01");

    have[0] = false;
    client.direct(map("path", "/two"));

    Call last = wire.api().get(wire.api().size() - 1);
    assertFalse(last.has && !"".equals(last.auth),
        "after the chain reports a miss the retracted credential must not go out;"
        + " the wire saw \"" + last.auth + "\"");
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
  public void active_aCachedMissIsReasked() {
    final boolean[] present = {false};
    final int[] calls = {0};
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(new TestProvider((name) -> {
          calls[0]++;
          return present[0] ? "LATEKEY01" : null;
        }))));

    client.direct(map("path", "/one"));
    Call first = wire.api().get(0);
    assertFalse(first.has && !"".equals(first.auth),
        "the chain has nothing yet, so no credential should go out");

    int asked = calls[0];
    assertTrue(0 < asked);

    // The secret is provisioned while the client is live.
    present[0] = true;
    client.direct(map("path", "/two"));

    credentialIs(wire.api().get(wire.api().size() - 1).auth, "LATEKEY01");
    assertTrue(asked < calls[0],
        "the MISS was cached: a secret that appears later can never be picked up");
  }

  // The other half of the same rule: a HIT is still cached by default, so
  // the fix above must not turn every request into a chain walk.
  @Test
  public void active_aCachedHitIsKept() {
    final int[] calls = {0};
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(new TestProvider((name) -> {
          calls[0]++;
          return "STABLEKEY01";
        }))));

    client.direct(map("path", "/one"));
    client.direct(map("path", "/two"));

    assertEquals(1, calls[0],
        "a hit must be cached under the default cache: true");
  }

  // `auth: null` - the documented way to disable auth outright, which
  // prepareAuth honours before it ever reads the apikey.
  //
  // This needs an explicit guard because struct nearly removed it in
  // silence: with a stored null read as "no value", the optspec default
  // fires and the suppression becomes "use default auth" - transmitting a
  // credential the caller explicitly asked not to send. makeOptions
  // captures suppliedness BEFORE validate and restores the null after it.
  @Test
  public void active_authNullSuppressesTheCredentialChainOrNoChain() {
    Wire wire = new Wire();
    Map<String, Object> opts = secretsOpts(
        List.of(memoryStore("envlike", "APIKEY", "CHAINKEY03")));
    opts.put("apikey", "OPTKEY01");
    opts.put("auth", null);
    UnivecSDK client = liveClient(wire, opts);

    client.direct(map("path", "/thing"));

    Call call = wire.api().get(0);
    assertFalse(call.has,
        "auth null must suppress the credential, got header \"" + call.auth + "\"");

    // The suppression survives option validation rather than being
    // replaced by the optspec's default auth map.
    Map<String, Object> optsmap = client.optionsMap();
    assertTrue(optsmap.containsKey("auth"), "options.auth must stay PRESENT");
    assertNull(optsmap.get("auth"), "options.auth must stay a present NULL");
  }

  @Test
  public void active_secretNameIsConfigurable() {
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(memoryStore("envlike", "API_TOKEN", "TOKKEY01")),
        "name", "api.token"));

    client.direct(map("path", "/thing"));
    credentialIs(wire.api().get(0).auth, "TOKKEY01");
  }

  @Test
  public void active_sekretoIsLiveForArbitrarySecretsAndRedaction() {
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(map("kind", "memory", "values", map("DB_PASSWORD", "dbpass01")))));

    SecretsFeature f = requireFeature(client);
    assertEquals("dbpass01", f.sekreto().get("db.password"));
    assertEquals("the password is [redacted], keep it safe",
        f.sekreto().redact("the password is dbpass01, keep it safe"));
  }

  // THE PROVIDER VOCABULARY IS NON-EMPTY.
  //
  // Upstream sekreto retired its self-registration registry: a kind not
  // passed in the `plugins` option is UNKNOWN to that Sekreto. So the
  // model's choice of plugin groups IS this SDK's provider vocabulary, and
  // the wiring that carries it - Config.featurePlugins, emitted from the
  // model's per-target `def` map - has exactly one observable failure:
  // every kind refused at runtime while every test that uses only built-in
  // kinds stays green.
  //
  // Conditional on the group being SELECTED, because this file ships to
  // projects that take the feature without the `vault` group. The probe is
  // Config's own declaration list rather than the class file's presence:
  // for a flat-container target the plugin sources are copied whether or
  // not a group is on, so a file on disk is not evidence that the model
  // asked for its kind.
  //
  // Not circular. featurePlugins saying `hashicorp` is DECLARED is the
  // precondition; what is asserted is that a chain NAMING that kind
  // actually builds - which is the failure this exists for: the
  // definitions generated but never threaded into Sekreto's `plugins`
  // option, so the SDK carries every plugin its model selected and refuses
  // every one of their kinds at runtime, while every test using only
  // built-in kinds stays green.
  @Test
  public void active_aSelectedPluginKindIsInTheSdkVocabulary() {
    boolean declared = false;
    for (Object d : Config.featurePlugins("secrets")) {
      if (d instanceof Definition && "hashicorp".equals(((Definition) d).name)) {
        declared = true;
      }
    }
    if (!declared) {
      // No vault group in this project's model: nothing to assert.
      return;
    }

    // Construction is where an unknown kind is REFUSED, so the Sekreto
    // being built at all IS the regression check. The memory store comes
    // FIRST so sekreto's first-hit rule answers from it and the vault is
    // never contacted - the kind has to be declarable, not reachable.
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(List.of(
        map("kind", "memory", "values", map("APIKEY", "VOCAB01")),
        map("kind", "hashicorp", "addr", "https://vault.test", "token", "x"))));

    Map<String, Object> res = client.direct(map("path", "/thing"));
    assertTrue(Boolean.TRUE.equals(res.get("ok")),
        "the chain naming a selected plugin kind must build: " + res.get("err"));
    credentialIs(wire.api().get(0).auth, "VOCAB01");
  }

  // ------------------------------------------------------------------
  // ACCESS-TOKEN EXCHANGE.
  //
  // What the chain resolves is a REFRESH token, which is POSTed to a token
  // endpoint for a short-lived ACCESS token; the access token is what the
  // Authorization header carries; and when the API answers 401 the client
  // buys another and tries the same request again, once.

  static Map<String, Object> exchangeOpts(Object... extra) {
    Map<String, Object> x = map("active", true);
    for (int i = 0; i + 1 < extra.length; i += 2) {
      x.put((String) extra[i], extra[i + 1]);
    }
    return secretsOpts(
        List.of(memoryStore("envlike", "REFRESH_TOKEN", "REFRESH01")),
        "name", "refresh_token",
        "exchange", x);
  }

  @Test
  public void exchange_refreshBuysAnAccessTokenAndASpentOneIsReboughtOnce() {
    Wire wire = new Wire();
    // First API call is refused, the retry succeeds.
    wire.apistatus = new ArrayList<>(List.of(401, 200));
    UnivecSDK client = liveClient(wire, exchangeOpts());

    Map<String, Object> res = client.direct(map("path", "/thing"));

    assertEquals(2, wire.token().size(),
        "expected the initial purchase plus exactly one rebuy");
    assertTrue(wire.token().get(0).body.contains("REFRESH01"),
        "the refresh token is sent in the request body, got: " + wire.token().get(0).body);
    assertTrue(wire.token().get(0).body.startsWith("{"),
        "the token request body must be JSON, got: " + wire.token().get(0).body);

    assertEquals(2, wire.api().size(), "expected the request to be retried exactly once");
    credentialIs(wire.api().get(0).auth, "ACCESS01");
    // The retry must carry the NEW token, not the spent one.
    credentialIs(wire.api().get(1).auth, "ACCESS02");

    assertTrue(Boolean.TRUE.equals(res.get("ok")),
        "the caller sees the successful retry: " + res.get("err"));
  }

  @Test
  public void exchange_reachesTheRawPathsAndOnePurchaseServesMany() {
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, exchangeOpts());

    client.direct(map("path", "/one"));
    client.graphql("{ two }", null, null);

    assertEquals(1, wire.token().size(), "a token still working must not be re-bought");
    assertEquals(2, wire.api().size());
    credentialIs(wire.api().get(0).auth, "ACCESS01");
    credentialIs(wire.api().get(1).auth, "ACCESS01");
  }

  @Test
  public void exchange_anExplicitRefreshWinsOverTheChain() {
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, exchangeOpts("refresh", "EXPLICIT01"));

    client.direct(map("path", "/thing"));

    assertTrue(wire.token().get(0).body.contains("EXPLICIT01"),
        "the explicit refresh must win: " + wire.token().get(0).body);
  }

  // The chain is empty AND no explicit refresh: an error, never an
  // unauthenticated call.
  @Test
  public void exchange_noRefreshAnywhereIsAnErrorNotAnUnauthenticatedCall() {
    Wire wire = new Wire();
    UnivecSDK client = liveClient(wire, secretsOpts(
        List.of(memoryStore("envlike", "NOTHING", "x")),
        "name", "refresh_token",
        "exchange", map("active", true)));

    Map<String, Object> res = client.direct(map("path", "/thing"));

    assertFalse(Boolean.TRUE.equals(res.get("ok")), "expected a failure");
    assertEquals(0, wire.api().size(),
        "a request must not go out unauthenticated because the chain was empty:"
        + " " + wire.leak());
  }

  @Test
  public void exchange_authNullSuppressesTheCredentialRefusalOrNot() {
    Wire wire = new Wire();
    wire.apistatus = new ArrayList<>(List.of(401));
    Map<String, Object> opts = exchangeOpts();
    opts.put("auth", null);
    UnivecSDK client = liveClient(wire, opts);

    client.direct(map("path", "/thing"));

    assertEquals(1, wire.api().size(), "a suppressed request must not be retried");
    assertFalse(wire.api().get(0).has,
        "no credential may be sent when auth is suppressed, got \""
        + wire.api().get(0).auth + "\"");

    // AND NO PURCHASE. resolve() runs before withrefresh's suppression
    // check, so the refresh token used to go to the token endpoint in a
    // request body even here. Stopping the retry does not unsend it, and
    // only the token endpoint can see this.
    assertEquals(0, wire.token().size(),
        "auth null suppressed the credential but the refresh token was still"
        + " POSTed to the exchange endpoint");
  }

  @Test
  public void exchange_testModeBuysNothingAndNeedsNoTokenEndpoint() {
    Wire wire = new Wire();
    Map<String, Object> opts = exchangeOpts();
    opts.put("base", BASE);
    opts.put("system", map("fetch", wire));
    UnivecSDK client = withSecrets(opts, (o) -> UnivecSDK.testSDK(null, o));

    driveEntityOpUntil(client, "resolved the fake token",
        () -> !"".equals(requireFeature(client).credential()));

    assertEquals(0, wire.calls.size(), "test mode must not do IO");
    // A deterministic placeholder, so offline suites need no configuration.
    assertEquals("test-access_token", requireFeature(client).credential());
  }
}
