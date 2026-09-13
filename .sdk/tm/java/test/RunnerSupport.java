package JAVAPACKAGE.sdktest;

// Shared test-runner SUPPORT (vendor-tag rollout): env overrides, the
// sdk-test-control.json skip machinery, live pacing, the
// ../.sdk/test/test.json spec loader, ctx/entity conversion helpers, and
// the canon/jsonStr comparison helpers the feature tests use. The corpus
// ENGINE that used to live beside them (runset/matchDeep/matchString) is
// retired: both corpora now run on the vendored omni runner through
// OmniResolver.java. The class name is unchanged so the emitted
// TestEntity/TestDirect call sites (RunnerSupport.skipReason,
// RunnerSupport.envOverride, ...) need no churn.

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Entity;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.UnivecSDK;
import JAVAPACKAGE.core.Response;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.SdkError;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.utility.Json;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
public final class RunnerSupport {

  private RunnerSupport() {}

  private static boolean envLocalLoaded = false;
  private static final Map<String, String> envLocal = new LinkedHashMap<>();

  private static Map<String, Object> cachedTestControl;
  private static Map<String, Object> cachedTestSpec;

  // loadEnvLocal reads ../.env.local (if present) into an overlay map
  // consulted by getenv(); real environment variables win.
  public static synchronized void loadEnvLocal() {
    if (envLocalLoaded) {
      return;
    }
    envLocalLoaded = true;
    try {
      String data = Files.readString(Path.of("..", ".env.local"));
      for (String line : data.split("\n")) {
        line = line.trim();
        if (line.isEmpty() || line.startsWith("#")) {
          continue;
        }
        int eq = line.indexOf('=');
        if (eq > 0) {
          envLocal.put(line.substring(0, eq).trim(), line.substring(eq + 1).trim());
        }
      }
    }
    catch (Exception e) {
      // absent .env.local is fine
    }
  }

  public static String getenv(String key) {
    String v = System.getenv(key);
    if (v != null && !v.isEmpty()) {
      return v;
    }
    return envLocal.get(key);
  }

  public static Map<String, Object> envOverride(Map<String, Object> m) {
    if ("TRUE".equals(getenv("PROJECTENV_TEST_LIVE"))
        || "TRUE".equals(getenv("PROJECTENV_TEST_OVERRIDE"))) {
      for (String key : new ArrayList<>(m.keySet())) {
        String envval = getenv(key);
        if (envval != null && !envval.isEmpty()) {
          envval = envval.trim();
          if (envval.startsWith("{")) {
            Object parsed = Json.parseOrNull(envval);
            if (parsed != null) {
              m.put(key, parsed);
              continue;
            }
          }
          m.put(key, envval);
        }
      }
    }

    String explain = getenv("PROJECTENV_TEST_EXPLAIN");
    if (explain != null && !explain.isEmpty()) {
      m.put("PROJECTENV_TEST_EXPLAIN", explain);
    }

    return m;
  }

  public static class EntityTestSetup {
    public UnivecSDK client;
    public Map<String, Object> data;
    public Map<String, Object> idmap;
    public Map<String, Object> env;
    public boolean explain;
    public boolean live;
    public boolean syntheticOnly;
    public long now;
  }

  // loadTestControl reads test/sdk-test-control.json; caches after first
  // read. Returns an empty-skip default if the file is missing or invalid
  // so tests never crash on a bad config.
  public static synchronized Map<String, Object> loadTestControl() {
    if (cachedTestControl != null) {
      return cachedTestControl;
    }
    Map<String, Object> def = (Map<String, Object>) Json.parse(
        "{\"version\":1,\"test\":{\"skip\":{"
        + "\"live\":{\"direct\":[],\"entityOp\":[]},"
        + "\"unit\":{\"direct\":[],\"entityOp\":[]}}}}");
    try {
      String data = Files.readString(Path.of("test", "sdk-test-control.json"));
      Object parsed = Json.parseOrNull(data);
      cachedTestControl = parsed instanceof Map ? (Map<String, Object>) parsed : def;
    }
    catch (Exception e) {
      cachedTestControl = def;
    }
    return cachedTestControl;
  }

  // skipReason checks sdk-test-control.json for a skip entry. Returns the
  // reason ("" when none given) or null when not skipped.
  public static String skipReason(String kind, String name, String mode) {
    Map<String, Object> ctrl = loadTestControl();
    Map<String, Object> test = Helpers.toMapAny(ctrl.get("test"));
    if (test == null) {
      return null;
    }
    Map<String, Object> skip = Helpers.toMapAny(test.get("skip"));
    if (skip == null) {
      return null;
    }
    Map<String, Object> modeMap = Helpers.toMapAny(skip.get(mode));
    if (modeMap == null) {
      return null;
    }
    Object itemsRaw = modeMap.get(kind);
    if (!(itemsRaw instanceof List)) {
      return null;
    }
    for (Object raw : (List<Object>) itemsRaw) {
      Map<String, Object> item = Helpers.toMapAny(raw);
      if (item == null) {
        continue;
      }
      String reason = item.get("reason") instanceof String
          ? (String) item.get("reason") : "";
      if ("direct".equals(kind) && name.equals(item.get("test"))) {
        return reason;
      }
      if ("entityOp".equals(kind)) {
        Object ent = item.get("entity");
        Object op = item.get("op");
        if (name.equals(ent + "." + op)) {
          return reason;
        }
      }
    }
    return null;
  }

  // liveClientOptions returns the extra SDK options every LIVE client is
  // constructed with, from sdk-test-control.json `test.client.options`.
  //
  // The generated live client knows two things: the base URL (from the
  // spec) and the credential (from the environment). Everything else about
  // how a particular API wants to be talked to - which features to switch
  // on, and with what settings - is a property of THAT API, known to the
  // project and to nothing in the toolchain.
  //
  // Merged UNDER the generated fields, so the suite's own base/apikey/server
  // values win: this ADDS to the live client, it does not redirect it.
  //
  // That contract is enforced HERE rather than left to each merge site: the
  // generated map only names a field when the model calls for one, so a
  // "base" in this block would face no competing value and would silently
  // redirect the whole suite - credential included - to another host.
  private static final List<String> LIVE_RESERVED = List.of(
      "base", "prefix", "suffix", "server", "apikey", "secret");

  public static Map<String, Object> liveClientOptions() {
    Map<String, Object> ctrl = loadTestControl();
    Map<String, Object> test = Helpers.toMapAny(ctrl.get("test"));
    if (test == null) {
      return new LinkedHashMap<>();
    }
    Map<String, Object> client = Helpers.toMapAny(test.get("client"));
    if (client == null) {
      return new LinkedHashMap<>();
    }
    Map<String, Object> opts = Helpers.toMapAny(client.get("options"));
    if (opts == null) {
      return new LinkedHashMap<>();
    }

    Map<String, Object> out = new LinkedHashMap<>();
    for (Map.Entry<String, Object> e : opts.entrySet()) {
      if (!LIVE_RESERVED.contains(e.getKey())) {
        out.put(e.getKey(), e.getValue());
      }
    }
    return out;
  }

  // liveDelayMs returns the configured per-test live delay in ms; default 500.
  public static int liveDelayMs() {
    Map<String, Object> ctrl = loadTestControl();
    Map<String, Object> test = Helpers.toMapAny(ctrl.get("test"));
    if (test == null) {
      return 500;
    }
    Map<String, Object> live = Helpers.toMapAny(test.get("live"));
    if (live == null) {
      return 500;
    }
    Object v = live.get("delayMs");
    if (v instanceof Number && ((Number) v).intValue() >= 0) {
      return ((Number) v).intValue();
    }
    return 500;
  }

  public static synchronized Map<String, Object> loadTestSpec() {
    if (cachedTestSpec != null) {
      return cachedTestSpec;
    }
    try {
      String data = Files.readString(Path.of("..", ".sdk", "test", "test.json"));
      cachedTestSpec = (Map<String, Object>) Json.parse(data);
    }
    catch (Exception e) {
      throw new AssertionError("Failed to load test.json: " + e.getMessage(), e);
    }
    return cachedTestSpec;
  }

  public static Map<String, Object> getSpec(Map<String, Object> spec, String... keys) {
    Object cur = spec;
    for (String key : keys) {
      if (cur instanceof Map) {
        cur = ((Map<String, Object>) cur).get(key);
      }
      else {
        return null;
      }
    }
    return Helpers.toMapAny(cur);
  }

  public static String jsonStr(Object val) {
    try {
      return Struct.jsonify(val);
    }
    catch (RuntimeException e) {
      return String.valueOf(val);
    }
  }

  // canon: numbers collapse to Long/Double, maps to sorted TreeMap, so
  // deep-equality ignores numeric-type and key-order differences.
  static Object canon(Object v) {
    if (v == null) {
      return null;
    }
    if (v instanceof Number) {
      double d = ((Number) v).doubleValue();
      if (Double.isFinite(d) && Math.floor(d) == d) {
        return (long) d;
      }
      return d;
    }
    if (v instanceof Boolean || v instanceof String) {
      return v;
    }
    if (v instanceof Map) {
      Map<String, Object> out = new TreeMap<>();
      for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) {
        out.put(Objects.toString(e.getKey(), ""), canon(e.getValue()));
      }
      return out;
    }
    if (v instanceof List) {
      List<Object> out = new ArrayList<>();
      for (Object x : (List<Object>) v) {
        out.add(canon(x));
      }
      return out;
    }
    return String.valueOf(v);
  }

  // makeCtxFromMap creates a Context from a JSON test entry's ctx or args map.
  public static Context makeCtxFromMap(Map<String, Object> ctxmap,
      UnivecSDK client, Utility utility) {

    if (ctxmap == null) {
      ctxmap = new LinkedHashMap<>();
    }

    Context ctx = new Context(ctxmap, null);

    if (client != null) {
      ctx.client = client;
      ctx.utility = utility;
    }
    if (ctx.options == null && client != null) {
      ctx.options = client.optionsMap();
    }

    // Handle spec from JSON map (Context expects Spec, but JSON gives map).
    Map<String, Object> specMap = Helpers.toMapAny(ctxmap.get("spec"));
    if (specMap != null) {
      ctx.spec = new Spec(specMap);
    }

    // Handle result from JSON map.
    Map<String, Object> resMap = Helpers.toMapAny(ctxmap.get("result"));
    if (resMap != null) {
      ctx.result = new Result(resMap);
      Map<String, Object> errMap = Helpers.toMapAny(resMap.get("err"));
      if (errMap != null && errMap.get("message") instanceof String) {
        ctx.result.err = new SdkError("", (String) errMap.get("message"), null);
      }
    }

    // Handle response from JSON map.
    Map<String, Object> respMap = Helpers.toMapAny(ctxmap.get("response"));
    if (respMap != null) {
      ctx.response = new Response(respMap);
      final Object body = respMap.get("body");
      if (body != null) {
        ctx.response.jsonFunc = (Supplier<Object>) () -> body;
      }
      Map<String, Object> headers = Helpers.toMapAny(respMap.get("headers"));
      if (headers != null) {
        Map<String, Object> lowerHeaders = new LinkedHashMap<>();
        for (Map.Entry<String, Object> h : headers.entrySet()) {
          lowerHeaders.put(h.getKey().toLowerCase(), h.getValue());
        }
        ctx.response.headers = lowerHeaders;
      }
    }

    return ctx;
  }

  public static void fixctx(Context ctx, UnivecSDK client) {
    if (ctx != null && ctx.client != null && ctx.options == null) {
      ctx.options = ctx.client.optionsMap();
    }
  }

  // errFromMap creates an error from a JSON map {"message": "...", "code": "..."}
  public static RuntimeException errFromMap(Map<String, Object> m) {
    if (m == null) {
      return null;
    }
    String msg = m.get("message") instanceof String ? (String) m.get("message") : "";
    if ("".equals(msg)) {
      return null;
    }
    String code = m.get("code") instanceof String ? (String) m.get("code") : "";
    return new SdkError(code, msg, null);
  }

  // entityListToData extracts data maps from a list of Entity objects.
  public static List<Object> entityListToData(List<Object> list) {
    List<Object> out = new ArrayList<>();
    if (list == null) {
      return out;
    }
    for (Object item : list) {
      if (item instanceof Entity) {
        Map<String, Object> dm = Helpers.toMapAny(((Entity) item).data());
        if (dm != null) {
          out.add(dm);
        }
      }
      else if (item instanceof Map) {
        out.add(item);
      }
    }
    return out;
  }
}
