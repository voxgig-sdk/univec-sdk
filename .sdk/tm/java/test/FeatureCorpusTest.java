package JAVAPACKAGE.sdktest;

// Univec SDK feature corpus test
//
// Feature behaviour, driven by the SHARED corpus.
//
// The same route PrimaryUtilityTest takes for the utilities: language-neutral
// cases in .sdk/test/test.json, executed against THIS generated SDK. The
// feature is the ordinary class, built by the generated config, installed by
// the generated constructor, and driven by a real entity operation. Not a
// miniature of the pipeline - that is what FeatureHarness does, and a
// miniature can only be as right as the miniature.
//
// Everything in a case is data. The one piece java writes for itself is
// turning scripted responses into a fetcher, through the documented
// `utility.fetcher` override.

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.function.Supplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.junit.jupiter.api.Test;

import JAVAPACKAGE.core.Entity;
import JAVAPACKAGE.core.Feature;
import JAVAPACKAGE.core.UnivecSDK;
import JAVAPACKAGE.core.SdkError;
import JAVAPACKAGE.core.Utility;

@SuppressWarnings({"unchecked"})
public class FeatureCorpusTest {

  // Features with a corpus section. A name here with no section is a skip,
  // not a failure: an SDK generated without the feature has nothing to run.
  private static final List<String> FEATURE_CORPUS_NAMES = List.of("cost");

  // The standard operation names, in the order the runner prefers them.
  private static final List<String> FEATURE_CORPUS_OPS =
      List.of("load", "list", "create", "update", "remove");

  /** One discovered operation: the client accessor plus the entity method. */
  private static final class Op {
    final String key;
    final Method accessor;
    final Method call;

    Op(String key, Method accessor, Method call) {
      this.key = key;
      this.accessor = accessor;
      this.call = call;
    }
  }

  private static Map<String, Object> corpus() {
    return RunnerSupport.loadTestSpec();
  }

  /**
   * A scripted transport built from a case's `res` list. Responses are
   * consumed in order and the last one repeats, so a case that does not care
   * how many attempts happen need only declare one.
   *
   * <p>Returns the shape the real fetcher returns: the parsed body behind a
   * `json` supplier and `body` as the raw string. A script that only set
   * `body` would look like an empty result, which reads as a feature defect
   * rather than a mis-shaped script.
   */
  private static Utility.FetcherFn scriptedFetcher(Object resRaw) {
    List<Object> res = resRaw instanceof List ? (List<Object>) resRaw : List.of();
    int[] n = {-1};
    return (ctx, fullurl, fetchdef) -> {
      n[0]++;
      Map<String, Object> spec = new LinkedHashMap<>();
      if (!res.isEmpty()) {
        int i = n[0] >= res.size() ? res.size() - 1 : n[0];
        Object entry = res.get(i);
        if (entry instanceof Map) {
          spec = (Map<String, Object>) entry;
        }
      }

      if (Boolean.TRUE.equals(spec.get("throw"))) {
        throw new RuntimeException("scripted transport failure");
      }

      Object statusRaw = spec.get("status");
      int status = statusRaw instanceof Number ? ((Number) statusRaw).intValue() : 200;
      Object body = spec.get("body");
      final Object jsonBody = body == null ? new LinkedHashMap<String, Object>() : body;

      Map<String, Object> headers = new LinkedHashMap<>();
      if (spec.get("headers") instanceof Map) {
        headers.putAll((Map<String, Object>) spec.get("headers"));
      }

      Map<String, Object> out = new LinkedHashMap<>();
      out.put("status", status);
      out.put("statusText", status < 400 ? "OK" : "ERR");
      out.put("headers", headers);
      out.put("json", (Supplier<Object>) () -> jsonBody);
      out.put("body", RunnerSupport.jsonStr(jsonBody));
      return out;
    };
  }

  /**
   * Build a client the way a caller would.
   *
   * <p>The plain constructor, not testSDK: the `test` feature is
   * transport: 'base' and REPLACES the transport, so a client in test mode
   * would shadow the script.
   */
  private static UnivecSDK buildClient(Map<String, Object> kase) {
    Map<String, Object> utility = new LinkedHashMap<>();
    utility.put("fetcher", scriptedFetcher(kase.get("res")));

    Map<String, Object> opts = new LinkedHashMap<>();
    opts.put("utility", utility);
    if (kase.get("feature") != null) {
      opts.put("feature", kase.get("feature"));
    }
    return new UnivecSDK(opts);
  }

  /**
   * Every operation this SDK declares, in a stable order.
   *
   * <p>The corpus cannot name an entity - it is shared by SDKs with none in
   * common - so the runner finds them here. An entity accessor is a client
   * method taking one Map and returning something that answers getName().
   */
  private static List<Op> candidates(UnivecSDK client) {
    Map<String, Object[]> found = new TreeMap<>();

    for (Method m : client.getClass().getMethods()) {
      if (1 != m.getParameterCount() || !Map.class.isAssignableFrom(m.getParameterTypes()[0])) {
        continue;
      }
      if (!Entity.class.isAssignableFrom(m.getReturnType())) {
        continue;
      }
      Object ent;
      String entname;
      try {
        ent = m.invoke(client, new Object[] {null});
        entname = ((Entity) ent).getName();
      }
      catch (Exception e) {
        continue;
      }
      if (null == entname || entname.isEmpty()) {
        continue;
      }
      found.put(entname, new Object[] {m, ent});
    }

    List<Op> out = new ArrayList<>();
    for (Map.Entry<String, Object[]> e : found.entrySet()) {
      Method accessor = (Method) e.getValue()[0];
      Object ent = e.getValue()[1];
      for (String opname : FEATURE_CORPUS_OPS) {
        Method call;
        try {
          call = ent.getClass().getMethod(opname, Map.class, Map.class);
        }
        catch (NoSuchMethodException ex) {
          continue;
        }
        out.add(new Op(e.getKey() + "." + opname, accessor, call));
      }
    }

    // SAFE OPS FIRST — see the ts harness for the reasoning: the cache stores
    // only successful GETs, so an SDK whose first usable op is a `create`
    // (POST) can never satisfy "a hit served from cache costs nothing".
    java.util.Map<String, Integer> safe = java.util.Map.of("list", 0, "load", 1);
    out.sort(java.util.Comparator
        .<Op>comparingInt(o -> safe.getOrDefault(o.key.substring(o.key.indexOf('.') + 1), 2))
        .thenComparing(o -> o.key));
    return out;
  }

  private static Object invoke(UnivecSDK client, Op op, Map<String, Object> ctrl)
      throws Exception {
    Object ent = op.accessor.invoke(client, new Object[] {null});
    try {
      return op.call.invoke(ent, new LinkedHashMap<String, Object>(), ctrl);
    }
    catch (java.lang.reflect.InvocationTargetException ite) {
      // Unwrap: a reflective call reports the SDK's error as its cause, and a
      // case asserting an error code needs the error itself.
      Throwable cause = ite.getCause();
      if (cause instanceof Exception) {
        throw (Exception) cause;
      }
      throw ite;
    }
  }

  /**
   * Pick operations by DRIVING them: an op is usable when it completes against
   * a plain 200 with no feature active. Declared operations are not all
   * callable with no arguments (a required path parameter, a body), and a case
   * failing for that reason would read as a feature defect.
   */
  private static List<Op> usableOps(int want) {
    List<Op> picked = new ArrayList<>();
    for (Op cand : candidates(buildClient(Map.of()))) {
      try {
        invoke(buildClient(Map.of()), cand, new LinkedHashMap<>());
      }
      catch (Exception e) {
        continue;
      }
      picked.add(cand);
      if (picked.size() >= want) {
        break;
      }
    }
    return picked;
  }

  /** Replace #OPn throughout a case, keys included. */
  private static Object resolve(Object node, Map<String, String> tokens) {
    if (node instanceof String) {
      String out = (String) node;
      for (Map.Entry<String, String> t : tokens.entrySet()) {
        out = out.replace(t.getKey(), t.getValue());
      }
      return out;
    }
    if (node instanceof List) {
      List<Object> out = new ArrayList<>();
      for (Object n : (List<Object>) node) {
        out.add(resolve(n, tokens));
      }
      return out;
    }
    if (node instanceof Map) {
      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<String, Object> e : ((Map<String, Object>) node).entrySet()) {
        out.put((String) resolve(e.getKey(), tokens), resolve(e.getValue(), tokens));
      }
      return out;
    }
    return node;
  }

  /** The highest #OPn a case mentions. */
  private static int tokensUsed(Object kase) {
    Matcher m = Pattern.compile("#OP(\\d+)").matcher(RunnerSupport.jsonStr(kase));
    int max = 0;
    while (m.find()) {
      max = Math.max(max, Integer.parseInt(m.group(1)));
    }
    return max;
  }

  /**
   * One named member of the record, whether the record is a map or a POJO.
   *
   * <p>The aggregates are typed classes here and plain maps in the dynamic
   * donors, so the corpus - which knows only field names - reaches both
   * through a public field or a map key.
   */
  private static Object[] member(Object actual, String key) {
    if (null == actual) {
      return new Object[] {null, false};
    }
    if (actual instanceof Map) {
      Map<String, Object> m = (Map<String, Object>) actual;
      return m.containsKey(key)
          ? new Object[] {m.get(key), true}
          : new Object[] {null, false};
    }
    try {
      Field f = actual.getClass().getField(key);
      return new Object[] {f.get(actual), true};
    }
    catch (Exception e) {
      return new Object[] {null, false};
    }
  }

  /**
   * Assert that `actual` contains `expect`, recursively. Cases assert only the
   * fields they are about, so a full equality check would force every case to
   * restate the whole record.
   */
  private void subset(Object actual, Object expect, String path) {
    if (expect instanceof Map) {
      for (Map.Entry<String, Object> e : ((Map<String, Object>) expect).entrySet()) {
        Object[] got = member(actual, e.getKey());
        assertTrue((Boolean) got[1], path + "." + e.getKey() + ": no such member");
        subset(got[0], e.getValue(), path + "." + e.getKey());
      }
      return;
    }

    if (expect instanceof Boolean) {
      assertEquals(expect, actual, path);
      return;
    }

    if (expect instanceof Number) {
      assertTrue(actual instanceof Number, path + ": expected a number, got " + actual);
      // Money is float arithmetic; compare with a tolerance far below any
      // amount a case states.
      assertEquals(((Number) expect).doubleValue(), ((Number) actual).doubleValue(), 1e-9, path);
      return;
    }

    assertEquals(expect, actual, path);
  }

  /**
   * The feature's own record, found by NAME.
   *
   * <p>Named, not typed: a project that trimmed the feature has no such class,
   * and a runner that referred to one would not compile there.
   */
  private static Object record(UnivecSDK client, String name) {
    for (Feature f : client.features) {
      if (name.equals(f.getName())) {
        return f;
      }
    }
    return null;
  }

  @Test
  public void corpusCarriesAFeatureSection() {
    // A corpus with no `feature` section is a SKIP, not a failure. Each
    // project carries its OWN materialised copy of .sdk/test/test.json, so a
    // project scaffolded before the section existed legitimately has no cases
    // to run - and a hard assertion here turned that into a red suite in every
    // SDK on the fleet, for a corpus the project had simply not re-pulled yet.
    // The strict check belongs where the corpus is CONTROLLED: sdkgen's own
    // end-to-end lane supplies one and requires the cases to actually run.
    assumeTrue(null != corpus().get("feature"),
        "this project's test.json has no `feature` section - recompile the "
            + "corpus (create-sdkgen .sdk/test/feature/) to run these cases");
    assertNotNull(corpus().get("feature"));
  }

  // At least one operation, or every case below would skip and this suite
  // would report green having run nothing.
  @Test
  public void sdkHasAnOperationTheCorpusCanDrive() {
    assertTrue(0 < usableOps(2).size(),
        "no declared operation completed against a plain 200 - the corpus "
            + "cannot exercise a feature without one");
  }

  @Test
  public void featureCorpus() throws Exception {
    Map<String, Object> features =
        (Map<String, Object>) corpus().getOrDefault("feature", Map.of());

    // Skip rather than run vacuously: with no section this asserts nothing,
    // and a test that passes having checked nothing is the false green the
    // corpus exists to prevent.
    assumeTrue(!features.isEmpty(),
        "this project's test.json has no `feature` section - recompile the "
            + "corpus (create-sdkgen .sdk/test/feature/) to run these cases");

    for (String name : FEATURE_CORPUS_NAMES) {
      Object sectionRaw = features.get(name);
      if (!(sectionRaw instanceof Map)) {
        continue;
      }
      Map<String, Object> section = (Map<String, Object>) sectionRaw;

      Object basic = section.get("basic");
      List<Object> cases = basic instanceof Map
          ? (List<Object>) ((Map<String, Object>) basic).getOrDefault("set", List.of())
          : List.of();
      assertTrue(0 < cases.size(),
          "corpus section feature." + name + " ran ZERO cases - a renamed "
              + "section or an emptied fixture must fail loudly");

      // Probed by ACTIVATING it: the feature defaults to inactive, so an idle
      // client never builds it and its absence says nothing.
      UnivecSDK probe = buildClient(Map.of("feature",
          List.of(Map.of("name", name, "active", true))));
      if (null == record(probe, name)) {
        continue;
      }

      List<Op> ops = usableOps(2);
      Map<String, Op> byKey = new LinkedHashMap<>();
      for (Op o : ops) {
        byKey.put(o.key, o);
      }

      int ran = 0;
      for (Object rawCase : cases) {
        int need = tokensUsed(rawCase);
        if (need > ops.size()) {
          continue;
        }

        Map<String, String> tokens = new LinkedHashMap<>();
        for (int i = 0; i < need; i++) {
          tokens.put("#OP" + (i + 1), ops.get(i).key);
        }
        Map<String, Object> kase = (Map<String, Object>) resolve(rawCase, tokens);

        UnivecSDK client = buildClient(kase);
        String label = String.valueOf(kase.get("name"));

        List<Object> steps = kase.get("op") instanceof List
            ? (List<Object>) kase.get("op") : List.of();
        for (Object stepRaw : steps) {
          Map<String, Object> step = (Map<String, Object>) stepRaw;
          Op op = byKey.get(step.get("op"));
          assertNotNull(op, label + ": no operation " + step.get("op"));
          Map<String, Object> ctrl = step.get("ctrl") instanceof Map
              ? new LinkedHashMap<>((Map<String, Object>) step.get("ctrl"))
              : new LinkedHashMap<>();
          Object wanterr = step.get("err");

          try {
            invoke(client, op, ctrl);
            if (null != wanterr) {
              fail(label + ": " + step.get("op") + " was expected to fail, and did not");
            }
          }
          catch (org.opentest4j.AssertionFailedError e) {
            throw e;
          }
          catch (Exception err) {
            assertNotNull(wanterr,
                label + ": " + step.get("op") + " failed unexpectedly: " + err);
            if (wanterr instanceof String) {
              // The CODE, not the message: makeError prefixes and humanises
              // the text, so matching it would pass on any error that
              // happened to mention the word.
              String code = err instanceof SdkError ? ((SdkError) err).code : null;
              assertEquals(wanterr, code, label + ": wrong error code (" + err + ")");
            }
          }
        }

        subset(record(client, name), kase.get("out"), label + ": _" + name);
        ran++;
      }

      assertTrue(0 < ran, "every feature." + name + " case was skipped");
      // Say how many ran. A partial run is legitimate (an SDK with one
      // operation skips the cases needing two) but it should be visible
      // rather than inferred from a green tick.
      System.err.println(String.format(
          "feature.%s: ran %d of %d case(s) against %d operation(s)",
          name, ran, cases.size(), ops.size()));
    }
  }
}
