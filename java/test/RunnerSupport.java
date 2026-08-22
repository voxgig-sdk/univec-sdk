package voxgig.univecsdk.sdktest;

// Shared test-runner support: env overrides, sdk-test-control.json skips,
// the ../.sdk/test/test.json spec loader, and the runset/match engine whose
// matching logic mirrors js/test/runner.js (and the go runner_test.go).

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.function.Supplier;
import java.util.regex.Pattern;

import voxgig.univecsdk.core.Context;
import voxgig.univecsdk.core.Entity;
import voxgig.univecsdk.core.Helpers;
import voxgig.univecsdk.core.UnivecSDK;
import voxgig.univecsdk.core.Response;
import voxgig.univecsdk.core.Result;
import voxgig.univecsdk.core.SdkError;
import voxgig.univecsdk.core.Spec;
import voxgig.univecsdk.core.Utility;
import voxgig.univecsdk.utility.Json;
import voxgig.univecsdk.utility.struct.Struct;

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
    if ("TRUE".equals(getenv("UNIVEC_TEST_LIVE"))
        || "TRUE".equals(getenv("UNIVEC_TEST_OVERRIDE"))) {
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

    String explain = getenv("UNIVEC_TEST_EXPLAIN");
    if (explain != null && !explain.isEmpty()) {
      m.put("UNIVEC_TEST_EXPLAIN", explain);
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

  @FunctionalInterface
  public interface RunSubject {
    Object run(Map<String, Object> entry) throws Exception;
  }

  // runset drives a test.json entry set against a subject, mirroring the
  // matching semantics of the go/js runners. All entry failures are
  // reported together as one AssertionError.
  public static void runset(Map<String, Object> testspec, RunSubject subject) {
    if (testspec == null || !(testspec.get("set") instanceof List)) {
      return;
    }
    List<Object> set = (List<Object>) testspec.get("set");

    List<String> failures = new ArrayList<>();

    for (int i = 0; i < set.size(); i++) {
      Map<String, Object> entry = Helpers.toMapAny(set.get(i));
      if (entry == null) {
        continue;
      }

      String mark = entry.get("mark") == null ? "" : " (mark=" + entry.get("mark") + ")";

      Object result = null;
      Exception err = null;
      try {
        result = subject.run(entry);
      }
      catch (Exception e) {
        err = e;
      }

      Object expectedErr = entry.get("err");

      if (err != null) {
        if (expectedErr != null) {
          String errMsg = err.getMessage() == null ? String.valueOf(err) : err.getMessage();
          if (expectedErr instanceof String
              && !matchString((String) expectedErr, errMsg)) {
            failures.add("entry " + i + mark + ": error mismatch: got \"" + errMsg
                + "\", want contains \"" + expectedErr + "\"");
          }
          Map<String, Object> matchSpec = Helpers.toMapAny(entry.get("match"));
          if (matchSpec != null) {
            Map<String, Object> resultMap = new LinkedHashMap<>();
            resultMap.put("in", entry.get("in"));
            resultMap.put("out", jsonNormalize(result));
            Map<String, Object> errRec = new LinkedHashMap<>();
            errRec.put("message", errMsg);
            resultMap.put("err", errRec);
            matchDeep(failures, i, mark, matchSpec, resultMap, "");
          }
          continue;
        }
        failures.add("entry " + i + mark + ": unexpected error: " + err);
        continue;
      }

      if (expectedErr != null) {
        failures.add("entry " + i + mark + ": expected error containing \""
            + expectedErr + "\" but got result: " + jsonStr(result));
        continue;
      }

      boolean matched = false;
      Map<String, Object> matchSpec = Helpers.toMapAny(entry.get("match"));
      if (matchSpec != null) {
        Map<String, Object> resultMap = new LinkedHashMap<>();
        resultMap.put("in", entry.get("in"));
        resultMap.put("out", jsonNormalize(result));
        if (entry.get("args") != null) {
          resultMap.put("args", entry.get("args"));
        }
        else if (entry.get("in") != null) {
          List<Object> args = new ArrayList<>();
          args.add(entry.get("in"));
          resultMap.put("args", args);
        }
        if (entry.get("ctx") != null) {
          resultMap.put("ctx", entry.get("ctx"));
        }
        matchDeep(failures, i, mark, matchSpec, resultMap, "");
        matched = true;
      }

      Object expectedOut = entry.get("out");
      if (expectedOut == null && matched) {
        continue;
      }
      if (expectedOut != null) {
        Object normResult = jsonNormalize(result);
        Object normExpected = jsonNormalize(expectedOut);
        if (!Objects.equals(canon(normResult), canon(normExpected))) {
          failures.add("entry " + i + mark + ": output mismatch:\n  got:  "
              + jsonStr(normResult) + "\n  want: " + jsonStr(normExpected));
        }
      }
    }

    if (!failures.isEmpty()) {
      throw new AssertionError(String.join("\n", failures));
    }
  }

  public static Object jsonNormalize(Object val) {
    if (val == null) {
      return null;
    }
    try {
      return Json.parse(Struct.jsonify(val));
    }
    catch (RuntimeException e) {
      return val;
    }
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

  static void matchDeep(List<String> failures, int entryIdx, String mark,
      Object check, Object base, String path) {

    if (check == null) {
      return;
    }

    if (check instanceof Map) {
      for (Map.Entry<String, Object> e : ((Map<String, Object>) check).entrySet()) {
        String childPath = path + "." + e.getKey();
        Object baseVal = base instanceof Map
            ? ((Map<String, Object>) base).get(e.getKey()) : null;
        matchDeep(failures, entryIdx, mark, e.getValue(), baseVal, childPath);
      }
    }
    else if (check instanceof List) {
      List<Object> checkList = (List<Object>) check;
      for (int i = 0; i < checkList.size(); i++) {
        String childPath = path + "[" + i + "]";
        Object baseVal = null;
        if (base instanceof List && i < ((List<Object>) base).size()) {
          baseVal = ((List<Object>) base).get(i);
        }
        matchDeep(failures, entryIdx, mark, checkList.get(i), baseVal, childPath);
      }
    }
    else {
      if ("__EXISTS__".equals(check)) {
        if (base == null) {
          failures.add("entry " + entryIdx + mark + ": match " + path
              + ": expected value to exist but got null");
        }
        return;
      }
      if ("__UNDEF__".equals(check)) {
        if (base != null) {
          failures.add("entry " + entryIdx + mark + ": match " + path
              + ": expected null but got " + base);
        }
        return;
      }

      Object normCheck = jsonNormalize(check);
      Object normBase = jsonNormalize(base);

      if (!Objects.equals(canon(normCheck), canon(normBase))) {
        if (check instanceof String && !"".equals(check)) {
          String baseStr = Struct.stringify(base);
          if (matchString((String) check, baseStr)) {
            return;
          }
        }
        failures.add("entry " + entryIdx + mark + ": match " + path + ": got "
            + jsonStr(normBase) + ", want " + jsonStr(normCheck));
      }
    }
  }

  // matchString checks if val matches pattern. If pattern is /regex/, use
  // regex; otherwise do case-insensitive contains.
  public static boolean matchString(String pattern, String val) {
    if (pattern.length() >= 2 && pattern.startsWith("/") && pattern.endsWith("/")) {
      try {
        return Pattern.compile(pattern.substring(1, pattern.length() - 1))
            .matcher(val).find();
      }
      catch (RuntimeException e) {
        return false;
      }
    }
    return val.toLowerCase().contains(pattern.toLowerCase());
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
